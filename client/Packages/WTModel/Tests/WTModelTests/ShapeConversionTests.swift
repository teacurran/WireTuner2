import CoreGraphics
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Live shapes edited as paths (D-078; rectangles-ellipses-lines.adoc "Editing a shape's points").
@Suite struct ShapeConversionTests {
    /// The shapes every test runs over.
    enum Fixture: String, CaseIterable, CustomTestStringConvertible {
        case rectangle, roundedRectangle, ellipse, closedArc, openArc, polygon, star

        var testDescription: String { rawValue }
    }

    static let placed = AffineTransform.rotation(radians: .pi / 9).concatenating(.translation(x: 60, y: 50))

    /// A grey fill and the standard stroke.
    static var look: Wiretuner_Doc_V1_AppearanceProps {
        var appearance = Appearances.standard
        appearance.fills = [Appearances.basicFill(red: 0.3, green: 0.5, blue: 0.7)]
        return appearance
    }

    /// Draws `fixture` rotated and placed, with a fill, a stroke, a shadow and a name.
    static func make(_ fixture: Fixture, on a: inout Replica) throws -> OpID {
        let size = Size(width: 80, height: 50)
        let node: OpID
        switch fixture {
        case .rectangle:
            node = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: size, transform: placed, appearance: look), on: &a)
        case .roundedRectangle:
            node = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: size, transform: placed, appearance: look), on: &a)
            try a.perform(SetCornerRadius([node], radius: nil, uniform: false))
            try a.perform(SetCornerRadius([node], radius: 12, corners: [.topLeft, .bottomRight]))
            try a.perform(SetCornerRadius([node], radius: 4, corners: [.topRight]))
        case .ellipse, .closedArc, .openArc:
            node = try LayerFixture.object(CreateShape(.ellipse, size: size, transform: placed, appearance: look), on: &a)
            if fixture != .ellipse { try a.perform(SetEllipseArc([node], start: 30, end: 290, open: fixture == .openArc)) }
        case .polygon, .star:
            let shape = PolygonShape(sides: fixture == .star ? 5 : 6, star: fixture == .star, radius: 40, innerRadius: 18, rotation: 0.3)
            node = try a.perform(CreatePolygon(shape, center: Point(x: 70, y: 60), appearance: look))!.createdObjects[0]
        }
        try a.perform(AddEffect([node], kind: .shadow))
        try a.perform(SetNameOrNote([node], .name, "Badge"))
        return node
    }

    /// RGBA bytes of the scene around the fixtures.
    static func pixels(_ state: EngineState) -> [UInt8] {
        CombineCommandTests.pixels(state, region: Rect(x: -10, y: -10, width: 170, height: 150))
    }

    /// How many pixels differ by more than rounding.
    static func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
        stride(from: 0, to: min(a.count, b.count), by: 4).filter { pixel in (0..<4).contains { abs(Int(a[pixel + $0]) - Int(b[pixel + $0])) > 2 } }.count
    }

    /// The one live path on the default layer.
    static func paths(in state: EngineState) -> [OpID] {
        let order = LayerOrder(state)
        return order.objects(on: order.defaultLayer!, in: state).filter { state.nodeKind($0) == .path }
    }

    // MARK: Conversion

    @Test(arguments: Fixture.allCases)
    func convertingDrawsExactlyWhatTheShapeDrew(_ fixture: Fixture) throws {
        var a = Replica(0xA)
        let shape = try Self.make(fixture, on: &a)
        let before = Self.pixels(a.state)
        let derived = try #require(ShapeConversion.path(of: shape, in: a.state))
        let stack = AppearanceEditing.stack(shape, in: a.state).map(\.list)
        try a.perform(Ungroup([shape]))
        #expect(!a.state.isLive(shape))
        let path = try #require(Self.paths(in: a.state).first)
        #expect(Self.differing(before, Self.pixels(a.state)) == 0, "the path draws exactly what the shape drew")
        let converted = a.path(path)
        #expect(converted.contours.map(\.closed) == derived.contours.map(\.closed))
        #expect(converted.contours.flatMap(\.drawn).map(\.anchor) == derived.contours.flatMap(\.drawn).map(\.anchor))
        #expect(converted.contours.flatMap(\.drawn).map(\.inHandle) == derived.contours.flatMap(\.drawn).map(\.inHandle))
        #expect(converted.contours.flatMap(\.drawn).map(\.outHandle) == derived.contours.flatMap(\.drawn).map(\.outHandle))
        #expect(converted.contours.flatMap(\.drawn).map(\.kind) == derived.contours.flatMap(\.drawn).map(\.kind))
        #expect(Objects.transform(of: path, in: a.state) == Self.placed || fixture == .polygon || fixture == .star)
        #expect(Objects.transform(of: path, in: a.state) == Objects.transform(of: shape, in: a.state))
        #expect(AppearanceEditing.stack(path, in: a.state).map(\.list) == stack)
        #expect(a.state.props(path).path.common.name == "Badge")
        a.undo()
        #expect(a.state.isLive(shape) && !a.state.isLive(path), "one undo brings the live shape back")
    }

    @Test(arguments: Fixture.allCases)
    func draggingAPointConvertsAndMovesItInOneChange(_ fixture: Fixture) throws {
        var a = Replica(0xA)
        let shape = try Self.make(fixture, on: &a)
        let derived = try #require(ShapeConversion.path(of: shape, in: a.state))
        let contour = derived.contours[0]
        let corner = contour.points[1]
        let to = corner.anchor + Vector(dx: 9, dy: -7)
        let drag = ShapeConversion.asPaths(MovePoints(node: shape, contour: contour.id, point: corner.id, to: to), in: a.state)
        #expect(drag.label == ShapeConversion.editPointsLabel)
        let change = try #require(try a.perform(drag))
        #expect(change.label == "Edit Points")
        #expect(!a.state.isLive(shape))
        let path = try #require(Self.paths(in: a.state).first)
        let drawn = a.path(path).contours[0].drawn
        var expected = contour.drawn.map(\.anchor)
        expected[1] = to
        #expect(drawn.map(\.anchor) == expected)
        #expect(drawn.map(\.inHandle) == contour.drawn.map(\.inHandle), "only the anchor moved")
        let conversions = ShapeConversion.conversions(in: change, state: a.state)
        #expect(conversions[shape]?.path == path)
        #expect(conversions[shape]?.points[PointRef(contour: contour.id, point: corner.id)]?.point == a.path(path).contours[0].points[1].id)
        a.undo()
        #expect(a.state.isLive(shape) && !a.state.isLive(path))
        #expect(ShapeConversion.path(of: shape, in: a.state) == derived, "the live shape as it was")
    }

    @Test func aRectangleWithACornersEffectConvertsWithSquareCornersAndKeepsTheEffect() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(CreateShape(.rectangle(.uniform(10)), size: Size(width: 60, height: 40), transform: .translation(x: 20, y: 20),
                                                       appearance: Self.look), on: &a)
        try a.perform(SetCornerRadius([rect], radius: 10))
        try a.perform(AddEffect([rect], kind: .corners))
        let before = Self.pixels(a.state)
        #expect(ShapeConversion.path(of: rect, in: a.state)?.contours[0].points.count == 4)
        try a.perform(Ungroup([rect]))
        let path = try #require(Self.paths(in: a.state).first)
        #expect(a.path(path).contours[0].points.count == 4)
        #expect(EffectReading.entries(path, in: a.state).contains { $0.kind == .corners })
        #expect(Self.differing(before, Self.pixels(a.state)) == 0)
    }

    @Test func theClipGroupAndConnectorsFollowTheShapeToItsPath() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 40, height: 40)), on: &a)
        let content = try LayerFixture.object(LayerFixture.rect(on: nil, x: 5), on: &a)
        let group = try a.perform(PasteContents(try ClippingTests.cut([content], on: &a), into: rect))!.createdObjects[0]
        #expect(ClipGroups.clipPath(of: group, in: a.state) == rect)
        let other = try LayerFixture.object(LayerFixture.rect(on: nil, x: 100), on: &a)
        let connector = try a.perform(CreateConnector(start: ConnectorEnd(node: NodeID(rect), point: Point(x: 40, y: 20)),
                                                      end: ConnectorEnd(node: NodeID(other), point: Point(x: 100, y: 5))))!.createdObjects[0]
        let before = Self.pixels(a.state)
        let derived = try #require(ShapeConversion.path(of: rect, in: a.state))
        try a.perform(ShapeConversion.asPaths(MovePoints(node: rect, contour: derived.contours[0].id, point: derived.contours[0].points[0].id,
                                                         to: Point(x: 0, y: 0)), in: a.state))
        let path = try #require(ClipGroups.clipPath(of: group, in: a.state))
        #expect(path != rect && a.state.nodeKind(path) == .path)
        #expect(Connectors.storedEnd(Connectors.props(connector, in: a.state).start).node == path)
        #expect(Connectors.storedEnd(Connectors.props(connector, in: a.state).end).node == other)
        #expect(Self.differing(before, Self.pixels(a.state)) == 0, "still clipped, still connected")
    }

    @Test func everyPointCommandRunsOnAShape() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 40, height: 40)), on: &a)
        let contour = try #require(ShapeConversion.path(of: rect, in: a.state)?.contours[0])
        let ids = contour.points.map(\.id)
        let commands: [any Command] = [
            SetHandles(node: rect, contour: contour.id, point: ids[0], out: Vector(dx: 5, dy: 0)),
            SetPointKind(node: rect, points: [(contour.id, ids[1])], kind: .curve),
            RetractHandles(node: rect, points: [(contour.id, ids[1])]),
            SetAutomatic(node: rect, points: [(contour.id, ids[1])], automatic: true),
            DeletePoints(node: rect, points: [(contour.id, ids[2])]),
            DeleteSegment(node: rect, contour: contour.id, from: ids[3]),
            InsertPointOnSegment(node: rect, contour: contour.id, from: ids[0], t: 0.5),
            SetClosed(node: rect, closed: false, contours: [contour.id]),
            ReverseContours(node: rect, contours: [contour.id]),
            RewritePath(node: rect, edits: [.init(contour: contour.id, points: Array(contour.points.prefix(3)), closed: true)], label: "Knife"),
        ]
        for command in commands {
            var b = a
            let converting = ShapeConversion.asPaths(command, in: b.state)
            #expect(converting is ConvertingShapes, "\(command.label)")
            let change = try #require(try b.perform(converting), "\(command.label)")
            #expect(!b.state.isLive(rect), "\(command.label)")
            #expect(ShapeConversion.conversions(in: change, state: b.state)[rect] != nil, "\(command.label): the selection can follow")
        }
        #expect(ShapeConversion.asPaths(SetPointKind(node: rect, points: [(contour.id, ids[1])], kind: .curve), in: a.state).label == "Edit Points")
        #expect(ShapeConversion.asPaths(ReverseContours(node: rect), in: a.state).label == "Reverse Direction")
    }

    @Test func pathCommandsConvertOnlyTheShapesTheyChange() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 40, height: 40)), on: &a)
        let path = try LayerFixture.object(PathFixture.closed([(0, 0), (100, 100), (100, 0), (0, 100)]), on: &a)
        // Nothing to correct or unoverlap on a rectangle: it stays live and nothing is written.
        #expect(try a.perform(ShapeConversion.asPaths(CorrectDirection([rect]), in: a.state)) == nil)
        #expect(try a.perform(ShapeConversion.asPaths(RemoveOverlap([rect]), in: a.state)) == nil)
        #expect(a.state.isLive(rect))
        // Remove Overlap over the bow tie and the rectangle: only the bow tie changes.
        #expect(try a.perform(ShapeConversion.asPaths(RemoveOverlap([rect, path]), in: a.state)) != nil)
        #expect(a.state.isLive(rect))
        #expect(RemoveOverlap.targets([rect, path], in: a.state) == [rect, path])
        // Add Points converts and doubles the points.
        let change = try #require(try a.perform(ShapeConversion.asPaths(AddPoints([rect]), in: a.state)))
        #expect(change.label == "Add Points")
        let converted = try #require(ShapeConversion.conversions(in: change, state: a.state)[rect]?.path)
        #expect(a.path(converted).contours[0].points.count == 8)
        // Simplify and Fractalize on a star, Correct Direction on nothing.
        let star = try a.perform(CreatePolygon(PolygonShape(sides: 5, star: true, radius: 40, innerRadius: 15), center: Point(x: 200, y: 200)))!.createdObjects[0]
        var b = a
        #expect(try b.perform(ShapeConversion.asPaths(Fractalize([star]), in: b.state)) != nil && !b.state.isLive(star))
        #expect(try a.perform(ShapeConversion.asPaths(SimplifyPaths([star], amount: 0), in: a.state)) == nil && a.state.isLive(star))
        // An open arc cannot be Remove Overlap's.
        let arc = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 40, height: 40)), on: &a)
        try a.perform(SetEllipseArc([arc], start: 0, end: 180, open: true))
        #expect(RemoveOverlap.targets([arc], in: a.state).isEmpty)
    }

    @Test func aCompositeOfPointEditsConvertsOnceUnderEditPoints() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 40, height: 40)), on: &a)
        let ellipse = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 40, height: 40), transform: .translation(x: 60, y: 0)), on: &a)
        let r = try #require(ShapeConversion.path(of: rect, in: a.state)?.contours[0])
        let e = try #require(ShapeConversion.path(of: ellipse, in: a.state)?.contours[0])
        let composite = CompositeCommand("Move Points", [
            MovePoints(node: rect, contour: r.id, point: r.points[0].id, to: Point(x: -5, y: -5)),
            MovePoints(node: ellipse, contour: e.id, point: e.points[0].id, to: Point(x: 20, y: -9)),
            OpsCommand("nothing", ops: []),
        ])
        let converting = ShapeConversion.asPaths(composite, in: a.state)
        #expect(converting.label == "Edit Points")
        let change = try #require(try a.perform(converting))
        #expect(!a.state.isLive(rect) && !a.state.isLive(ellipse))
        #expect(ShapeConversion.conversions(in: change, state: a.state).count == 2)
        #expect(CompositeCommand("Mixed", [AddPoints([rect]), MovePoints(node: rect, moves: [])]).convertedLabel == "Mixed")
        // Asked twice, it is not wrapped again; a path command on paths only is left as it is.
        #expect(ShapeConversion.asPaths(converting, in: a.state) is ConvertingShapes)
        let path = try LayerFixture.object(PathFixture.open([(0, 0), (1, 1)]), on: &a)
        #expect(ShapeConversion.asPaths(AddPoints([path]), in: a.state) is AddPoints)
        #expect(ShapeConversion.asPaths(MoveObjects([rect], by: Vector(dx: 1, dy: 0)), in: a.state) is MoveObjects)
    }

    @Test func lockedShapesAreNotConverted() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 40, height: 40)), on: &a)
        try a.perform(SetLocked([rect], locked: true))
        #expect(ShapeConversion.shapes([rect], in: a.state).isEmpty)
        #expect(ShapeConversion.asPaths(AddPoints([rect]), in: a.state) is AddPoints)
        var builder = ChangeBuilder(replica: 0xA, startCounter: 1)
        #expect(try ShapeConversion.convert(OpID(counter: 999, replica: 9), state: a.state, builder: &builder) == nil)
        #expect(ShapeConversion.path(of: OpID(counter: 999, replica: 9), in: a.state) == nil)
    }

    @Test func namesAndIdentityMapping() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 4, height: 4)), on: &a)
        let ellipse = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 4, height: 4)), on: &a)
        let polygon = try a.perform(CreatePolygon(PolygonShape(sides: 5, radius: 4), center: .zero))!.createdObjects[0]
        let star = try a.perform(CreatePolygon(PolygonShape(sides: 5, star: true, radius: 4), center: .zero))!.createdObjects[0]
        let path = try LayerFixture.object(PathFixture.open([(0, 0), (1, 1)]), on: &a)
        #expect([rect, ellipse, polygon, star, path].map { ShapeConversion.name(of: $0, in: a.state) } == ["Rectangle", "Ellipse", "Polygon", "Star", "Shape"])
        let none = ShapeConversions()
        #expect(none.isEmpty)
        let id = OpID(counter: 5, replica: 1)
        #expect(none.node(id) == id && none.contour(id, of: id) == id && none.point(id, contour: id, of: id) == id)
        #expect(none.vectorPoints([VectorPoint(anchor: .zero)], contour: id, of: id) == [VectorPoint(anchor: .zero)])
    }

    @Test func mismatchedOutlinesAndIdleEditsConvertNothing() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 40, height: 40)), on: &a)
        let rounded = try LayerFixture.object(CreateShape(.rectangle(.uniform(5)), size: Size(width: 40, height: 40)), on: &a)
        #expect(!ShapeConversion.isShape(OpID(counter: 999, replica: 9), in: a.state))
        // An edit that answers nothing converts nothing.
        #expect(try a.perform(ConvertingShapes("Nothing", [rect]) { _, _ in nil }) == nil)
        #expect(a.state.isLive(rect))
        let derived = try #require(ShapeConversion.path(of: rect, in: a.state))
        let change = try #require(try a.perform(Ungroup([rect])))
        let path = try #require(change.createdObjects.first)
        let range = path.counter..<(path.counter + 1_000)
        #expect(ShapeConversion.converted(rect, derived: derived, to: path, created: 0..<0, in: a.state) == nil, "no contour made there")
        let eight = try #require(ShapeConversion.path(of: rounded, in: a.state))
        #expect(ShapeConversion.converted(rect, derived: eight, to: path, created: range, in: a.state) == nil, "four points are not eight")
        #expect(ShapeConversion.converted(rect, derived: derived, to: path, created: range, in: a.state) != nil)
        // A rewrite that removes the shape's contour.
        var b = a
        b.undo()
        let contour = derived.contours[0]
        let rewrite = RewritePath(node: rect, removed: [contour.id], added: [NewContour(closed: true, points: PathFixture.points([(0, 0), (9, 0), (9, 9)]))],
                                  label: "Rewrite")
        #expect(try b.perform(ShapeConversion.asPaths(rewrite, in: b.state)) != nil && !b.state.isLive(rect))
    }

    @Test func aChangeThatIsNotAConversionFindsNone() throws {
        var a = Replica(0xA)
        let one = try CombineCommandTests.square(&a, x: 0)
        let two = try CombineCommandTests.square(&a, x: 10)
        let change = try #require(try a.perform(CombineCommand(.union, [one, two])))
        #expect(ShapeConversion.conversions(in: change, state: a.state).isEmpty, "a union is not a conversion")
        let rect = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 4, height: 4)), on: &a)
        let deletion = try #require(try a.perform(DeleteNodes([rect])))
        #expect(ShapeConversion.conversions(in: deletion, state: a.state).isEmpty)
    }
}

