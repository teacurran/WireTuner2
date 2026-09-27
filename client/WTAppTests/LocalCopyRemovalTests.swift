import Foundation
import Testing
import WTSync
@testable import WireTuner

/// IO-035's *Remove Local Copy*: the command, the checks before closing anything, and what follows
/// a removal.
@Suite(.serialized) @MainActor struct LocalCopyRemovalTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "LocalCopyRemovalTests-\(UUID().uuidString)")

    func url(_ id: String) -> URL { folder.appending(components: id, "store.sqlite") }

    func makeStore(_ id: String, blob: Bool = false) async throws {
        let store = try await LocalStore.open(documentID: id, at: url(id))
        if blob { try await store.addPendingBlob(.init(hash: "img", path: "/i", size: 1)) }
        try await store.close()
    }

    @Test func removesACopyOnceItIsSyncedAndTellsWhyOtherwise() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let removal = LocalCopyRemoval()
        removal.storeURL = { self.url($0) }
        let alerts = TestBox<[String]>([])
        let confirmations = TestBox(0)
        let answer = TestBox(true)
        let closed = TestBox<[String]>([])
        let removed = TestBox<[String]>([])
        let state = TestBox<SyncState?>(.saved)
        removal.alert = { message, _ in alerts.value.append(message) }
        removal.confirm = { _, _ in confirmations.value += 1; return answer.value }
        removal.closeDocument = { closed.value.append($0) }
        removal.onRemoved = { removed.value.append($0) }
        removal.syncState = { _ in state.value }
        removal.isOpen = { $0 == "open" }
        // No copy.
        #expect(await removal.remove(.init(id: "none", title: "None")) == .notOnThisMac && alerts.value == ["“None” is not on this Mac."])
        // An open document still syncing: nothing is asked or closed.
        try await makeStore("open")
        state.value = .syncing(2)
        #expect(await removal.remove(.init(id: "open", title: "Poster")) == nil)
        #expect(alerts.value.last == "“Poster” is still syncing." && confirmations.value == 0 && closed.value.isEmpty)
        // Cancelled.
        state.value = .saved
        answer.value = false
        #expect(await removal.remove(.init(id: "open", title: "Poster")) == nil && closed.value.isEmpty)
        // Synced: the windows close, the copy goes.
        answer.value = true
        #expect(await removal.remove(.init(id: "open", title: "Poster")) == .removed)
        #expect(closed.value == ["open"] && removed.value == ["open"] && !removal.hasCopy("open"))
        // An image still waiting in the store: kept, and the person is told.
        try await makeStore("waiting", blob: true)
        state.value = nil
        #expect(await removal.remove(.init(id: "waiting", title: "Flyer")) == .waiting(LocalCopies.Waiting(blobs: 1)))
        #expect(alerts.value.last == "The local copy of “Flyer” was kept." && removal.hasCopy("waiting") && removed.value == ["open"])
        // The command acts on the targets that have a copy.
        removal.targets = { [.init(id: "none", title: "None")] }
        let command = removal.command()
        #expect(command.validation() != .enabled)
        removal.targets = { [.init(id: "waiting", title: "Flyer")] }
        #expect(removal.command().validation() == .enabled)
        #expect(command.title == "Remove Local Copy…")
    }

    @Test func theLibraryForgetsTheOfflineBadge() {
        let model = LibraryModel(services: FakeLibraryServer().services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        model.keepAvailableOffline("d1")
        #expect(model.cache.offlineAvailable.contains("d1") && !model.hasLocalCopy("d1") && model.removeLocalCopy == nil)
        model.forgetLocalCopy("d1")
        #expect(!model.cache.offlineAvailable.contains("d1"))
    }

    @Test func sessionsReportStateAndReleaseAClosedDocument() async {
        let sessions = DocumentSessions(connector: nil)
        #expect(sessions.state(of: "x") == nil)
        let document = DocumentHandle.memory(title: "M")
        let session = sessions.session(for: document)
        #expect(sessions.state(of: document.id) == session.status.state)
        let closedBackend = TestBox(false)
        sessions.closeDocument = { _ in closedBackend.value = true }
        sessions.documentDidClose(document)
        await sessions.released(document.id)
        #expect(closedBackend.value && sessions.state(of: document.id) == nil)
    }
}
