import Testing
@testable import WTGeometry

@Suite struct CubicBezierLengthTests {
    @Test func straightCubicLengthEqualsChord() {
        let uniform = Line(Point(0, 0), Point(3, 4)).elevated()
        #expect(approx(uniform.length(), 5, 1e-9))
        // Collinear but unevenly spaced control points: the speed is not polynomial-smooth
        // everywhere the same way, yet the length is still the chord.
        let uneven = CubicBezier(Point(0, 0), Point(0.1, 0), Point(2.9, 0), Point(3, 0))
        #expect(approx(uneven.length(), 3, 1e-6))
        #expect(approx(uneven.length(tolerance: 1e-10), 3, 1e-9))
    }

    @Test func quarterCircleApproximationLength() {
        let arc = quarterCircle()
        let length = arc.length()
        // The quadrature is held to a dense polyline of the same cubic.  The cubic itself is
        // not a circle: with κ = 4(√2 − 1)/3 it bulges outside the arc by up to 2.7e-4·r, and its
        // arc length exceeds π/2 by 2.2e-4, which is the approximation's error, not ours.
        #expect(approx(length, polylineLength(of: arc), 1e-6))
        #expect(approx(length, Double.pi / 2, 3e-4))
        #expect(length > Double.pi / 2)
        #expect(approx(arc.length(tolerance: 1e-10), polylineLength(of: arc, samples: 1_000_000), 1e-8))
    }

    @Test func partialLengthsAddUp() {
        let curve = CubicBezier(Point(0, 0), Point(1, 3), Point(2, -3), Point(3, 0))
        let whole = curve.length()
        let a = curve.length(from: 0, to: 0.3)
        let b = curve.length(from: 0.3, to: 1)
        #expect(approx(a + b, whole, 1e-6))
        #expect(curve.length(from: 0.5, to: 0.5) == 0)
        #expect(approx(curve.length(from: 1, to: 0), -whole, 1e-9))
        #expect(approx(whole, polylineLength(of: curve), 1e-5))
    }

    @Test func degenerateCurveHasZeroLength() {
        let dot = CubicBezier(Point(1, 1), Point(1, 1), Point(1, 1), Point(1, 1))
        #expect(dot.length() == 0)
        #expect(dot.parameter(atLength: 0.5) == 0)
        #expect(dot.speed(0.5) == 0)
    }

    @Test func arcLengthParametrizationInvertsLength() {
        let curve = CubicBezier(Point(0, 0), Point(0, 5), Point(10, 5), Point(10, 0))
        let total = curve.length()
        for fraction in [0.1, 0.25, 0.5, 0.75, 0.9] {
            let s = fraction * total
            let t = curve.parameter(atLength: s)
            #expect(approx(curve.length(from: 0, to: t), s, 1e-6))
            #expect(approx(curve.point(atLength: s), curve.evaluate(t)))
        }
        #expect(curve.parameter(atLength: -1) == 0)
        #expect(curve.parameter(atLength: 0) == 0)
        #expect(curve.parameter(atLength: total) == 1)
        #expect(curve.parameter(atLength: total + 1) == 1)
        // Symmetric curve: half the length sits at t = 0.5.
        #expect(approx(curve.parameter(atLength: total / 2), 0.5, 1e-6))
    }

    @Test func arcLengthParametrizationWhereSpeedVanishes() {
        // A cusp-like curve whose speed drops to zero inside: Newton must fall back to bisection.
        let cusp = CubicBezier(Point(0, 0), Point(2, 2), Point(-2, 2), Point(0, 0))
        let total = cusp.length()
        #expect(total > 0)
        let t = cusp.parameter(atLength: total / 2)
        #expect(approx(cusp.length(from: 0, to: t), total / 2, 1e-6))
        // With a coarse tolerance the answer is accepted early.
        let coarse = cusp.parameter(atLength: total / 3, tolerance: 1e-2)
        #expect(approx(cusp.length(from: 0, to: coarse), total / 3, 1e-2))
    }

    @Test func gaussLengthIsExactForConstantSpeed() {
        let line = Line(Point(0, 0), Point(6, 8)).elevated()
        #expect(approx(line.gaussLength(from: 0, to: 1), 10, 1e-12))
        #expect(approx(line.gaussLength(from: 0.25, to: 0.75), 5, 1e-12))
    }
}
