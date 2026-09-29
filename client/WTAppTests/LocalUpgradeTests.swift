import AppKit
import Foundation
import Testing
import WTGeometry
import WTModel
import WTRender
import WTSync
@testable import WireTuner

/// Upgrading from Local mode (D-079): what was made without an account keeps its pending upload,
/// and the first sign-in creates it in the personal space -- folders first -- and uploads its
/// changes, open or closed, against the fake library and sync servers.
@Suite(.serialized) @MainActor struct LocalUpgradeTests {
    let server = FakeLibraryServer()
    let suite = TestDefaults()

    /// The token closure is `@Sendable`: it reads a lock-guarded copy of the box.
    final class SignedInFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    @Test func theFirstSignInCreatesWhatLocalModeMade() async throws {
        let signedIn = TestBox(false)
        let flag = SignedInFlag()
        let services = LibraryServices(documents: server, teams: server, blobs: server, account: server) {
            guard flag.value else { throw AuthError.notSignedIn }
            return "token"
        }
        let mode = LocalMode(isLocalBuild: false, defaults: suite.defaults)
        mode.isSignedIn = { signedIn.value }
        mode.useWithoutAccount()
        let library = LibraryModel(services: services, store: nil, thumbnails: ThumbnailCache(directory: nil), debounce: .milliseconds(1))
        library.isLocal = { mode.isActive }

        // Made in Local mode: a folder in a folder, a document in each, one trashed, one at the top.
        let clients = try #require(await library.createFolder(named: "Clients"))
        await library.show(.folder(clients.id))
        let acme = try #require(await library.createFolder(named: "Acme"))
        let brief = library.recordDocument(name: "Brief")
        await library.show(.folder(acme.id))
        let logo = library.recordDocument(name: "Logo")
        await library.show(.folder(nil))
        let draft = library.recordDocument(name: "Scrap")
        await library.trash(draft.id)
        #expect(server.calls.isEmpty && library.pendingUploads.isEmpty)
        #expect([brief, logo, draft].allSatisfy { library.cache.documents[$0.id]?.isPendingUpload == true })

        // Signing in: the library refresh creates everything in the personal space.
        signedIn.value = true
        flag.value = true
        mode.accountDidChange()
        #expect(!mode.isActive)
        await library.refresh()
        let calls = server.calls
        let order = ["createFolder:Clients", "createFolder:Acme"].compactMap { calls.firstIndex(of: $0) }
        #expect(order.count == 2 && order[0] < order[1], "parents first: \(calls)")
        #expect(order.allSatisfy { index in calls.firstIndex { $0.hasPrefix("create:") }.map { index < $0 } ?? false }, "folders before documents")
        let uploaded = server.documents
        #expect(uploaded[brief.id]?.spaceID == server.accountID && uploaded[brief.id]?.folderID == "f-Clients")
        #expect(uploaded[logo.id]?.folderID == "f-Acme")
        #expect(uploaded[draft.id]?.isTrashed == true, "trashed on this Mac, trashed on the server")
        #expect(library.cache.documents.values.allSatisfy { !$0.isPendingUpload })
        #expect(library.cache.folders.values.allSatisfy { !$0.isLocal })
        #expect(library.cache.folders["f-Acme"]?.parentID == "f-Clients")
    }

    @Test func theOpenAndClosedDocumentsUploadTheirChanges() async throws {
        let signedIn = TestBox(false)
        let mode = LocalMode(isLocalBuild: false, defaults: suite.defaults)
        mode.isSignedIn = { signedIn.value }
        mode.useWithoutAccount()

        // An open document edited in Local mode: its session runs no client.
        let directory = TestStores.directory()
        let connector = FakeSyncConnector()
        let sessions = DocumentSessions(connector: connector, isLocal: { mode.isActive })
        let handle = TestStores.handle(id: "open-doc", in: directory)
        let session = sessions.session(for: handle)
        await session.start().value
        #expect(session.status.state == .localOnly && connector.connections == 0)
        await handle.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        #expect(sessions.waitingDocuments.isEmpty, "nothing waits at quit")
        #expect(session.leaveLocalMode() == nil, "still in Local mode")

        // A closed document with a change in its store.
        let stores = TestStores.directory()
        let closed = try await LocalStore.open(documentID: "closed-doc", at: stores.appending(components: "closed-doc", "store.sqlite"))
        let document = await WTModel.Document(backend: closed)
        _ = try await document.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5), transform: .identity, appearance: Appearances.standard))
        await document.settle()
        try await closed.close()

        // Signing in: the open session connects and pushes; the closed store uploads headlessly.
        signedIn.value = true
        await sessions.localModeDidChange().value
        #expect(connector.connections == 1)
        #expect(await eventually { await connector.server.head >= 1 })
        #expect(await eventually { session.status.state == .saved })
        let started = await HeadlessUploads.begin(in: stores, connector: connector, sessions: sessions) { $0 }
        #expect(started.map(\.documentID) == ["closed-doc"])
        #expect(await eventually { await connector.server.head >= 2 })

        // Back to Local mode: the client stops, the work stays.
        signedIn.value = false
        await sessions.localModeDidChange().value
        #expect(session.status.state == .localOnly && session.client == nil)
        await sessions.stopAll()
        handle.close()
    }

    @Test func theAppUploadsWhenLocalModeEnds() async throws {
        let stores = TestStores.directory()
        let store = try await LocalStore.open(documentID: "made-here", at: stores.appending(components: "made-here", "store.sqlite"))
        let document = await WTModel.Document(backend: store)
        _ = try await document.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5), transform: .identity, appearance: Appearances.standard))
        await document.settle()
        try await store.close()

        let mode = LocalMode(isLocalBuild: false, defaults: suite.defaults)
        mode.useWithoutAccount()
        let connector = FakeSyncConnector()
        let library = LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil), debounce: .milliseconds(1))
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults, library: library, syncConnector: connector,
                                   storesDirectory: { stores }, localMode: mode)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            for id in delegate.documents.documents.map(\.id) { delegate.documents.close(id) }
            delegate.activeSelection.presence = nil
            suite.remove()
        }
        #expect(await eventually { delegate.activeDocumentWindow != nil })
        let launch = try #require(delegate.activeDocumentWindow?.documentHandle.id)
        #expect(delegate.sessions.headless.isEmpty && connector.connections == 0, "Local mode uploads nothing at launch")
        #expect(library.cache.documents[launch]?.isPendingUpload == true)

        // The sign-in: the launch document is created in the personal space, the store uploads.
        delegate.account.apply(.signedIn(TokenClaims(subject: "s")))
        await delegate.localModeChange?.value
        #expect(server.documents[launch]?.spaceID == server.accountID)
        #expect(await eventually { await connector.server.head >= 1 })
    }
}
