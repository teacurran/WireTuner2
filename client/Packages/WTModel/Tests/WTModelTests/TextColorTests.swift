import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import WTText

/// TYPE-029 text and block colour (text-color.adoc).
@Suite @MainActor struct TextColorTests {
    static let red = Appearances.inline(red: 1, green: 0, blue: 0)

    /// The display items of `node` as the scene draws it.
    static func items(_ replica: Replica, _ node: OpID) throws -> [DisplayItem] {
        let fonts = DocumentFontIndex(state: replica.state)
        guard case .group(let group)? = TextLayoutReading.item(node, in: replica.state, engine: fonts.layoutEngine) else {
            throw TextEditError.notText(node)
        }
        return group.children
    }

    static func flattened(_ items: [DisplayItem]) -> [DisplayItem] {
        items.flatMap { item -> [DisplayItem] in
            if case .group(let group) = item { return flattened(group.children) }
            return [item]
        }
    }

    static func paths(_ items: [DisplayItem]) -> [PathItem] {
        flattened(items).compactMap { if case .path(let path) = $0 { path } else { nil } }
    }

    @Test func glyphFillStrokeAndBothReachTheDrawing() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "Fill Stroke Both")
        try a.perform(TextColor.fill(node: node, from: .start, to: TextFixture.at(a, node, 4), Self.red))
        try a.perform(TextColor.stroke(node: node, from: TextFixture.at(a, node, 5), to: .end))
        try a.perform(TextColor.fill(node: node, from: TextFixture.at(a, node, 12), to: .end, Self.red))
        let content = TextLayoutReading.content(TextFixture.text(a, node))
        let fills = content.runs.map(\.attributes.fill)
        #expect(fills.first == Color(red: 1, green: 0, blue: 0))
        #expect(content.runs.first?.attributes.stroke == nil)
        #expect(content.runs.last?.attributes.stroke?.style.width == 1)
        #expect(content.runs.last?.attributes.fill == Color(red: 1, green: 0, blue: 0))
        // Glyph strokes are drawn as outlines in the display list.
        let items = try Self.items(a, node)
        #expect(Self.paths(items).contains { $0.appearance.strokes.first?.style.width == 1 })
        // Removing: no fill draws clear glyphs; no stroke draws none.
        try a.perform(TextColor.removeFill(node: node, from: .start, to: TextFixture.at(a, node, 4)))
        try a.perform(TextColor.removeStroke(node: node, from: .start, to: .end))
        let removed = TextLayoutReading.content(TextFixture.text(a, node))
        #expect(removed.runs.first?.attributes.fill == .clear)
        #expect(removed.runs.allSatisfy { $0.attributes.stroke == nil })
        #expect(TextColor.defaultStroke.width == 1)
    }

    @Test func aDeletedSwatchLeavesTheTextColourUnchanged() throws {
        var a = Replica(1)
        let swatch = try #require(try a.perform(AddSwatch(Color(red: 0, green: 0.5, blue: 1), name: "Brand")))
        let id = OpID(counter: swatch.startCounter, replica: swatch.replica)
        let node = try TextFixture.block(&a, "Brand")
        let ref = ColorResolver(a.state).reference(to: id)
        try a.perform(TextColor.fill(node: node, from: .start, to: .end, ref))
        let before = TextLayoutReading.content(TextFixture.text(a, node), colors: ColorResolver(a.state)).runs[0].attributes.fill
        try a.perform(RemoveSwatches([id]))
        let after = TextLayoutReading.content(TextFixture.text(a, node), colors: ColorResolver(a.state)).runs[0].attributes.fill
        #expect(before == after)
        #expect(after.red == 0 && after.blue == 1)
    }

    @Test func blockFillsAndStrokesWithDisplayBorderAutoEnable() throws {
        var a = Replica(1)
        let node = try #require(try a.perform(CreateTextBlock(.area(Rect(x: 0, y: 0, width: 100, height: 40)), text: "Boxed"))).createdObjects[0]
        let add = try #require(try a.perform(AddTextBlockAppearance.fill(node)))
        #expect(add.label == "Add Fill")
        #expect(TextFixture.text(a, node).props.block.displayBorder)
        // The second paint does not write the flag again.
        let stroke = try #require(try a.perform(AddTextBlockAppearance.stroke(node)))
        #expect(stroke.label == "Add Stroke")
        #expect(stroke.ops.count == 1)
        let rows = TextBlockAppearance.rows(node, in: a.state)
        #expect(rows.map(\.list) == [.fills, .strokes])
        // Recolour the fill, thicken the stroke.
        try a.perform(SetTextBlockAppearance.color(node: node, row: rows[0], Self.red))
        var thick = Wiretuner_Doc_V1_Stroke()
        thick.settings.basic.width = 3
        let edit = try #require(try a.perform(SetTextBlockAppearance(node: node, row: rows[1], stroke: thick, fields: [[3, 2, 2]])))
        #expect(edit.label == "Stroke")
        let appearance = TextBlockAppearance.appearance(node, in: a.state)
        #expect(appearance.fills.count == 1 && appearance.strokes.first?.style.width == 3)
        // Drawn: the fill rectangle behind the text, the border in front.
        let items = try Self.items(a, node)
        let paths = Self.paths(items)
        #expect(paths.first?.appearance.fills.isEmpty == false)
        #expect(paths.last?.appearance.strokes.first?.style.width == 3)
        // Display border off hides both; the rows stay.
        try a.perform(SetTextBlock(node: node, block: .with { $0.displayBorder = false }, fields: [[6]]))
        #expect(Self.paths(try Self.items(a, node)).allSatisfy { $0.appearance.fills.isEmpty && $0.appearance.strokes.isEmpty })
        // Remove.
        let remove = try #require(try a.perform(RemoveTextBlockAppearance(node: node, row: rows[1])))
        #expect(remove.label == "Remove Stroke")
        #expect(RemoveTextBlockAppearance(node: node, row: rows[0]).label == "Remove Fill")
        #expect(SetTextBlockAppearance(node: node, row: rows[0], fields: [[2]]).label == "Fill")
        #expect(TextBlockAppearance.rows(node, in: a.state).map(\.list) == [.fills])
        // Refusals.
        #expect(throws: TextEditError.invalidValue("row")) { try a.perform(RemoveTextBlockAppearance(node: node, row: rows[1])) }
        #expect(throws: TextEditError.invalidValue("fields")) { try a.perform(SetTextBlockAppearance(node: node, row: rows[0], fields: [])) }
        #expect(throws: TextEditError.notText(WellKnown.layers)) { try a.perform(AddTextBlockAppearance.fill(WellKnown.layers)) }
        #expect(TextBlockAppearance.appearance(WellKnown.layers, in: a.state) == Appearance())
    }

    @Test func rowsAtOnePositionOrderByElementId() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "x")
        try a.perform(TestBlockRows(node: node))
        let rows = TextBlockAppearance.rows(node, in: a.state)
        #expect(rows.count == 2 && rows[0].element < rows[1].element)
        #expect(TextLayoutReading.sources(node, in: a.state).contains(WellKnown.settings))
    }

    @Test func paragraphAndColumnRulesDrawWithTheBlockStroke() throws {
        var a = Replica(1)
        let node = try #require(try a.perform(CreateTextBlock(.area(Rect(x: 0, y: 0, width: 200, height: 60)), text: "one\ntwo"))).createdObjects[0]
        try a.perform(AddTextBlockAppearance.stroke(node))
        try a.perform(SetTextBlock(node: node, block: .with { $0.displayBorder = false }, fields: [[6]]))
        try a.perform(SetParagraph(node: node, from: .start, to: .start, props: .with { $0.rule.mode = .paragraph }, fields: [[11, 1]]))
        // A rule with its own stroke on the second paragraph.
        try a.perform(SetParagraph(node: node, from: .end, to: .end, props: .with {
            $0.rule.mode = .centered
            $0.rule.widthPercent = 50
            $0.rule.basis = .column
            $0.rule.stroke = .with { $0.width = 4 }
        }, fields: [[11]]))
        let paragraphs = TextLayoutReading.content(TextFixture.text(a, node)).paragraphs
        #expect(paragraphs[0].rule.mode == .paragraph && paragraphs[0].rule.stroke == nil && paragraphs[0].rule.widthPercent == 100)
        #expect(paragraphs[1].rule.mode == .centered && paragraphs[1].rule.stroke?.style.width == 4 && paragraphs[1].rule.basis == .column)
        let strokes = Self.paths(try Self.items(a, node)).compactMap { $0.appearance.strokes.first?.style.width }
        #expect(strokes.contains(1) && strokes.contains(4))
    }

    @Test func effectsAreReadForTheDrawing() {
        func read(_ build: (inout Wiretuner_Doc_V1_TextEffect) -> Void) -> WTText.TextEffect? {
            var effect = Wiretuner_Doc_V1_TextEffect()
            build(&effect)
            return TextLayoutReading.attributes([.with { $0.effect = effect }]).effect
        }
        #expect(read { $0.highlight = .with { $0.width = 2; $0.color = Self.red } } == .highlight(WTText.TextLineEffect(width: 2, color: Color(red: 1, green: 0, blue: 0))))
        #expect(read { $0.underline = .with { $0.position = -2; $0.dash = .with { $0.lengths = [2, 1] } } }
                == .underline(WTText.TextLineEffect(position: -2, dash: [2, 1])))
        #expect(read { $0.strikethrough = .init() } == .strikethrough(WTText.TextLineEffect()))
        #expect(read { $0.inline = .with { $0.count = 2; $0.strokeWidth = 1 } }
                == .inline(WTText.TextInlineEffect(count: 2, strokeWidth: 1, strokeColor: .black, backgroundWidth: 0, backgroundColor: .white)))
        #expect(read { $0.shadow = .with { $0.offsetX = 5; $0.tint = 40 } } == .shadow(WTText.TextShadowEffect(offsetX: 5, offsetY: 0, color: .black, tint: 40)))
        #expect(read { $0.zoom = .with { $0.zoomTo = 30; $0.to = .with { $0.none = true } } }
                == .zoom(WTText.TextZoomEffect(zoomTo: 30, offsetX: 0, offsetY: 0, from: .black, to: .clear)))
        #expect(read { _ in } == nil)
        // A cleared stroke mark reads as none.
        #expect(TextLayoutReading.attributes([.with { $0.stroke = .init() }]).stroke == nil)
    }

    // MARK: Merge

    @Test func textFillAndBlockFillFromTwoReplicasBothApply() throws {
        var pair = Pair()
        let node = try TextFixture.block(&pair.a, "both")
        pair.sync()
        try pair.a.perform(TextColor.fill(node: node, from: .start, to: .end, Self.red))
        try pair.b.perform(AddTextBlockAppearance.fill(node, Appearances.basicFill(red: 0, green: 0, blue: 1)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        for replica in [pair.a, pair.b] {
            #expect(TextLayoutReading.content(TextFixture.text(replica, node)).runs[0].attributes.fill == Color(red: 1, green: 0, blue: 0))
            #expect(TextBlockAppearance.appearance(node, in: replica.state).fills.count == 1)
            #expect(TextFixture.text(replica, node).props.block.displayBorder)
        }
    }
}

/// A fill and a stroke inserted at the same position (a tie two replicas could make).
struct TestBlockRows: Command {
    var node: OpID
    var label: String { "Rows" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        builder.append(Ops.elementInsert(node, TextBlockAppearance.sequence(.strokes), positions: [[0x80]],
                                         values: TextBlockAppearance.values { $0.strokes = [Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 1)] }))
        builder.append(Ops.elementInsert(node, TextBlockAppearance.sequence(.fills), positions: [[0x80]],
                                         values: TextBlockAppearance.values { $0.fills = [Appearances.basicFill(red: 0, green: 0, blue: 0)] }))
    }
}
