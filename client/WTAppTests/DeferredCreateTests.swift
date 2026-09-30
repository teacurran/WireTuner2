import Foundation
import Testing
import WTGeometry
import WTModel
import WTRender
import WTSync
@testable import WireTuner

/// DOC-019, D-089: a document made while signed in but offline defers `DocumentService.Create`;
/// when the network comes back its sync client creates it first, through the library, so the
/// server -- which answers `NOT_FOUND` for a document it has not created -- sees the `Create`
/// before any Subscribe or push, without waiting for a library refresh.
@Suite(.serialized) @MainActor struct DeferredCreateTests {
    let library = FakeLibraryServer()

    /// A library, sessions over a connector whose server knows only what the library created, and
    /// the connector.
    func fixture(gated: Bool = true) async -> (LibraryModel, DocumentSessions, FakeSyncConnector) {
        let model = LibraryModel(services: library.services(), store: nil, thumbnails: ThumbnailCache(directory: nil), debounce: .milliseconds(1))
        let connector = FakeSyncConnector()
        let created = library
        let exists: @Sendable (String) -> Bool = { created.documents[$0] != nil }
        await connector.server.update { $0.exists = exists }
        let sessions = DocumentSessions(connector: connector)
        if gated { sessions.creation = model.creationGate }
        return (model, sessions, connector)
    }

    @Test func aDocumentMadeOfflineIsCreatedBeforeItsSessionSyncs() async throws {
        let (model, sessions, connector) = await fixture()
        library.offline = true
        let document = model.createDocument(name: "From Template", template: .builtIn)
        await model.pendingUploads[document.id]?.value
        #expect(model.isWaitingToUpload(document.id), "offline: the Create waits")

        let handle = TestStores.handle(id: document.id, title: document.name, in: TestStores.directory())
        let session = sessions.session(for: handle)
        await handle.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        #expect(await eventually { if case .offline = session.status.state { true } else { false } })
        #expect(await connector.server.subscribes == 0, "no Subscribe while the document is not created")

        // Back online, and no library refresh: the session's next attempt creates it first.
        library.offline = false
        #expect(await eventually(.seconds(10)) { session.status.state == .saved })
        #expect(library.documents[document.id] != nil && !model.isWaitingToUpload(document.id))
        #expect(await connector.server.refusedSubscribes == 0)
        #expect(await connector.server.head >= 1, "the outbox went up after Create")
        await sessions.stopAll()
        handle.close()
    }

    /// The race the gate closes: without it the reconnecting session subscribes first and halts.
    @Test func withoutTheGateTheSessionHaltsOnNotFound() async throws {
        let (model, sessions, connector) = await fixture(gated: false)
        library.offline = true
        let document = model.recordDocument(name: "Untitled")
        await model.pendingUploads[document.id]?.value
        library.offline = false
        let handle = TestStores.handle(id: document.id, in: TestStores.directory())
        let session = sessions.session(for: handle)
        #expect(await eventually { session.status.state == .error("The document no longer exists.") })
        #expect(await connector.server.refusedSubscribes == 1)
        await sessions.stopAll()
        handle.close()
    }

    /// A closed store of a document made offline (a duplicate, a package or a foreign file opened
    /// as a new document) uploads headlessly at launch -- before the library's refresh -- only
    /// after the gate created it.
    @Test func aHeadlessUploadCreatesTheDocumentFirst() async throws {
        let (model, sessions, connector) = await fixture()
        library.offline = true
        let document = model.recordDocument(name: "Copy", like: nil)
        await model.pendingUploads[document.id]?.value
        let stores = TestStores.directory()
        let store = try await LocalStore.open(documentID: document.id, at: stores.appending(components: document.id, "store.sqlite"))
        let content = await WTModel.Document(backend: store)
        _ = try await content.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5), transform: .identity, appearance: Appearances.standard))
        await content.settle()
        try await store.close()

        library.offline = false
        let started = await HeadlessUploads.begin(in: stores, connector: connector, sessions: sessions) { $0 }
        #expect(started.map(\.documentID) == [document.id])
        #expect(await eventually(.seconds(10)) { await connector.server.head >= 1 })
        #expect(library.documents[document.id] != nil)
        #expect(await connector.server.refusedSubscribes == 0)
        await sessions.stopAll()
    }

    /// In Local mode (D-079) the gate creates nothing: the document waits for a sign-in.
    @Test func localModeCreatesNothing() async throws {
        let model = LibraryModel(services: library.services(), store: nil, thumbnails: ThumbnailCache(directory: nil), debounce: .milliseconds(1))
        let local = TestBox(true)
        model.isLocal = { local.value }
        let document = model.recordDocument(name: "Here")
        await #expect(throws: LibraryModel.LocalModeWait.self) { try await model.createOnServer(document.id) }
        #expect(library.calls.isEmpty)
        local.value = false
        try await model.createOnServer(document.id)
        try await model.createOnServer(document.id)
        #expect(library.calls == ["create:Here"], "once; a created document is left alone")
        #expect(await model.creationGate.isPending(document.id) == false)
        library.offline = true
        let other = model.recordDocument(name: "Offline")
        await model.pendingUploads[other.id]?.value
        await #expect(throws: (any Error).self) { try await model.creationGate.create(other.id) }
        #expect(!model.isOnline)
    }
}
