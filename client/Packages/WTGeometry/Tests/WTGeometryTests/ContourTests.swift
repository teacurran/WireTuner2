import Testing
@testable import WTGeometry

@Suite struct ContourTests {
    let square = Contour(polygon: [Point(0, 0), Point(4, 0), Point(4, 4), Point(0, 4)])

    @Test func polygonConstruction() {
        #expect(square.segments.count == 4)
        #expect(square.isClosed)
        #expect(!square.isEmpty)
        #expect(square.startPoint == Point(0, 0))
        #expect(square.endPoint == Point(0, 0))
        #expect(square.closingSegment == nil)
        let open = Contour(polygon: [Point(0, 0), Point(4, 0), Point(4, 4)], closed: false)
        #expect(open.segments.count == 2 && !open.isClosed)
        #expect(open.closingSegment == Line(Point(4, 4), Point(0, 0)).elevated())
        let explicit = Contour(polygon: [Point(0, 0), Point(4, 0), Point(0, 0)])
        #expect(explicit.segments.count == 2)
        let empty = Contour(polygon: [Point(1, 1)])
        #expect(empty.isEmpty && empty.startPoint == nil && empty.endPoint == nil && empty.closingSegment == nil)
        #expect(Contour(segments: [], closed: false).bounds.isNull)
        #expect(Contour(segments: [], closed: false).controlBounds.isNull)
    }

    @Test func boundsAndLength() {
        #expect(square.bounds == Rect(minX: 0, minY: 0, maxX: 4, maxY: 4))
        #expect(square.controlBounds == square.bounds)
        #expect(approx(square.length(), 16, 1e-9))
        let openClosed = Contour(polygon: [Point(0, 0), Point(3, 0), Point(3, 4)], closed: false)
        #expect(approx(openClosed.length(), 7, 1e-9))
        // A closed contour whose segments do not meet up counts the closing chord.
        let gap = Contour(segments: openClosed.segments, closed: true)
        #expect(approx(gap.length(), 12, 1e-9))
        let c = circle(radius: 2)
        // Four κ arcs each run 2.2e-4·r long (see CubicBezierLengthTests).
        #expect(approx(c.length(), 4 * Double.pi, 2e-3))
        #expect(approx(c.bounds.minX, -2, 1e-9) && approx(c.bounds.maxY, 2, 1e-9))
    }

    @Test func squareWinding() {
        #expect(square.windingNumber(at: Point(2, 2)) == 1)
        #expect(square.windingNumber(at: Point(5, 2)) == 0)
        #expect(square.windingNumber(at: Point(-1, 2)) == 0)
        #expect(square.windingNumber(at: Point(2, 5)) == 0)
        #expect(square.windingNumber(at: Point(2, -1)) == 0)
        #expect(square.reversed().windingNumber(at: Point(2, 2)) == -1)
        #expect(square.contains(Point(2, 2)))
        #expect(square.contains(Point(2, 2), rule: .evenOdd))
        #expect(!square.contains(Point(6, 2)))
        #expect(!square.contains(Point(6, 2), rule: .evenOdd))
        // A ray through a vertex's y counts one crossing, not two or zero.
        #expect(square.windingNumber(at: Point(2, 0)) == 1)
        #expect(square.windingNumber(at: Point(2, 4)) == 0)
        #expect(square.crossingCount(at: Point(2, 0)) == 1)
    }

    @Test func openContourIsClosedImplicitly() {
        let triangle = Contour(polygon: [Point(0, 0), Point(4, 0), Point(0, 4)], closed: false)
        #expect(triangle.windingNumber(at: Point(1, 1)) == 1)
        #expect(triangle.windingNumber(at: Point(3, 3)) == 0)
        #expect(triangle.contains(Point(1, 1), rule: .evenOdd))
    }

    @Test func circleWindingAndReversal() {
        let c = circle(radius: 3)
        #expect(c.windingNumber(at: .zero) == 1)
        #expect(c.windingNumber(at: Point(2, 2)) == 1)
        #expect(c.windingNumber(at: Point(2.5, 2.5)) == 0)
        #expect(c.windingNumber(at: Point(-2.9, 0)) == 1)
        #expect(c.windingNumber(at: Point(0, 2.99)) == 1)
        #expect(c.windingNumber(at: Point(4, 0)) == 0)
        #expect(c.reversed().windingNumber(at: .zero) == -1)
        #expect(c.crossingCount(at: .zero) == 1)
        #expect(c.crossingCount(at: Point(4, 0)) == 0)
        // Sample the disc: winding agrees with the analytic circle away from the rim.
        var rng = SeededGenerator(seed: 3)
        for _ in 0..<500 {
            let p = rng.point(in: -4...4)
            let r = (p - Point.zero).length
            if abs(r - 3) > 0.01 {
                #expect(c.windingNumber(at: p) == (r < 3 ? 1 : 0), "\(p)")
                #expect(c.contains(p, rule: .evenOdd) == (r < 3), "\(p)")
            }
        }
    }

