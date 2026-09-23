import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto

/// Undoing and redoing several steps in a row over the same targets (UndoRebase.swift): each undo
/// is a new write, and the steps below still undo.
@MainActor @Suite struct UndoChainTests {
    static let r: UInt64 = 7

    func document() async -> Document {
        await Document(backend: MemoryBackend(replica: Self.r))
    }

    func create(_ doc: Document, _ props: Wiretuner_Doc_V1_NodeProps, position: [UInt8] = [0x80]) async throws -> OpID {
        let change = try await doc.perform(OpsCommand("Create", ops: [Ops.create(parent: Fixture.layers, position: position, props: props)]))
        return OpID(counter: change!.startCounter, replica: Self.r)
    }

    func perform(_ doc: Document, _ op: Wiretuner_Doc_V1_Op, _ label: String = "Edit") async throws -> Wiretuner_Doc_V1_Change {
        try #require(try await doc.perform(OpsCommand(label, ops: [op])))
    }

    @Test func registersUndoAndRedoInARow() async throws {
        let doc = await document()
        let node = try await create(doc, Fixture.layer(name: "A"))
        for name in ["B", "C", "D"] { _ = try await perform(doc, Fixture.rename(node, name)) }
        func name() async -> [UInt8]? { await doc.read { $0.register(node, Fixture.name)?.value } }
        for expected in ["C", "B", "A"] {
            #expect(try await doc.undo() != nil)
            #expect(await name() == Fixture.nameValue(expected))
        }
        for expected in ["B", "C", "D"] {
            #expect(try await doc.redo() != nil)
            #expect(await name() == Fixture.nameValue(expected))
        }
    }

    @Test func placementsUndoInARow() async throws {
        let doc = await document()
        let node = try await create(doc, Fixture.layer(name: "A"))
        _ = try await perform(doc, Ops.move(node, parent: Fixture.layers, position: [0x90]))
        _ = try await perform(doc, Ops.move(node, parent: Fixture.layers, position: [0xA0]))
        func position() async -> [UInt8]? { await doc.read { $0.store.placement(node)?.position } }
        try await doc.undo()
        #expect(await position() == [0x90])
        try await doc.undo()
        #expect(await position() == [0x80])
        try await doc.redo()
        try await doc.redo()
        #expect(await position() == [0xA0])
    }

    @Test func aDeletionAndTheCreationUndoInARow() async throws {
        let doc = await document()
        let node = try await create(doc, Fixture.layer(name: "A"))
        _ = try await perform(doc, Ops.setDeleted(node), "Delete")
        _ = try await perform(doc, Ops.setDeleted(node, false), "Restore")
        func deleted() async -> Bool? { await doc.read { $0.store.deleted(node)?.current.value } }
        try await doc.undo()
        #expect(await deleted() == true)
        try await doc.undo()
        #expect(await deleted() == false)
        try await doc.undo()   // the creation, after two undos wrote its deleted flag
        #expect(await deleted() == true)
        try await doc.redo()
        #expect(await deleted() == false)
        try await doc.redo()
        #expect(await deleted() == true)
        try await doc.redo()
        #expect(await deleted() == false)
    }

    @Test func elementsUndoInARow() async throws {
        let doc = await document()
        var props = Wiretuner_Doc_V1_NodeProps()
        props.page = Wiretuner_Doc_V1_PageProps()
        let page = try await create(doc, props)
        let guides = RegisterPath([3, 7])
        let inserted = try await perform(doc, Ops.elementInsert(page, guides, positions: [[0x80]]), "Add Guide")
        let element = guides.element(OpID(counter: inserted.startCounter, replica: Self.r))
        _ = try await perform(doc, Ops.elementMove(page, element, position: [0x90]), "Move Guide")
        _ = try await perform(doc, Ops.elementMove(page, element, position: [0xA0]), "Move Guide")
        _ = try await perform(doc, Ops.elementDelete(page, [element]), "Delete Guide")
        func state() async -> (position: [UInt8]?, deleted: Bool?) {
            await doc.read { ($0.store.element(page, element)?.position.current.value, $0.store.element(page, element)?.deleted?.current.value) }
        }
        try await doc.undo()
        #expect(await state().deleted == false)
        try await doc.undo()
        #expect(await state().position == [0x90])
        try await doc.undo()
        #expect(await state().position == [0x80])
        try await doc.undo()   // the insert, after the undo of the delete wrote its flag
        #expect(await state().deleted == true)
        for _ in 0..<4 { try await doc.redo() }
        let end = await state()
        #expect(end.position == [0xA0] && end.deleted == true)
    }

    @Test func membersUndoInARow() async throws {
        let doc = await document()
        var props = Wiretuner_Doc_V1_NodeProps()
        props.glyph = Wiretuner_Doc_V1_GlyphProps()
        let glyph = try await create(doc, props)
        let set = RegisterPath([220, 3])
        var values = Wiretuner_Doc_V1_NodeProps()
        values.glyph.codepoints = [65]
        _ = try await perform(doc, Ops.setAdd(glyph, set, values: values), "Add")
        _ = try await perform(doc, Ops.setAdd(glyph, set, values: values), "Add Again")
        _ = try await perform(doc, Ops.setRemove(glyph, set, values: values), "Remove")
        func members() async -> Int { await doc.read { $0.store.members(glyph, set).count } }
        #expect(await members() == 0)
        try await doc.undo()
        #expect(await members() == 1)
        try await doc.undo()
        try await doc.undo()   // the add, after the undo of the remove re-added the member
        #expect(await members() == 0)
    }

    @Test func textUndoesInARow() async throws {
        let doc = await document()
        let block = try await create(doc, Fixture.textBlock())
        let typed = try await perform(doc, Ops.textInsert(block, Fixture.text, "abc"), "Typing")
        let b = OpID(counter: typed.startCounter + 1, replica: Self.r)
        _ = try await perform(doc, Ops.textDelete(block, Fixture.text, first: b, count: 1), "Delete")
        func text() async -> String? { await doc.read { $0.text(block, Fixture.text)?.string } }
        #expect(await text() == "ac")
        try await doc.undo()
        #expect(await text() == "abc")
        try await doc.undo()   // the typing, after the undo of the delete re-inserted the b
        #expect(await text() == "")
        try await doc.redo()
        #expect(await text() == "abc")
        try await doc.redo()
        #expect(await text() == "ac")
    }
}
