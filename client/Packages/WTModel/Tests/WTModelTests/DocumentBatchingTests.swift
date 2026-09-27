import Foundation
import Synchronization
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto

/// D-076: local commands apply at once on the main actor through the `DocumentEngine`; the
/// keystrokes of a word extend one open change (`DocumentCore.open`) instead of taking a seq each,
/// and the result is the state the unbatched keystrokes make, here and on every other replica.
@MainActor @Suite struct DocumentBatchingTests {
    typealias Typed = TextCommandTests

    /// Types `string` into `node`, collecting every outcome's outbox by seq (the last version of an
    /// open change wins); `sealing` seals after each keystroke (the unbatched pipeline).
    static func type(_ string: String, into node: OpID, _ core: inout DocumentCore, clock: TestClock, pause: TimeInterval = 0.1,
                     sealing: Bool = false, into changes: inout [UInt64: Wiretuner_Doc_V1_Change]) throws {
        for character in string {
            clock.advance(pause)
            let outcome = try core.perform(InsertText(node: node, text: String(character), at: .end, typing: true),
                                           recording: DocumentCore.Recording(limit: 100, now: clock.now))
            if let outbox = outcome?.outbox { changes[outbox.seq] = outbox }
            if sealing { core.seal() }
        }
    }

    /// The state a replica that never typed reaches from `changes` in seq order.
    static func replay(_ creation: Wiretuner_Doc_V1_Change, _ changes: [UInt64: Wiretuner_Doc_V1_Change]) -> EngineState {
        var state = EngineState()
        state.apply(creation)
        for seq in changes.keys.sorted() { state.apply(changes[seq]!) }
        return state
    }

    static func creation() throws -> (DocumentCore, OpID, TestClock, Wiretuner_Doc_V1_Change) {
        var core = DocumentCore(state: EngineState(), replica: 1)
        let clock = TestClock()
        let outcome = try core.perform(CreateTextBlock(.point(.zero), text: ""), recording: DocumentCore.Recording(limit: 100, now: clock.now))
        return (core, outcome!.change!.createdObjects[0], clock, outcome!.outbox!)
    }

    @Test func aWordIsOneChangeAndTheStateMatchesTheUnbatchedKeystrokes() throws {
        var (batched, node, clock, creation) = try Self.creation()
        // One creation for both (a new block's position is not deterministic).
        var unbatched = batched
        let unbatchedClock = TestClock()
        unbatchedClock.advance(clock.now.timeIntervalSince(unbatchedClock.now))
        let first = batched.nextSeq
        var merged: [UInt64: Wiretuner_Doc_V1_Change] = [:]
        var single: [UInt64: Wiretuner_Doc_V1_Change] = [:]
        let text = "hello world, this is typed"
        try Self.type(text, into: node, &batched, clock: clock, into: &merged)
        try Self.type(text, into: node, &unbatched, clock: unbatchedClock, sealing: true, into: &single)
        #expect(single.count == text.count, "unbatched, every keystroke is a change")
        #expect(merged.count == 5, "one change per word: \(merged.count)")
        #expect(batched.nextSeq == first + 5 && batched.open?.seq == first + 4, "the last word is still open")
        #expect(merged[first]!.ops.count == 6 && merged[first]!.label == "Type")
        #expect(Typed.string(batched, node) == text && Typed.string(unbatched, node) == text)
        // Same state here, and on a replica that receives either set of changes.
        let local = StateHash.of(batched.state.store)
        #expect(StateHash.of(unbatched.state.store) == local)
        #expect(StateHash.of(Self.replay(creation, merged).store) == local)
        #expect(StateHash.of(Self.replay(creation, single).store) == local)
        // Undo is untouched: two... five words are five steps, as before.
        _ = batched.undo(recording: DocumentCore.Recording(limit: 100, now: clock.now))
        #expect(Typed.string(batched, node) == "hello world, this is " && batched.open == nil)
    }

