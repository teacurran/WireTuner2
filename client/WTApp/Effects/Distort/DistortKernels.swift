import Foundation
import WTGeometry
import WTModel

/// One contour a distortion reshapes: its points in drawing order, pasteboard space.
struct DistortContour: Equatable {
    var points: [VectorPoint]
    var closed: Bool

    /// The segments between consecutive points (and back to the first when closed).
    var segments: [CubicBezier] { ContourPoints.segments(points, closed: closed) }

    /// Twice the signed area of the anchor polygon: positive when the contour turns clockwise on
    /// screen (y down).
    var signedArea: Double {
        guard points.count >= 3 else { return 0 }
        return points.indices.reduce(0) { sum, index in
            let a = points[index].anchor, b = points[(index + 1) % points.count].anchor
            return sum + (a.x * b.y - b.x * a.y)
        }
    }
}

/// A random source the kernels draw from: the system generator in the app, a seeded one in tests.
/// Roughen is unseeded by design (path-effects.adoc, "Kernels"): the result is written, so replicas
/// never recompute it.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The destructive distortions' kernels (path-effects.adoc, "Kernels"; FX-030, FX-032): each
/// takes a contour's points in pasteboard space and returns the new points.  Existing points keep
/// their element ids, so a concurrent drag of one of them merges point by point; new points have
/// the zero id.
enum DistortKernels {
    // MARK: Fractalize

    /// Fractalize: every segment becomes four -- its first third, a spike out to the outward side
    /// of its middle third (an equilateral Koch spike), and its last third.  The two split points
    /// and the spike are corners.
    static func fractalize(_ contour: DistortContour) -> DistortContour {
        let segments = contour.segments
        guard !segments.isEmpty else { return contour }
        // Outward is to the left of travel for a clockwise contour (y down), else to the right.
        let side: Double = contour.closed && contour.signedArea < 0 ? -1 : 1
        var points = contour.points
        var inserted: [[VectorPoint]] = []
        for (index, segment) in segments.enumerated() {
            // Thirds by length (a straight segment's retracted handles make `t` uneven).
            let length = segment.length()
            let t1 = segment.parameter(atLength: length / 3), t2 = segment.parameter(atLength: length * 2 / 3)
            let (first, rest) = segment.split(at: t1)
            let (_, last) = rest.split(at: (t2 - t1) / max(1 - t1, 1e-12))
            points[index].outHandle = first.p1 - first.p0
            points[(index + 1) % points.count].inHandle = last.p2 - last.p3
            let a = first.p3, b = last.p0
            let chord = b - a
            let spike = Point.lerp(a, b, 0.5) + chord.perpendicular.normalized * (-side * chord.length * 3.0.squareRoot() / 2)
            inserted.append([
                VectorPoint(anchor: a, inHandle: first.p2 - first.p3, kind: .corner),
                VectorPoint(anchor: spike, kind: .corner),
                VectorPoint(anchor: b, outHandle: last.p1 - last.p0, kind: .corner),
            ])
        }
        var result: [VectorPoint] = []
        for index in points.indices {
            result.append(points[index])
            if index < inserted.count { result += inserted[index] }
        }
        return DistortContour(points: result, closed: contour.closed)
    }

    // MARK: Roughen

    /// Roughen: points added every `1 / amount` inch along the outline (none at 0), then every
    /// point moved along the outline's normal by `random(−1, 1) × distance × 0.1`.  *Rough* makes
    /// corners with no handles; *Smooth* makes curve points with handles through their neighbours.
    static func roughen<G: RandomNumberGenerator>(_ contour: DistortContour, amount: Double, smooth: Bool, distance: Double, using random: inout G) -> DistortContour {
        let segments = contour.segments
        guard !segments.isEmpty else { return contour }
        let spacing = amount > 0 ? 72 / amount : .infinity
        var points: [(point: VectorPoint, normal: Vector)] = []
        for (index, segment) in segments.enumerated() {
            let length = segment.length()
            let count = spacing.isFinite ? max(Int((length / spacing).rounded(.up)), 1) : 1
            points.append((contour.points[index], normal(segment, at: 0)))
            for step in 1..<count {
                let t = segment.parameter(atLength: length * Double(step) / Double(count))
                points.append((VectorPoint(anchor: segment.evaluate(t)), normal(segment, at: t)))
            }
        }
        if !contour.closed, let last = contour.points.last, let segment = segments.last {
            points.append((last, normal(segment, at: 1)))
        }
        let reach = abs(distance) * 0.1
        var moved = points.map { entry -> VectorPoint in
            var point = entry.point
            point.anchor = point.anchor + entry.normal * (Double.random(in: -1...1, using: &random) * reach)
            point.inHandle = .zero
            point.outHandle = .zero
            point.kind = .corner
            point.automatic = false
            return point
        }
        if smooth { moved = smoothed(moved, closed: contour.closed) }
        return DistortContour(points: moved, closed: contour.closed)
    }

    /// The unit normal of `segment` at `t` (the chord's for a degenerate one).
    static func normal(_ segment: CubicBezier, at t: Double) -> Vector {
        let tangent = segment.derivative(t)
        let direction = tangent.lengthSquared > 1e-18 ? tangent : segment.p3 - segment.p0
        return direction.lengthSquared > 0 ? direction.normalized.perpendicular : Vector(dx: 0, dy: 0)
    }

