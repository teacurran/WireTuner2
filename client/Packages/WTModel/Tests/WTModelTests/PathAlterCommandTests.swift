import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto

/// DRAW-030 (Simplify, Reverse Direction, Correct Direction) and FX-031 (Add Points, Fractalize).
@Suite struct PathAlterCommandTests {
    /// A traced-looking closed path: `count` corner points around a circle of `radius`, with a
    /// little deterministic jitter.
    static func traced(count: Int = 1_000, radius: Double = 200) -> CreatePath {
        var points: [VectorPoint] = []
        for index in 0..<count {
            let angle = Double(index) / Double(count) * 2 * .pi
            let wobble = sin(Double(index) * 0.37) * 0.2
            points.append(VectorPoint(anchor: Point(x: 300 + (radius + wobble) * cos(angle), y: 300 + (radius + wobble) * sin(angle))))
        }
        return CreatePath(contours: [NewContour(closed: true, points: points)])
    }

    /// The greatest distance from a sample of `original`'s outline to `result`'s.
    static func outlineError(_ original: VectorContour, _ result: VectorContour) -> Double {
        let segments = result.segments.map(\.cubic)
        var worst = 0.0
        for segment in original.segments {
            for t in stride(from: 0.0, through: 1.0, by: 0.25) {
                let point = segment.cubic.evaluate(t)
                worst = max(worst, segments.map { $0.distance(to: point) }.min()!)
            }
        }
        return worst
    }

    @Test func simplifyAtZeroIsANoOp() throws {
        var a = Replica(0xA)
        let node = try LayerFixture.object(Self.traced(count: 50), on: &a)
        #expect(try a.perform(SimplifyPaths([node], amount: 0)) == nil)
        #expect(PathAlterKernels.simplifyTolerance(amount: .nan) == 0)
        #expect(PathAlterKernels.simplifyTolerance(amount: 400) == 5)
        #expect(SimplifyPaths.preview([node], amount: 0, in: a.state)[node] == a.path(node))
    }

    @Test func simplifyAtOneHundredThinsATracedPathWithinTheTolerance() throws {
        var a = Replica(0xA)
        let node = try LayerFixture.object(Self.traced(), on: &a)
        let before = a.path(node).contours[0]
        #expect(before.points.count == 1_000)
        let preview = try #require(SimplifyPaths.preview([node], amount: 100, in: a.state)[node])
        let change = try #require(try a.perform(SimplifyPaths([node], amount: 100)))
        #expect(change.label == "Simplify")
        let after = a.path(node).contours[0]
        #expect(after.points.count < 100)
        #expect(after.closed && after.id == before.id)
        #expect(Set(after.points.map(\.id)).isDisjoint(with: before.points.map(\.id)), "every point is new")
        #expect(Self.outlineError(before, after) <= PathAlterKernels.simplifyTolerance(amount: 100) + 0.01)
        #expect(preview.contours[0].drawn.map(\.anchor) == after.drawn.map(\.anchor))
        // Undo brings the old points back.
        a.undo()
        #expect(a.path(node).contours[0].points.map(\.id) == before.points.map(\.id))
    }

    @Test func simplifyLeavesWhatItCannotShortenAndSkipsOtherKinds() throws {
        var a = Replica(0xA)
        let square = try LayerFixture.object(PathFixture.closed([(0, 0), (10, 0), (10, 10), (0, 10)]), on: &a)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        #expect(try a.perform(SimplifyPaths([square, rect], amount: 100)) == nil)
        // An open wiggly line simplifies too, keeping its ends.
        var points: [(Double, Double)] = []
        for index in 0...200 { points.append((Double(index), sin(Double(index) / 20) * 10)) }
        let line = try LayerFixture.object(PathFixture.open(points), on: &a)
        try a.perform(SimplifyPaths([line], amount: 40))
        let simplified = a.path(line).contours[0]
        #expect(simplified.points.count < 50)
        #expect(simplified.drawn.first?.anchor == Point(x: 0, y: 0))
        #expect(simplified.drawn.last.map { $0.anchor.distance(to: Point(x: 200, y: sin(10) * 10)) < 1e-9 } == true)
        // Smooth joins come back as curve points.
        #expect(simplified.points.contains { $0.kind == .curve })
    }

    @Test func reverseWritesOnlyReversed() throws {
        var a = Replica(0xA)
        let (node, contour) = PathFixture.ids(try a.perform(PathFixture.closed([(0, 0), (10, 0), (10, 10)])), in: a.state)
        let change = try #require(try a.perform(ReverseContours(node: node)))
        #expect(change.label == "Reverse Direction")
        #expect(change.ops.count == 1 && change.ops[0].set.paths.map(RegisterPath.init) == [PathFields.reversed(contour)])
    }

