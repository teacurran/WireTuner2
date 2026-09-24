import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
@testable import WireTuner

/// DATA-003's Text tool half (data-merge.adoc, "Text placeholders"): a typed `{{name}}` becomes a
/// placeholder as soon as its closing braces are typed, a placeholder is selected, stepped over and
/// deleted as one unit, and *Insert Field* types one at the insertion point in the pending format.
@Suite(.serialized) @MainActor struct TextPlaceholderTests {
    static func placeholders(_ document: DocumentHandle, _ node: OpID) -> [DataPlaceholder] {
        DataModel(document.state).placeholders(in: document.state.textNode(node)!)
    }

    @Test func typingTheClosingBracesMakesAPlaceholder() async throws {
        let document = DocumentHandle.memory(title: "Typing")
        _ = await document.perform(AddFields([AddFields.Field("first_name")])).value
        let node = try #require(await document.addText("Dear ", at: Point(x: 40, y: 40)))
        let session = TextEditingSession(document: document, sink: document, target: .node(node))
        session.select(anchor: 5, focus: 5)
        for character in "{{first_name}}" { session.insert(String(character)) }
        await session.settle()
        await document.settle()
        let spans = Self.placeholders(document, node)
        #expect(spans.count == 1 && spans[0].range == 5..<19 && spans[0].resolved?.name == "first_name" && document.undoTitle == "Undo Insert field")
        // A name matching no field is marked too (red, with the create-field offer).
        session.select(anchor: 19, focus: 19)
        for character in " {{nobody}}" { session.insert(String(character)) }
        await session.settle()
        await document.settle()
        #expect(Self.placeholders(document, node).last?.resolved == nil && Self.placeholders(document, node).count == 2)
        // Braces that do not close a name, and pasted text, stay text.
        session.insert("}}", typing: false)
        session.insert("x}")
        await session.settle()
        await document.settle()
        #expect(Self.placeholders(document, node).count == 2)
    }

    @Test func aPlaceholderIsSelectedSteppedOverAndDeletedAsOneUnit() async throws {
        let document = DocumentHandle.memory(title: "Units")
        _ = await document.perform(AddFields([AddFields.Field("city")])).value
        let field = try #require(DataModel(document.state).field(named: "city")?.id)
        let node = try #require(await document.addText("In ", at: Point(x: 40, y: 40)))
        _ = await document.perform(InsertPlaceholder(node: node, at: .end, field: field)).value
        _ = await document.perform(InsertText(node: node, text: " now", at: .end)).value
        await document.settle()
        #expect(document.state.textNode(node)?.string == "In {{city}} now")
        let session = TextEditingSession(document: document, sink: document, target: .node(node))
        // Arrow keys step over it.
        session.select(anchor: 3, focus: 3)
        session.move(.right, extend: false)
        #expect(session.selectedRange == 4..<4 || session.selectedRange == 11..<11)
        session.select(anchor: 4, focus: 4)
        session.move(.right, extend: false)
        #expect(session.selectedRange == 11..<11)
        session.select(anchor: 10, focus: 10)
        session.move(.left, extend: false)
        #expect(session.selectedRange == 3..<3)
        // A click inside selects all of it.
        let layout = try #require(session.layout)
        let inside = try #require(layout.caret(atOffset: 6, upstream: false))
        session.click(at: session.toPasteboard.apply(inside.baseline), granularity: .character, extend: false)
        #expect(session.selectedRange == 3..<11)
        // Delete next to it takes all of it.
        session.select(anchor: 11, focus: 11)
        session.delete(.backspace)
        await session.settle()
        await document.settle()
        #expect(document.state.textNode(node)?.string == "In  now")
        _ = await document.undo().value
        await document.settle()
        session.select(anchor: 3, focus: 3)
        session.delete(.forwardDelete)
        await session.settle()
        await document.settle()
        #expect(document.state.textNode(node)?.string == "In  now")
        _ = await document.undo().value
        await document.settle()
        // A selection touching it grows to cover it.
        session.select(anchor: 1, focus: 5)
        session.delete(.deleteSelection)
        await session.settle()
        await document.settle()
        #expect(document.state.textNode(node)?.string == "I now")
        // Ordinary deletes are unchanged.
        session.select(anchor: 5, focus: 5)
        session.delete(.backspace)
        await session.settle()
        await document.settle()
        #expect(document.state.textNode(node)?.string == "I no")
    }

    @Test func insertFieldTypesAPlaceholderAtTheInsertionPoint() async throws {
        let document = DocumentHandle.memory(title: "Insert")
        _ = await document.perform(AddFields([AddFields.Field("name")])).value
        let field = try #require(DataModel(document.state).field(named: "name")?.id)
        let node = try #require(await document.addText("Hi there", at: Point(x: 40, y: 40)))
        let session = TextEditingSession(document: document, sink: document, target: .node(node))
        session.select(anchor: 3, focus: 8)
        session.insertField(field)
        await session.settle()
        await document.settle()
        #expect(document.state.textNode(node)?.string == "Hi {{name}}")
        session.select(anchor: 0, focus: 0)
        session.format(.with { $0.size = 20 })
        session.insertField(field)
        await session.settle()
        await document.settle()
        let text = try #require(document.state.textNode(node))
        #expect(text.string == "{{name}}Hi {{name}}" && text.values(at: 2).contains(.with { $0.size = 20 }))
        // Before the block exists there is nowhere to insert.
        let pending = TextEditingSession(document: document, sink: document, target: .pending(.point(Point(x: 1, y: 1))))
        pending.insertField(field)
        await pending.settle()
    }
}
