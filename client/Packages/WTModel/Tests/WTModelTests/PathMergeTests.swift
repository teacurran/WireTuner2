import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// The merge cases of vector-basics.adoc, "Merge semantics" (DRAW-002), plus the merge tests of
/// DRAW-004, DRAW-007 and DRAW-021, each through two in-process replicas.
@Suite struct PathMergeTests {
    /// Two replicas sharing one path created on A.
    struct Shared {
        var pair = Pair()
        let node: OpID
        let contour: OpID
        let ids: [OpID]

        init(_ command: CreatePath) throws {
            let change = try pair.a.perform(command)
            (node, contour) = PathFixture.ids(change, in: pair.a.state)
            ids = pair.a.path(node).contours[0].points.map(\.id)
            pair.sync()
        }

        /// Both replicas read the same state; returns the merged contour.
        func merged() -> VectorContour {
            #expect(pair.a.state.stateHash == pair.b.state.stateHash)
            #expect(pair.a.path(node) == pair.b.path(node))
            return pair.a.path(node).contour(contour)!
        }
    }

    static func line(_ n: Int) -> CreatePath {
        PathFixture.open((0..<n).map { (Double($0) * 10, 0) })
    }

    @Test func samePointDragGoesToTheGreaterOpID() throws {
        var s = try Shared(Self.line(3))
        let a = try s.pair.a.perform(MovePoints(node: s.node, contour: s.contour, point: s.ids[1], to: Point(x: 1, y: 1)))!
        let b = try s.pair.b.perform(MovePoints(node: s.node, contour: s.contour, point: s.ids[1], to: Point(x: 2, y: 2)))!
        s.pair.sync()
        let winner = OpID(counter: a.startCounter, replica: a.replica) > OpID(counter: b.startCounter, replica: b.replica) ? Point(x: 1, y: 1) : Point(x: 2, y: 2)
        #expect(s.merged().points[1].anchor == winner)
        #expect(s.pair.a.state.store.losingWrites(s.node, PathFields.anchor(s.contour, s.ids[1])).count == 2)   // creation and the loser
    }

    @Test func pointAndHandleOfOnePointBothSurvive() throws {
        var s = try Shared(Self.line(3))
        try s.pair.a.perform(MovePoints(node: s.node, contour: s.contour, point: s.ids[1], to: Point(x: 50, y: 50)))
        try s.pair.b.perform(SetHandles(node: s.node, contour: s.contour, point: s.ids[1], out: Vector(dx: 5, dy: 0)))
        s.pair.sync()
        let point = s.merged().points[1]
        #expect(point.anchor == Point(x: 50, y: 50))
        #expect(point.outControl == Point(x: 55, y: 50))
    }

    @Test func concurrentCurveHandleDragsRenderAsStoredUntilRelinked() throws {
        let curve = VectorPoint(anchor: Point(x: 10, y: 0), inHandle: Vector(dx: -2, dy: 0), outHandle: Vector(dx: 2, dy: 0), kind: .curve)
        var s = try Shared(CreatePath(contours: [NewContour(points: [VectorPoint(anchor: .zero), curve, VectorPoint(anchor: Point(x: 20, y: 0))])]))
        // A's arriving handle is written later (a higher counter) than B's tandem pair.
        try s.pair.a.perform(OpsCommand("Other", ops: [Ops.noop()]))
        try s.pair.a.perform(SetHandles(node: s.node, contour: s.contour, point: s.ids[1], in: Vector(dx: -3, dy: 3), linked: false))
        try s.pair.b.perform(SetHandles(node: s.node, contour: s.contour, point: s.ids[1], out: Vector(dx: 0, dy: 4)))
        s.pair.sync()
        let point = s.merged().points[1]
        #expect(point.kind == .curve)
        #expect(point.inHandle == Vector(dx: -3, dy: 3))
        #expect(point.outHandle == Vector(dx: 0, dy: 4))
        #expect(point.handlesUnlinked)
        // Rendered as stored.
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(s.pair.a.state)
        guard case .path(let item) = scene.displayList.items[0], case .cubicCurve(let c1, let c2, _) = item.path.elements[1] else {
            Issue.record("curve"); return
        }
        #expect(c1 == Point(x: 0, y: 0) && c2 == Point(x: 7, y: 3))
        // The next type change by anyone relinks them.
        try s.pair.b.perform(SetPointKind(node: s.node, points: [(s.contour, s.ids[1])], kind: .curve))
        s.pair.sync()
        #expect(!s.merged().points[1].handlesUnlinked)
    }

