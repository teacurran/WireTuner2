import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// A presence frame for `user` whose server-filled session is `session`.
func presenceFrame(user: String, name: String, color: UInt32 = 2, session: UInt64) throws -> Wiretuner_Sync_V1_PresenceUpdate {
    var update = Wiretuner_Sync_V1_PresenceUpdate()
    update.user.userID = user
    update.user.displayName = name
    update.colorIndex = color
    update.state = .active
    update.session = session
    return update
}

/// One op salvage could not apply (the type has no public initialiser; it is Codable).
func droppedOp() -> SalvageReport.Dropped {
    let json = #"{"replica":1,"seq":2,"label":"Move","opIndex":0,"op":"SetFields","missingCounter":1,"missingReplica":2}"#
    return try! JSONDecoder().decode(SalvageReport.Dropped.self, from: Data(json.utf8))
}

/// A review holding the outbox with one entry for `node`.
func heldReview(_ node: OpID, kinds: Set<OverlapKind> = [.sameRegister], actions: [ReviewAction] = [.useMine, .useTheirs, .keepBoth],
                properties: [PropertyConflict] = [], mode: ReviewModel.Mode = .perObject) -> ReviewModel {
    var review = ReviewModel(recovered: SalvageReport(reason: .expired))
    review.mode = mode
    review.recovered = nil
    review.localOps = 3
    review.remoteOps = 2
    review.authors = [ReviewAuthor(replica: 77, name: "Priya", ops: 2)]
    review.entries = [ReviewEntry(node: node, kinds: kinds, properties: properties, authors: [77], actions: actions)]
    review.documentActions = mode == .readOnly ? [] : [.keepMerged, .saveCopy, .keepBranch]
    return review
}

@Suite(.serialized) @MainActor struct DocumentSessionTests {
    @Test func aStoredDocumentSyncsItsChangesAndStops() async throws {
        let directory = TestStores.directory()
        let connector = FakeSyncConnector()
        let handle = TestStores.handle(in: directory)
        let session = DocumentSession(document: handle, connector: connector, localUserID: "me")
        #expect(session.start() == session.start())
        await session.start().value
        #expect(connector.connections == 1 && session.client != nil)
        #expect(await eventually { session.status.state == .saved })
        #expect(session.status.details.lastSynced != nil)
        await handle.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        #expect(await eventually { await connector.server.head == 1 })
        #expect(await eventually { session.status.state == .saved })

        // A collaborator's frame names the replica its changes come from.
        let replica: UInt64 = 0xABCD
        try await connector.server.send(.with { $0.presenceUpdate = try presenceFrame(user: "u-priya", name: "Priya", session: replica) })
        #expect(await eventually { session.author(of: replica)?.name == "Priya" })
        #expect(await eventually { session.status.details.collaborators == ["Priya"] })
        #expect(session.author(of: session.localReplica ?? 0) == nil)

        // A remote change lands in the document.
        let other = DocumentOpener.memoryDocument()
        let change = try #require(await other.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5), transform: .identity, appearance: Appearances.standard)))
        await connector.server.accept(change, author: "Priya")
        #expect(await eventually { handle.state.store.exists(OpID(counter: change.startCounter, replica: change.replica)) })

        // Retry and sign-in reach the client; review is empty.
        session.perform(.retryNow)
        session.signedIn()
        #expect(!session.canReview && session.openReview() == nil)
        let work = try await session.localWork()
        #expect(work.changes.isEmpty && work.baseSeq == 0)
        #expect(try await session.remoteWork().isEmpty)
        try await session.resolveReview(.upload)

        await session.stop()
        #expect(connector.closes == 1 && session.client == nil && session.isStopped)
        await session.stop()
        handle.close()
    }

    @Test func aMemoryDocumentReportsSavedWithoutAConnection() async {
        let handle = DocumentHandle.memory(title: "Memory")
        let session = DocumentSession(document: handle, connector: FakeSyncConnector(), localUserID: "me")
        await session.start().value
        #expect(session.status.state == .saved && session.client == nil)
        let noConnector = DocumentSession(document: handle, connector: nil, localUserID: "me")
        await noConnector.start().value
        #expect(noConnector.status.state == .saved)
        session.perform(.retryNow)
        session.signedIn()
        let work = try? await session.localWork()
        #expect(work?.changes.isEmpty == true)
        #expect((try? await session.remoteWork())?.isEmpty == true)
        await session.stop()
    }

