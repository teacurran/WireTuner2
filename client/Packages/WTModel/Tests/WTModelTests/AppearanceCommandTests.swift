import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// The attribute stack commands (OBJ-004).
@Suite struct AppearanceCommandTests {
    static func strokes(_ node: OpID, _ state: EngineState) -> [Wiretuner_Doc_V1_Stroke] {
        NodeValues.appearance(state.props(node))?.strokes ?? []
    }

    @Test func addAboveTheSelectedRowOrAtTheTop() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let first = AppearanceEditing.rows(rect, .strokes, in: a.state)[0]
        let red = Appearances.basicStroke(red: 1, green: 0, blue: 0, width: 3)
        let added = try a.perform(AddAppearance.stroke([rect], red))!
        #expect(added.label == "Add Stroke")
        let blue = Appearances.basicStroke(red: 0, green: 0, blue: 1, width: 2)
        try a.perform(AddAppearance.stroke([rect], above: AppearanceRow(.strokes, first), blue))
        #expect(Self.strokes(rect, a.state).map(\.settings.basic.width) == [1, 2, 3])
        // A row of another list: to the top of this one.
        try a.perform(AddAppearance.fill([rect], above: AppearanceRow(.strokes, first)))
        try a.perform(AddAppearance.fill([rect]))
        #expect(NodeValues.appearance(a.state.props(rect))?.fills.count == 2)
        var effect = Wiretuner_Doc_V1_Effect()
        effect.hidden = true
        #expect(try a.perform(AddAppearance.effect([rect], effect))?.label == "Add Effect")
        #expect(AppearanceEditing.rows(rect, .effects, in: a.state).count == 1)
        // A group has a stack; a layer does not.
        let layer = Objects.parent(of: rect, in: a.state)!
        #expect(throws: ObjectEditError.notAnObject(layer)) { try a.perform(AddAppearance.fill([layer])) }
        #expect(AppearanceEditing.rows(layer, .fills, in: a.state).isEmpty)
    }

    @Test func removeMoveAndDuplicate() throws {
        var a = Replica(0xA)
        let path = try LayerFixture.object(PathFixture.open([(0, 0), (1, 1)]), on: &a)
        try a.perform(AddAppearance.stroke([path], Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 2)))
        try a.perform(AddAppearance.stroke([path], Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 3)))
        let rows = AppearanceEditing.rows(path, .strokes, in: a.state)
        let move = try a.perform(MoveAppearance(node: path, row: AppearanceRow(.strokes, rows[2]), to: 0))!
        #expect(move.label == "Move Stroke")
        #expect(Self.strokes(path, a.state).map(\.settings.basic.width) == [3, 1, 2])
        #expect(try a.perform(MoveAppearance(node: path, row: AppearanceRow(.strokes, rows[2]), to: 0)) == nil)
        try a.perform(MoveAppearance(node: path, row: AppearanceRow(.strokes, rows[2]), to: 99))
        #expect(Self.strokes(path, a.state).map(\.settings.basic.width) == [1, 2, 3])
        let duplicate = try a.perform(DuplicateAppearance(node: path, row: AppearanceRow(.strokes, rows[0])))!
        #expect(duplicate.label == "Duplicate Stroke")
        let after = Self.strokes(path, a.state)
        #expect(after.map(\.settings.basic.width) == [1, 1, 2, 3])
        #expect(after[0].id != after[1].id)
        let remove = try a.perform(RemoveAppearance(node: path, row: AppearanceRow(.strokes, rows[1])))!
        #expect(remove.label == "Remove Stroke")
        #expect(Self.strokes(path, a.state).map(\.settings.basic.width) == [1, 1, 3])
        let missing = OpID(counter: 999, replica: 9)
        #expect(throws: PathEditError.unknownPoint(missing)) { try a.perform(RemoveAppearance(node: path, row: AppearanceRow(.strokes, missing))) }
        #expect(throws: PathEditError.unknownPoint(missing)) { try a.perform(MoveAppearance(node: path, row: AppearanceRow(.strokes, missing), to: 0)) }
        #expect(throws: PathEditError.unknownPoint(missing)) { try a.perform(DuplicateAppearance(node: path, row: AppearanceRow(.fills, missing))) }
        #expect(throws: PathEditError.unknownPoint(missing)) { try a.perform(DuplicateAppearance(node: path, row: AppearanceRow(.effects, missing))) }
    }

    @Test func duplicateCopiesFillsAndEffects() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        try a.perform(AddAppearance.fill([rect], Appearances.basicFill(red: 0.5, green: 0, blue: 0)))
        var effect = Wiretuner_Doc_V1_Effect()
        effect.hidden = true
        try a.perform(AddAppearance.effect([rect], effect))
        let fill = AppearanceEditing.rows(rect, .fills, in: a.state)[0]
        let fx = AppearanceEditing.rows(rect, .effects, in: a.state)[0]
        try a.perform(DuplicateAppearance(node: rect, row: AppearanceRow(.fills, fill)))
        try a.perform(DuplicateAppearance(node: rect, row: AppearanceRow(.effects, fx)))
        let stack = NodeValues.appearance(a.state.props(rect))!
        #expect(stack.fills.map(\.settings.basic.color) == Array(repeating: Appearances.basicFill(red: 0.5, green: 0, blue: 0).settings.basic.color, count: 2))
        #expect(stack.effects.count == 2 && stack.effects.allSatisfy(\.hidden))
        #expect(AppearanceEditing.element(OpID(counter: 99, replica: 1), AppearanceRow(.fills, fill), in: a.state) == nil)
    }

    @Test func colorAndWidthEditsFanOut() throws {
        var a = Replica(0xA)
        let one = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let two = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let rows = [one, two].map { ($0, AppearanceEditing.rows($0, .strokes, in: a.state)[0]) }
        let width = try a.perform(SetStrokeWidth(rows.map { (node: $0.0, element: $0.1) }, width: 2.0004))!
        #expect(width.label == "Change stroke width of 2 objects")
        #expect(SetStrokeWidth([rows[0]].map { (node: $0.0, element: $0.1) }, width: 1).label == "Change stroke width")
        #expect(Self.strokes(two, a.state)[0].settings.basic.width == 2)
        let red = Appearances.basicFill(red: 1, green: 0, blue: 0).settings.basic.color
        let color = try a.perform(SetAppearanceColor(rows.map { (node: $0.0, row: AppearanceRow(.strokes, $0.1)) }, color: red))!
        #expect(color.label == "Change stroke color of 2 objects")
        #expect(Self.strokes(one, a.state)[0].settings.basic.color == red)
        #expect(Self.strokes(one, a.state)[0].settings.basic.width == 2)
        try a.perform(AddAppearance.fill([one]))
        let fill = AppearanceEditing.rows(one, .fills, in: a.state)[0]
        #expect(SetAppearanceColor([(node: one, row: AppearanceRow(.fills, fill))], color: red).label == "Change fill color")
        try a.perform(SetAppearanceColor([(node: one, row: AppearanceRow(.fills, fill))], color: red))
        #expect(NodeValues.appearance(a.state.props(one))?.fills[0].settings.basic.color == red)
        #expect(throws: ObjectEditError.invalidValue("width")) { try a.perform(SetStrokeWidth([(node: one, element: rows[0].1)], width: -1)) }
        #expect(throws: PathEditError.unknownPoint(fill)) { try a.perform(SetStrokeWidth([(node: one, element: fill)], width: 1)) }
        #expect(throws: PathEditError.unknownPoint(fill)) { try a.perform(SetAppearanceColor([(node: one, row: AppearanceRow(.effects, fill))], color: red)) }
        #expect(SetAppearanceColor([], color: red).label == "Change fill color")
    }
}

