import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// The baking the release commands share: drawn items expanded to plain path nodes.
@Suite struct BakingTests {
    static let square = DisplayPath(rect: Rect(x: 0, y: 0, width: 10, height: 10))

    static func path(_ items: [AppearanceItem], transform: AffineTransform = .identity) -> DisplayItem {
        .path(PathItem(path: square, appearance: Appearance(items), transform: transform))
    }

    @Test func fillsStrokesAndGradientsBecomePathNodes() throws {
        #expect(Baking.trees([]).isEmpty)
        let linear = Gradient(.linear, from: .black, to: .white, axis: Gradient.Axis(start: Point(x: 0, y: 0), end: Point(x: 10, y: 0)))
        let dashed = StrokePaint(paint: .solid(Color(red: 1, green: 0, blue: 0)), style: StrokeStyle(width: 2, cap: .round, join: .bevel, dash: [3, 1]))
        let trees = Baking.trees([Self.path([.fill(FillPaint(paint: .gradient(linear), rule: .evenOdd)), .stroke(dashed)],
                                            transform: .translation(x: 5, y: 0))])
        #expect(trees.count == 2)
        let fill = trees[0].props.path
        #expect(fill.evenOdd && fill.appearance.fills[0].settings.kind == .gradient && fill.common.transform.tx == 5)
        let gradient = fill.appearance.fills[0].settings.gradient
        #expect(gradient.type == .linear && gradient.stops.count == 2 && gradient.axis.end.x == 10)
        let stroke = trees[1].props.path.appearance.strokes[0].settings.basic
        #expect(stroke.width == 2 && stroke.cap == .round && stroke.join == .bevel && stroke.dash.lengths == [3, 1])

        // A radial gradient keeps its frame as the axis; a gradient stroke is drawn in its first colour.
        let radial = Gradient(.radial, from: .white, to: .black, behavior: .reflect, repeatCount: 2,
                              axis: Gradient.Axis(start: Point(x: 5, y: 5), end: Point(x: 10, y: 5)))
        let round = Baking.trees([Self.path([.fill(FillPaint(paint: .gradient(radial))), .stroke(StrokePaint(paint: .gradient(radial)))])])
        let settings = round[0].props.path.appearance.fills[0].settings.gradient
        #expect(settings.type == .radial && settings.behavior == .reflect && settings.axis.start.x == 5 && settings.axis.hasEnd2)
        #expect(round.count == 2)
    }

    @Test func groupsImagesAndPlacement() throws {
        let red = AppearanceItem.fill(FillPaint(paint: .solid(Color(red: 1, green: 0, blue: 0))))
        let two = Baking.trees([.group(GroupItem(children: [Self.path([red]), Self.path([red], transform: .translation(x: 20, y: 0))], opacity: 0.5))])
        #expect(two.count == 1 && two[0].props.group.kind == .group && two[0].children.count == 2)
        let one = Baking.trees([.group(GroupItem(children: [Self.path([red])], opacity: 0.5))])
        #expect(one.count == 1 && one[0].kind == .path, "a lone child stands for its group")
        // What the flattener can only rasterize is left out.
        let textured = AppearanceItem.fill(FillPaint(paint: .textured(TexturedFill(texture: .oak, color: .black))))
        #expect(Baking.trees([Self.path([textured])]).isEmpty)
        // Cap and join mapping.
        #expect([LineCapCase.butt, .round, .square].map(\.proto) == [.butt, .round, .square])
        #expect([LineJoinCase.miter, .round, .bevel].map(\.proto) == [.miter, .round, .bevel])

        // The group is created in the parent's space.
        var a = Replica(0xA)
        let layer = try LayerFixture.layers(["Moved"], on: &a)[0]
        var props = Wiretuner_Doc_V1_NodeProps()
        props.layer.common.transform = PathEditing.proto(.translation(x: 100, y: 0))
        try a.perform(OpsCommand("Move layer", ops: [Ops.set(layer, [RegisterPath([150, 1, 4])], values: props)]))
        let change = try a.perform(BakeCommand(trees: two, parent: layer))!
        let group = ColorFixture.created(change)[0]
        #expect(Objects.transform(of: group, in: a.state).tx == -100)
    }
}

/// Runs `Baking.createGroup` as a command.
private struct BakeCommand: Command {
    let trees: [NodeTree]
    let parent: OpID
    var label: String { "Bake" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try Baking.createGroup(trees, parent: parent, position: try PathEditing.topPosition(in: parent, state: state), state: state, builder: &builder)
    }
}

/// The display list's caps and joins, named here without importing both modules' types.
private enum LineCapCase {
    case butt, round, square

    var proto: Wiretuner_Doc_V1_LineCap {
        switch self {
        case .butt: Appearances.proto(Appearances.cap(.butt))
        case .round: Appearances.proto(Appearances.cap(.round))
        case .square: Appearances.proto(Appearances.cap(.square))
        }
    }
}

private enum LineJoinCase {
    case miter, round, bevel

    var proto: Wiretuner_Doc_V1_LineJoin {
        switch self {
        case .miter: Appearances.proto(Appearances.join(.miter))
        case .round: Appearances.proto(Appearances.join(.round))
        case .bevel: Appearances.proto(Appearances.join(.bevel))
        }
    }
}
