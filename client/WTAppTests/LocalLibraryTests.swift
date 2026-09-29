import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTRender
import WTSync
@testable import WireTuner

/// The Library in Local mode (D-079; creating-opening.adoc, "The Library without an account"):
/// rename, move, folders, duplicate, the local Trash with Restore, Delete Permanently and Empty
/// Trash, all on the library cache without a server.
@Suite(.serialized) @MainActor struct LocalLibraryTests {
    let server = FakeLibraryServer()

    func model(store: LibraryCacheStore? = nil) -> LibraryModel {
        let model = LibraryModel(services: server.services(signedIn: false), store: store, thumbnails: ThumbnailCache(directory: nil),
                                 debounce: .milliseconds(1))
        model.isLocal = { true }
        var next = 0
        model.makeID = {
            next += 1
            return "id-\(next)"
        }
        return model
    }

    @Test func documentsAreMadeRenamedMovedAndFlaggedOnThisMac() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "Library-\(UUID().uuidString).json")
        let model = model(store: LibraryCacheStore(url: url))
        var opened: [String] = []
        model.onOpen = { opened += $0.map(\.id) }
        let document = model.createDocument(name: "Poster")
        #expect(opened == [document.id] && document.isPendingUpload && model.pendingUploads.isEmpty, "no upload is started")
        #expect(model.isAvailable(LibraryDocument(id: "elsewhere", spaceID: "x", name: "Not here")))
        await model.rename(document.id, to: "  Big poster ")
        #expect(model.cache.documents[document.id]?.name == "Big poster")
        await model.setTemplate(document.id, true)
        #expect(model.cache.documents[document.id]?.isTemplate == true)
        #expect(model.cache.documents(in: .templates, spaceID: model.currentSpace.id).map(\.id) == [document.id])

        let folder = try #require(await model.createFolder(named: "Clients"))
        #expect(folder.isLocal && folder.spaceID == LibraryModel.localPersonalID && model.folders.map(\.id) == [folder.id])
        await model.move(document.id, toFolder: folder.id)
        #expect(model.cache.documents[document.id]?.folderID == folder.id)
        await model.show(.folder(folder.id))
        #expect(model.documents.map(\.id) == [document.id] && model.folderPath.map(\.name) == ["Clients"])
        await model.renameFolder(folder.id, to: "Customers")
        await model.renameFolder(folder.id, to: "  ")
        await model.renameFolder("unknown", to: "X")
        #expect(model.cache.folders[folder.id]?.name == "Customers")

        // Deleting a folder moves what it held up, as the server does.
        let inner = try #require(await model.createFolder(named: "Acme"))
        #expect(inner.parentID == folder.id)
        await model.deleteFolder(folder.id)
        #expect(model.cache.folders[folder.id] == nil && model.cache.folders[inner.id]?.parentID == nil)
        #expect(model.cache.documents[document.id]?.folderID == nil && model.section == .folder(nil))
        await model.deleteFolder("unknown")

        // Nothing went to the server; the cache was saved.
        #expect(server.calls.isEmpty)
        #expect(LibraryCacheStore(url: url).load().documents[document.id]?.name == "Big poster")
        #expect(LibraryCacheStore(url: url).load().folders[inner.id]?.isLocal == true)
    }

    @Test func theTrashRestoresAndDeletesForGood() async throws {
        let model = model()
        var removed: [String] = []
        var trashedEvents: [String] = []
        model.removeFromThisMac = { removed.append($0) }
        model.onTrashed = { trashedEvents.append($0) }
        let folder = try #require(await model.createFolder(named: "Old"))
        await model.show(.folder(folder.id))
        let kept = model.recordDocument(name: "Keep")
        let gone = model.recordDocument(name: "Gone")
        let also = model.recordDocument(name: "Also")
        model.open([kept, gone, also])
        for id in [kept.id, gone.id, also.id] { await model.trash(id) }
        #expect(trashedEvents == [kept.id, gone.id, also.id])
        #expect(model.documents.isEmpty && model.cache.recentDocuments.isEmpty)
        await model.show(.trash)
        #expect(model.documents.map(\.name) == ["Also", "Gone", "Keep"])

        // Restore puts it back; its folder gone, at the top level.
        await model.deleteFolder(folder.id)
        model.restore(kept.id)
        #expect(model.cache.documents[kept.id]?.isTrashed == false && model.cache.documents[kept.id]?.folderID == nil)
        // Delete Permanently: only from the Trash, and the store goes too.
        await model.deletePermanently(kept.id)
        #expect(model.cache.documents[kept.id] != nil && removed.isEmpty)
        await model.deletePermanently(gone.id)
        #expect(model.cache.documents[gone.id] == nil && removed == [gone.id])
        #expect(!model.cache.recents.contains { $0.documentID == gone.id } && !model.cache.offlineAvailable.contains(gone.id))
        await model.emptyTrash()
        #expect(removed == [gone.id, also.id] && model.documents.isEmpty)
        #expect(server.calls.isEmpty)

        // With an account, none of this is Local mode's to do.
        model.isLocal = { false }
        await model.trash(kept.id)
        model.restore(kept.id)
        await model.deletePermanently(kept.id)
        #expect(model.cache.documents[kept.id] != nil)
    }

    @Test func duplicateCopiesTheContentHere() async throws {
        let model = model()
        let source = model.recordDocument(name: "Card")
        var copies: [(String, String)] = []
        model.copyContent = { from, to in
            copies.append((from, to))
            return true
        }
        let copy = try #require(await model.duplicate(source.id))
        #expect(copy.name == "Card copy" && copy.isPendingUpload && copies.first?.0 == source.id && copies.first?.1 == copy.id)
        model.copyContent = { _, _ in false }
        #expect(await model.duplicate(source.id) == nil)
        #expect(model.errorMessage == LibraryModel.copyFailedMessage && model.cache.documents.count == 2)
        model.copyContent = nil
        #expect(await model.duplicate(source.id)?.name == "Card copy")
        #expect(await model.duplicate("unknown") == nil)
        #expect(server.calls.isEmpty)
    }

    @Test func nothingAsksTheServer() async {
        let model = model()
        model.searchText = "po"
        #expect(model.searchHint == nil && model.pendingSearch == nil)
        await model.refresh()
        await model.reloadSection()
        await model.loadMore()
        await model.refreshTemplates()
        await model.refreshMentions()
        await model.prefetchThumbnails()
        await model.runSearch("po")
        #expect(await model.document(withID: "unknown") == nil)
        #expect(model.isOnline && model.errorMessage == nil && model.connectionNote?.title == LibraryModel.onThisMac)
        #expect(LibrarySyncBadge.badge(.localOnly) == nil, "no badge for On this Mac")
        model.isLocal = { false }
        #expect(model.connectionNote == nil)
        #expect(server.calls.filter { $0 != "search" }.isEmpty)
    }

    @Test func theLibraryWindowInLocalMode() async throws {
        let model = model()
        let document = model.recordDocument(name: "Shown")
        _ = try #require(await model.createFolder(named: "Folder"))
        let view = NSHostingView(rootView: LibraryView(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.layoutSubtreeIfNeeded()
        await model.trash(document.id)
        await model.show(.trash)
        view.layoutSubtreeIfNeeded()
        #expect(LibraryToolbar(model: model).title == "Personal › Trash")
        #expect(!LibraryView.deleteWarning.isEmpty)
    }

    @Test func aDocumentsContentIsCopiedIntoANewOne() async throws {
        let source = DocumentOpener.memoryDocument()
        _ = try await source.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5), transform: .identity, appearance: Appearances.standard))
        let copy = WTModel.Document(memory: DocumentCore(state: EngineState(), replica: 99))
        try await LocalDocumentCopy.fill(copy, from: source.state)
        #expect(copy.state.store.nodes.count == source.state.store.nodes.count)
    }

    @Test func theAppCopiesAndDeletesStoresOnThisMac() async throws {
        let suite = TestDefaults()
        defer { suite.remove() }
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults, localMode: LocalMode(isLocalBuild: true))
        let stores = TestStores.directory()
        delegate.localCopyRemoval.storeURL = { stores.appending(components: $0, "store.sqlite") }
        let store = try await LocalStore.open(documentID: "doomed", at: stores.appending(components: "doomed", "store.sqlite"))
        try await store.close()
        #expect(LocalCopies.exists(at: stores.appending(components: "doomed", "store.sqlite")))
        await delegate.removeFromThisMac("doomed")
        #expect(!LocalCopies.exists(at: stores.appending(components: "doomed", "store.sqlite")))
        await delegate.removeFromThisMac("never-here")
        // A test launch's documents are memory documents: the copy is made through them.
        #expect(await delegate.copyDocumentContent(from: "source", to: "copy"))
        let open = delegate.documents.open(delegate.documents.environment.makeDocument(id: "open", title: "Open"))
        #expect(await delegate.copyDocumentContent(from: "open", to: "copy-2"))
        delegate.documents.close(open.documentHandle.id)
        // A store that cannot be read: nothing is copied, and a damaged one is still let go of.
        delegate.documents.environment.openModel = { _ in throw CocoaError(.fileReadCorruptFile) }
        #expect(await !delegate.copyDocumentContent(from: "source", to: "copy-3"))
        try FileManager.default.createDirectory(at: stores.appending(path: "damaged"), withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: stores.appending(components: "damaged", "store.sqlite"))
        await delegate.removeFromThisMac("damaged")
        delegate.activeSelection.presence = nil
    }
}
