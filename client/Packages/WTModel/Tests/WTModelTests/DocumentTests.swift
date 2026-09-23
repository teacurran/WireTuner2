import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto

/// APP-011: the command → change → inverse pipeline, menu titles, grouping and the "skip what
/// someone else changed" rule, over `MemoryBackend`.
@MainActor @Suite struct DocumentTests {
    static let local: UInt64 = 7
    static let remote: UInt64 = 99

    func document(undoLevels: Int = Document.defaultUndoLevels, clock: TestClock = TestClock()) async -> Document {
        await Document(backend: MemoryBackend(replica: Self.local), undoLevels: undoLevels, clock: clock.function)
    }

    /// Creates layer "A" (node 1:7) and renames it "B".
    func createAndRename(_ doc: Document) async throws -> OpID {
        let created = try await doc.perform(OpsCommand("Create Layer", ops: [Fixture.createLayer("A")]))
        let node = OpID(counter: created!.startCounter, replica: Self.local)
        try await doc.perform(OpsCommand("Rename", ops: [Fixture.rename(node, "B")]))
        return node
    }

    func name(_ doc: Document, _ node: OpID) async -> [UInt8]? {
        await doc.read { $0.register(node, Fixture.name)?.value }
    }

    @Test func performNumbersAppliesAndTitlesTheChange() async throws {
        let clock = TestClock()
        let doc = await document(clock: clock)
        #expect(doc.undoTitle == "Undo" && doc.redoTitle == "Redo" && !doc.canUndo && !doc.canRedo)
        #expect(doc.replica == Self.local && doc.revision == 0 && doc.lastChange == nil)
        let change = try #require(try await doc.perform(OpsCommand("Create Layer", ops: [Fixture.createLayer("A")])))
        #expect(change.replica == Self.local && change.seq == 1 && change.startCounter == 1 && change.label == "Create Layer")
        #expect(change.wallTimeMs == Int64(clock.now.timeIntervalSince1970 * 1000))
        #expect(doc.undoTitle == "Undo Create Layer" && doc.canUndo && doc.revision == 1 && doc.lastChange == change)
        let node = OpID(counter: 1, replica: Self.local)
        #expect(await name(doc, node) == Fixture.nameValue("A"))
        let rename = try #require(try await doc.perform(OpsCommand("Rename", ops: [Fixture.rename(node, "B")])))
        #expect(rename.seq == 2 && rename.startCounter == 2)
    }

    @Test func undoAndRedoRestoreTheLocalValue() async throws {
        let doc = await document()
        let node = try await createAndRename(doc)
        #expect(await name(doc, node) == Fixture.nameValue("B"))
        let undo = try #require(try await doc.undo())
        #expect(undo.label == "Undo Rename" && undo.seq == 3)
        #expect(await name(doc, node) == Fixture.nameValue("A"))
        #expect(doc.undoTitle == "Undo Create Layer" && doc.redoTitle == "Redo Rename" && doc.canRedo)
        let redo = try #require(try await doc.redo())
        #expect(redo.label == "Redo Rename" && redo.seq == 4)
        #expect(await name(doc, node) == Fixture.nameValue("B"))
        #expect(doc.undoTitle == "Undo Rename" && !doc.canRedo)
        // Undoing the creation deletes the node; redoing it restores it.
        try await doc.undo()
        try await doc.undo()
        #expect(await doc.read { $0.store.deleted(node)?.current.value } == true)
        try await doc.redo()
        #expect(await doc.read { $0.store.deleted(node)?.current.value } == false)
    }

    /// Vector: A renames, B renames the same register, A undoes: B's value stands, the undo emits
    /// nothing, and the redo item still appears.
    @Test func undoAfterARemoteOverwriteLeavesTheRemoteValue() async throws {
        let doc = await document()
        let node = try await createAndRename(doc)
        try await doc.receive(Fixture.change(Self.remote, seq: 1, start: 100, [Fixture.rename(node, "R")]), serverSeq: 1)
        #expect(await name(doc, node) == Fixture.nameValue("R") && doc.revision == 3)
        #expect(try await doc.undo() == nil)
        #expect(await name(doc, node) == Fixture.nameValue("R"))
        #expect(doc.redoTitle == "Redo Rename" && doc.undoTitle == "Undo Create Layer")
        // Redo finds nothing of its own to re-apply either.
        #expect(try await doc.redo() == nil)
        #expect(await name(doc, node) == Fixture.nameValue("R"))
    }

    /// A partial undo: the register someone else changed is skipped, the rest is undone.
    @Test func undoSkipsOnlyWhatSomeoneElseChanged() async throws {
        let doc = await document()
        let created = try await doc.perform(OpsCommand("Create Layer", ops: [Fixture.createLayer("A")]))
        let node = OpID(counter: created!.startCounter, replica: Self.local)
        try await doc.perform(OpsCommand("Edit", ops: [Ops.set(node, [Fixture.name, Fixture.note],
                                                                values: Fixture.layer(name: "B", note: "n"))]))
        var remote = Fixture.change(Self.remote, seq: 1, start: 100, [Fixture.rename(node, "R")])
        remote.baseServerSeq = 0
        try await doc.receive(remote, serverSeq: 1)
        let undo = try #require(try await doc.undo())
        #expect(undo.baseServerSeq == 1)
        #expect(await name(doc, node) == Fixture.nameValue("R"))
        #expect(await doc.read { $0.register(node, Fixture.note)?.value } == nil)
    }