    @Test func figureEightWindingNumbers() {
        // Two S-curves joined into a figure eight crossing itself at the origin.  The left lobe
        // runs in the positive direction, the right lobe in the negative direction.
        let eight = Contour(
            segments: [
                CubicBezier(Point(-2, 0), Point(0, -4), Point(0, 4), Point(2, 0)),
                CubicBezier(Point(2, 0), Point(0, -4), Point(0, 4), Point(-2, 0)),
            ],
            closed: true)
        #expect(eight.windingNumber(at: Point(-1, 0)) == 1)
        #expect(eight.windingNumber(at: Point(1, 0)) == -1)
        #expect(eight.windingNumber(at: Point(0, 2)) == 0)
        #expect(eight.windingNumber(at: Point(-3, 0)) == 0)
        #expect(eight.windingNumber(at: Point(3, 0)) == 0)
        #expect(eight.contains(Point(-1, 0)) && eight.contains(Point(1, 0)))
        #expect(eight.contains(Point(-1, 0), rule: .evenOdd) && eight.contains(Point(1, 0), rule: .evenOdd))
        #expect(!eight.contains(Point(0, 2), rule: .evenOdd))
        #expect(eight.reversed().windingNumber(at: Point(-1, 0)) == -1)
        #expect(eight.reversed().windingNumber(at: Point(1, 0)) == 1)

        // The polygon bow tie behaves the same way.
        let bowTie = Contour(polygon: [Point(0, 0), Point(2, 2), Point(2, 0), Point(0, 2)])
        #expect(bowTie.windingNumber(at: Point(0.3, 1)) == 1)
        #expect(bowTie.windingNumber(at: Point(1.7, 1)) == -1)
        #expect(bowTie.windingNumber(at: Point(1, 1.5)) == 0)
        #expect(bowTie.contains(Point(0.3, 1), rule: .evenOdd) && bowTie.contains(Point(1.7, 1), rule: .evenOdd))
    }

    @Test func doublyWoundContour() {
        // The same circle traversed twice winds twice; even-odd says outside.
        let c = circle(radius: 1)
        let twice = Contour(segments: c.segments + c.segments, closed: true)
        #expect(twice.windingNumber(at: .zero) == 2)
        #expect(twice.contains(.zero))
        #expect(!twice.contains(.zero, rule: .evenOdd))
    }

    @Test func windingContributionHalfOpenRules() {
        // A horizontal segment never crosses a ray.
        let flat = Line(Point(0, 1), Point(5, 1)).elevated()
        #expect(flat.windingContribution(at: Point(-1, 1)) == 0)
        #expect(flat.crossingCount(at: Point(-1, 1)) == 0)
        // A rising segment counts +1 for a ray that starts left of it, at or above its lower end
        // and strictly below its upper end.
        let rising = Line(Point(2, 0), Point(2, 4)).elevated()
        #expect(rising.windingContribution(at: Point(0, 0)) == 1)
        #expect(rising.windingContribution(at: Point(0, 3.999)) == 1)
        #expect(rising.windingContribution(at: Point(0, 4)) == 0)
        #expect(rising.windingContribution(at: Point(0, -0.001)) == 0)
        #expect(rising.windingContribution(at: Point(3, 2)) == 0)
        #expect(rising.windingContribution(at: Point(2, 2)) == 0)
        #expect(rising.reversed().windingContribution(at: Point(0, 2)) == -1)
        // An S in y that ends below the ray crosses it twice (up, then down): winding 0.
        let s = CubicBezier(Point(0, 0), Point(1, 3), Point(2, -3), Point(3, 0))
        #expect(s.crossingCount(at: Point(-1, 0.3)) == 2)
        #expect(s.windingContribution(at: Point(-1, 0.3)) == 0)
        #expect(s.crossingCount(at: Point(-1, -0.3)) == 2)
        // Both crossings of y = 0.3 happen at x < 1.6 (x = 3t and the down-crossing is before t = 0.5).
        #expect(s.crossingCount(at: Point(1.6, 0.3)) == 0)
        // Ray at the start point's own y: the rising first piece counts (0 <= y < top), the
        // falling middle piece counts (bottom <= y < top), the rising last piece ends at y and
        // does not (y < y is false): two crossings, winding 0.
        #expect(s.crossingCount(at: Point(-1, 0)) == 2)
        #expect(s.windingContribution(at: Point(-1, 0)) == 0)
        // Ending above the ray adds the third crossing.
        let s3 = CubicBezier(Point(0, 0), Point(1, 3), Point(2, -3), Point(3, 1))
        #expect(s3.crossingCount(at: Point(-1, 0.3)) == 3)
        #expect(s3.windingContribution(at: Point(-1, 0.3)) == 1)
    }

    @Test func nearestPointAcrossSegments() {
        let n = square.nearestPoint(to: Point(4.5, 1))
        #expect(n != nil)
        #expect(n!.segmentIndex == 1)
        #expect(approx(n!.point, Point(4, 1), 1e-9))
        #expect(approx(n!.distance, 0.5, 1e-9))
        #expect(approx(n!.t, 0.25, 1e-9))
        #expect(Contour(segments: [], closed: true).nearestPoint(to: .zero) == nil)
        let location = ContourLocation(segmentIndex: 2, t: 0.5, point: Point(1, 1), distance: 3)
        #expect(location.segmentIndex == 2 && location.t == 0.5 && location.point == Point(1, 1) && location.distance == 3)
    }

    @Test func reversedAndTransformed() {
        let r = square.reversed()
        #expect(r.segments.count == 4)
        #expect(r.startPoint == square.endPoint)
        #expect(r.segments[0] == square.segments[3].reversed())
        #expect(r.isClosed == square.isClosed)
        let moved = square.applying(.translation(x: 10, y: 0))
        #expect(moved.bounds == Rect(minX: 10, minY: 0, maxX: 14, maxY: 4))
        #expect(moved.windingNumber(at: Point(12, 2)) == 1)
        #expect(moved.windingNumber(at: Point(2, 2)) == 0)
    }

    @Test func fillRuleValues() {
        #expect(FillRule.nonZero != FillRule.evenOdd)
        let set: Set<FillRule> = [.nonZero, .evenOdd, .nonZero]
        #expect(set.count == 2)
    }
}