    @Test func correctDirectionAlternatesNestedContours() throws {
        var a = Replica(0xA)
        let outer = PathFixture.points([(0, 0), (100, 0), (100, 100), (0, 100)])
        let middle = PathFixture.points([(10, 10), (90, 10), (90, 90), (10, 90)])
        let inner = PathFixture.points([(30, 30), (70, 30), (70, 70), (30, 70)])
        let beside = PathFixture.points([(200, 0), (200, 50), (250, 50), (250, 0)])
        let open = PathFixture.points([(0, 200), (50, 250)])
        let node = try LayerFixture.object(CreatePath(contours: [NewContour(closed: true, points: outer), NewContour(closed: true, points: middle),
                                                                 NewContour(closed: true, points: inner), NewContour(closed: true, points: beside),
                                                                 NewContour(points: open)]), on: &a)
        let change = try #require(try a.perform(CorrectDirection([node])))
        #expect(change.label == "Correct Direction")
        let ids = a.path(node).contours.map(\.id)
        // The middle square turns (inside one), and the separate one (drawn the other way round).
        #expect(Set(change.ops.flatMap { $0.set.paths.map(RegisterPath.init) }) == [PathFields.reversed(ids[1]), PathFields.reversed(ids[3])])
        let areas = a.path(node).contours.prefix(4).map { PathAlterKernels.signedArea(PathAlterKernels.polygon($0)) }
        #expect(areas[0] > 0 && areas[1] < 0 && areas[2] > 0 && areas[3] > 0)
        // Already correct: nothing to write.
        #expect(try a.perform(CorrectDirection([node])) == nil)
        #expect(PathAlterKernels.signedArea([Point(x: 0, y: 0), Point(x: 1, y: 1)]) == 0)
    }

    @Test func correctDirectionSkipsDegenerateContours() throws {
        var a = Replica(0xA)
        let flat = try LayerFixture.object(PathFixture.closed([(0, 0), (10, 0), (20, 0)]), on: &a)
        #expect(try a.perform(CorrectDirection([flat])) == nil)
    }

    @Test func addPointsKeepsTheGeometryExactly() throws {
        var a = Replica(0xA)
        let curve = [VectorPoint(anchor: .zero, outHandle: Vector(dx: 5, dy: 9)), VectorPoint(anchor: Point(x: 40, y: 3), inHandle: Vector(dx: -7, dy: 11)),
                     VectorPoint(anchor: Point(x: 60, y: 30)), VectorPoint(anchor: Point(x: 20, y: 50), inHandle: Vector(dx: 9, dy: 1), outHandle: Vector(dx: -9, dy: -1))]
        let node = try LayerFixture.object(CreatePath(contours: [NewContour(closed: true, points: curve)]), on: &a)
        let before = a.path(node).contours[0]
        try a.perform(AddPoints([node]))
        let after = a.path(node).contours[0]
        #expect(after.segments.count == 2 * before.segments.count)
        for (index, segment) in before.segments.enumerated() {
            let (left, right) = (after.segments[2 * index].cubic, after.segments[2 * index + 1].cubic)
            for t in stride(from: 0.0, through: 1.0, by: 0.1) {
                let exact = segment.cubic.evaluate(t)
                // A curved segment splits at t = 0.5 exactly; a straight one (retracted handles)
                // at its midpoint, so compare the outline, not the parameter.
                #expect(min(left.distance(to: exact), right.distance(to: exact)) < 1e-6)
            }
        }
    }

    @Test func fractalizeSpikesEverySegmentOutward() throws {
        var a = Replica(0xA)
        let square = try LayerFixture.object(PathFixture.closed([(0, 0), (30, 0), (30, 30), (0, 30)]), on: &a)
        let ids = a.path(square).contours[0].points.map(\.id)
        let change = try #require(try a.perform(Fractalize([square])))
        #expect(change.label == "Fractalize")
        let spiked = a.path(square).contours[0]
        #expect(spiked.segments.count == 16)
        #expect(Set(ids).isSubset(of: spiked.points.map(\.id)), "the corners keep their ids")
        let apexes = stride(from: 2, to: 16, by: 4).map { spiked.drawn[$0].anchor }
        let expected = 30 * 3.0.squareRoot() / 6
        #expect(apexes.allSatisfy { $0.x < -expected + 1e-9 || $0.x > 30 + expected - 1e-9 || $0.y < -expected + 1e-9 || $0.y > 30 + expected - 1e-9 })
        // The other winding spikes outward too.
        let backwards = try LayerFixture.object(PathFixture.closed([(0, 0), (0, 30), (30, 30), (30, 0)]), on: &a)
        try a.perform(Fractalize([backwards]))
        let other = a.path(backwards).contours[0].drawn
        #expect(stride(from: 2, to: 16, by: 4).allSatisfy { index in
            let point = other[index].anchor
            return point.x < 0 || point.x > 30 || point.y < 0 || point.y > 30
        })
    }

    @Test func fractalizeKeepsCurvesAndOpenEnds() throws {
        var a = Replica(0xA)
        var curve = [VectorPoint(anchor: .zero, outHandle: Vector(dx: 10, dy: -10)), VectorPoint(anchor: Point(x: 30, y: 0), inHandle: Vector(dx: -10, dy: -10)),
                     VectorPoint(anchor: Point(x: 60, y: 0))]
        curve[1].automatic = true
        let node = try LayerFixture.object(CreatePath(contours: [NewContour(points: curve)]), on: &a)
        let before = a.path(node).contours[0]
        try a.perform(Fractalize([node]))
        let after = a.path(node).contours[0]
        #expect(after.points.count == 3 + 2 * 3)
        #expect(!after.points.contains { $0.automatic })
        // The first third of the first segment is the original curve's.
        let original = before.segments[0].cubic
        let first = after.segments[0].cubic
        for t in stride(from: 0.0, through: 1.0, by: 0.25) {
            #expect(original.evaluate(t / 3).distance(to: first.evaluate(t)) < 1e-9)
        }
        // A lone point and a shape are left alone.
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        #expect(try a.perform(Fractalize([rect])) == nil)
        #expect(PathAlterKernels.fractalized(VectorContour(points: [VectorPoint(anchor: .zero)])).count == 1)
    }
}

