import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// OBJ-036's end-to-end check of the user-facing undo rules (undo.adoc, "Undo in a shared
/// document"; crdt-model.adoc, "Undo") for every op kind, the *Undo levels* cap, the menu titles
/// and a relaunch.  The store half of the cap and of the relaunch (the `undo` table) is WTSync's
/// `LocalStoreTests.theUndoStackIsPersistedCappedAndRebased`.
@Suite struct UndoRulesTests {
    static func recording(limit: Int = 100) -> DocumentCore.Recording {
        DocumentCore.Recording(limit: limit, now: Replica.now)
    }

    /// Redoes on `replica` and relays the change to `other` (the pair's `sync` relays only what
    /// `perform` and `undo` sent).
    @discardableResult
    static func redo(_ replica: inout Replica, relayingTo other: inout Replica) -> Wiretuner_Doc_V1_Change? {
        let outcome = replica.core.redo(recording: recording())
        if let change = outcome?.outbox { other.receive([change]) }
        return outcome?.change
    }

    static func tx(_ node: OpID, in state: EngineState) -> Double {
        Objects.transform(of: node, in: state).tx
    }

    @Test func titlesFollowLabelsAndANewChangeClearsRedo() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        try a.perform(MoveObjects([rect], by: Vector(dx: 5, dy: 0)))
        #expect(a.core.undoStack.undoTitle == "Undo Move")
        try a.perform(PasteAttributes(AttributePayload(stack: []), to: [rect]))
        #expect(a.core.undoStack.undoTitle == "Undo Paste attributes")
        let undone = a.undo()
        let undo = try #require(undone)
        #expect(undo.label == "Undo Paste attributes")
        #expect(a.core.undoStack.redoTitle == "Redo Paste attributes" && a.core.undoStack.canRedo)
        try a.perform(MoveObjects([rect], by: Vector(dx: 1, dy: 0)))
        #expect(!a.core.undoStack.canRedo && a.core.undoStack.redoTitle == "Redo")
    }

    @Test func undoLevelsFiveKeepsFiveStepsAfterTen() throws {
        var core = DocumentCore(state: EngineState(), replica: 0xA)
        _ = try core.perform(LayerFixture.rect(on: nil), recording: Self.recording(limit: 5))
        let rect = core.state.store.children(core.state.store.children(WellKnown.layers)[0])[0]
        for step in 1...10 {
            _ = try core.perform(MoveObjects([rect], by: Vector(dx: Double(step), dy: 0)), recording: Self.recording(limit: 5))
        }
        #expect(core.undoStack.undo.count == 5)
        for _ in 0..<5 { #expect(core.undo(recording: Self.recording(limit: 5))?.change != nil) }
        #expect(core.undo(recording: Self.recording(limit: 5)) == nil)
        // Five undone: the object sits where the fifth move left it (1 + 2 + 3 + 4 + 5).
        #expect(Self.tx(rect, in: core.state) == 15)
    }

    @Test func tenChangesStayUndoableAcrossARelaunch() throws {
        var core = DocumentCore(state: EngineState(), replica: 0xA)
        _ = try core.perform(LayerFixture.rect(on: nil), recording: Self.recording())
        let rect = core.state.store.children(core.state.store.children(WellKnown.layers)[0])[0]
        for _ in 1...10 {
            _ = try core.perform(MoveObjects([rect], by: Vector(dx: 1, dy: 0)), recording: Self.recording())
        }
        // What the local store persists: the state, the sequence and the stack.
        var relaunched = DocumentCore(state: core.state, replica: 0xA, nextSeq: core.nextSeq, undoStack: core.undoStack)
        for _ in 1...10 { #expect(relaunched.undo(recording: Self.recording())?.change != nil) }
        #expect(Self.tx(rect, in: relaunched.state) == 0)
        #expect(relaunched.undoStack.canUndo)   // the creation is still there
    }

    @Test func aRemoteMoveStandsAgainstUndoAndRedoRestoresOnlyAnUntouchedValue() throws {
        var pair = Pair()
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        pair.sync()
        // A moves, B moves, A undoes: B's matrix stands.
        try pair.a.perform(MoveObjects([rect], by: Vector(dx: 10, dy: 0)))
        pair.sync()
        try pair.b.perform(MoveObjects([rect], by: Vector(dx: 20, dy: 0)))
        pair.sync()
        let partial = pair.a.undo()
        #expect(partial == nil)                               // a partial undo: nothing left to undo
        #expect(pair.a.core.undoStack.canRedo)               // the redo item still appears
        pair.sync()
        #expect(Self.tx(rect, in: pair.a.state) == 30 && pair.a.state.stateHash == pair.b.state.stateHash)
        // A moves and undoes; nobody writes again: redo restores A's value.
        try pair.a.perform(MoveObjects([rect], by: Vector(dx: 5, dy: 0)))
        pair.a.undo()
        pair.sync()
        #expect(Self.redo(&pair.a, relayingTo: &pair.b) != nil)
        #expect(Self.tx(rect, in: pair.a.state) == 35 && Self.tx(rect, in: pair.b.state) == 35)
        // A moves and undoes; B writes again: redo leaves B's value.
        try pair.a.perform(MoveObjects([rect], by: Vector(dx: 5, dy: 0)))
        pair.a.undo()
        pair.sync()
        try pair.b.perform(MoveObjects([rect], by: Vector(dx: 100, dy: 0)))
        pair.sync()
        #expect(Self.redo(&pair.a, relayingTo: &pair.b) == nil)
        #expect(Self.tx(rect, in: pair.a.state) == 135 && pair.a.state.stateHash == pair.b.state.stateHash)
    }

    @Test func undoingACreationKeepsARemoteEditOnTheTombstone() throws {
        var pair = Pair()
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        pair.sync()
        try pair.b.perform(SetNameOrNote([rect], .name, "Theirs"))
        pair.sync()
        pair.a.undo()
        pair.sync()
        #expect(!pair.a.state.isLive(rect) && pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(NodeValues.common(pair.a.state.props(rect))?.name == "Theirs")
    }

    @Test func undoingADeletionBringsTheEditsMadeInBetween() throws {
        var pair = Pair()
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        pair.sync()
        try pair.a.perform(DeleteObjectsForClipTest([rect]))
        pair.sync()
        var note = Wiretuner_Doc_V1_NodeProps()
        note.rect.common.note = "Theirs"
        try pair.b.perform(OpsCommand("Note", ops: [Ops.set(rect, [RegisterPath([21, 1, 2])], values: note)]))
        pair.sync()
        pair.a.undo()
        pair.sync()
        #expect(pair.a.state.isLive(rect) && pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(NodeValues.common(pair.a.state.props(rect))?.note == "Theirs")
    }

    @Test func undoingAMoveNodeRestoresTheParentOnlyIfStillOurs() throws {
        var pair = Pair()
        let row = try ArrangeTests.row(3, on: &pair.a)
        pair.sync()
        let group = try pair.a.perform(GroupObjects([row[0], row[1]]))!.createdObjects[0]
        pair.sync()
        try pair.b.perform(Ungroup([group]))
        let layer = Objects.parent(of: row[2], in: pair.b.state)!
        pair.sync()
        pair.a.undo()                                         // the group's creation and the members' moves
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        // B's moves out of the group are newer: the members stay where B put them.
        #expect(Objects.parent(of: row[0], in: pair.a.state) == layer && Objects.parent(of: row[1], in: pair.a.state) == layer)
    }

    @Test func elementAndTextOpsUndoAsTheRulesSay() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let before = AppearanceEditing.stack(rect, in: a.state)
        try a.perform(AddAppearance.fill([rect]))
        a.undo()                                              // an ElementInsert: the element is deleted
        #expect(AppearanceEditing.stack(rect, in: a.state) == before)
        let text = try LayerFixture.object(CreateTextBlock(.point(Point(x: 0, y: 0)), text: "ab"), on: &a)
        try a.perform(InsertText(node: text, text: "cd", at: .end))
        #expect(a.state.textNode(text)?.string == "abcd")
        a.undo()                                              // a TextInsert: its characters are deleted
        #expect(a.state.textNode(text)?.string == "ab")
        let node = try #require(a.state.textNode(text))
        try a.perform(DeleteText(node: text, from: node.anchor(at: 0), to: node.anchor(at: 1)))
        #expect(a.state.textNode(text)?.string == "b")
        a.undo()                                              // a TextDelete: re-inserted as fresh characters
        let restored = try #require(a.state.textNode(text))
        #expect(restored.string == "ab" && restored.chars[0] != node.chars[0])
    }
}
