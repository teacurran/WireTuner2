import Foundation
@testable import WTGeometry

/// Whether two doubles agree to within `tolerance`.
func approx(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

/// Whether two points agree to within `tolerance`.
func approx(_ a: Point, _ b: Point, _ tolerance: Double = 1e-9) -> Bool {
    a.isApproximatelyEqual(to: b, tolerance: tolerance)
}

/// Whether two vectors agree to within `tolerance`.
func approx(_ a: Vector, _ b: Vector, _ tolerance: Double = 1e-9) -> Bool {
    a.isApproximatelyEqual(to: b, tolerance: tolerance)
}

/// The control-point offset that makes a cubic approximate a quarter circle.
let kappa = 4.0 / 3.0 * (2.0.squareRoot() - 1)

/// A cubic approximating the quarter circle of radius `r` about `center` from angle 0 to π/2
/// (from `(r, 0)` to `(0, r)`), running in the positive rotation direction.
func quarterCircle(center: Point = .zero, radius r: Double = 1) -> CubicBezier {
    CubicBezier(
        p0: center + Vector(r, 0),
        p1: center + Vector(r, kappa * r),
        p2: center + Vector(kappa * r, r),
        p3: center + Vector(0, r))
}

/// A closed contour of four quarter arcs, running in the positive rotation direction.
func circle(center: Point = .zero, radius r: Double = 1) -> Contour {
    let q = quarterCircle(center: center, radius: r)
    let rotate = { (k: Int) in AffineTransform.rotation(radians: Double(k) * Double.pi / 2, around: center) }
    return Contour(segments: [q, q.applying(rotate(1)), q.applying(rotate(2)), q.applying(rotate(3))], closed: true)
}

/// A cubic whose y is a symmetric S: crosses y = 0 at t = 0, 0.5 and 1.
let sCurve = CubicBezier(Point(0, 0), Point(1, 3), Point(2, -3), Point(3, 0))

/// A cubic that crosses itself.
let loopCurve = CubicBezier(Point(0, 0), Point(4, 3), Point(-3, 3), Point(1, 0))

/// Number of sign changes of the signed distance from `line` along `curve`, sampled densely,
/// counting only changes whose crossing projects onto the segment at least `margin` of its
/// length away from either end: a reference lower bound on the transversal crossings of the
/// segment.  A sample exactly on the line carries no sign and is skipped.
func sampledCrossings(of curve: CubicBezier, with line: Line, samples: Int = 200_000, margin: Double = 0) -> Int {
    var count = 0
    var previous = line.signedDistance(to: curve.evaluate(0))
    var previousPoint = curve.evaluate(0)
    let direction = line.direction
    for i in 1...samples {
        let p = curve.evaluate(Double(i) / Double(samples))
        let d = line.signedDistance(to: p)
        if d == 0 {
            continue
        }
        if previous != 0 && (d < 0) != (previous < 0) {
            let crossing = Point.lerp(previousPoint, p, 0.5)
            let along = (crossing - line.start).dot(direction) / direction.lengthSquared
            if along >= margin && along <= 1 - margin {
                count += 1
            }
        }
        previous = d
        previousPoint = p
    }
    return count
}

/// Arc length by dense flattening: a slow reference for the quadrature.
func polylineLength(of curve: CubicBezier, samples: Int = 100_000) -> Double {
    var total = 0.0
    var previous = curve.evaluate(0)
    for i in 1...samples {
        let p = curve.evaluate(Double(i) / Double(samples))
        total += previous.distance(to: p)
        previous = p
    }
    return total
}

/// A small deterministic generator so fuzz tests are reproducible (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &self)
    }

    mutating func point(in range: ClosedRange<Double>) -> Point {
        Point(double(in: range), double(in: range))
    }

    mutating func cubic(in range: ClosedRange<Double>) -> CubicBezier {
        CubicBezier(point(in: range), point(in: range), point(in: range), point(in: range))
    }
}
