import Foundation
import Testing
@testable import WTGeometry

@Suite struct NearestPointTests {
    @Test func nearestPointOnStraightSegmentIsTheProjection() {
        let line = Line(Point(0, 0), Point(10, 0)).elevated()
        let n = line.nearestPoint(to: Point(4, 3))
        #expect(approx(n.t, 0.4, 1e-9))
        #expect(approx(n.point, Point(4, 0), 1e-9))
        #expect(approx(n.distance, 3, 1e-9))
        #expect(approx(line.distance(to: Point(4, 3)), 3, 1e-9))
    }

    @Test func endpointsWinWhenTheQueryIsBeyondThem() {
        let line = Line(Point(0, 0), Point(10, 0)).elevated()
        let before = line.nearestPoint(to: Point(-5, 0))
        #expect(before.t == 0 && before.point == Point(0, 0) && before.distance == 5)
        let after = line.nearestPoint(to: Point(15, 1))
        #expect(after.t == 1 && after.point == Point(10, 0))
    }

    @Test func symmetricCurveReportsTheSymmetricDistance() {
        // Symmetric arch: the axis of symmetry is x = 2.  A point on the axis above the arch is
        // nearest to the apex; a point on the axis far below has two equidistant nearest points.
        let arch = CubicBezier(Point(0, 0), Point(0, 4), Point(4, 4), Point(4, 0))
        let apex = arch.nearestPoint(to: Point(2, 10))
        #expect(approx(apex.t, 0.5, 1e-9))
        #expect(approx(apex.point, arch.evaluate(0.5), 1e-9))
        #expect(approx(apex.distance, 10 - arch.evaluate(0.5).y, 1e-9))

        let below = arch.nearestPoint(to: Point(2, -10))
        #expect(below.t == 0 || below.t == 1)
        #expect(approx(below.distance, Point(2, -10).distance(to: Point(0, 0)), 1e-9))

        // Off-axis queries find the mirrored parameter on the mirrored side.
        let left = arch.nearestPoint(to: Point(0.5, 2))
        let right = arch.nearestPoint(to: Point(3.5, 2))
        #expect(approx(left.t, 1 - right.t, 1e-7))
        #expect(approx(left.distance, right.distance, 1e-9))
    }

    @Test func quarterCircleNearestPointIsRadial() {
        let arc = quarterCircle(radius: 10)
        for angle in stride(from: 0.1, through: 1.5, by: 0.2) {
            let query = Point(30 * cos(angle), 30 * sin(angle))
            let n = arc.nearestPoint(to: query)
            // The approximation deviates from the circle by at most 2.7e-4 · r.
            #expect(approx(n.distance, 20, 0.01))
            #expect(approx((n.point - Point.zero).normalized.dot((query - Point.zero).normalized), 1, 1e-4))
        }
    }

    @Test func nearestPointIsNoFurtherThanAnySample() {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<200 {
            let curve = rng.cubic(in: -50...50)
            let query = rng.point(in: -80...80)
            let n = curve.nearestPoint(to: query)
            var sampledMin = Double.infinity
            for i in 0...500 {
                sampledMin = min(sampledMin, curve.evaluate(Double(i) / 500).distance(to: query))
            }
            #expect(n.distance <= sampledMin + 1e-6, "\(curve) query \(query)")
            #expect(n.t >= 0 && n.t <= 1)
            #expect(approx(n.point, curve.evaluate(n.t)))
        }
    }

    @Test func pointOnTheCurveHasZeroDistance() {
        let curve = CubicBezier(Point(0, 0), Point(1, 3), Point(2, -3), Point(3, 0))
        let on = curve.evaluate(0.37)
        let n = curve.nearestPoint(to: on)
        #expect(approx(n.t, 0.37, 1e-6))
        #expect(n.distance < 1e-7)
        // Few samples and few iterations still converge for a smooth curve.
        let coarse = curve.nearestPoint(to: on, samples: 4, iterations: 30, tolerance: 1e-12)
        #expect(approx(coarse.t, 0.37, 1e-6))
    }

    @Test func degenerateCurve() {
        let dot = CubicBezier(Point(1, 1), Point(1, 1), Point(1, 1), Point(1, 1))
        let n = dot.nearestPoint(to: Point(4, 5))
        #expect(n.distance == 5 && n.point == Point(1, 1))
    }
}