    @Test func aPauseAReceivedChangeUndoAndOtherCommandsSealTheOpenChange() throws {
        var (core, node, clock, _) = try Self.creation()
        var changes: [UInt64: Wiretuner_Doc_V1_Change] = [:]
        try Self.type("ab", into: node, &core, clock: clock, into: &changes)
        let open = try #require(core.open)
        // A pause: the next keystroke is a new undo step and a new change.
        try Self.type("c", into: node, &core, clock: clock, pause: 1.5, into: &changes)
        #expect(core.open!.seq == open.seq + 1)
        // A remote change seals it.
        var remote = Wiretuner_Doc_V1_Change()
        remote.replica = 99
        remote.seq = 1
        remote.startCounter = 1_000
        remote.ops = [Ops.noop()]
        core.receive(remote, serverSeq: 1)
        #expect(core.open == nil)
        try Self.type("d", into: node, &core, clock: clock, into: &changes)
        #expect(core.open!.seq == open.seq + 2, "after a received change the keystroke takes a seq of its own")
        // Another command seals it.
        _ = try core.perform(OpsCommand("Nothing", ops: [Ops.noop()]), recording: DocumentCore.Recording(limit: 100, now: clock.now))
        #expect(core.open == nil)
        try Self.type("e", into: node, &core, clock: clock, into: &changes)
        _ = core.undo(recording: DocumentCore.Recording(limit: 100, now: clock.now))
        #expect(core.open == nil)
        try Self.type("f", into: node, &core, clock: clock, into: &changes)
        core.rotate(to: 55)
        #expect(core.open == nil)
        // Inside a drag group typing does not open a change; a command that records no undo neither.
        _ = try core.perform(InsertText(node: node, text: "g", at: .end, typing: true), recording: .init(group: 3, limit: 100, now: clock.now))
        #expect(core.open == nil)
    }

    @Test func theOpenChangeStopsGrowingAtItsOpLimit() throws {
        var (core, node, clock, _) = try Self.creation()
        var changes: [UInt64: Wiretuner_Doc_V1_Change] = [:]
        try Self.type(String(repeating: "a", count: DocumentCore.openChangeOpLimit + 3), into: node, &core, clock: clock, pause: 0.01, into: &changes)
        #expect(changes.count == 2 && changes.values.map(\.ops.count).max() == DocumentCore.openChangeOpLimit)
    }

    // MARK: The engine and the façade

    @Test func performNowAppliesAndPublishesBeforeItReturns() throws {
        let doc = Document(memory: DocumentCore(state: EngineState(), replica: 7))
        var seen: [DocumentEvent.Origin] = []
        doc.observe { seen.append($0.origin) }
        let change = try #require(try doc.performNow(OpsCommand("Create Layer", ops: [Fixture.createLayer("A")])))
        #expect(seen == [.local] && doc.revision == 1 && doc.lastChange == change)
        #expect(doc.state.store.isCreated(OpID(counter: change.startCounter, replica: 7)))
        #expect(try doc.undoNow() != nil && seen == [.local, .undo])
        #expect(try doc.redoNow() != nil && seen == [.local, .undo, .redo])
    }

    @Test func theGateAndABackendFailureRefuseLocalChanges() throws {
        let engine = DocumentEngine(core: DocumentCore(state: EngineState(), replica: 7), persists: false)
        let recording = DocumentCore.Recording(limit: 10, now: Date())
        engine.setGate(DocumentEngine.Gate(readOnly: true))
        #expect(engine.gate.readOnly && !engine.gate.commentsAllowed)
        #expect(throws: DocumentEngine.Refusal.readOnly) { try engine.perform(OpsCommand("Create", ops: [Fixture.createLayer("A")]), recording: recording) }
        #expect(throws: DocumentEngine.Refusal.readOnly) { try engine.undo(recording: recording) }
        engine.setGate(DocumentEngine.Gate(readOnly: true, commentsAllowed: true))
        #expect(throws: DocumentEngine.Refusal.readOnly) { try engine.perform(OpsCommand("Create", ops: [Fixture.createLayer("A")]), recording: recording) }
        #expect(throws: DocumentEngine.Refusal.readOnly) { try engine.redo(recording: recording) }
        engine.setGate(DocumentEngine.Gate())
        #expect(!DocumentEngine.Gate(readOnly: false, commentsAllowed: true).commentsAllowed)
        _ = try engine.perform(OpsCommand("Create", ops: [Fixture.createLayer("A")]), recording: recording)
        struct Broken: Error {}
        engine.fail(Broken())
        #expect(engine.failure is Broken)
        #expect(throws: Broken.self) { try engine.perform(OpsCommand("Create", ops: [Fixture.createLayer("B")]), recording: recording) }
        #expect(throws: Broken.self) { try engine.undo(recording: recording) }
        #expect(!engine.hasPending, "an engine that keeps nothing queues nothing")
    }