    @Test func deleteWinsOverAMoveOfTheSamePoint() throws {
        var s = try Shared(Self.line(3))
        try s.pair.a.perform(DeletePoints(node: s.node, points: [(s.contour, s.ids[1])]))
        try s.pair.b.perform(MovePoints(node: s.node, contour: s.contour, point: s.ids[1], to: Point(x: 99, y: 99)))
        s.pair.sync()
        #expect(s.merged().points.map(\.id) == [s.ids[0], s.ids[2]])
        // The anchor write is retained on the tombstone.
        let written = s.pair.a.state.register(s.node, PathFields.anchor(s.contour, s.ids[1]))
        #expect(written?.value == s.pair.b.state.register(s.node, PathFields.anchor(s.contour, s.ids[1]))?.value)
    }

    @Test func closeAndAppendBothSurvive() throws {
        var s = try Shared(Self.line(3))
        try s.pair.a.perform(SetClosed(node: s.node, closed: true))
        try s.pair.b.perform(InsertPoints(node: s.node, contour: s.contour, at: .end, points: [VectorPoint(anchor: Point(x: 30, y: 5))]))
        s.pair.sync()
        let contour = s.merged()
        #expect(contour.closed)
        #expect(contour.drawn.map(\.anchor.x) == [0, 10, 20, 30])
        let closing = contour.segments.last!
        #expect(closing.from.anchor == Point(x: 30, y: 5) && closing.to.id == s.ids[0])
    }

    @Test func togglingClosedInTheObjectPanelWhileAnotherAppends() throws {
        // DRAW-004's merge test, starting from a closed contour opened by the panel.
        var s = try Shared(PathFixture.closed([(0, 0), (10, 0), (10, 10)]))
        try s.pair.a.perform(SetClosed(node: s.node, closed: false))
        try s.pair.a.perform(SetClosed(node: s.node, closed: true))
        try s.pair.b.perform(InsertPoints(node: s.node, contour: s.contour, at: .end, points: [VectorPoint(anchor: Point(x: 0, y: 10))]))
        s.pair.sync()
        let contour = s.merged()
        #expect(contour.closed && contour.points.count == 4)
        #expect(contour.drawn.last?.anchor == Point(x: 0, y: 10))
    }

    @Test func reverseDoesNotDisturbAConcurrentInsert() throws {
        var s = try Shared(Self.line(3))
        try s.pair.a.perform(ReverseContours(node: s.node))
        let insert = try s.pair.b.perform(InsertPoints(node: s.node, contour: s.contour, at: .after(s.ids[1]), points: [VectorPoint(anchor: Point(x: 15, y: 0))]))!
        let inserted = insert.insertedElements(s.node, PathFields.points(s.contour))[0]
        s.pair.sync()
        let contour = s.merged()
        #expect(contour.reversed)
        #expect(contour.points.map(\.id) == [s.ids[0], s.ids[1], inserted, s.ids[2]])
        #expect(contour.drawn.map(\.anchor.x) == [20, 15, 10, 0])
        // Two concurrent reversals reverse once.
        try s.pair.a.perform(ReverseContours(node: s.node))
        try s.pair.b.perform(ReverseContours(node: s.node))
        s.pair.sync()
        #expect(!s.merged().reversed)
    }

    @Test func openingAtASegmentKeepsConcurrentEdits() throws {
        var s = try Shared(PathFixture.closed([(0, 0), (10, 0), (10, 10), (0, 10)]))
        try s.pair.a.perform(DeleteSegment(node: s.node, contour: s.contour, from: s.ids[3]))
        try s.pair.b.perform(MovePoints(node: s.node, contour: s.contour, point: s.ids[1], to: Point(x: 20, y: 0)))
        s.pair.sync()
        let contour = s.merged()
        #expect(!contour.closed && contour.start == s.ids[0])
        #expect(contour.drawn.map(\.anchor) == [Point(x: 0, y: 0), Point(x: 20, y: 0), Point(x: 10, y: 10), Point(x: 0, y: 10)])
    }