    /// Vector: redo after undo restores the local value, unless someone wrote again meanwhile.
    @Test func redoAfterUndoRestoresTheLocalValueOnlyIfUntouched() async throws {
        let doc = await document()
        let node = try await createAndRename(doc)
        try await doc.undo()
        try await doc.redo()
        #expect(await name(doc, node) == Fixture.nameValue("B"))
        try await doc.undo()
        try await doc.receive(Fixture.change(Self.remote, seq: 1, start: 100, [Fixture.rename(node, "R")]), serverSeq: 1)
        #expect(try await doc.redo() == nil)
        #expect(await name(doc, node) == Fixture.nameValue("R"))
    }

    @Test func aDragGroupIsOneUndoStep() async throws {
        let doc = await document()
        let created = try await doc.perform(OpsCommand("Create Layer", ops: [Fixture.createLayer("A")]))
        let node = OpID(counter: created!.startCounter, replica: Self.local)
        try await doc.perform(OpsCommand("Move", ops: [Fixture.moveTo(node, 1)]))
        doc.beginGroup()
        doc.beginGroup()  // nested: the outermost group decides
        #expect(doc.isGrouping)
        for step in 2...60 {
            try await doc.perform(OpsCommand("Move", ops: [Fixture.moveTo(node, Double(step))]))
        }
        // Typing inside a group joins the group too.
        doc.endGroup()
        #expect(doc.isGrouping)
        try await doc.perform(OpsCommand("Move", ops: [Fixture.moveTo(node, 61)]))
        doc.endGroup()
        #expect(!doc.isGrouping)
        #expect(await doc.read { $0.register(node, Fixture.transform)?.value } == Fixture.txValue(61))
        let undo = try #require(try await doc.undo())
        #expect(undo.ops.count == 1)
        #expect(await doc.read { $0.register(node, Fixture.transform)?.value } == Fixture.txValue(1))
        #expect(doc.undoTitle == "Undo Move")
        // A new group after the first is a new step.
        doc.beginGroup()
        try await doc.perform(OpsCommand("Move", ops: [Fixture.moveTo(node, 70)]))
        doc.endGroup()
        doc.beginGroup()
        try await doc.perform(OpsCommand("Move", ops: [Fixture.moveTo(node, 80)]))
        doc.endGroup()
        try await doc.undo()
        #expect(await doc.read { $0.register(node, Fixture.transform)?.value } == Fixture.txValue(70))
    }

    @Test func typingCoalescesPerWordAndPause() async throws {
        let clock = TestClock()
        let doc = await document(clock: clock)
        let created = try await doc.perform(OpsCommand("Create Text", ops: [Ops.create(parent: Fixture.layers, position: [0x80],
                                                                                        props: Fixture.textBlock())]))
        let node = OpID(counter: created!.startCounter, replica: Self.local)
        var left = OpID.zero
        func type(_ chars: String) async throws {
            let change = try #require(try await doc.perform(Typing(node: node, left: left, chars: chars)))
            left = OpID(counter: change.startCounter + UInt64(chars.unicodeScalars.count) - 1, replica: Self.local)
            clock.advance(0.2)
        }
        func text() async -> String? { await doc.read { $0.text(node, Fixture.text)?.string } }
        for char in ["h", "i", " "] { try await type(char) }   // one word, ended by the space
        for char in ["y", "o"] { try await type(char) }        // a second word...
        clock.advance(1.5)
        try await type("u")                                     // ...split by a pause
        #expect(await text() == "hi you")
        try await doc.undo()
        #expect(await text() == "hi yo")
        try await doc.undo()
        #expect(await text() == "hi ")
        try await doc.undo()
        #expect(await text() == "")
        #expect(doc.undoTitle == "Undo Create Text")
        try await doc.redo()
        #expect(await text() == "hi ")
    }

    @Test func undoLevelsCapTheStack() async throws {
        let doc = await document(undoLevels: 5)
        let node = try await createAndRename(doc)
        for index in 0..<8 {
            try await doc.perform(OpsCommand("Rename", ops: [Fixture.rename(node, "N\(index)")]))
        }
        let summary = await doc.backend.summary()
        #expect(summary.undo.undoCount == 5)
        for _ in 0..<5 { try await doc.undo() }
        #expect(!doc.canUndo && doc.undoTitle == "Undo")
        #expect(try await doc.undo() == nil)
        #expect(await name(doc, node) == Fixture.nameValue("N2"))
        // Redo is capped by the same limit and re-enters the undo list.
        for _ in 0..<5 { try await doc.redo() }
        #expect(try await doc.redo() == nil)
        #expect(await name(doc, node) == Fixture.nameValue("N7"))
    }

    @Test func undoLevelsAreClamped() async {
        #expect(await document(undoLevels: 0).undoLevels == 1)
        #expect(await document(undoLevels: 5_000).undoLevels == 1_000)
        #expect(await document().undoLevels == 100)
    }

    @Test func aCommandWithoutOpsOrThatThrowsChangesNothing() async throws {
        let doc = await document()
        #expect(try await doc.perform(OpsCommand("Nothing", ops: [])) == nil)
        await #expect(throws: Failing.Failure.self) { try await doc.perform(Failing()) }
        #expect(doc.revision == 0 && !doc.canUndo)
        #expect(await doc.read { $0.clock.max } == 0)
    }

    @Test func aChangeThatChangesNothingUndoableIsNotAStep() async throws {
        let doc = await document()
        let change = try await doc.perform(OpsCommand("Nothing", ops: [Ops.noop()]))
        #expect(change?.ops.count == 1 && doc.revision == 1 && !doc.canUndo)
    }

    @Test func aDocumentOpensWithTheBackendsStack() async throws {
        let backend = MemoryBackend(replica: Self.local)
        let first = await Document(backend: backend)
        try await first.perform(OpsCommand("Create Layer", ops: [Fixture.createLayer("A")]))
        let second = await Document(backend: backend)
        #expect(second.undoTitle == "Undo Create Layer" && second.canUndo)
    }
}
