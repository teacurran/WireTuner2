import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
import WTRender

/// `Document.reload()`: the backend's state replaced wholesale (a snapshot bootstrap or a salvage,
/// WTSync's `SyncEvent.stateReplaced`) is re-read and republished as one `.reload` event, and the
/// display list is rebuilt from scratch with a whole-document summary.
@MainActor @Suite struct DocumentReloadTests {
    final class Log {
        var events: [DocumentEvent] = []
    }

    @Test func reloadRereadsTheBackendAndRepublishes() async throws {
        let backend = MemoryBackend(replica: 7)
        let doc = await Document(backend: backend)
        let log = Log()
        doc.observe { log.events.append($0) }
        let kept = try #require(try await doc.perform(PathFixture.open([(0, 0), (10, 10)]))?.createdObjects.first)
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(doc.state)
        // The store's state is replaced: another replica's document with a different object.
        var replacement = DocumentCore(state: EngineState(), replica: 9)
        let fresh = try #require(try replacement.perform(PathFixture.closed([(0, 0), (20, 0), (20, 20)]),
                                                         recording: DocumentCore.Recording(limit: 10, now: Date()))?.change?.createdObjects.first)
        await backend.replace(with: replacement)
        let revision = doc.revision
        await doc.reload()
        #expect(doc.revision == revision + 1)
        #expect(doc.replica == 9)
        #expect(doc.undoTitle == "Undo Path" && doc.canUndo)
        #expect(doc.state.stateHash == replacement.state.stateHash)
        let event = try #require(log.events.last)
        #expect(event.origin == .reload && event.change == Wiretuner_Doc_V1_Change())
        #expect(event.before.isLive(kept) && !event.after.isLive(kept) && event.after.isLive(fresh))
        // The builder rebuilds everything and names every object before and after.
        let (scene, summary) = builder.reload(event.after)
        #expect(summary.isStructural && summary.origin == .remote)
        #expect(summary.touchedNodes == [NodeID(kept), NodeID(fresh)])
        #expect(scene.object(fresh) != nil && scene.object(kept) == nil)
        #expect(summary.bounds[NodeID(kept)]?.new == nil && summary.bounds[NodeID(fresh)]?.old == nil)
    }
}
