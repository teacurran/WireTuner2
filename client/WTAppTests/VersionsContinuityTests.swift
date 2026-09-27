import AppKit
import CoreSpotlight
import GRPCCore
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// Save Version (IO-003), Duplicate (IO-004), Spotlight (IO-035) and Handoff (IO-036).
/// A version server: names what it is sent, or refuses as told.
@MainActor
final class VersionTestServer {
    var requests: [Wiretuner_Docs_V1_NameVersionRequest] = []
    var offline = false
    /// Refuses a request that names a local change.
    var refusesAnchors = false

    func send(_ request: Wiretuner_Docs_V1_NameVersionRequest) throws -> Wiretuner_Docs_V1_Version {
        if offline { throw RPCError(code: .unavailable, message: "offline") }
        if refusesAnchors, request.hasThroughLocalChange { throw RPCError(code: .notFound, message: "unknown change") }
        requests.append(request)
        var version = Wiretuner_Docs_V1_Version()
        version.id = request.versionID
        version.serverSeq = request.serverSeq
        version.name = request.name
        return version
    }
}

/// Pending versions in memory.
@MainActor
final class VersionTestStore {
    var data: Data?
    var storage: VersionSaving.Storage {
        VersionSaving.Storage(load: { self.data }, save: { self.data = $0 })
    }
}


/// Records what reaches the index.
final class FakeSpotlightIndex: SpotlightIndexing, @unchecked Sendable {
    var indexed: [CSSearchableItem] = []
    var deleted: [String] = []
    var fails = false
    func index(_ items: [CSSearchableItem]) async throws {
        if fails { throw CocoaError(.fileWriteUnknown) }
        indexed += items
    }
    func delete(_ identifiers: [String]) async throws { deleted += identifiers }
}


@Suite(.serialized) @MainActor struct VersionsContinuityTests {
    static func change(_ replica: UInt64, _ seq: UInt64, _ label: String = "Move") -> LocalChangeRef {
        LocalChangeRef(replica: replica, seq: seq, counter: seq * 10, label: label)
    }

    func saver(_ server: VersionTestServer, _ store: VersionTestStore, head: @escaping @MainActor () -> VersionHead) -> VersionSaving {
        let saver = VersionSaving(documentID: "0190a1b2-0000-7000-8000-000000000001", storage: store.storage, head: { head() })
        saver.send = { try server.send($0) }
        return saver
    }

    // MARK: IO-003

    @Test func aVersionSavedWithEverythingUploadedIsNamedAtOnce() async throws {
        let server = VersionTestServer(), store = VersionTestStore()
        let saver = saver(server, store) { VersionHead(serverSeq: 41, replica: 7) }
        let outcome = await saver.save(name: "Proof", note: "for the client")
        guard case .named(let version) = outcome else { Issue.record("not named"); return }
        #expect(version.serverSeq == 41 && version.name == "Proof")
        let request = try #require(server.requests.first)
        #expect(request.serverSeq == 41 && !request.hasThroughLocalChange && request.note == "for the client")
        #expect(request.documentID == saver.documentID && !request.versionID.isEmpty)
        #expect(saver.pending.isEmpty)
    }

    @Test func aVersionSavedWithChangesWaitingIsPendingUntilTheyAreAcknowledged() async throws {
        let server = VersionTestServer(), store = VersionTestStore()
        let head = Box(VersionHead(serverSeq: 10, replica: 7, outbox: [Self.change(7, 3), Self.change(7, 4)]))
        let saver = saver(server, store) { head.value }
        guard case .pending(let version) = await saver.save(name: "Offline") else { Issue.record("not pending"); return }
        #expect(version.anchor == Self.change(7, 4) && version.serverSeq == 10)
        #expect(server.requests.isEmpty)
        #expect(await saver.flush() == 0, "its change is not acknowledged yet")
        // It survives a relaunch.
        let relaunched = self.saver(server, store) { head.value }
        await relaunched.load()
        #expect(relaunched.pending.map(\.id) == [version.id])
        head.value.outbox = []
        #expect(await relaunched.flush() == 1)
        let request = try #require(server.requests.first)
        #expect(request.versionID == version.id && request.throughLocalChange.counter == 40 && request.throughLocalChange.replica == 7)
        #expect(relaunched.pending.isEmpty)
        let reloaded = self.saver(server, store) { head.value }
        await reloaded.load()
        #expect(reloaded.pending.isEmpty)
    }