    @Test func aConnectorThatFailsIsAnError() async {
        let connector = FakeSyncConnector()
        connector.failure = SyncCallError(code: SyncCallError.unavailable, message: "no route")
        let handle = TestStores.handle(in: TestStores.directory())
        let session = DocumentSession(document: handle, connector: connector, localUserID: "me")
        await session.start().value
        guard case .error = session.status.state else {
            Issue.record("expected error, got \(session.status.state)")
            return
        }
        #expect(session.status.details.errorDetail != nil)
        await session.stop()
        handle.close()
    }

    @Test func eventsBecomeNotices() async throws {
        let handle = DocumentHandle.memory(title: "Events")
        let ids = await handle.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        let session = DocumentSession(document: handle, connector: nil, localUserID: "me")
        var notices: [String] = []
        let token = session.observe { notice in
            switch notice {
            case .reviewNeeded: notices.append("review")
            case .merged(let review): notices.append("merged:\(review.toast)")
            case .message(let text): notices.append(text)
            case .openReview: notices.append("open")
            case .document: notices.append("event")
            }
        }
        var signIns = 0, exports = 0
        session.onSignIn = { signIns += 1 }
        session.onExportPackage = { exports += 1 }
        let review = heldReview(ids[0].opID)
        var merged = review
        merged.mode = .readOnly
        session.handle(.merged(merged))
        #expect(session.lastMerge == merged && session.canReview)
        #expect(session.openReview() == merged)
        session.handle(.reviewNeeded(review))
        #expect(session.pendingReview == review)
        session.status.perform(.reviewMerge)
        session.status.perform(.signIn)
        session.status.perform(.exportPackage)
        #expect(signIns == 1 && exports == 1)
        session.handle(.salvaged(SalvageReport(reason: .expired, salvagedChanges: 1)))
        session.handle(.salvaged(SalvageReport(reason: .expired, salvagedChanges: 3, dropped: [
            droppedOp(),
        ])))
        session.handle(.salvaged(SalvageReport(reason: .oversized, salvagedChanges: 1)))
        session.handle(.salvaged(SalvageReport(reason: .oversized, salvagedChanges: 2, dropped: [droppedOp()])))
        session.handle(.changeDropped(seq: 4, message: "bad"))
        session.handle(.collectionPoint(seq: 1, timeMs: 0))
        session.handle(.collectionPoint(seq: 0, timeMs: 0))
        session.handle(.stateReplaced(serverSeq: 3))
        session.handle(.presence(.with { $0.participants = [try! presenceFrame(user: "u", name: "Tom", session: 9), Wiretuner_Sync_V1_PresenceUpdate()] }))
        session.handle(.stable(1))
        session.handle(.document(.with { $0.renamed = .with { $0.name = "R" } }))
        #expect(session.author(of: 9)?.name == "Tom")
        #expect(notices == [
            "merged:Merged 2 changes from Priya", "open", "review", "open", "Recovered 1 change from an expired session",
            "Recovered 3 changes from an expired session; 1 could not be applied",
            "A large change was split to send it", "2 large changes were split to send them; 1 could not be applied",
            "A change could not be synced and was left out; it is kept on this Mac", "event",
        ])
        session.stopObserving(token)
        try await session.resolveReview(.upload)
        #expect(session.pendingReview == nil)
        // A rotation makes the new replica this client's own: its changes never pulse.
        session.handle(.replicaRotated(from: 1, to: 9))
        #expect(session.localReplica == 9 && session.author(of: 9) == nil)
        await handle.settle()
    }
}