    @Test func aStartDeletedConcurrentlyFallsToTheNextSurvivor() throws {
        var s = try Shared(PathFixture.closed([(0, 0), (10, 0), (10, 10), (0, 10)]))
        try s.pair.a.perform(DeleteSegment(node: s.node, contour: s.contour, from: s.ids[1]))   // start = ids[2]
        try s.pair.b.perform(DeletePoints(node: s.node, points: [(s.contour, s.ids[2])]))
        s.pair.sync()
        let contour = s.merged()
        #expect(contour.start == s.ids[3])
        #expect(contour.drawn.map(\.id) == [s.ids[3], s.ids[0], s.ids[1]])
    }

    @Test func joinAbsorbsThePathAndAConcurrentEditLandsOnTheDeletedNode() throws {
        var pair = Pair()
        let (target, targetContour) = PathFixture.ids(try pair.a.perform(PathFixture.open([(0, 0), (10, 0)])), in: pair.a.state)
        let (source, sourceContour) = PathFixture.ids(try pair.a.perform(PathFixture.open([(20, 0), (30, 0)])), in: pair.a.state)
        let sourcePoints = pair.a.path(source).contours[0].points.map(\.id)
        pair.sync()
        try pair.a.perform(JoinPaths(target: target, targetContour: targetContour, targetEnd: .end, source: source, sourceContour: sourceContour, sourceEnd: .start))
        try pair.b.perform(MovePoints(node: source, contour: sourceContour, point: sourcePoints[1], to: Point(x: 40, y: 5)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(pair.a.path(target).contours[0].drawn.map(\.anchor.x) == [0, 10, 20, 30])
        #expect(!pair.a.state.isLive(source) && !pair.b.state.isLive(source))
        #expect(pair.a.path(source).contours[0].points[1].anchor == Point(x: 40, y: 5))
    }

    @Test func concurrentRectanglesBothExistInTheSameOrder() throws {
        var pair = Pair()
        // With no layer yet, each replica creates its own "Foreground" layer.
        let a = try pair.a.perform(CreateShape(.rectangle(.uniform(0)), size: Size(width: 10, height: 10)))!.createdObjects[0]
        let b = try pair.b.perform(CreateShape(.rectangle(.uniform(0)), size: Size(width: 20, height: 20)))!.createdObjects[0]
        pair.sync()
        var sceneA = DocumentDisplayListBuilder(canvas: "c")
        var sceneB = DocumentDisplayListBuilder(canvas: "c")
        #expect(sceneA.rebuild(pair.a.state).topLevel == sceneB.rebuild(pair.b.state).topLevel)
        #expect(Set(sceneA.scene.topLevel) == [NodeID(a), NodeID(b)])
        // On a shared layer.
        let c = try pair.a.perform(CreateShape(.ellipse, size: Size(width: 10, height: 10)))!.createdObjects[0]
        let d = try pair.b.perform(CreateShape(.ellipse, size: Size(width: 10, height: 10)))!.createdObjects[0]
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let order = sceneA.rebuild(pair.a.state).topLevel
        #expect(order == sceneB.rebuild(pair.b.state).topLevel)
        #expect(Set(order.suffix(2)) == [NodeID(c), NodeID(d)])
    }

    @Test func twoReplicasContinuingTheSameEndBothKeepTheirPoints() throws {
        var s = try Shared(Self.line(2))
        let fromA = try s.pair.a.perform(InsertPoints(node: s.node, contour: s.contour, at: .end, points: [VectorPoint(anchor: Point(x: 100, y: 0)), VectorPoint(anchor: Point(x: 110, y: 0))]))!
        let fromB = try s.pair.b.perform(InsertPoints(node: s.node, contour: s.contour, at: .end, points: [VectorPoint(anchor: Point(x: 200, y: 0))]))!
        s.pair.sync()
        let contour = s.merged()
        #expect(contour.points.count == 5)
        #expect(Array(contour.points.prefix(2).map(\.id)) == s.ids)
        let added = Set(fromA.insertedElements(s.node, PathFields.points(s.contour)) + fromB.insertedElements(s.node, PathFields.points(s.contour)))
        #expect(Set(contour.points.suffix(3).map(\.id)) == added)
    }
}