    @Test func offlineVersionsWaitAndGoUpOnceOnline() async {
        let server = VersionTestServer(), store = VersionTestStore()
        server.offline = true
        let saver = saver(server, store) { VersionHead(serverSeq: 3, replica: 1) }
        guard case .pending = await saver.save(name: "Train") else { Issue.record("not pending"); return }
        #expect(await saver.flush() == 0)
        server.offline = false
        #expect(await saver.flush() == 1)
        #expect(server.requests.map(\.name) == ["Train"])
    }

    @Test func twoVersionsSavedAtOnceGetDistinctIDs() async {
        let server = VersionTestServer(), store = VersionTestStore()
        let first = saver(server, store) { VersionHead(serverSeq: 5, replica: 1) }
        let second = saver(server, VersionTestStore()) { VersionHead(serverSeq: 5, replica: 2) }
        async let a = first.save(name: "A")
        async let b = second.save(name: "B")
        _ = await (a, b)
        #expect(server.requests.count == 2 && Set(server.requests.map(\.versionID)).count == 2)
    }

    @Test func aVersionFollowsItsChangeThroughSalvage() {
        var version = PendingVersion(id: "v", name: "n", note: "", createdAt: Date(), serverSeq: 1, anchor: Self.change(1, 9, "Recolor"))
        // Rotated: the change waits in the retired outbox for salvage.
        var head = VersionHead(serverSeq: 1, replica: 2, retired: [Self.change(1, 9, "Recolor")])
        #expect(head.resolve(&version) == .waiting)
        // Salvaged: re-issued under the new replica with its label.
        head = VersionHead(serverSeq: 1, replica: 2, outbox: [Self.change(2, 1, "Move"), Self.change(2, 2, "Recolor")])
        #expect(head.resolve(&version) == .waiting)
        #expect(version.anchor == Self.change(2, 2, "Recolor"), "re-anchored to the rebased change")
        head.outbox = []
        #expect(head.resolve(&version) == .ready(Self.change(2, 2, "Recolor")))
        // Acknowledged before the rotation: ready as it was.
        var acked = PendingVersion(id: "w", name: "n", note: "", createdAt: Date(), serverSeq: 1, anchor: Self.change(1, 3))
        #expect(VersionHead(replica: 2).resolve(&acked) == .ready(Self.change(1, 3)))
        var plain = PendingVersion(id: "x", name: "n", note: "", createdAt: Date(), serverSeq: 1)
        #expect(VersionHead().resolve(&plain) == .ready(nil))
    }

    @Test func anAnchorTheServerDoesNotKnowFallsBackToTheHead() async throws {
        let server = VersionTestServer(), store = VersionTestStore()
        server.refusesAnchors = true
        let head = Box(VersionHead(serverSeq: 8, replica: 1, outbox: [Self.change(1, 2)]))
        let saver = saver(server, store) { head.value }
        await saver.save(name: "Salvaged")
        head.value.outbox = []
        #expect(await saver.flush() == 1)
        #expect(server.requests.first?.hasThroughLocalChange == false)
    }

    @Test func withoutAClientEveryVersionStaysPending() async {
        let saver = VersionSaving(documentID: "d", storage: VersionTestStore().storage, head: { nil })
        guard case .pending(let version) = await saver.save(name: "Solo") else { Issue.record("not pending"); return }
        #expect(version.serverSeq == 0 && version.anchor == nil)
        #expect(await saver.flush() == 0)
        // A store-less document names at the head once a client is there.
        let server = VersionTestServer()
        saver.send = { try server.send($0) }
        #expect(await saver.flush() == 1 && server.requests.map(\.name) == ["Solo"])
        async let one = saver.flush()
        async let two = saver.flush()
        #expect(await one + two == 0)
    }