@Suite(.serialized) @MainActor struct DocumentSessionsTests {
    @Test func oneSessionPerDocumentAndBackgroundUploads() async {
        let sessions = DocumentSessions(connector: nil, localUserID: { "me" })
        var closed: [String] = []
        sessions.closeDocument = { closed.append($0.id) }
        var changes = 0
        let token = sessions.observe { changes += 1 }
        var signIns = 0, exports = 0
        sessions.onSignIn = { signIns += 1 }
        sessions.onExportPackage = { exports += 1 }
        let first = DocumentHandle.memory(title: "B")
        let second = DocumentHandle.memory(title: "A")
        let session = sessions.session(for: first)
        #expect(sessions.session(for: first) === session)
        session.onSignIn()
        session.onExportPackage()
        #expect(signIns == 1 && exports == 1)
        let other = sessions.session(for: second)
        await session.start().value
        await other.start().value
        sessions.signedIn()

        // A session still uploading keeps running after its window closes.
        session.status.update(.syncing(2))
        other.status.update(.offline(3))
        #expect(sessions.waitingDocuments.map(\.title) == ["A", "B"])
        #expect(sessions.waitingDocuments.map(\.detail) == ["3 changes waiting (offline)", "Syncing 2 changes"])
        await sessions.documentDidClose(first).value
        #expect(sessions.background[first.id] === session && closed.isEmpty)
        session.status.update(.syncing(1))
        session.status.update(.saved)
        #expect(await eventually { closed == [first.id] })
        #expect(sessions.background.isEmpty)

        // One that is done stops at once; one parked in the background is released for a window.
        other.status.update(.saved)
        await sessions.documentDidClose(second).value
        #expect(closed == [first.id, second.id])
        await sessions.documentDidClose(DocumentHandle.memory(title: "Never")).value
        #expect(closed.count == 3)

        let third = DocumentHandle.memory(title: "C")
        let parked = sessions.session(for: third)
        parked.status.update(.uploadingBlobs(1))
        await sessions.documentDidClose(third).value
        await sessions.release(third.id)
        #expect(sessions.background.isEmpty && closed.last == third.id)
        await sessions.release("unknown")
        #expect(changes > 0)
        sessions.stopObserving(token)

        let fourth = DocumentHandle.memory(title: "D")
        _ = sessions.session(for: fourth)
        await sessions.stopAll()
        #expect(sessions.sessions.isEmpty)
    }

    @Test func keepsUploadingOnlyWhileWorkGoesUp() {
        #expect(DocumentSessions.keepsUploading(.syncing(1)))
        #expect(DocumentSessions.keepsUploading(.uploadingBlobs(1)))
        #expect(DocumentSessions.keepsUploading(.uploadingBacklog(5)))
        #expect(DocumentSessions.keepsUploading(.offline(2)))
        #expect(!DocumentSessions.keepsUploading(.offline(0)))
        #expect(!DocumentSessions.keepsUploading(.needsReview))
        #expect(WaitingDocument(id: "a", title: "A", state: .offline(1)).detail == "1 change waiting (offline)")
        #expect(WaitingDocument(id: "a", title: "A", state: .uploadingBlobs(1)).detail == "1 image uploading")
        #expect(WaitingDocument(id: "a", title: "A", state: .uploadingBlobs(2)).detail == "2 images uploading")
        #expect(WaitingDocument(id: "a", title: "A", state: .uploadingBacklog(61)).detail == "Uploading backlog 61%")
    }

    @Test func syncStatesPresentThemselves() {
        #expect(SyncState.offline(1).hasWaitingWork && !SyncState.offline(0).hasWaitingWork && !SyncState.saved.hasWaitingWork)
        #expect(SyncState.readOnly(.roleInsufficient).hasWaitingWork && !SyncState.readOnly(.role).hasWaitingWork)
        #expect(SyncState.needsReview.needsAttention && !SyncState.saved.needsAttention)
        #expect(SyncState.offline(2).actions == [.retryNow] && SyncState.readOnly(.accessRemoved).actions == [.retryNow])
        #expect(SyncState.needsReview.actions == [.reviewMerge] && SyncState.needsSignIn.actions == [.signIn])
        #expect(SyncState.error("x").actions == [.retryNow, .exportPackage] && SyncState.saved.actions.isEmpty)
        #expect(SyncState.saved.readOnlyReason == nil)
        for reason in [ReadOnlyReason.role, .clientTooOld, .roleInsufficient, .accessRemoved] {
            #expect(SyncState.readOnly(reason).readOnlyReason?.isEmpty == false)
        }
        #expect(SyncAction.allCases.map(\.title) == ["Retry Now", "Review Merge…", "Sign In…", "Export a Package…"])
    }
}