    /// Curve points with Catmull-Rom handles (a third of the way to each neighbour, along the line
    /// through both); an open contour's ends keep none on their outer side.
    static func smoothed(_ points: [VectorPoint], closed: Bool) -> [VectorPoint] {
        let count = points.count
        guard count >= 3 else { return points }
        return points.indices.map { index in
            var point = points[index]
            let hasPrevious = closed || index > 0, hasNext = closed || index < count - 1
            let previous = points[(index - 1 + count) % count].anchor, next = points[(index + 1) % count].anchor
            let direction = (hasNext ? next : point.anchor) - (hasPrevious ? previous : point.anchor)
            guard direction.lengthSquared > 0 else { return point }
            let unit = direction.normalized
            if hasPrevious { point.inHandle = unit * (-point.anchor.distance(to: previous) / 3) }
            if hasNext { point.outHandle = unit * (point.anchor.distance(to: next) / 3) }
            point.kind = hasPrevious && hasNext ? .curve : .corner
            return point
        }
    }

    // MARK: Fisheye

    /// The lens curve: `x` (a distance over the radius, 0...1) mapped for `perspective` −100...100;
    /// convex (positive) pushes points outward, concave pulls them in.  0 and 1 map to themselves.
    static func lens(_ x: Double, perspective: Double) -> Double {
        let s = min(max(perspective, -100), 100) / 100
        guard x > 0, x < 1, s != 0 else { return x }
        return s > 0 ? pow(x, 1 / (1 + 2 * s)) : pow(x, 1 - 2 * s)
    }

    /// A point seen through the lens of `radius` about `center`.
    static func fisheye(_ point: Point, center: Point, radius: Double, perspective: Double) -> Point {
        let offset = point - center
        let d = offset.length
        guard radius > 0, d > 0, d < radius else { return point }
        return center + offset * (radius * lens(d / radius, perspective: perspective) / d)
    }

    /// Fisheye: every anchor inside the lens mapped along its radial, its handles mapped with it.
    static func fisheye(_ contour: DistortContour, center: Point, radius: Double, perspective: Double) -> DistortContour {
        mapped(contour) { fisheye($0, center: center, radius: radius, perspective: perspective) }
    }

    /// `contour` with every anchor and handle end mapped through `map`.
    static func mapped(_ contour: DistortContour, _ map: (Point) -> Point) -> DistortContour {
        DistortContour(points: contour.points.map { point in
            var copy = point
            copy.anchor = map(point.anchor)
            copy.inHandle = point.inHandle == .zero ? .zero : map(point.anchor + point.inHandle) - copy.anchor
            copy.outHandle = point.outHandle == .zero ? .zero : map(point.anchor + point.outHandle) - copy.anchor
            return copy
        }, closed: contour.closed)
    }

    // MARK: Bend

    /// The farthest control point of `contours` from `center` (the Bend kernel's `d_max`).
    static func farthest(_ contours: [DistortContour], from center: Point) -> Double {
        contours.flatMap(\.segments).flatMap { [$0.p0, $0.p1, $0.p2, $0.p3] }.reduce(0) { max($0, $1.distance(to: center)) }
    }

    /// Bend, as WTRender's `BendKernel` draws the Bend effect: every anchor and handle end moves
    /// along its radial from `center` by `size × (1 − d / farthest)`; the handles of anchors that
    /// were smooth are turned back onto one line.  A negative size spikes (a star), a positive one
    /// bloats (a cushion).
    static func bend(_ contour: DistortContour, center: Point, size: Double, farthest: Double) -> DistortContour {
        guard size != 0, farthest > 0 else { return contour }
        func displaced(_ point: Point) -> Point {
            let offset = point - center
            let d = offset.length
            guard d > 0 else { return point }
            return point + offset / d * (size * (1 - d / farthest))
        }
        var result = contour.points.map { point -> VectorPoint in
            var copy = point
            copy.anchor = displaced(point.anchor)
            copy.inHandle = displaced(point.anchor + point.inHandle) - copy.anchor
            copy.outHandle = displaced(point.anchor + point.outHandle) - copy.anchor
            return copy
        }
        let count = result.count
        for index in result.indices {
            let hasBoth = contour.closed || (index > 0 && index < count - 1)
            let old = contour.points[index]
            guard hasBoth, old.inHandle.length > 1e-9, old.outHandle.length > 1e-9,
                  abs(old.inHandle.normalized.cross(old.outHandle.normalized)) < 1e-6, old.inHandle.dot(old.outHandle) < 0 else { continue }
            let newIn = result[index].inHandle, newOut = result[index].outHandle
            let unit = (newOut.normalized - newIn.normalized).normalized
            result[index].inHandle = unit * -newIn.length
            result[index].outHandle = unit * newOut.length
        }
        return DistortContour(points: result, closed: contour.closed)
    }

    /// The Bend tool's size for a drag of `dy` view points (up is negative: a spike) at *amount*
    /// 1...10: `±distance × amount / 10`.
    static func bendSize(dragDistance: Double, up: Bool, amount: Double) -> Double {
        let amount = min(max(amount, 1), 10)
        return (up ? -1 : 1) * abs(dragDistance) * amount / 10
    }
}