    @Test func theGRPCClientSendsNameVersion() async throws {
        let caller = FakeUnaryCaller([
            route(Wiretuner_Docs_V1_VersionService.Method.NameVersion.descriptor) { (request: Wiretuner_Docs_V1_NameVersionRequest) in
                var response = Wiretuner_Docs_V1_NameVersionResponse()
                response.version.id = request.versionID
                response.version.name = request.name
                return response
            },
        ])
        let client = GRPCVersionClient(caller: caller)
        let version = PendingVersion(id: "v1", name: "Named", note: "n", createdAt: Date(), serverSeq: 4)
        let request = VersionRequests.nameVersion(documentID: "d", version: version, anchor: Self.change(3, 1))
        #expect(request.throughLocalChange.replica == 3 && request.serverSeq == 4)
        let named = try await client.nameVersion(request, accessToken: "token")
        #expect(named.id == "v1" && named.name == "Named" && caller.tokens.all == ["token"])
        _ = GRPCVersionClient(api: URL(string: "http://localhost:8080")!, clientVersion: "1/1", deviceID: "device")
    }

    @Test func theLocalStoreKeepsPendingVersionsAndReportsItsHead() async throws {
        let directory = TestEnvironment.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString
        let store = try await LocalStore.open(documentID: id, at: directory.appending(path: "store.sqlite"))
        let document = DocumentHandle(id: id, title: "Stored", model: await WTModel.Document(backend: store, undoLevels: 10))
        await document.addRectangles([Rect(x: 0, y: 0, width: 5, height: 5)])
        let local = VersionSaving.localStore(of: document)
        let head = try #require(await local.head())
        #expect(head.outbox.count == 1 && head.outbox[0].label == "Rectangle" && head.retired.isEmpty)
        await local.storage.save(Data("[]".utf8))
        #expect(await local.storage.load() == Data("[]".utf8))
        try await store.close()
        let none = VersionSaving.localStore(of: DocumentHandle.memory(title: "Memory"))
        #expect(await none.head() == nil)
    }

    @Test func saveVersionAsksForANameOrSavesSilently() async throws {
        let environment = TestEnvironment()
        let controller = DocumentWindowController(document: .memory(title: "Versions"), environment: environment.document)
        defer { controller.close() }
        let server = VersionTestServer()
        let features = VersionFeatures()
        features.now = { Date(timeIntervalSince1970: 1_790_000_000) }
        features.local = { _ in (VersionTestStore().storage, { VersionHead(serverSeq: 2) }) }
        features.client = FakeVersionClient(server: server)
        features.accessToken = { "token" }
        features.install(into: environment.commands) { [weak controller] in controller }
        #expect(environment.commands.command(VersionFeatures.ID.saveVersion)?.defaultKey == KeyEquivalent("s", .command))
        #expect(environment.commands.command(VersionFeatures.ID.duplicate)?.defaultKey == KeyEquivalent("s", [.command, .shift]))
        #expect(environment.commands.validate(VersionFeatures.ID.saveVersion) == .enabled)
        // Silent: named with the date and time, confirmed in the status bar.
        features.asksForName = { false }
        #expect(features.saveVersion(from: controller) == nil)
        #expect(await eventually { server.requests.count == 1 })
        #expect(server.requests[0].name == SaveVersionSheet.defaultName(for: Date(timeIntervalSince1970: 1_790_000_000)))
        // Asking: the sheet, prefilled.
        features.asksForName = { true }
        let sheet = try #require(features.saveVersion(from: controller))
        #expect(sheet.identifier == SaveVersionSheet.identifier && controller.window?.attachedSheet === sheet)
        controller.window?.endSheet(sheet)
        let outcome = await features.save(name: "Named", note: "", in: controller)
        if case .named = outcome {} else { Issue.record("named") }
        #expect(VersionFeatures.message(for: outcome, name: "Named") == "Saved version “Named”")
        #expect(VersionFeatures.message(for: .pending(PendingVersion(id: "", name: "", note: "", createdAt: Date(), serverSeq: 0)), name: "X").contains("pending"))
        #expect(features.saver(for: controller.documentHandle) === features.savers[controller.documentHandle.id])
        #expect(SaveVersionSheet.defaultName(for: Date(timeIntervalSince1970: 1_790_000_000), locale: Locale(identifier: "en_US_POSIX")).contains("2026"))
        let answers = Box<[(name: String, note: String)?]>([])
        let view = SaveVersionSheetView(initialName: "  Kept  ") { answers.value.append($0) }
        #expect(view.trimmedName == "Kept")
        view.save()
        view.cancel()
        #expect(answers.value.count == 2 && answers.value[0]?.name == "Kept" && answers.value[1] == nil)
        // Without a window nothing runs.
        let orphan = VersionFeatures()
        orphan.install(into: environment.commands) { nil }
        #expect(environment.commands.validate(VersionFeatures.ID.saveVersion) == .disabled(ViewCommands.noDocument))
        for id in [VersionFeatures.ID.saveVersion, VersionFeatures.ID.duplicate] {
            if case .perform(let run)? = environment.commands.command(id)?.action { run() }
        }
        _ = NSHostingView(rootView: view).fittingSize
    }