@Suite(.serialized) @MainActor struct HeadlessUploadTests {
    @Test func storesWithWorkUploadBeforeAnyWindow() async throws {
        let directory = TestStores.directory()
        // One store with an unsent change, one clean, one held by a review, and a stray folder.
        let busy = try await LocalStore.open(documentID: "busy", at: directory.appending(components: "busy", "store.sqlite"))
        let document = await WTModel.Document(backend: busy)
        _ = try await document.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5), transform: .identity, appearance: Appearances.standard))
        await document.settle()
        try await busy.close()
        let clean = try await LocalStore.open(documentID: "clean", at: directory.appending(components: "clean", "store.sqlite"))
        try await clean.close()
        let held = try await LocalStore.open(documentID: "held", at: directory.appending(components: "held", "store.sqlite"))
        let heldDocument = await WTModel.Document(backend: held)
        _ = try await heldDocument.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5), transform: .identity, appearance: Appearances.standard))
        await heldDocument.settle()
        try await held.setReviewHold(LocalStore.ReviewHold(kind: .merge, baseSeq: 0))
        try await held.close()
        try FileManager.default.createDirectory(at: directory.appending(path: "stray"), withIntermediateDirectories: true)
        #expect(HeadlessUploads.storedDocuments(in: directory) == ["busy", "clean", "held"])
        #expect(HeadlessUploads.storedDocuments(in: directory.appending(path: "missing")).isEmpty)

        let connector = FakeSyncConnector()
        let sessions = DocumentSessions(connector: connector)
        let started = await HeadlessUploads.begin(in: directory, connector: connector, sessions: sessions) { "Title of \($0)" }
        #expect(started.map(\.documentID) == ["busy"])
        #expect(started.first?.title == "Title of busy")
        #expect(await eventually { await connector.server.head == 1 })
        #expect(await eventually { sessions.headless.isEmpty })
        #expect(started.first?.isStopped == true)
        await started.first?.stop()
        #expect(HeadlessUpload.isDone(.needsReview) && !HeadlessUpload.isDone(.syncing(1)))
        #expect(try HeadlessUploads.defaultDirectory().lastPathComponent == "Documents")

        // A store that cannot be opened is skipped; a closed store needs nothing.
        let broken = TestStores.directory()
        try FileManager.default.createDirectory(at: broken.appending(path: "bad"), withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: broken.appending(components: "bad", "store.sqlite"))
        #expect(await HeadlessUploads.begin(in: broken, connector: connector, sessions: sessions) { $0 }.isEmpty)
        let closed = try await LocalStore.open(documentID: "c", at: broken.appending(components: "c", "store.sqlite"))
        try await closed.close()
        #expect(await !HeadlessUploads.needsUpload(closed))
    }

    @Test func aWindowTakesOverAHeadlessUpload() async throws {
        let directory = TestStores.directory()
        let store = try await LocalStore.open(documentID: "doc", at: directory.appending(components: "doc", "store.sqlite"))
        let connector = FakeSyncConnector()
        let connection = try connector.connect(store: store, sink: store, presence: nil)
        let upload = HeadlessUpload(documentID: "doc", title: "Doc", store: store, connection: connection)
        let sessions = DocumentSessions(connector: connector)
        sessions.add(upload)
        #expect(sessions.waitingDocuments.map(\.title) == ["Doc"] || sessions.waitingDocuments.isEmpty)
        await sessions.release("doc")
        #expect(sessions.headless.isEmpty && upload.isStopped && connector.closes == 1)
    }
}

@Suite(.serialized) @MainActor struct QuitTests {
    @Test func quittingWithChangesWaiting() async {
        let sessions = DocumentSessions(connector: nil)
        var replies: [Bool] = []
        let warns = TestBox(true)
        let quit = QuitCoordinator(sessions: sessions, warns: { warns.value })
        quit.reply = { replies.append($0) }
        #expect(quit.shouldTerminate() == .terminateNow)
        let handle = DocumentHandle.memory(title: "Logo refresh")
        let session = sessions.session(for: handle)
        await session.start().value
        session.status.update(.offline(412))
        warns.value = false
        #expect(quit.shouldTerminate() == .terminateNow)
        warns.value = true
        #expect(quit.shouldTerminate() == .terminateLater)
        #expect(quit.shouldTerminate() == .terminateLater)
        #expect(quit.window?.identifier == QuitCoordinator.windowIdentifier)
        let model = try! #require(quit.model)
        #expect(model.headline == "1 document has changes that haven't reached the cloud yet.")
        let view = NSHostingView(rootView: QuitSheetView(model: model))
        view.layoutSubtreeIfNeeded()
        QuitSheetView.action(model, .quitNow)()
        #expect(replies == [true] && quit.model == nil)

        #expect(quit.shouldTerminate() == .terminateLater)
        quit.model?.choose(.cancel)
        #expect(replies == [true, false])

        #expect(quit.shouldTerminate() == .terminateLater)
        let waiting = try! #require(quit.model)
        waiting.choose(.quitWhenUploaded)
        #expect(waiting.isWaiting && replies.count == 2)
        NSHostingView(rootView: QuitSheetView(model: waiting)).layoutSubtreeIfNeeded()
        session.status.update(.syncing(1))
        session.status.update(.saved)
        #expect(replies == [true, false, true])
        let two = QuitSheetModel(documents: [WaitingDocument(id: "a", title: "A", state: .saved), WaitingDocument(id: "b", title: "B", state: .saved)])
        #expect(two.headline.hasPrefix("2 documents"))
        await sessions.stopAll()
    }
}

