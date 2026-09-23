import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto

/// The façade's published state and change events (DRAW-002 additions to `Document`).
@MainActor @Suite struct DocumentEventTests {
    final class Log {
        var events: [DocumentEvent] = []
    }

    @Test func aMemoryDocumentIsReadyAtOnce() throws {
        var core = DocumentCore(state: EngineState(), replica: 7)
        _ = try core.perform(PathFixture.open([(0, 0), (1, 1)]), recording: DocumentCore.Recording(limit: 10, now: Date()))
        let doc = Document(memory: core, undoLevels: 5000)
        #expect(doc.undoLevels == Document.undoLevelsRange.upperBound)
        #expect(doc.canUndo && doc.undoTitle == "Undo Path" && !doc.canRedo)
        #expect(doc.replica == 7)
        #expect(doc.state.stateHash == core.state.stateHash)
    }

    @Test func eventsCarryOriginAndStates() async throws {
        let doc = Document(memory: DocumentCore(state: EngineState(), replica: 7))
        let log = Log()
        let token = doc.observe { log.events.append($0) }
        let created = try #require(try await doc.perform(PathFixture.open([(0, 0), (1, 1)])))
        let node = created.createdObjects[0]
        #expect(doc.state.isLive(node))
        #expect(log.events.count == 1)
        #expect(log.events[0].origin == .local && log.events[0].change == created)
        #expect(!log.events[0].before.isLive(node) && log.events[0].after.isLive(node))
        try await doc.undo()
        try await doc.redo()
        #expect(log.events.map(\.origin) == [.local, .undo, .redo])
        // A remote change.
        var other = DocumentCore(state: doc.state, replica: 99)
        let remote = try #require(try other.perform(DeleteNodes([node]), recording: DocumentCore.Recording(limit: 10, now: Date()))?.change)
        try await doc.receive(remote, serverSeq: 1)
        #expect(log.events.last?.origin == .remote && !doc.state.isLive(node))
        // Nothing to undo publishes no event.
        doc.stopObserving(token)
        try await doc.perform(PathFixture.open([(0, 0), (1, 1)]))
        #expect(log.events.count == 4)
        #expect(try await doc.perform(OpsCommand("Nothing", ops: [])) == nil)
    }

    @Test func callsRunInOrderAndSettleWaitsForThem() async throws {
        let doc = await Document(backend: MemoryBackend(replica: 7))
        let log = Log()
        doc.observe { log.events.append($0) }
        doc.observe { _ in }
        var tasks: [Task<Void, Never>] = []
        for index in 0..<5 {
            tasks.append(Task { @MainActor in
                _ = try? await doc.perform(PathFixture.open([(Double(index), 0), (1, 1)]))
            })
        }
        await doc.settle()
        for task in tasks { await task.value }
        await doc.settle()
        #expect(log.events.count == 5)
        #expect(log.events.map(\.change.seq) == [1, 2, 3, 4, 5])
        #expect(doc.revision == 5)
        #expect(doc.state.stateHash == (await doc.read { $0.stateHash }))
    }

    @Test func aThrowingCommandStillLetsLaterCallsRun() async throws {
        let doc = Document(memory: DocumentCore(state: EngineState(), replica: 7))
        await #expect(throws: PathEditError.self) { try await doc.perform(SetEvenOdd(node: OpID(counter: 9, replica: 9), evenOdd: true)) }
        #expect(try await doc.perform(PathFixture.open([(0, 0), (1, 1)])) != nil)
        await doc.settle()
    }
}