    @Test func theSheetFinishesTheSaveAndCancelLeavesIt() async throws {
        let environment = TestEnvironment()
        let controller = DocumentWindowController(document: .memory(title: "Sheet"), environment: environment.document)
        defer { controller.close() }
        let server = VersionTestServer()
        let features = VersionFeatures()
        features.local = { _ in (VersionTestStore().storage, { VersionHead(serverSeq: 1) }) }
        features.client = FakeVersionClient(server: server)
        features.accessToken = { "t" }
        // Drive the presenter's callback as the view's buttons would.
        let sheet = try #require(features.saveVersion(from: controller))
        #expect(sheet.title == "Save Version" && controller.window?.attachedSheet === sheet)
        let hosting = try #require(sheet.contentViewController as? NSHostingController<SaveVersionSheetView>)
        hosting.rootView.finish(("From the sheet", "note"))
        #expect(await eventually { server.requests.map(\.name) == ["From the sheet"] })
        #expect(controller.window?.attachedSheet == nil)
        let again = try #require(features.saveVersion(from: controller))
        (again.contentViewController as? NSHostingController<SaveVersionSheetView>)?.rootView.finish(nil)
        #expect(controller.window?.attachedSheet == nil)
        (again.contentViewController as? NSHostingController<SaveVersionSheetView>)?.rootView.finish(nil)
        #expect(server.requests.count == 1, "cancel names nothing")
    }

    @Test func pendingVersionsGoUpWhenTheDocumentIsSavedToTheCloud() async throws {
        let environment = TestEnvironment()
        let status = StubSyncStatus()
        var document = environment.document
        document.makeSyncStatus = { _ in status }
        let controller = DocumentWindowController(document: .memory(title: "Status"), environment: document)
        defer { controller.close() }
        let server = VersionTestServer()
        server.offline = true
        let features = VersionFeatures()
        features.local = { _ in (VersionTestStore().storage, { VersionHead(serverSeq: 1) }) }
        features.client = FakeVersionClient(server: server)
        features.accessToken = { "t" }
        features.documentDidOpen(controller)
        features.documentDidOpen(controller)
        await features.save(name: "Later", note: "", in: controller)
        #expect(controller.statusBar.message.stringValue.contains("pending"))
        server.offline = false
        status.state = .offline(0)
        status.state = .saved
        #expect(await eventually { server.requests.map(\.name) == ["Later"] })
    }

    // MARK: IO-004