/// The merge of a conversion with a concurrent edit of the live shape (rectangles-ellipses-lines.adoc,
/// "Merge semantics": *Convert to path vs. any shape edit*).
@Suite struct ShapeConversionMergeTests {
    @Test func convertingByAPointDragVersusAConcurrentRadiusEditKeepsTheRadiusOnTheDeletedShape() throws {
        var pair = Pair()
        let rect = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 40, height: 30)), on: &pair.a)
        pair.sync()
        let contour = try #require(ShapeConversion.path(of: rect, in: pair.a.state)?.contours[0])
        try pair.a.perform(ShapeConversion.asPaths(MovePoints(node: rect, contour: contour.id, point: contour.points[2].id, to: Point(x: 50, y: 40)),
                                                   in: pair.a.state))
        try pair.b.perform(SetCornerRadius([rect], radius: 6))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        for replica in [pair.a, pair.b] {
            #expect(!replica.state.isLive(rect), "the conversion deleted the shape")
            let path = try #require(ShapeConversionTests.paths(in: replica.state).first)
            #expect(replica.path(path).contours[0].drawn[2].anchor == Point(x: 50, y: 40), "the drag landed on the path")
            #expect(replica.path(path).contours[0].points.count == 4, "with the corners it had when converted")
            #expect(replica.state.props(rect).rect.corners.topLeft == 6, "the radius edit is kept on the deleted shape (edit vs delete)")
        }
        // Restore brings the shape back beside the path, with the radius.
        try pair.b.perform(OpsCommand("Restore", ops: [Ops.setDeleted(rect, false)]))
        pair.sync()
        #expect(pair.a.state.isLive(rect) && ShapeConversion.path(of: rect, in: pair.a.state)?.contours[0].points.count == 8)
    }

    @Test func twoReplicasConvertingTheSameShapeGetTwoPathsAndNoShape() throws {
        var pair = Pair()
        let ellipse = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 40, height: 30)), on: &pair.a)
        pair.sync()
        let contour = try #require(ShapeConversion.path(of: ellipse, in: pair.a.state)?.contours[0])
        try pair.a.perform(ShapeConversion.asPaths(MovePoints(node: ellipse, contour: contour.id, point: contour.points[0].id, to: Point(x: 20, y: -10)),
                                                   in: pair.a.state))
        try pair.b.perform(ShapeConversion.asPaths(AddPoints([ellipse]), in: pair.b.state))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(!pair.a.state.isLive(ellipse))
        #expect(ShapeConversionTests.paths(in: pair.a.state).count == 2, "each conversion made its own path; the review lists both")
    }
}
