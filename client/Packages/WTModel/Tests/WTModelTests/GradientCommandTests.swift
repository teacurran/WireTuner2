import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// ATTR-024: the gradient commands, the sorted ramp and the read-time normalizations.
@Suite struct GradientCommandTests {
    static let red = Appearances.inline(red: 1, green: 0, blue: 0)
    static let blue = Appearances.inline(red: 0, green: 0, blue: 1)

    /// A rectangle with a red basic fill above its stroke; the fill's row.
    static func filled(_ replica: inout Replica, x: Double = 0) throws -> (node: OpID, row: AppearanceRow) {
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil, x: x), on: &replica)
        try replica.perform(AddAppearance.fill([rect], Appearances.basicFill(red: 1, green: 0, blue: 0)))
        return (rect, AppearanceEditing.stack(rect, in: replica.state).first { $0.list == .fills }!)
    }

    static func gradient(_ node: OpID, _ row: AppearanceRow, _ state: EngineState) -> Wiretuner_Doc_V1_GradientFill {
        AppearanceEditing.entries(node, in: state).first { $0.row == row }!.fill.settings.gradient
    }

    static func ramp(_ fill: (node: OpID, row: AppearanceRow), _ state: EngineState) -> [GradientRampStop] {
        GradientReading.ramp(gradient(fill.node, fill.row, state))
    }

    @Test func choosingGradientWritesTheKindAndAStartingRamp() throws {
        var a = Replica(0xA)
        let fill = try Self.filled(&a)
        let change = try a.perform(ChooseGradient([fill], type: .radial))!
        #expect(change.label == "Change fill type")
        let entry = AppearanceEditing.entries(fill.node, in: a.state).first { $0.row == fill.row }!
        #expect(entry.kind == .fill(.gradient) && entry.summary == "Gradient, Radial")
        let ramp = Self.ramp(fill, a.state)
        #expect(ramp.map(\.offset) == [0, 1] && ramp[0].color == Self.red && ramp[1].color == ColorResolver.inline(.white))
        // Back to Basic takes the ramp's left colour; choosing Gradient again keeps the ramp.
        try a.perform(RecolorGradientStop(node: fill.node, row: fill.row, stop: ramp[0].id, color: Self.blue))
        let basic = try a.perform(ConvertGradientToBasic([fill]))!
        #expect(basic.label == "Change fill type")
        let back = AppearanceEditing.entries(fill.node, in: a.state).first { $0.row == fill.row }!
        #expect(back.kind == .fill(.basic) && back.fill.settings.basic.color == Self.blue)
        try a.perform(ChooseGradient([fill, fill]))
        #expect(Self.ramp(fill, a.state).count == 2 && Self.gradient(fill.node, fill.row, a.state).type == .radial)
        #expect(ChooseGradient([fill, fill]).label == "Change fill type of 2 objects")
        // SetAttributeKind still refuses Gradient: this is the command that writes the ramp.
        #expect(throws: ObjectEditError.invalidValue("kind")) { try a.perform(SetAttributeKind([fill], fill: .gradient)) }
        let stroke = AppearanceEditing.stack(fill.node, in: a.state)[0]
        #expect(throws: PathEditError.unknownPoint(stroke.element)) { try a.perform(ChooseGradient([(fill.node, stroke)])) }
    }

    @Test func typeBehaviorCountAndAxis() throws {
        var a = Replica(0xA)
        let fill = try Self.filled(&a)
        try a.perform(ChooseGradient([fill]))
        try a.perform(EditGradient.type([fill], .cone))
        try a.perform(EditGradient.behavior([fill], .reflect))
        let count = try a.perform(EditGradient.count([fill], 4))!
        #expect(count.label == "Change gradient count")
        let axis = try a.perform(EditGradient.axis([fill], start: Point(x: 1, y: 2), end: Point(x: 5, y: 2), end2: Point(x: 1, y: 9)))!
        #expect(axis.label == "Move gradient handle")
        let gradient = Self.gradient(fill.node, fill.row, a.state)
        #expect(gradient.type == .cone && gradient.behavior == .reflect && gradient.repeatCount == 4)
        #expect(gradient.axis.start.x == 1 && gradient.axis.end.x == 5 && gradient.axis.end2.y == 9)
        #expect(throws: ObjectEditError.invalidValue("count")) { try a.perform(EditGradient.count([fill], 0)) }
        #expect(throws: ObjectEditError.invalidValue("stops")) {
            try a.perform(EditGradient([fill], label: "x", fields: [GradientFields.stops]) { _ in })
        }
        #expect(EditGradient.type([fill, fill], .linear).label == "Change gradient type of 2 objects")
        // The display list reads the axis and ramp.
        var builder = DocumentDisplayListBuilder(canvas: "c")
        guard case .path(let item)? = builder.rebuild(a.state).object(fill.node)?.item, case .fill(let paint) = item.appearance.items[1],
              case .gradient(let drawn) = paint.paint else { Issue.record("no gradient"); return }
        #expect(drawn.kind == .cone && drawn.behavior == .reflect && drawn.repeatCount == 4 && drawn.stops.count == 2)
    }

    @Test func stopsKeepTheirTwoEnds() throws {
        var a = Replica(0xA)
        let fill = try Self.filled(&a)
        try a.perform(ChooseGradient([fill]))
        let add = try a.perform(AddGradientStop(node: fill.node, row: fill.row, offset: 0.5, color: Self.blue))!
        #expect(add.label == "Add color stop")
        var ramp = Self.ramp(fill, a.state)
        #expect(ramp.map(\.offset) == [0, 0.5, 1])
        // A middle stop moves freely; an end stop dragged inward leaves a copy at the end.
        let move = try a.perform(MoveGradientStop(node: fill.node, row: fill.row, stop: ramp[1].id, offset: 0.25))!
        #expect(move.label == "Move color stop" && Self.ramp(fill, a.state).map(\.offset) == [0, 0.25, 1])
        #expect(try a.perform(MoveGradientStop(node: fill.node, row: fill.row, stop: ramp[1].id, offset: 0.25)) == nil)
        try a.perform(MoveGradientStop(node: fill.node, row: fill.row, stop: ramp[2].id, offset: 0.8))
        ramp = Self.ramp(fill, a.state)
        #expect(ramp.map(\.offset) == [0, 0.25, 0.8, 1] && ramp[3].color == ramp[2].color && ramp[3].id != ramp[2].id)
        try a.perform(MoveGradientStop(node: fill.node, row: fill.row, stop: ramp[0].id, offset: 0.1))
        ramp = Self.ramp(fill, a.state)
        #expect(ramp.map(\.offset) == [0, 0.1, 0.25, 0.8, 1])
        // Copy (Cmd-drag), recolour and remove.
        let copy = try a.perform(CopyGradientStop(node: fill.node, row: fill.row, stop: ramp[2].id, offset: 0.9))!
        #expect(copy.label == "Copy color stop" && Self.ramp(fill, a.state).count == 6)
        let recolor = try a.perform(RecolorGradientStop(node: fill.node, row: fill.row, stop: ramp[1].id, color: Self.blue))!
        #expect(recolor.label == "Change stop color" && Self.ramp(fill, a.state)[1].color == Self.blue)
        let remove = try a.perform(RemoveGradientStop(node: fill.node, row: fill.row, stop: ramp[1].id))!
        #expect(remove.label == "Remove color stop" && Self.ramp(fill, a.state).count == 5)
        ramp = Self.ramp(fill, a.state)
        #expect(throws: ObjectEditError.invalidValue("stop")) { try a.perform(RemoveGradientStop(node: fill.node, row: fill.row, stop: ramp[0].id)) }
        #expect(throws: ObjectEditError.invalidValue("stop")) { try a.perform(RemoveGradientStop(node: fill.node, row: fill.row, stop: ramp[4].id)) }
        let missing = OpID(counter: 999, replica: 9)
        #expect(throws: PathEditError.unknownPoint(missing)) { try a.perform(RecolorGradientStop(node: fill.node, row: fill.row, stop: missing, color: Self.red)) }
        #expect(throws: ObjectEditError.invalidValue("offset")) { try a.perform(AddGradientStop(node: fill.node, row: fill.row, offset: .nan, color: Self.red)) }
        #expect(throws: ObjectEditError.invalidValue("offset")) { try a.perform(MoveGradientStop(node: fill.node, row: fill.row, stop: ramp[1].id, offset: .infinity)) }
        #expect(throws: ObjectEditError.invalidValue("offset")) { try a.perform(CopyGradientStop(node: fill.node, row: fill.row, stop: ramp[1].id, offset: .nan)) }
        // Two stops left: neither can go.
        var two = try Self.filled(&a, x: 40)
        try a.perform(ChooseGradient([two]))
        two = (two.node, two.row)
        let ends = Self.ramp(two, a.state)
        #expect(throws: ObjectEditError.invalidValue("stop")) { try a.perform(RemoveGradientStop(node: two.node, row: two.row, stop: ends[0].id)) }
        // An end moved onto a place another stop already holds leaves no copy.
        try a.perform(AddGradientStop(node: two.node, row: two.row, offset: 0, color: Self.blue))
        let three = Self.ramp(two, a.state)
        try a.perform(MoveGradientStop(node: two.node, row: two.row, stop: three[0].id, offset: 0.5))
        #expect(Self.ramp(two, a.state).count == 3)
    }

    @Test func theRampSortsAndNormalizes() {
        var gradient = Wiretuner_Doc_V1_GradientFill()
        func stop(_ counter: UInt64, _ offset: Double) -> Wiretuner_Doc_V1_GradientStop {
            var stop = Wiretuner_Doc_V1_GradientStop()
            stop.id = OpID(counter: counter, replica: 1).elementID
            stop.offset = offset
            return stop
        }
        gradient.stops = [stop(3, 0.5), stop(1, 2), stop(2, 0.5), stop(4, -1), stop(5, .nan)]
        let ramp = GradientReading.ramp(gradient)
        #expect(ramp.map(\.id.counter) == [4, 5, 2, 3, 1] && ramp.map(\.offset) == [0, 0, 0.5, 0.5, 1], "offset, then element id")
        // Normalizations.
        var normal = GradientReading.normalized(gradient)
        #expect(normal.type == .linear && normal.behavior == .normal && normal.repeatCount == 1 && normal.axis == nil)
        gradient.stops = [stop(1, 0.3)]
        gradient.type = .radial
        gradient.behavior = .repeat
        gradient.repeatCount = 0
        gradient.axis.start.x = 2
        gradient.axis.end.x = 2
        normal = GradientReading.normalized(gradient)
        #expect(normal.stops.map(\.offset) == [0, 1] && normal.repeatCount == 1)
        #expect(normal.axis == Gradient.Axis(start: Point(x: 2, y: 0), end: Point(x: 3, y: 0), end2: Point(x: 2, y: 1)),
                "a zero axis reads 1 pt; a missing end2 is end − start turned 90°")
        gradient.repeatCount = 500
        gradient.type = .contour
        gradient.behavior = .autoSize
        normal = GradientReading.normalized(gradient)
        #expect(normal.repeatCount == 1 && normal.type == .contour && normal.axis?.end2 == nil)
        gradient.behavior = .reflect
        gradient.type = .UNRECOGNIZED(40)
        normal = GradientReading.normalized(gradient)
        #expect(normal.repeatCount == 100 && normal.type == .linear)
        // No stops: a Basic fill of the fill's own colour.
        var fill = Wiretuner_Doc_V1_FillSettings()
        fill.kind = .gradient
        fill.basic.color = Self.red
        #expect(Appearances.fill(fill, evenOdd: false).paint == .solid(Color(red: 1, green: 0, blue: 0)))
    }

    @Test func applyingOverGroupsFitsEachObject() throws {
        var a = Replica(0xA)
        let one = try Self.filled(&a)
        let two = try LayerFixture.object(LayerFixture.rect(on: nil, x: 30), on: &a)
        let group = try a.perform(GroupObjects([one.node, two]))!.createdObjects[0]
        var gradient = Wiretuner_Doc_V1_GradientFill()
        gradient.type = .radial
        for (offset, color) in [(0.0, Self.red), (1.0, Self.blue)] {
            var stop = Wiretuner_Doc_V1_GradientStop()
            stop.offset = offset
            stop.color = color
            gradient.stops.append(stop)
        }
        try a.perform(ChooseGradient([one]))
        let change = try a.perform(ApplyGradient([group], gradient: gradient))!
        #expect(change.label == "Apply gradient")
        for node in [one.node, two] {
            let fill = AppearanceEditing.entries(node, in: a.state).last { $0.row.list == .fills }!
            #expect(fill.kind == .fill(.gradient) && fill.fill.settings.gradient.type == .radial && !fill.fill.settings.gradient.hasAxis)
            #expect(GradientReading.ramp(fill.fill.settings.gradient).map(\.color) == [Self.red, Self.blue], "the old ramp is replaced")
        }
        #expect(ApplyGradient([one.node, two], gradient: gradient).label == "Apply gradient to 2 objects")
        var single = gradient
        single.stops = [gradient.stops[0]]
        #expect(throws: ObjectEditError.invalidValue("stops")) { try a.perform(ApplyGradient([group], gradient: single)) }
    }

    @Test func edgeCases() throws {
        var a = Replica(0xA)
        // A fill without a colour starts its ramp from black.
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        try a.perform(AddAppearance.fill([rect], Wiretuner_Doc_V1_Fill()))
        let fill = (node: rect, row: AppearanceEditing.stack(rect, in: a.state).first { $0.list == .fills }!)
        try a.perform(ChooseGradient([fill]))
        #expect(Self.ramp(fill, a.state)[0].color == ColorResolver.inline(.black))
        // Applying skips duplicates and dead nodes.
        var gradient = Wiretuner_Doc_V1_GradientFill()
        gradient.stops = Self.gradient(fill.node, fill.row, a.state).stops
        #expect(ApplyGradient.leaves([rect, rect, OpID(counter: 999, replica: 9)], in: a.state) == [rect])
        // A radial axis with its own second end.
        gradient.type = .radial
        gradient.axis.end.x = 4
        gradient.axis.end2.y = 6
        #expect(GradientReading.normalized(gradient).axis?.end2 == Point(x: 0, y: 6))
    }

    // MARK: Merges

    @Test func removeVersusRecolorVersusAxisDrag() throws {
        var a = Replica(0xA)
        var b = Replica(0xB)
        var c = Replica(0xC)
        let fill = try Self.filled(&a)
        try a.perform(ChooseGradient([fill]))
        try a.perform(AddGradientStop(node: fill.node, row: fill.row, offset: 0.5, color: Self.red))
        b.receive(a.sent)
        c.receive(a.sent)
        let middle = Self.ramp(fill, a.state)[1].id
        let sentA = a.sent.count
        try a.perform(RemoveGradientStop(node: fill.node, row: fill.row, stop: middle))
        try b.perform(RecolorGradientStop(node: fill.node, row: fill.row, stop: middle, color: Self.blue))
        try c.perform(EditGradient.axis([fill], start: Point(x: 3, y: 3), end: Point(x: 9, y: 3)))
        a.receive(b.sent + c.sent)
        b.receive(Array(a.sent[sentA...]) + c.sent)
        c.receive(Array(a.sent[sentA...]) + b.sent)
        for replica in [a, b, c] {
            #expect(Self.ramp(fill, replica.state).count == 2)
            #expect(GradientReading.tombstoneColor(fill.node, row: fill.row, stop: middle, in: replica.state) == Self.blue)
            #expect(Self.gradient(fill.node, fill.row, replica.state).axis.start.x == 3)
        }
        #expect(a.state.stateHash == b.state.stateHash && b.state.stateHash == c.state.stateHash)
        #expect(GradientReading.tombstoneColor(OpID(counter: 999, replica: 9), row: fill.row, stop: middle, in: a.state) == nil)
        #expect(GradientReading.tombstoneColor(fill.node, row: fill.row, stop: OpID(counter: 999, replica: 9), in: a.state) == nil)
    }

    @Test func undoOfAHandleDragAfterARemoteDragKeepsTheRemoteAxis() throws {
        var pair = Pair()
        let fill = try Self.filled(&pair.a)
        try pair.a.perform(ChooseGradient([fill]))
        pair.sync()
        try pair.a.perform(EditGradient.axis([fill], start: Point(x: 1, y: 1), end: Point(x: 2, y: 1)))
        pair.sync()
        try pair.b.perform(EditGradient.axis([fill], start: Point(x: 7, y: 7), end: Point(x: 8, y: 7)))
        pair.sync()
        pair.a.undo()
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(Self.gradient(fill.node, fill.row, replica.state).axis.start.x == 7)
        }
    }
}