@Suite @MainActor struct SyncConnectorTests {
    @Test func tokensMapSignInFailures() async throws {
        let ok = AuthTokenProvider(valid: { "valid" }, refresh: { "fresh" })
        #expect(try await ok.accessToken(forceRefresh: false) == "valid")
        #expect(try await ok.accessToken(forceRefresh: true) == "fresh")
        let signedOut = AuthTokenProvider(valid: { throw AuthError.notSignedIn }, refresh: { throw AuthError.tokenEndpoint(code: "invalid_grant", description: nil) })
        await #expect(throws: TokenFailure.signInRequired) { try await signedOut.accessToken(forceRefresh: false) }
        await #expect(throws: TokenFailure.signInRequired) { try await signedOut.accessToken(forceRefresh: true) }
        let transient = AuthTokenProvider(valid: { throw AuthError.http(status: 503) }, refresh: { "x" })
        await #expect(throws: AuthError.http(status: 503)) { try await transient.accessToken(forceRefresh: false) }
        #expect(!AuthTokenProvider.requiresSignIn(.cancelled))
        let auth = AuthService(configuration: AuthConfiguration(infoDictionary: nil), store: InMemoryTokenStore(), authenticator: WebAuthenticationSession())
        let provider = AuthTokenProvider(auth: auth)
        await #expect(throws: TokenFailure.signInRequired) { try await provider.accessToken(forceRefresh: false) }
        await #expect(throws: TokenFailure.signInRequired) { try await provider.accessToken(forceRefresh: true) }
    }

    @Test func optionsReadThePreferences() {
        let suite = TestDefaults()
        let preferences = PreferenceStore(defaults: suite.defaults)
        preferences.set(7, for: PreferenceCatalog.Sync.askOverlapCount)
        preferences.set(true, for: PreferenceCatalog.Sync.alwaysAsk)
        preferences.set(40, for: PreferenceCatalog.Sync.undoLevels)
        let options = SyncClient.Options.from(preferences)
        let reconcile = options.reconcile()
        #expect(reconcile.askOverlapCount == 7 && reconcile.alwaysAsk && reconcile.askOverlapShare == 0.25)
        #expect(reconcile.suggestReviewAfter == .seconds(12 * 3600) && options.undoLevels == 40)
    }

    @Test func theGRPCConnectorMakesAClientPerStore() async throws {
        let store = try await LocalStore.open(documentID: "g", at: TestStores.directory().appending(components: "g", "store.sqlite"))
        let blobs = TestStores.directory()
        let connector = GRPCSyncConnector(
            api: URL(string: "http://127.0.0.1:9")!, identity: .init(clientVersion: "1/1", deviceID: "d"), tokens: StaticTokens(),
            blobDirectory: { blobs }
        )
        let connection = try connector.connect(store: store, sink: store, presence: nil)
        #expect(connection.client.documentID == "g")
        await connection.close()
        try await store.close()
        let launch = LaunchEnvironment(arguments: [], environment: [:])
        let suite = TestDefaults()
        let preferences = PreferenceStore(defaults: suite.defaults)
        let account = AccountModel(auth: AuthService(configuration: AuthConfiguration(infoDictionary: nil), store: InMemoryTokenStore(), authenticator: WebAuthenticationSession()),
                                   client: GRPCAccountClient(api: URL(string: "http://127.0.0.1:9")!, clientVersion: "1", deviceID: "d"),
                                   devices: GRPCTeamClient(api: URL(string: "http://127.0.0.1:9")!, clientVersion: "1", deviceID: "d"))
        #expect(launch.makeSyncConnector(account: account, infoDictionary: nil, defaults: suite.defaults, preferences: preferences) is GRPCSyncConnector)
        #expect(LaunchEnvironment(arguments: [LaunchEnvironment.uiTestingArgument], environment: [:])
            .makeSyncConnector(account: account, infoDictionary: nil, defaults: suite.defaults, preferences: preferences) == nil)
        #expect(launch.makeReviewWork(account: account, infoDictionary: nil, defaults: suite.defaults) is GRPCReviewWorkClient)
        #expect(LaunchEnvironment.clientVersion(["CFBundleShortVersionString": "2", "CFBundleVersion": "5"]) == "2/5")
        #expect(LaunchEnvironment.clientVersion(nil) == "0/0")
    }
}
