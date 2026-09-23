import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto

@Suite struct UndoStackTests {
    static let t0 = Date(timeIntervalSince1970: 0)

    /// A non-empty inverse (a real one, recorded by the engine).
    static func inverse(_ name: String = "A") -> Inverse {
        var state = EngineState()
        return state.applyLocal(Fixture.change(1, seq: 1, start: 1, [Fixture.createLayer(name)]))
    }

    @Test func titlesNameTheTopStep() {
        var stack = UndoStack()
        #expect(stack.undoTitle == "Undo" && stack.redoTitle == "Redo")
        stack.apply(.push(UndoEntry(label: "", inverse: Self.inverse(), updatedAt: Self.t0), limit: 10))
        #expect(stack.undoTitle == "Undo" && stack.canUndo)
        stack.apply(.push(UndoEntry(label: "Paste 3 objects", inverse: Self.inverse(), updatedAt: Self.t0), limit: 10))
        #expect(stack.undoTitle == "Undo Paste 3 objects")
        stack.apply(.undo(redo: UndoEntry(label: "Paste 3 objects", inverse: Self.inverse(), updatedAt: Self.t0)))
        #expect(stack.redoTitle == "Redo Paste 3 objects" && stack.canRedo && stack.undo.count == 1)
    }

    @Test func anEmptyInverseRecordsNothing() {
        let stack = UndoStack()
        #expect(stack.recording(Inverse(steps: []), label: "x", key: nil, stillOpen: true, now: Self.t0, limit: 5) == nil)
    }

    @Test func aNewStepClearsRedoAndClosesTheStepBelow() {
        var stack = UndoStack()
        let key = CoalesceKey.typing(node: OpID(counter: 1, replica: 1), field: Fixture.text)
        let typed = stack.recording(Self.inverse(), label: "Typing", key: key, stillOpen: true, now: Self.t0, limit: 5)!
        stack.apply(typed)
        #expect(stack.undo.last?.openKey == key)
        stack.apply(.push(UndoEntry(label: "Move", inverse: Self.inverse(), updatedAt: Self.t0), limit: 5))
        #expect(stack.undo.first?.openKey == nil)
        stack.apply(.undo(redo: UndoEntry(label: "Move", inverse: Self.inverse(), updatedAt: Self.t0)))
        // The typing step below is closed now: more typing starts a new step.
        let more = stack.recording(Self.inverse(), label: "Typing", key: key, stillOpen: true, now: Self.t0, limit: 5)!
        guard case .push = more else { Issue.record("expected a new step"); return }
        stack.apply(more)
        #expect(stack.redo.isEmpty && stack.undo.count == 2)
        // A joined step clears redo as well.
        stack.apply(.undo(redo: UndoEntry(label: "Typing", inverse: Self.inverse(), updatedAt: Self.t0)))
        stack.apply(.redo(undo: UndoEntry(label: "Typing", inverse: Self.inverse(), updatedAt: Self.t0, openKey: key), limit: 5))
        stack.apply(.undo(redo: UndoEntry(label: "X", inverse: Self.inverse(), updatedAt: Self.t0)))
        stack.apply(.replaceTop(UndoEntry(label: "Y", inverse: Self.inverse(), updatedAt: Self.t0)))
        #expect(stack.redo.isEmpty && stack.undoTitle == "Undo Y")
    }

    @Test func joinedStepsUndoAsOne() {
        var stack = UndoStack()
        let key = CoalesceKey.group(1)
        stack.apply(stack.recording(Self.inverse("A"), label: "Drag", key: key, stillOpen: true, now: Self.t0, limit: 5)!)
        let joined = stack.recording(Self.inverse("B"), label: "Other", key: key, stillOpen: true,
                                     now: Self.t0.addingTimeInterval(60), limit: 5)!
        guard case .replaceTop(let entry) = joined else { Issue.record("expected a join"); return }
        #expect(entry.label == "Drag" && entry.inverse.steps.count == Self.inverse().steps.count * 2)
    }

    @Test func aLimitBelowOneKeepsOne() {
        var stack = UndoStack()
        for _ in 0..<3 {
            stack.apply(.push(UndoEntry(label: "x", inverse: Self.inverse(), updatedAt: Self.t0), limit: 0))
        }
        #expect(stack.undo.count == 1)
    }
}

@Suite struct OpsTests {
    @Test func buildersFillEveryField() {
        let node = OpID(counter: 5, replica: 2)
        let move = Ops.move(node, parent: Fixture.layers, position: [0x81])
        #expect(move.move.node == node.proto && move.move.parent == Fixture.layers.proto && move.move.position == Data([0x81]))
        let deleted = Ops.setDeleted(node, false)
        #expect(deleted.setDeleted.node == node.proto && !deleted.setDeleted.deleted)
        let delete = Ops.textDelete(node, Fixture.text, first: OpID(counter: 9, replica: 2), count: 3)
        #expect(delete.textDelete.ranges.first?.count == 3 && delete.textDelete.ranges.first?.first.counter == 9)
        #expect(Ops.noop().op == .noop(Wiretuner_Doc_V1_Noop()))
        let insert = Ops.textInsert(node, Fixture.text, "ab", left: OpID(counter: 1, replica: 2), right: OpID(counter: 3, replica: 2))
        #expect(insert.textInsert.leftOrigin.counter == 1 && insert.textInsert.rightOrigin.counter == 3)
    }

    @Test func aChangeBuilderNumbersOpsByTheCountersTheyTake() {
        var builder = ChangeBuilder(replica: 3, startCounter: 10)
        #expect(builder.append(Fixture.createLayer("A")) == OpID(counter: 10, replica: 3))
        #expect(builder.append(Ops.textInsert(OpID(counter: 1, replica: 1), Fixture.text, "abc")) == OpID(counter: 11, replica: 3))
        #expect(builder.append(Ops.noop()) == OpID(counter: 14, replica: 3))
        #expect(builder.nextCounter == 15 && builder.ops.count == 3 && builder.startCounter == 10 && builder.replica == 3)
    }
}

@Suite struct DocumentCoreTests {
    @Test func replayAcknowledgeAndRotate() {
        var core = DocumentCore(state: EngineState(), replica: 7, nextSeq: 4, lastServerSeq: 9)
        core.replay(Fixture.change(7, seq: 1, start: 1, [Fixture.createLayer("A")]), serverSeq: 12)
        #expect(core.lastServerSeq == 9 && core.state.store.nodes.contains(OpID(counter: 1, replica: 7)))
        core.acknowledge(seq: 1, serverSeq: 12)
        core.rotate(to: 8)
        #expect(core.replica == 8 && core.nextSeq == 1)
        core.receive(Fixture.change(5, seq: 1, start: 50, [Fixture.createLayer("B")]), serverSeq: 20)
        #expect(core.lastServerSeq == 20)
    }

    @Test func wallTimeBeforeTheEpochIsZero() throws {
        var core = DocumentCore(state: EngineState(), replica: 7)
        let outcome = try core.perform(OpsCommand("A", ops: [Fixture.createLayer("A")]),
                                       recording: .init(limit: 5, now: Date(timeIntervalSince1970: -5)))
        #expect(outcome?.change?.wallTimeMs == 0)
        #expect(core.undo(recording: .init(limit: 5, now: Date(timeIntervalSince1970: 1)))?.change?.wallTimeMs == 1000)
    }
}
