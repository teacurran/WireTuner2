import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Stroke fitting and continuation (DRAW-016/017), Bezigon points (DRAW-022), Add Points (DRAW-026).
@Suite struct PathToolTests {
    static func arc(_ count: Int, radius: Double = 100) -> [Point] {
        (0...count).map { i in
            let t = Double(i) / Double(count) * .pi
            return Point(x: radius * cos(t), y: radius * sin(t))
        }
    }

    @Test func aFreehandStrokeFitsToCurvePoints() {
        let points = StrokeFit.points([.freehand(Self.arc(60))], precision: PrecisionSetting(5))
        #expect(points.count >= 2 && points.count < 10)
        #expect(points.first?.kind == .corner && points.last?.kind == .corner)
        #expect(points.first!.anchor.distance(to: Point(x: 100, y: 0)) < 1)
        #expect(points.dropFirst().dropLast().allSatisfy { $0.kind == .curve })
        // Higher precision follows more closely: never fewer points.
        let precise = StrokeFit.points([.freehand(Self.arc(60))], precision: PrecisionSetting(10))
        #expect(precise.count >= points.count)
        // Zoomed in 16×, the tolerance is 16× smaller in pasteboard units.
        #expect(PrecisionSetting(5).tolerance(zoom: 16) * 16 == PrecisionSetting(5).tolerance(zoom: 1))
        #expect(StrokeFit.points([.freehand([Point(x: 1, y: 1)])], precision: PrecisionSetting(5)).isEmpty)
    }

    @Test func optionSpansAreStraightBetweenCorners() {
        let spans: [StrokeFit.Span] = [
            .freehand(Self.arc(40, radius: 50)),
            .straight(Point(x: -50, y: 0), Point(x: -50, y: -40)),
            .straight(Point(x: -50, y: -40), Point(x: -50, y: -40)),
        ]
        let points = StrokeFit.points(spans, precision: PrecisionSetting(5))
        let last = points[points.count - 1], join = points[points.count - 2]
        #expect(last.anchor == Point(x: -50, y: -40) && last.inHandle == .zero && last.kind == .corner)
        #expect(join.kind == .corner && join.outHandle == .zero)
        #expect(join.anchor.distance(to: Point(x: -50, y: 0)) < 1e-6)
        #expect(StrokeFit.points([.straight(.zero, Point(x: 10, y: 0))], precision: PrecisionSetting(1)).map(\.anchor) == [.zero, Point(x: 10, y: 0)])
        #expect(StrokeFit.smooth(.zero, Vector(dx: 1, dy: 0)) == false)
        #expect(StrokeFit.fitted(Contour(segments: [], closed: false)).isEmpty)
    }

    @Test func continuationInsertsAtTheRightEnd() throws {
        var a = Replica(0xA)
        let (node, contour) = PathFixture.ids(try a.perform(PathFixture.open([(0, 0), (10, 0)])), in: a.state)
        let stroke = [VectorPoint(anchor: Point(x: 10, y: 0), outHandle: Vector(dx: 3, dy: 0)), VectorPoint(anchor: Point(x: 20, y: 5), kind: .curve),
                      VectorPoint(anchor: Point(x: 30, y: 0))]
        let change = try a.perform(ContinuePath(node: node, contour: contour, end: .end, points: stroke))!
        #expect(change.label == "Pencil")
        var drawn = a.path(node).contour(contour)!.drawn
        #expect(drawn.map(\.anchor) == [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 20, y: 5), Point(x: 30, y: 0)])
        #expect(drawn[1].outHandle == Vector(dx: 3, dy: 0))
        // From the start: the new points come before it, reversed.
        let back = [VectorPoint(anchor: .zero, outHandle: Vector(dx: -2, dy: 0)), VectorPoint(anchor: Point(x: -10, y: 0))]
        try a.perform(ContinuePath(node: node, contour: contour, end: .start, points: back))
        drawn = a.path(node).contour(contour)!.drawn
        #expect(drawn.first?.anchor == Point(x: -10, y: 0))
        #expect(drawn[1].inHandle == Vector(dx: -2, dy: 0))
        #expect(throws: PathEditError.invalidValue("continuation")) {
            try a.perform(ContinuePath(node: node, contour: contour, end: .end, points: [stroke[0]]))
        }
    }

    @Test func bezigonPointsAreAutomatic() throws {
        var a = Replica(0xA)
        let (node, contour) = PathFixture.ids(try a.perform(PathFixture.open([(0, 0), (10, 10)])), in: a.state)
        let end = a.path(node).contour(contour)!.drawn.last!.id
        try a.perform(InsertPoints(node: node, contour: contour, at: .after(end), points: [VectorPoint(anchor: Point(x: 20, y: 0), kind: .curve, automatic: true)]))
        let added = a.path(node).contour(contour)!.drawn.last!
        #expect(added.automatic)
        #expect(added.inHandle == (Point(x: 10, y: 10) - Point(x: 20, y: 0)) / 3)
    }

    @Test func addPointsDoublesThePointCountWithoutChangingTheOutline() throws {
        var a = Replica(0xA)
        let ellipse = try a.perform(Ungroup([try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 100, height: 60)), on: &a)]))!.createdRoots[0]
        let square = try LayerFixture.object(PathFixture.closed([(0, 0), (10, 0), (10, 10), (0, 10)]), on: &a)
        var automatic = PathFixture.open([(0, 0), (10, 10), (20, 0)])
        automatic.contours[0].points[1].automatic = true
        let auto = try LayerFixture.object(automatic, on: &a)
        let before = a.path(ellipse).contours[0]
        let change = try a.perform(AddPoints([ellipse, square, auto]))!
        #expect(change.label == "Add Points")
        let after = a.path(ellipse).contours[0]
        #expect(after.points.count == 8)
        for segment in before.segments {
            for t in stride(from: 0.0, through: 1.0, by: 0.125) {
                let point = segment.cubic.evaluate(t)
                let nearest = after.segments.map { $0.cubic.distance(to: point) }.min()!
                #expect(nearest < 0.01)
            }
        }
        #expect(a.path(square).contours[0].drawn.map(\.anchor) == PathFixture.points([(0, 0), (5, 0), (10, 0), (10, 5), (10, 10), (5, 10), (0, 10), (0, 5)]).map(\.anchor))
        #expect(a.path(auto).contours[0].points.count == 5)
        let stillAutomatic = a.path(auto).contours[0].points.contains { $0.automatic }
        #expect(!stillAutomatic)
    }
}

