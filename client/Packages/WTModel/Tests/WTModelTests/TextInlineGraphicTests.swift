import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import WTText

/// TYPE-038 inline graphics (text-effects.adoc, "Inline graphics").
@Suite @MainActor struct TextInlineGraphicTests {
    /// A copied 10 x 20 rectangle (and optionally a second one), as the clipboard holds it.
    static func payload(_ replica: inout Replica, count: Int = 1) throws -> ClipboardPayload {
        var nodes: [OpID] = []
        for index in 0..<count {
            let change = try replica.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 20),
                                                         transform: .translation(x: 300 + Double(index) * 20, y: 300)))
            nodes.append(try #require(change).createdObjects[0])
        }
        return ClipboardPayload(copying: nodes, from: replica.state)
    }

    static func placements(_ replica: Replica, _ node: OpID) -> [(offset: Int, graphic: OpID)] {
        InlineGraphics.placements(TextFixture.text(replica, node))
    }

    @Test func pasteSpecialMakesAChildAPlaceholderAndAMark() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "ab")
        let payload = try Self.payload(&a)
        let change = try #require(try a.perform(PasteInlineGraphic(node: node, at: TextFixture.at(a, node, 1), payload: payload)))
        #expect(change.label == "Paste")
        let text = TextFixture.text(a, node)
        #expect(text.string == "a\u{FFFC}b")
        let placements = Self.placements(a, node)
        #expect(placements.count == 1 && placements[0].offset == 1)
        let graphic = placements[0].graphic
        #expect(a.state.store.placement(graphic)?.parent == node)
        #expect(a.state.nodeKind(graphic) == .rect)
        // The layout reads the graphic with its own bounds; typing after it does not grow the mark.
        let context = TextReadingContext(node, in: a.state)
        let bounds = try #require(context.graphics[graphic]?.bounds)
        // Its drawn bounds: the 10 x 20 rectangle with its stroke's (mitred) outset.
        #expect(bounds.width >= 10 && bounds.width <= 14 && bounds.height >= 20 && bounds.height <= 24)
        let content = TextLayoutReading.content(text, context: context)
        #expect(content.runs.contains { $0.text == "\u{FFFC}" && $0.attributes.inlineGraphic != nil })
        try a.perform(InsertText(node: node, text: "Z", at: TextFixture.at(a, node, 2)))
        #expect(Self.placements(a, node).count == 1)
        // Several objects paste as one grouped graphic.
        let two = try Self.payload(&a, count: 2)
        try a.perform(PasteInlineGraphic(node: node, at: .end, payload: two))
        let grouped = try #require(Self.placements(a, node).last?.graphic)
        #expect(a.state.nodeKind(grouped) == .group)
        #expect(a.state.liveChildren(grouped).count == 2)
        #expect(throws: TextEditError.invalidValue("payload")) { try a.perform(PasteInlineGraphic(node: node, at: .end, payload: ClipboardPayload(nodes: []))) }
    }

    @Test func theGraphicFlowsWithTheTextAcrossALineBreak() throws {
        var a = Replica(1)
        let node = try #require(try a.perform(CreateTextBlock(.area(Rect(x: 0, y: 0, width: 60, height: 200)), text: "word word word"))).createdObjects[0]
        let payload = try Self.payload(&a)
        try a.perform(PasteInlineGraphic(node: node, at: .end, payload: payload))
        let fonts = DocumentFontIndex(state: a.state)
        var layout = TextLayoutReading.layout(TextFixture.text(a, node), engine: fonts.layoutEngine, state: a.state)
        let before = try #require(layout.inlineGraphics().first)
        // Typing before it pushes it along; enough text moves it down a line.
        try a.perform(InsertText(node: node, text: "more words here ", at: .start))
        layout = TextLayoutReading.layout(TextFixture.text(a, node), engine: fonts.layoutEngine, state: a.state)
        let after = try #require(layout.inlineGraphics().first)
        #expect(after.transform.ty > before.transform.ty)
        #expect(after.offset == before.offset + 16)
        // The scene draws the graphic's own items inside the text item.
        guard case .group(let group)? = TextLayoutReading.item(node, in: a.state, engine: fonts.layoutEngine) else {
            Issue.record("item"); return
        }
        #expect(TextColorTests.paths(group.children).contains { $0.path.elements.count == 6 && $0.appearance.strokes.count == 1 })
    }

    @Test func aMissingGraphicDrawsAnEmptyBoxAndASecondReferenceNothing() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "x")
        // A mark naming a node that is not there, and two placeholders naming one graphic.
        try a.perform(TestPlaceholders(node: node, graphics: [OpID(counter: 77, replica: 7)]))
        let payload = try Self.payload(&a)
        try a.perform(PasteInlineGraphic(node: node, at: .end, payload: payload))
        let graphic = try #require(Self.placements(a, node).last?.graphic)
        try a.perform(TestPlaceholders(node: node, graphics: [graphic]))
        let content = TextLayoutReading.content(TextFixture.text(a, node), context: TextReadingContext(node, in: a.state))
        let graphics = content.runs.filter { $0.text == "\u{FFFC}" }.map(\.attributes.inlineGraphic)
        #expect(graphics.count == 3)
        #expect(graphics[0]?.items == nil && graphics[0] != nil)
        #expect(graphics[1]?.items != nil)
        #expect(graphics[2] == nil)
        // Not a text node: no graphics.
        #expect(InlineGraphics.graphics(of: WellKnown.layers, in: a.state).isEmpty)
    }

    @Test func deletingThePlaceholderDeletesTheGraphicAndRestoreBringsBothBack() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "ab")
        let payload = try Self.payload(&a)
        try a.perform(PasteInlineGraphic(node: node, at: TextFixture.at(a, node, 1), payload: payload))
        let graphic = try #require(Self.placements(a, node).first?.graphic)
        try a.perform(DeleteText(node: node, from: TextFixture.at(a, node, 1), to: TextFixture.at(a, node, 2)))
        #expect(!a.state.isLive(graphic))
        #expect(TextFixture.text(a, node).string == "ab")
        let restore = try #require(try a.perform(RestoreInlineGraphic(node: node, graphic: graphic)))
        #expect(restore.label == "Restore")
        #expect(a.state.isLive(graphic))
        #expect(TextFixture.text(a, node).string == "a\u{FFFC}b")
        #expect(Self.placements(a, node).map(\.graphic) == [graphic])
        // Restoring again changes nothing; a graphic of another node is refused.
        #expect(try a.perform(RestoreInlineGraphic(node: node, graphic: graphic)) == nil)
        #expect(throws: TextEditError.invalidValue("graphic")) { try a.perform(RestoreInlineGraphic(node: node, graphic: node)) }
        // Deleting a range with the placeholder and a second reference outside keeps the graphic.
        try a.perform(TestPlaceholders(node: node, graphics: [graphic]))
        try a.perform(DeleteText(node: node, from: .start, to: TextFixture.at(a, node, 3)))
        #expect(a.state.isLive(graphic))
    }

    @Test func restoringAGraphicThatNeverHadAPlaceholderAddsOneAtTheEnd() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "ab")
        let rect = try #require(try a.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 3, height: 3)))).createdObjects[0]
        try a.perform(TestMove(node: rect, parent: node))
        try a.perform(RestoreInlineGraphic(node: node, graphic: rect))
        #expect(Self.placements(a, node).map(\.offset) == [2])
    }

    @Test func cutAndPasteElsewhereMovesTheGraphic() throws {
        var a = Replica(1)
        let first = try TextFixture.block(&a, "one")
        let second = try TextFixture.block(&a, "two")
        let payload = try Self.payload(&a)
        try a.perform(PasteInlineGraphic(node: first, at: .end, payload: payload))
        let graphic = try #require(Self.placements(a, first).first?.graphic)
        // Cut: the character and the node go.
        try a.perform(DeleteText(node: first, from: TextFixture.at(a, first, 3), to: .end))
        let change = try #require(try a.perform(PlaceInlineGraphic(node: second, at: .start, graphic: graphic)))
        #expect(change.label == "Paste")
        #expect(a.state.store.placement(graphic)?.parent == second)
        #expect(a.state.isLive(graphic))
        #expect(Self.placements(a, second).map(\.graphic) == [graphic])
        #expect(Self.placements(a, first).isEmpty)
        // Placing it again in the same block only adds a placeholder.
        try a.perform(PlaceInlineGraphic(node: second, at: .end, graphic: graphic))
        #expect(Self.placements(a, second).count == 2)
        #expect(throws: TextEditError.invalidValue("graphic")) { try a.perform(PlaceInlineGraphic(node: second, at: .end, graphic: second)) }
    }

    @Test func anInlineGraphicInAStyledParagraphIsAnOverride() throws {
        var a = Replica(1)
        let style = try TextStyleTests.style(&a, name: "Body") { $0.character.size = 12 }
        let node = try TextFixture.block(&a, "ab")
        try a.perform(ApplyParagraphStyle(node: node, from: .start, to: .end, style: style))
        #expect(a.state.textStyles.overrides(in: TextFixture.text(a, node), paragraph: 0).character.isEmpty)
        try a.perform(PasteInlineGraphic(node: node, at: TextFixture.at(a, node, 1), payload: try Self.payload(&a)))
        #expect(a.state.textStyles.overrides(in: TextFixture.text(a, node), paragraph: 0).character == ["17"])
    }

    // MARK: Merge

    @Test func deleteTheParagraphVersusEditingTheGraphicThenRestore() throws {
        var pair = Pair()
        let node = try TextFixture.block(&pair.a, "one\ntwo")
        let payload = try Self.payload(&pair.a)
        try pair.a.perform(PasteInlineGraphic(node: node, at: TextFixture.at(pair.a, node, 1), payload: payload))
        pair.sync()
        let graphic = try #require(Self.placements(pair.a, node).first?.graphic)
        // A deletes the first paragraph; B moves the graphic's rectangle.
        try pair.a.perform(DeleteText(node: node, from: .start, to: TextFixture.at(pair.a, node, 5)))
        try pair.b.perform(SetTransforms([(graphic, .translation(x: 5, y: 5))]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(!pair.b.state.isLive(graphic))
        try pair.b.perform(RestoreInlineGraphic(node: node, graphic: graphic))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        for replica in [pair.a, pair.b] {
            #expect(replica.state.isLive(graphic))
            #expect(Self.placements(replica, node).map(\.graphic) == [graphic])
            #expect(replica.state.props(graphic).rect.common.transform.tx == 5)
        }
    }

    @Test func twoReplicasPasteDifferentGraphicsAtOneAnchor() throws {
        var pair = Pair()
        let node = try TextFixture.block(&pair.a, "ab")
        pair.sync()
        let fromA = try Self.payload(&pair.a)
        let fromB = try Self.payload(&pair.b)
        try pair.a.perform(PasteInlineGraphic(node: node, at: TextFixture.at(pair.a, node, 1), payload: fromA))
        try pair.a.perform(InsertText(node: node, text: "A", at: TextFixture.at(pair.a, node, 2)))
        try pair.b.perform(PasteInlineGraphic(node: node, at: TextFixture.at(pair.b, node, 1), payload: fromB))
        try pair.b.perform(InsertText(node: node, text: "B", at: TextFixture.at(pair.b, node, 2)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let merged = TextFixture.text(pair.a, node).string
        // Each side's graphic stays with the character typed after it.
        #expect(merged == "a\u{FFFC}A\u{FFFC}Bb" || merged == "a\u{FFFC}B\u{FFFC}Ab")
        #expect(Set(Self.placements(pair.a, node).map(\.graphic)).count == 2)
    }
}

/// Inserts one U+FFFC per graphic at the end of the text, each with its `inline_graphic` mark --
/// states the commands never write (a mark naming a missing node, a second reference).
struct TestPlaceholders: Command {
    var node: OpID
    var graphics: [OpID]
    var label: String { "Test" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var left = state.insertionOrigins(node, TextFields.text, at: TextNode(node, in: state)!.length, stableSeq: 0).left
        for graphic in graphics {
            let char = builder.append(Ops.textInsert(node, TextFields.text, "\u{FFFC}", left: left))
            builder.append(TextEditing.mark(node, InlineGraphics.mark(graphic), first: char, last: char, next: .zero))
            left = char
        }
    }
}