/// The merge tests of DRAW-030 and FX-031.
@Suite struct PathAlterMergeTests {
    @Test func reverseVersusAConcurrentInsertKeepsBoth() throws {
        var pair = Pair()
        let (node, contour) = PathFixture.ids(try pair.a.perform(PathFixture.open([(0, 0), (10, 0), (20, 0)])), in: pair.a.state)
        pair.sync()
        let ids = pair.a.path(node).contour(contour)!.points.map(\.id)
        try pair.a.perform(ReverseContours(node: node))
        try pair.b.perform(InsertPoints(node: node, contour: contour, at: .after(ids[0]), points: [VectorPoint(anchor: Point(x: 5, y: 5))]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let merged = pair.a.path(node).contour(contour)!
        #expect(merged.reversed)
        #expect(merged.drawn.map(\.anchor) == [Point(x: 20, y: 0), Point(x: 10, y: 0), Point(x: 5, y: 5), Point(x: 0, y: 0)])
    }

    @Test func simplifyVersusAConcurrentPointMoveDeletesTheMovedPoint() throws {
        var pair = Pair()
        let node = try LayerFixture.object(PathAlterCommandTests.traced(count: 200), on: &pair.a)
        pair.sync()
        let contour = pair.a.path(node).contours[0]
        let moved = contour.points[17].id
        try pair.a.perform(SimplifyPaths([node], amount: 100))
        try pair.b.perform(MovePoints(node: node, contour: contour.id, point: moved, to: Point(x: 0, y: 0)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let merged = pair.a.path(node).contours[0]
        #expect(!merged.points.contains { $0.id == moved }, "the edit landed on a deleted point (edit vs delete)")
        #expect(merged.points.count < 50)
        let element = try #require(pair.a.state.store.element(node, PathFields.point(contour.id, moved)))
        #expect(element.isDeleted)
    }

    @Test func addPointsVersusAConcurrentPointDragKeepsBoth() throws {
        var pair = Pair()
        let (node, contour) = PathFixture.ids(try pair.a.perform(PathFixture.closed([(0, 0), (10, 0), (10, 10), (0, 10)])), in: pair.a.state)
        pair.sync()
        let ids = pair.a.path(node).contour(contour)!.points.map(\.id)
        try pair.a.perform(AddPoints([node]))
        try pair.b.perform(MovePoints(node: node, contour: contour, point: ids[2], to: Point(x: 14, y: 14)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let merged = pair.a.path(node).contour(contour)!
        #expect(merged.points.count == 8)
        #expect(merged.points.first { $0.id == ids[2] }?.anchor == Point(x: 14, y: 14))
    }

    @Test func fractalizeVersusAConcurrentPointDragKeepsBoth() throws {
        var pair = Pair()
        let (node, contour) = PathFixture.ids(try pair.a.perform(PathFixture.closed([(0, 0), (30, 0), (30, 30), (0, 30)])), in: pair.a.state)
        pair.sync()
        let ids = pair.a.path(node).contour(contour)!.points.map(\.id)
        try pair.a.perform(Fractalize([node]))
        try pair.b.perform(MovePoints(node: node, contour: contour, point: ids[1], to: Point(x: 40, y: -5)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let merged = pair.a.path(node).contour(contour)!
        #expect(merged.points.count == 16)
        #expect(merged.points.first { $0.id == ids[1] }?.anchor == Point(x: 40, y: -5))
    }
}