/// The merge tests of DRAW-016, DRAW-017, DRAW-022 and DRAW-026.
@Suite struct PathToolMergeTests {
    @Test func continuationVersusAConcurrentPointMoveElsewhereKeepsBoth() throws {
        var pair = Pair()
        let (node, contour) = PathFixture.ids(try pair.a.perform(PathFixture.open([(0, 0), (10, 0), (20, 0)])), in: pair.a.state)
        pair.sync()
        let first = pair.b.path(node).contour(contour)!.points[0].id
        try pair.a.perform(ContinuePath(node: node, contour: contour, end: .end,
                                        points: [VectorPoint(anchor: Point(x: 20, y: 0)), VectorPoint(anchor: Point(x: 30, y: 5))]))
        try pair.b.perform(MovePoints(node: node, contour: contour, point: first, to: Point(x: -5, y: 0)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let anchors = pair.a.path(node).contour(contour)!.drawn.map(\.anchor)
        #expect(anchors == [Point(x: -5, y: 0), Point(x: 10, y: 0), Point(x: 20, y: 0), Point(x: 30, y: 5)])
    }

    @Test func continuationVersusDeleteLeavesADeletedPathWithTheEdit() throws {
        var pair = Pair()
        let (node, contour) = PathFixture.ids(try pair.a.perform(PathFixture.open([(0, 0), (10, 0)])), in: pair.a.state)
        pair.sync()
        try pair.a.perform(ContinuePath(node: node, contour: contour, end: .end,
                                        points: [VectorPoint(anchor: Point(x: 10, y: 0)), VectorPoint(anchor: Point(x: 20, y: 5))]))
        try pair.b.perform(DeleteNodes([node]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(!pair.a.state.isLive(node))
        #expect(pair.a.path(node).contour(contour)!.points.count == 3)
    }

    @Test func bezigonResmoothVersusAHandleDragIsPerRegister() throws {
        var pair = Pair()
        var command = PathFixture.open([(0, 0), (10, 10)])
        command.contours[0].points[1].automatic = true
        command.contours[0].points[1].kind = .curve
        let (node, contour) = PathFixture.ids(try pair.a.perform(command), in: pair.a.state)
        pair.sync()
        let end = pair.a.path(node).contour(contour)!.drawn.last!.id
        try pair.a.perform(InsertPoints(node: node, contour: contour, at: .after(end), points: [VectorPoint(anchor: Point(x: 20, y: 0), kind: .curve, automatic: true)]))
        try pair.b.perform(SetHandles(node: node, contour: contour, point: end, out: Vector(dx: 4, dy: 0)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let point = pair.a.path(node).contour(contour)!.points.first { $0.id == end }!
        #expect(!point.automatic)   // the drag made it an ordinary point
        #expect(pair.a.path(node).contour(contour)!.points.count == 3)
    }

    @Test func deleteSegmentVersusAConcurrentPointMoveKeepsTheMove() throws {
        var pair = Pair()
        let (node, contour) = PathFixture.ids(try pair.a.perform(PathFixture.closed([(0, 0), (10, 0), (10, 10), (0, 10)])), in: pair.a.state)
        pair.sync()
        let ids = pair.a.path(node).contour(contour)!.points.map(\.id)
        try pair.a.perform(DeleteSegment(node: node, contour: contour, from: ids[1]))
        try pair.b.perform(MovePoints(node: node, contour: contour, point: ids[3], to: Point(x: -1, y: 11)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let merged = pair.a.path(node).contour(contour)!
        #expect(!merged.closed && merged.start == ids[2])
        #expect(merged.points.first { $0.id == ids[3] }?.anchor == Point(x: -1, y: 11))
    }

    @Test func addPointsVersusAConcurrentHandleDragConverges() throws {
        var pair = Pair()
        let curve = [VectorPoint(anchor: .zero, outHandle: Vector(dx: 5, dy: 5)), VectorPoint(anchor: Point(x: 20, y: 0), inHandle: Vector(dx: -5, dy: 5))]
        let node = try LayerFixture.object(CreatePath(contours: [NewContour(points: curve)]), on: &pair.a)
        pair.sync()
        let contour = pair.a.path(node).contours[0]
        try pair.a.perform(AddPoints([node]))
        try pair.b.perform(SetHandles(node: node, contour: contour.id, point: contour.points[0].id, out: Vector(dx: 9, dy: 0), linked: false))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(pair.a.path(node).contours[0].points.count == 3)
    }
}