/// The merge tests of OBJ-004.
@Suite struct AppearanceMergeTests {
    @Test func reorderAndRecolorOfOneRowKeepBoth() throws {
        var pair = Pair()
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        try pair.a.perform(AddAppearance.stroke([rect], Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 5)))
        pair.sync()
        let rows = AppearanceEditing.rows(rect, .strokes, in: pair.a.state)
        let red = Appearances.basicFill(red: 1, green: 0, blue: 0).settings.basic.color
        try pair.a.perform(MoveAppearance(node: rect, row: AppearanceRow(.strokes, rows[1]), to: 0))
        try pair.b.perform(SetAppearanceColor([(node: rect, row: AppearanceRow(.strokes, rows[1]))], color: red))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let strokes = AppearanceCommandTests.strokes(rect, pair.a.state)
        #expect(strokes[0].settings.basic.width == 5 && strokes[0].settings.basic.color == red)
    }

    @Test func removeAndRecolorLeaveTheRowDeletedWithTheColorOnTheTombstone() throws {
        var pair = Pair()
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        pair.sync()
        let row = AppearanceEditing.rows(rect, .strokes, in: pair.a.state)[0]
        let red = Appearances.basicFill(red: 1, green: 0, blue: 0).settings.basic.color
        try pair.a.perform(RemoveAppearance(node: rect, row: AppearanceRow(.strokes, row)))
        try pair.b.perform(SetAppearanceColor([(node: rect, row: AppearanceRow(.strokes, row))], color: red))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(AppearanceEditing.rows(rect, .strokes, in: pair.a.state).isEmpty)
        let path = AppearanceEditing.color(.rect, AppearanceRow(.strokes, row))!
        #expect(pair.a.state.store.register(rect, path)?.value != nil)
        // Restoring the row brings the colour back.
        pair.a.undo()
        #expect(AppearanceCommandTests.strokes(rect, pair.a.state).first?.settings.basic.color == red)
    }

    @Test func concurrentInsertsAtOneGapOrderByElementID() throws {
        var pair = Pair()
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        try pair.a.perform(AddAppearance.stroke([rect]))
        try pair.a.perform(AddAppearance.stroke([rect]))
        pair.sync()
        let rows = AppearanceEditing.rows(rect, .strokes, in: pair.a.state)
        try pair.a.perform(AddAppearance.stroke([rect], above: AppearanceRow(.strokes, rows[0]), Appearances.basicStroke(red: 1, green: 0, blue: 0, width: 7)))
        try pair.b.perform(AddAppearance.stroke([rect], above: AppearanceRow(.strokes, rows[0]), Appearances.basicStroke(red: 0, green: 1, blue: 0, width: 8)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let widths = AppearanceCommandTests.strokes(rect, pair.a.state).map(\.settings.basic.width)
        #expect(widths.count == 5 && widths[0] == 1 && Set(widths[1...2]) == [7, 8])
    }
}