    @Test func aPersistentEngineQueuesOutcomesAndCallsItsBackendOncePerBurst() throws {
        let engine = DocumentEngine(core: DocumentCore(state: EngineState(), replica: 7), persists: true)
        let calls = Mutex(0)
        engine.onPending { calls.withLock { $0 += 1 } }
        let recording = DocumentCore.Recording(limit: 10, now: Date())
        #expect(engine.lastLocalChange == nil)
        for name in ["A", "B", "C"] {
            _ = try engine.perform(OpsCommand("Create", ops: [Fixture.createLayer(name)]), recording: recording)
        }
        #expect(calls.withLock { $0 } == 1 && engine.hasPending && engine.lastLocalChange != nil)
        // `update` leaves the queue; `mutate` hands it over and empties it.
        engine.update { $0.seal() }
        #expect(engine.hasPending)
        let (pending, seen) = engine.mutate { core, queued in queued.count }
        #expect(pending.count == 3 && seen == 3 && !engine.hasPending)
        _ = try engine.undo(recording: recording)
        #expect(calls.withLock { $0 } == 2 && engine.takePending().count == 1)
        // A command that writes nothing queues nothing.
        _ = try engine.perform(OpsCommand("Nothing", ops: []), recording: recording)
        #expect(!engine.hasPending)
        _ = try engine.perform(OpsCommand("Create", ops: [Fixture.createLayer("D")]), recording: recording)
        engine.replace(with: DocumentCore(state: EngineState(), replica: 8))
        #expect(!engine.hasPending && engine.summary.replica == 8 && engine.core.nextSeq == 1)
        engine.onPending(nil)
    }

    @Test func aSequenceCommandsLaterStepsReadWhatTheEarlierOnesWrote() throws {
        var core = DocumentCore(state: EngineState(), replica: 7)
        let recording = DocumentCore.Recording(limit: 10, now: Date())
        let command = SequenceCommand("Create and rename", [
            OpsCommand("Create", ops: [Fixture.createLayer("A")]),
            StateCommand("Rename") { state in
                let node = state.store.nodes.first { state.store.isCreated($0) && $0.replica == 7 }
                return node.map { OpsCommand("Rename", ops: [Fixture.rename($0, "B")]) }
            },
            StateCommand("Nothing") { _ in nil },
        ])
        let change = try #require(try core.perform(command, recording: recording)?.change)
        #expect(change.ops.count == 2 && command.label == "Create and rename")
        #expect(core.state.register(OpID(counter: change.startCounter, replica: 7), Fixture.name)?.value == Fixture.nameValue("B"))
    }

    @Test func aMemoryBackendsActorCallsGoThroughTheEngine() async throws {
        let backend = MemoryBackend(replica: 7)
        let recording = DocumentCore.Recording(limit: 10, now: Date())
        let created = try #require(try await backend.perform(OpsCommand("Create", ops: [Fixture.createLayer("A")]), recording: recording).change)
        #expect(try await backend.undo(recording: recording).change != nil)
        #expect(try await backend.redo(recording: recording).change != nil)
        var remote = Wiretuner_Doc_V1_Change()
        remote.replica = 99
        remote.seq = 1
        remote.startCounter = 500
        remote.ops = [Ops.noop()]
        #expect(await backend.receive(remote, serverSeq: 1).change == remote)
        #expect(await backend.read { $0.store.isCreated(OpID(counter: created.startCounter, replica: 7)) })
        try await backend.flush()
        let summary = await backend.summary()
        let last = await backend.core.lastServerSeq
        #expect(last == 1 && summary.replica == 7)
    }
}