    @Test func duplicateMakesACopyInANewWindowWithoutTheOriginalsLaterChanges() async throws {
        let environment = TestEnvironment()
        let documents = DocumentController(environment: environment.document)
        let source = documents.newDocument(show: false)
        defer { for id in documents.documents.map(\.id) { documents.close(id) } }
        await source.documentHandle.addRectangles([Rect(x: 10, y: 10, width: 20, height: 20)])
        let features = VersionFeatures()
        var recorded: [(String, String)] = []
        features.recordDocument = { name, from in
            recorded.append((name, from))
            return "copy-id"
        }
        features.openDocument = { id, name in documents.open(environment.document.makeDocument(id: id, title: name), show: false).documentHandle }
        features.install(into: environment.commands) { source }
        #expect(environment.commands.perform(VersionFeatures.ID.duplicate))
        #expect(await eventually { documents.document(id: "copy-id") != nil })
        let copy = try #require(documents.document(id: "copy-id"))
        await copy.settle()
        #expect(await eventually { copy.selectableIDs().count == 1 })
        #expect(recorded.map(\.0) == [DocumentDuplicate.name(for: source.documentHandle.title)] && recorded.map(\.1) == [source.documentHandle.id])
        #expect(copy.title == "\(source.documentHandle.title) copy")
        #expect(copy.undoTitle == "Undo Duplicate", "one undo step")
        let replicas = Set(copy.state.store.nodes.filter { $0.replica != 0 }.map(\.replica))
        #expect(!replicas.contains(source.documentHandle.state.store.nodes.first { $0.replica != 0 }!.replica) || replicas.count == 1)
        // Without a library record nothing is made.
        features.recordDocument = { _, _ in nil }
        #expect(await features.duplicate(source) == nil)
    }

    @Test func theLibraryRecordsADeferredCreationInTheSourcesFolder() async {
        let server = FakeLibraryServer()
        server.put(LibraryDocument(id: "src", spaceID: "team", folderID: "folder", name: "Poster"))
        let library = LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        #expect(await library.document(withID: "src")?.name == "Poster")
        #expect(await library.document(withID: "src")?.folderID == "folder", "then from the cache")
        server.offline = true
        #expect(await library.document(withID: "elsewhere") == nil)
        var opened = 0
        library.onOpen = { _ in opened += 1 }
        let copy = library.recordDocument(name: "Poster copy", like: "src")
        #expect(copy.spaceID == "team" && copy.folderID == "folder" && copy.isPendingUpload && opened == 0)
        #expect(library.cache.documents[copy.id]?.name == "Poster copy")
        let loose = library.recordDocument(name: "Loose")
        #expect(loose.isPendingUpload)
    }

    // MARK: IO-036

