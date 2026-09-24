import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Join and Split (OBJ-024, combining-paths.adoc "Join").
@Suite struct JoinSplitTests {
    static func circle(_ x: Double, on a: inout Replica) throws -> OpID {
        try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 10, height: 10), transform: .translation(x: x, y: 0)), on: &a)
    }

    /// The anchors of `node`'s contours in pasteboard space.
    static func anchors(_ node: OpID, in state: EngineState) -> [[Point]] {
        let matrix = Objects.pasteboardTransform(of: node, in: state)
        return Objects.localPath(node, in: state)!.contours.map { $0.drawn.map { matrix.apply($0.anchor) } }
    }

    static func near(_ a: [[Point]], _ b: [[Point]]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y in
            x.count == y.count && zip(x, y).allSatisfy { abs($0.x - $1.x) < 1e-9 && abs($0.y - $1.y) < 1e-9 }
        }
    }

    @Test func joiningThreeCirclesMakesOneCompositeThatSplitsIntoThree() throws {
        var a = Replica(0xA)
        let circles = try [0.0, 20, 40].map { try Self.circle($0, on: &a) }
        try a.perform(AddAppearance.fill([circles[0]], Appearances.basicFill(red: 1, green: 0, blue: 0)))
        let before = circles.flatMap { Self.anchors($0, in: a.state) }
        let look = try #require(AttributePasteTests.look(circles[0], in: a.state))
        #expect(look.count == 2)
        let layer = Objects.parent(of: circles[0], in: a.state)!
        let change = try #require(try a.perform(JoinObjects(circles)))
        #expect(change.label == "Join 3 paths")
        let joined = try #require(change.createdRoots.first)
        #expect(a.state.nodeKind(joined) == .path)
        #expect(a.state.liveElements(joined, PathFields.contours).count == 3)
        #expect(Self.near(Self.anchors(joined, in: a.state), before))
        #expect(AttributePasteTests.look(joined, in: a.state) == look)
        #expect(!circles.contains(where: a.state.isLive))
        #expect(a.state.liveChildren(layer) == [joined])
        let split = try #require(try a.perform(SplitObjects([joined])))
        #expect(split.label == "Split")
        let pieces = split.createdRoots
        #expect(pieces.count == 3)
        #expect(Self.near(pieces.flatMap { Self.anchors($0, in: a.state) }, before))
        #expect(pieces.allSatisfy { AttributePasteTests.look($0, in: a.state) == look })
        #expect(a.state.liveChildren(layer) == pieces)
        // A path of one contour does not split; undo brings the composite back.
        #expect(try a.perform(SplitObjects([pieces[0]])) == nil)
        #expect(!SplitObjects.splits(circles[0], in: a.state))
        a.undo()
        #expect(a.state.isLive(joined) && !a.state.isLive(pieces[0]))
        a.undo()
        #expect(circles.allSatisfy(a.state.isLive))
    }

    @Test func theResultKeepsTheBackmostTransformAndSitsAtTheFrontmostSlot() throws {
        var a = Replica(0xA)
        let back = try LayerFixture.object(PathFixture.closed([(0, 0), (10, 0), (10, 10)]), on: &a)
        try a.perform(TransformObjects([back], matrix: .rotation(radians: 0.5), about: Point(x: 0, y: 0), kind: .rotate))
        let other = try LayerFixture.object(LayerFixture.rect(on: nil, x: 50), on: &a)
        let front = try LayerFixture.object(PathFixture.closed([(100, 0), (110, 0), (110, 10)]), on: &a)
        let top = try LayerFixture.object(LayerFixture.rect(on: nil, x: 200), on: &a)
        let group = try a.perform(GroupObjects([front]))!.createdObjects[0]
        try a.perform(MoveObjects([group], by: Vector(dx: 5, dy: 5)))
        let before = [back, front].flatMap { Self.anchors($0, in: a.state) }
        let joined = try #require(try a.perform(JoinObjects([front, back]))?.createdRoots.first)
        #expect(Objects.parent(of: joined, in: a.state) == group)
        #expect(Self.near(Self.anchors(joined, in: a.state), before))
        #expect(nearly(Objects.pasteboardTransform(of: joined, in: a.state), Objects.pasteboardTransform(of: back, in: a.state)))
        #expect(a.state.isLive(other) && a.state.isLive(top))
    }

    @Test func openPathsJoinOnlyWhenTheirEndsTouch() throws {
        var a = Replica(0xA)
        let first = try LayerFixture.object(PathFixture.open([(0, 0), (10, 0)]), on: &a)
        let touching = try LayerFixture.object(PathFixture.open([(10, 0), (10, 10)]), on: &a)
        let apart = try LayerFixture.object(PathFixture.open([(12, 12), (20, 20)]), on: &a)
        let change = try #require(try a.perform(JoinObjects([first, touching, apart])))
        let joined = change.createdRoots[0]
        let path = a.path(joined)
        #expect(path.contours.count == 2)
        #expect(path.contours.allSatisfy { !$0.closed })
        #expect(PathFixture.anchors(path.contours[0]) == [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 10)])
        a.undo()
        // With Join non-touching paths on, ends within the snap distance join too.
        let snapped = try #require(try a.perform(JoinObjects([first, touching, apart], snapDistance: 3))?.createdRoots.first)
        let one = a.path(snapped)
        #expect(one.contours.count == 1)
        #expect(PathFixture.anchors(one.contours[0]) == [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 11, y: 11), Point(x: 20, y: 20)])
    }

    @Test func endsJoinWhicheverWayRoundTheyMeet() {
        func line(_ from: (Double, Double), _ to: (Double, Double)) -> [VectorPoint] {
            [VectorPoint(anchor: Point(x: from.0, y: from.1), outHandle: Vector(dx: 1, dy: 0)),
             VectorPoint(anchor: Point(x: to.0, y: to.1), inHandle: Vector(dx: -1, dy: 0))]
        }
        func anchors(_ contours: [[VectorPoint]]) -> [[Point]] { contours.map { $0.map(\.anchor) } }
        let o = Point(x: 0, y: 0), p = Point(x: 5, y: 0), q = Point(x: 9, y: 0)
        // last-first, last-last, first-last, first-first.
        #expect(anchors(JoinObjects.joinEnds([line((0, 0), (5, 0)), line((5, 0), (9, 0))], within: 0)) == [[o, p, q]])
        #expect(anchors(JoinObjects.joinEnds([line((0, 0), (5, 0)), line((9, 0), (5, 0))], within: 0)) == [[o, p, q]])
        #expect(anchors(JoinObjects.joinEnds([line((5, 0), (9, 0)), line((0, 0), (5, 0))], within: 0)) == [[o, p, q]])
        #expect(anchors(JoinObjects.joinEnds([line((5, 0), (0, 0)), line((5, 0), (9, 0))], within: 0)) == [[o, p, q]])
        // The joint keeps the arriving in handle and the leaving out handle.
        let joint = JoinObjects.joinEnds([line((0, 0), (5, 0)), line((5, 0), (9, 0))], within: 0)[0][1]
        #expect(joint.inHandle == Vector(dx: -1, dy: 0) && joint.outHandle == Vector(dx: 1, dy: 0))
        #expect(JoinObjects.joinEnds([line((0, 0), (5, 0))], within: 0).count == 1)
    }

    @Test func joinNeedsTwoUnlockedPaths() throws {
        var a = Replica(0xA)
        let one = try LayerFixture.object(PathFixture.closed([(0, 0), (10, 0), (10, 10)]), on: &a)
        let locked = try LayerFixture.object(PathFixture.closed([(20, 0), (30, 0), (30, 10)]), on: &a)
        let group = try a.perform(GroupObjects([try LayerFixture.object(LayerFixture.rect(on: nil, x: 60), on: &a)]))!.createdObjects[0]
        try a.perform(SetLocked([locked], locked: true))
        #expect(try a.perform(JoinObjects([one, locked, group])) == nil)
        #expect(JoinObjects.inputs([one], in: a.state).isEmpty)
        #expect(try a.perform(SplitObjects([locked])) == nil)
    }

    @Test func aDegenerateBackmostTransformFallsBackToTheParentSpace() throws {
        var a = Replica(0xA)
        let flat = try LayerFixture.object(PathFixture.closed([(0, 0), (10, 0), (10, 10)]), on: &a)
        let other = try LayerFixture.object(PathFixture.closed([(20, 0), (30, 0), (30, 10)]), on: &a)
        var zero = Wiretuner_Doc_V1_Transform()
        zero.a = 0
        zero.d = 0
        zero.tx = 1
        try a.perform(OpsCommand("flatten", ops: [Ops.set(flat, [PathFields.transform], values: NodeValues.with(kind: .path, transform: zero))]))
        let joined = try #require(try a.perform(JoinObjects([flat, other]))?.createdRoots.first)
        #expect(Objects.transform(of: joined, in: a.state) == .identity)
        #expect(a.path(joined).contours.count == 2)
    }
}

/// OBJ-024's merge test.
@Suite struct JoinSplitMergeTests {
    @Test func joinVersusARemotePointEditKeepsTheEditOnTheDeletedInputAndOneResult() throws {
        var pair = Pair()
        let first = try LayerFixture.object(PathFixture.closed([(0, 0), (10, 0), (10, 10)]), on: &pair.a)
        let second = try LayerFixture.object(PathFixture.closed([(20, 0), (30, 0), (30, 10)]), on: &pair.a)
        pair.sync()
        let contour = pair.b.state.liveElements(second, PathFields.contours)[0]
        let point = pair.b.state.liveElements(second, PathFields.points(contour))[1]
        try pair.b.perform(MovePoints(node: second, contour: contour, point: point, to: Point(x: 40, y: 5)))
        let joined = try #require(try pair.a.perform(JoinObjects([first, second]))?.createdRoots.first)
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(!pair.a.state.isLive(second) && !pair.a.state.isLive(first))
        #expect(pair.a.path(second).contours[0].points[1].anchor == Point(x: 40, y: 5))
        let layer = Objects.parent(of: joined, in: pair.a.state)!
        #expect(pair.a.state.liveChildren(layer) == [joined])
    }
}
