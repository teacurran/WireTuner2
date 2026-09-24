import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// The document's default attributes (OBJ-037): creation-time copying, the current colours over
/// them, the style link, *Changing object changes defaults* and the merge rules.
@Suite struct DocumentDefaultsTests {
    static let red = Appearances.basicFill(red: 1, green: 0, blue: 0).settings.basic.color
    static let blue = Appearances.basicFill(red: 0, green: 0, blue: 1).settings.basic.color

    static func defaults(_ state: EngineState) -> Wiretuner_Doc_V1_AppearanceProps {
        state.props(WellKnown.settings).settings.defaults.appearance
    }

    static func fills(_ node: OpID, _ state: EngineState) -> [Wiretuner_Doc_V1_Fill] {
        NodeValues.appearance(state.props(node))?.fills ?? []
    }

    @Test func anEmptyStackReadsAsTheBuiltInDefaults() {
        #expect(DocumentDefaults.appearance(in: EngineState()) == Appearances.standard)
        let colors = DocumentDefaults.colors(of: Appearances.standard)
        #expect(colors.fill == .noColor && colors.stroke == .color(Appearances.standard.strokes[0].settings.basic.color))
    }

    @Test func addingADefaultFillReachesTheNextRectangleAsACopy() throws {
        var a = Replica(0xA)
        let change = try #require(try a.perform(AddAppearance.fill([WellKnown.settings], Appearances.basicFill(red: 1, green: 0, blue: 0))))
        #expect(change.ops.count == 1)
        guard case .elementInsert(let insert)? = change.ops[0].op else { Issue.record("not an ElementInsert"); return }
        #expect(OpID(insert.node) == WellKnown.settings && RegisterPath(insert.sequence) == RegisterPath([2, 10, 1, 1]))
        let appearance = DocumentDefaults.appearance(in: a.state)
        #expect(appearance.fills.map(\.settings.basic.color) == [Self.red] && appearance.strokes.isEmpty)
        #expect(appearance.fills.allSatisfy { !$0.hasID }, "the copy carries no element id")
        let rect = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10), appearance: appearance), on: &a)
        let fill = try #require(Self.fills(rect, a.state).first)
        let defaultID = try #require(OpID(element: Self.defaults(a.state).fills[0].id))
        #expect(fill.settings.basic.color == Self.red && OpID(element: fill.id) != defaultID, "fresh element ids")
        // Editing the defaults afterwards leaves the rectangle alone: no reference.
        try a.perform(SetAppearanceColor([(WellKnown.settings, AppearanceRow(.fills, defaultID))], color: Self.blue))
        #expect(Self.fills(rect, a.state)[0].settings.basic.color == Self.red)
        #expect(DocumentDefaults.appearance(in: a.state).fills[0].settings.basic.color == Self.blue)
    }

    @Test func currentColoursLayOverTheDefaults() {
        var base = Appearances.standard
        base.fills = [Appearances.basicFill(red: 0, green: 1, blue: 0)]
        let recoloured = DocumentDefaults.applying(fill: .color(Self.red), stroke: .color(Self.blue), to: base)
        #expect(recoloured.fills.map(\.settings.basic.color) == [Self.red] && recoloured.strokes.map(\.settings.basic.color) == [Self.blue])
        let none = DocumentDefaults.applying(fill: .noColor, stroke: .noColor, to: base)
        #expect(none.fills.isEmpty && none.strokes.isEmpty)
        #expect(DocumentDefaults.applying(fill: nil, stroke: nil, to: base) == base)
        let added = DocumentDefaults.applying(fill: .color(Self.red), stroke: .color(Self.blue), to: Wiretuner_Doc_V1_AppearanceProps())
        #expect(added.fills.map(\.settings.basic.color) == [Self.red])
        #expect(added.strokes.map(\.settings.basic.color) == [Self.blue] && added.strokes[0].settings.basic.width == 1)
        #expect(DocumentDefaults.newObjectAppearance(in: EngineState(), fill: .color(Self.red)).fills.count == 1)
        var pattern = base
        pattern.fills[0].settings.kind = .pattern
        pattern.strokes[0].settings.kind = .brush
        let colors = DocumentDefaults.colors(of: pattern)
        #expect(colors.fill == .noColor && colors.stroke == .noColor, "only basic elements have a well colour")
        let over = DocumentDefaults.applying(fill: .color(Self.red), stroke: .color(Self.red), to: pattern)
        #expect(over.fills.count == 2 && over.strokes.count == 2, "a basic element goes on top of a pattern")
    }

    @Test func aStyleLinksTheDefaultsAndDanglingReadsAsNormal() throws {
        var a = Replica(0xA)
        let style = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        var look = Appearances.standard
        look.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0)]
        try a.perform(AddAppearance.fill([WellKnown.settings]))
        let change = try #require(try a.perform(SetDefaultsStyle(style: style, appearance: look)))
        #expect(change.label == "Change default attributes")
        #expect(DocumentDefaults.style(in: a.state) == style)
        #expect(DocumentDefaults.appearance(in: a.state).fills.map(\.settings.basic.color) == [Self.red])
        #expect(DocumentDefaults.appearance(in: a.state).strokes.count == 1)
        try a.perform(DeleteNodes([style]))
        #expect(DocumentDefaults.style(in: a.state) == nil, "a dangling style reads as Normal")
        try a.perform(SetDefaultsStyle(style: nil, appearance: Wiretuner_Doc_V1_AppearanceProps()))
        #expect(DocumentDefaults.style(in: a.state) == nil)
        #expect(DocumentDefaults.appearance(in: a.state) == Appearances.standard, "every element deleted reads as the built-in defaults")
    }

    @Test func changingAnObjectChangesTheDefaultsInTheSameChange() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let wrapped = DocumentDefaults.following(AddAppearance.fill([rect], Appearances.basicFill(red: 1, green: 0, blue: 0)))
        #expect(wrapped.label == "Add Fill (and defaults)")
        let change = try #require(try a.perform(wrapped))
        #expect(change.label == "Add Fill (and defaults)")
        #expect(DocumentDefaults.appearance(in: a.state).fills.map(\.settings.basic.color) == [Self.red])
        #expect(DocumentDefaults.appearance(in: a.state).strokes.count == 1)
        a.undo()
        #expect(Self.fills(rect, a.state).isEmpty)
        #expect(DocumentDefaults.appearance(in: a.state) == Appearances.standard, "one undo takes back both")
        // Edits of the defaults themselves, and other commands, are not wrapped.
        #expect(DocumentDefaults.following(AddAppearance.fill([WellKnown.settings])) is AddAppearance)
        #expect(DocumentDefaults.following(DeleteNodes([rect])) is DeleteNodes)
        // An edit that writes nothing writes no defaults.
        #expect(try a.perform(AlsoChangingDefaults(DeleteNodes([]), source: rect)) == nil)
    }

    @Test func everyAttributeEditNamesTheObjectItEdits() {
        let node = OpID(counter: 9, replica: 9)
        let row = AppearanceRow(.fills, OpID(counter: 3, replica: 9))
        let commands: [any Command] = [
            AddAppearance.stroke([node]), RemoveAppearance(node: node, row: row), MoveAppearance(node: node, row: row, to: 0),
            DuplicateAppearance(node: node, row: row), SetAppearanceColor([(node, row)], color: Self.red),
            SetStrokeWidth([(node, row.element)], width: 2), SetAppearanceHidden([(node, row)], hidden: true),
            ReorderAttribute([(node, row)], to: 0), ApplyColor([node], target: .fill, color: Self.red),
            SetAttributeKind([(node, row)], fill: .pattern),
            EditAttribute([(node, row)], label: "Edit", fields: [], settings: AttributeSettings(.fills)),
        ]
        for command in commands {
            #expect(DocumentDefaults.editedObject(of: command) == node, "\(type(of: command))")
        }
        #expect(DocumentDefaults.editedObject(of: DeleteNodes([node])) == nil)
    }

    @Test func concurrentDefaultStrokeAndFillEditsKeepBothAndSameColourEditsConverge() throws {
        var pair = Pair()
        try pair.a.perform(AddAppearance.fill([WellKnown.settings]))
        pair.sync()
        let fill = try #require(AppearanceEditing.rows(WellKnown.settings, .fills, in: pair.a.state).first)
        try pair.a.perform(AddAppearance.stroke([WellKnown.settings], Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 3)))
        try pair.b.perform(SetAppearanceColor([(WellKnown.settings, AppearanceRow(.fills, fill))], color: Self.red))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let both = DocumentDefaults.appearance(in: pair.a.state)
        #expect(both.fills.map(\.settings.basic.color) == [Self.red] && both.strokes.map(\.settings.basic.width) == [3])
        // Two replicas recolouring the same default fill: one colour wins on both, by OpId.
        try pair.a.perform(SetAppearanceColor([(WellKnown.settings, AppearanceRow(.fills, fill))], color: Self.blue))
        try pair.b.perform(SetAppearanceColor([(WellKnown.settings, AppearanceRow(.fills, fill))], color: Self.red))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(DocumentDefaults.appearance(in: pair.a.state).fills[0].settings.basic.color == Self.red, "replica 0xB's later OpId wins")
    }
}