    @Test func theHandoffActivityCarriesOnlyIDsAndAView() throws {
        let place = HandoffActivity.Place(documentID: "0190a1b2-0000-7000-8000-000000000001", pageIndex: 2, zoom: 2, center: Point(x: 1234.5, y: 678.25))
        let info = HandoffActivity.userInfo(place)
        #expect(HandoffActivity.place(from: info) == place)
        let size = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).count
        #expect(size < 256, "no document content")
        #expect(HandoffActivity.place(from: nil) == nil && HandoffActivity.place(from: ["document_id": ""]) == nil)
        #expect(HandoffActivity.place(from: ["document_id": "x"]) == HandoffActivity.Place(documentID: "x", pageIndex: 0, zoom: 1, center: .zero))
        let activity = HandoffActivity.make(title: "Poster")
        #expect(activity.activityType == HandoffActivity.type && activity.isEligibleForHandoff && !activity.isEligibleForSearch)
        #expect(activity.webpageURL == nil)
    }

    @Test func theActivityIsMarkedOncePerPageZoomAndIdleScroll() async {
        let handoff = WindowHandoff(title: "Marks")
        handoff.idle = .milliseconds(20)
        var viewport = Viewport(size: Size(width: 100, height: 100))
        handoff.viewDidChange(viewport)
        await handoff.settle()
        #expect(handoff.saves == 1, "the first view settles once")
        for step in 1...5 {
            viewport.scrollOrigin = Point(x: Double(step), y: 0)
            handoff.viewDidChange(viewport)
        }
        await handoff.settle()
        #expect(handoff.saves == 2, "a scroll marks once, when it stops")
        viewport.zoom = 2
        handoff.viewDidChange(viewport)
        #expect(handoff.saves == 3, "a zoom marks at once")
        handoff.pageDidChange(0)
        handoff.pageDidChange(0)
        #expect(handoff.saves == 3)
        handoff.pageDidChange(2)
        #expect(handoff.saves == 4)
        handoff.invalidate()
    }

    @Test func theWindowFillsTheActivityAndAppliesAPlace() async throws {
        let environment = TestEnvironment()
        let document = DocumentHandle.memory(title: "Place")
        let controller = DocumentWindowController(document: document, environment: environment.document)
        defer { controller.close() }
        #expect(controller.userActivity === controller.handoff.activity)
        let activity = NSUserActivity(activityType: HandoffActivity.type)
        controller.updateUserActivityState(activity)
        #expect(HandoffActivity.place(from: activity.userInfo)?.documentID == document.id)
        let place = HandoffActivity.Place(documentID: document.id, pageIndex: 0, zoom: 2, center: Point(x: 7000, y: 7000))
        controller.apply(place)
        #expect(controller.viewport.zoom == 2)
        let center = controller.viewport.toPasteboard(controller.viewport.viewCenter)
        #expect(abs(center.x - 7000) < 1 && abs(center.y - 7000) < 1, "the same scroll within 1 pt")
        #expect(controller.handoffPlace.zoom == 2)
        controller.windowDidBecomeMain(Notification(name: NSWindow.didBecomeMainNotification))
    }

    // MARK: IO-035, IO-036 continuations

    @Test func continuationsOpenByIDOrShowTheLibraryWithAMessage() async throws {
        let environment = TestEnvironment()
        let documents = DocumentController(environment: environment.document)
        defer { for id in documents.documents.map(\.id) { documents.close(id) } }
        let opener = ContinuityOpener()
        let entries = Box<[String: LibraryDocument]>(["known": LibraryDocument(id: "known", spaceID: "s", name: "Known"),
                                                      "gone": LibraryDocument(id: "gone", spaceID: "s", name: "Gone", isTrashed: true)])
        let messages = Box<[String]>([])
        let online = Box(true)
        opener.entry = { entries.value[$0] }
        opener.isOnline = { online.value }
        opener.hasLocalCopy = { $0 == "local" }
        opener.window = { documents.views(of: $0).first }
        opener.open = { id, name in documents.open(environment.document.makeDocument(id: id, title: name), show: false) }
        opener.showLibrary = { messages.value.append($0) }
        // A Handoff opens the document and applies the place once it is open.
        let place = HandoffActivity.Place(documentID: "known", pageIndex: 0, zoom: 4, center: Point(x: 8000, y: 8000))
        let handoff = NSUserActivity(activityType: HandoffActivity.type)
        handoff.addUserInfoEntries(from: HandoffActivity.userInfo(place))
        #expect(await opener.continueActivity(handoff)?.value == .opened("known"))
        #expect(documents.views(of: "known").first?.viewport.zoom == 4)
        // Open already: comes forward with the place.
        #expect(await opener.open("known", place: HandoffActivity.Place(documentID: "known", pageIndex: 0, zoom: 1, center: .zero)) == .opened("known"))
        #expect(documents.views(of: "known").first?.viewport.zoom == 1)
        #expect(await opener.open("local", place: nil) == .opened("local"), "a local copy opens without a library entry")
        #expect(await opener.open("gone", place: nil) == .library(ContinuityOpener.trashedMessage("Gone")))
        #expect(await opener.open("unknown", place: nil) == .library(ContinuityOpener.unavailableMessage()))
        online.value = false
        #expect(await opener.open("unknown", place: nil) == .library(ContinuityOpener.offlineMessage()))
        #expect(messages.value.count == 3, "a message, never an error dialog")
        // Spotlight results open the same way.
        let result = NSUserActivity(activityType: CSSearchableItemActionType)
        result.addUserInfoEntries(from: [CSSearchableItemActivityIdentifier: "known"])
        #expect(SpotlightIndexer.documentID(of: result) == "known")
        #expect(await opener.continueActivity(result)?.value == .opened("known"))
        #expect(opener.continueActivity(NSUserActivity(activityType: "other")) == nil)
        #expect(SpotlightIndexer.documentID(of: NSUserActivity(activityType: "other")) == nil)
        // A window that cannot be made.
        entries.value["broken"] = LibraryDocument(id: "broken", spaceID: "s", name: "Broken")
        opener.open = { _, _ in nil }
        #expect(await opener.open("broken", place: nil) == .library(ContinuityOpener.unavailableMessage()))
        let defaults = ContinuityOpener()
        #expect(!defaults.hasLocalCopy(UUID().uuidString) && defaults.isOnline() && defaults.window("x") == nil && defaults.open("x", "y") == nil)
        #expect(await defaults.entry("x") == nil)
        defaults.showLibrary("x")
    }

    // MARK: IO-035 Spotlight

    @Test func closingAWindowIndexesTheDocumentOnceAndOnlyWhenItChanged() async throws {
        let index = FakeSpotlightIndex()
        let directory = TestEnvironment.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: SpotlightIndexer.fileName)
        let indexer = SpotlightIndexer(index: index, url: url)
        indexer.thumbnail = { _ in Data([1, 2, 3]) }
        let document = DocumentHandle.memory(title: "Quokka poster")
        _ = await document.perform(CreateTextBlock(.area(Rect(x: 0, y: 0, width: 200, height: 40)), text: "The quokka")).value
        #expect(await indexer.documentDidClose(document))
        let item = try #require(index.indexed.first)
        #expect(item.uniqueIdentifier == document.id && item.domainIdentifier == SpotlightIndexer.domain)
        #expect(item.attributeSet.title == "Quokka poster" && item.attributeSet.textContent == "The quokka" && item.attributeSet.thumbnailData == Data([1, 2, 3]))
        #expect(!(await indexer.documentDidClose(document)), "closing without changes does not reindex")
        var keywords = Wiretuner_Doc_V1_NodeProps()
        keywords.settings.info.keywords = ["animal"]
        _ = await document.perform(OpsCommand("Keywords", ops: [Ops.setAdd(WellKnown.settings, RegisterPath([2, 130, 4]), values: keywords)])).value
        var info = Wiretuner_Doc_V1_NodeProps()
        info.settings.info.description_p = "A poster"
        _ = await document.perform(OpsCommand("Describe", ops: [Ops.set(WellKnown.settings, [RegisterPath([2, 130, 3])], values: info)])).value
        #expect(await indexer.documentDidClose(document), "a keyword edit reindexes")
        #expect(index.indexed.last?.attributeSet.contentDescription == "A poster")
        #expect(index.indexed.count == 2 && index.indexed[1].attributeSet.keywords == ["animal"])
        // The digests survive a relaunch.
        let relaunched = SpotlightIndexer(index: index, url: url)
        relaunched.thumbnail = { _ in Data([1, 2, 3]) }
        #expect(!(await relaunched.documentDidClose(document)))
        await relaunched.remove(document.id)
        #expect(index.deleted == [document.id] && relaunched.digests[document.id] == nil)
        // A failed write is tried again next time; a document not open yet is skipped.
        index.fails = true
        #expect(!(await relaunched.documentDidClose(document)))
        #expect(relaunched.builds == 1)
        let unopened = DocumentHandle(title: "Unopened") { throw CocoaError(.fileReadUnknown) }
        _ = await unopened.openedModel()
        #expect(!(await relaunched.documentDidClose(unopened)))
        #expect(SpotlightIndexer.defaultURL.lastPathComponent == SpotlightIndexer.fileName)
        try await NoSpotlightIndex().index([])
        try await NoSpotlightIndex().delete([])
        // The Mac's index takes nothing and a removal of nothing.
        try? await DefaultSpotlightIndex().index([])
        try? await DefaultSpotlightIndex().delete(["\(UUID().uuidString)"])
    }

    /// IO-035's rest: the open documents' items follow the snapshot interval as well as window
    /// closes -- rebuilt only when what they index changed.
    @Test func openDocumentsAreReindexedEverySnapshotInterval() async throws {
        let index = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(index: index)
        let document = DocumentHandle.memory(title: "Open poster")
        _ = await document.perform(CreateTextBlock(.area(Rect(x: 0, y: 0, width: 200, height: 40)), text: "Wombat")).value
        #expect(await indexer.refresh([document]) == 1)
        #expect(await indexer.refresh([document]) == 0, "unchanged: nothing rebuilt")
        _ = await document.perform(CreateTextBlock(.area(Rect(x: 0, y: 60, width: 200, height: 40)), text: "Numbat")).value
        let documents = TestBox([document])
        indexer.startRefreshing(every: { .milliseconds(20) }, documents: { documents.value })
        for _ in 0..<200 where index.indexed.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        indexer.stopRefreshing()
        #expect(index.indexed.count == 2 && index.indexed.last?.attributeSet.textContent?.contains("Numbat") == true && indexer.refreshing == nil)
    }

    @Test func theAppWiresVersionsContinuityAndSpotlight() async throws {
        let suite = TestDefaults()
        let server = FakeLibraryServer()
        let library = LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        let index = FakeSpotlightIndex()
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults, library: library, spotlight: SpotlightIndexer(index: index))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            delegate.libraryWindowController?.close()
            for id in delegate.documents.documents.map(\.id) { delegate.documents.close(id) }
            suite.remove()
        }
        #expect(delegate.commands.command(VersionFeatures.ID.saveVersion)?.validation() == .enabled)
        #expect(delegate.versions.client is GRPCVersionClient)
        #expect(delegate.versions.asksForName())
        let front = try #require(delegate.documents.activeWindowController)
        #expect(await front.objectDragging.writePDF?(URL(fileURLWithPath: "/tmp/nothing-\(UUID().uuidString).pdf")) == false, "nothing selected")
        #expect(front.toolManager.context.newObjectAppearance() == Appearances.standard, "no current colours yet")
        let directory = TestEnvironment.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let drawn = await front.documentHandle.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20)])
        front.selection.model.set(Selection(drawn))
        let pdf = directory.appending(path: "Objects.pdf")
        #expect(await delegate.writeSelectionPDF(of: front, to: pdf))
        #expect(FileManager.default.fileExists(atPath: pdf.path))
        // Duplicate records the copy in the library and opens it.
        let before = delegate.documents.documents.count
        let copy = await delegate.versions.duplicate(front)
        #expect(copy != nil && delegate.documents.documents.count == before + 1)
        #expect(library.cache.documents[copy?.id ?? ""]?.name.hasSuffix(" copy") == true)
        // A Spotlight result for an unknown document shows the Library window.
        let result = NSUserActivity(activityType: CSSearchableItemActionType)
        result.addUserInfoEntries(from: [CSSearchableItemActivityIdentifier: "nowhere"])
        #expect(delegate.application(NSApp, continue: result) { _ in })
        #expect(await eventually { delegate.libraryWindowController != nil })
        #expect(!delegate.application(NSApp, continue: NSUserActivity(activityType: "other")) { _ in })
        // A Handoff for a library document opens it.
        server.put(LibraryDocument(id: "handed", spaceID: "s", name: "Handed over"))
        let handoff = NSUserActivity(activityType: HandoffActivity.type)
        handoff.addUserInfoEntries(from: HandoffActivity.userInfo(HandoffActivity.Place(documentID: "handed", pageIndex: 0, zoom: 1, center: .zero)))
        #expect(delegate.application(NSApp, continue: handoff) { _ in })
        #expect(await eventually { delegate.documents.document(id: "handed") != nil })
        // Closing a window indexes its document; trashing removes it.
        let id = front.documentHandle.id
        delegate.documents.close(id)
        #expect(await eventually { index.indexed.contains { $0.uniqueIdentifier == id } })
        server.put(LibraryDocument(id: id, spaceID: "s", name: "Trash me"))
        await library.trash(id)
        #expect(await eventually { index.deleted == [id] })
        #expect(await library.document(withID: id)?.isTrashed == true)
        library.show(message: "Hello")
    }
}

/// `VersionClient` over a test server.
struct FakeVersionClient: VersionClient {
    let server: VersionTestServer

    func nameVersion(_ request: Wiretuner_Docs_V1_NameVersionRequest, accessToken: String) async throws -> Wiretuner_Docs_V1_Version {
        try await server.send(request)
    }
}
