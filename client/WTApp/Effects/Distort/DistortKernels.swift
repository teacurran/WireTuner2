import Foundation
import WTGeometry
import WTModel

/// One contour a distortion reshapes: its points in drawing order, pasteboard space.
struct DistortContour: Equatable {
    var points: [VectorPoint]
    var closed: Bool

    /// The segments between consecutive points (and back to the first when closed).
    var segments: [CubicBezier] { ContourPoints.segments(points, closed: closed) }
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

    /// Fisheye: the outline seen through the lens, wherever its points are.  Every segment that
    /// passes through the lens is cut into pieces (see `warped`), each reshaped along its radials,
    /// so an outline crossing the lens between two points bends smoothly; what lies outside the
    /// lens keeps its points and handles.
    static func fisheye(_ contour: DistortContour, center: Point, radius: Double, perspective: Double) -> DistortContour {
        guard radius > 0 else { return contour }
        return warped(contour, Warp(radius: radius, touches: { hullMeetsDisk([$0.p0, $0.p1, $0.p2, $0.p3], center: center, radius: radius) }) {
            fisheye($0, center: center, radius: radius, perspective: perspective)
        })
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

    // MARK: Warping

    /// A non-affine map of a region, and how finely an outline is cut to follow it.
    struct Warp {
        /// The map, the identity wherever `touches` is false.
        var map: (Point) -> Point
        /// Whether the map may move any point of the curve (tested on its control points' hull).
        var touches: (CubicBezier) -> Bool
        /// The longest piece mapped at once (control-polygon length).
        var spacing: Double
        /// The largest distance a piece may stray from the true mapped curve.
        var tolerance: Double
        /// The shortest piece cut further.
        var minimum: Double
        /// The finite-difference step of the map's derivative.
        var step: Double

        /// The warp of a region of `radius`: pieces no longer than a radius / 8, true to within
        /// 0.05 pt (a radius / 200 for a small one).
        init(radius: Double, touches: @escaping (CubicBezier) -> Bool, map: @escaping (Point) -> Point) {
            self.map = map
            self.touches = touches
            spacing = radius / 8
            tolerance = min(0.05, radius / 200)
            minimum = radius / 256
            step = radius / 512
        }
    }

    /// `contour` through `warp`: a segment the warp does not touch is kept as it is; one it does is
    /// cut into pieces no longer than `warp.spacing` (shorter where the mapped piece strays more than
    /// `warp.tolerance`), each mapped as the cubic with the mapped ends and the mapped end tangents.
    /// Existing points keep their ids and kinds; the points between pieces are new (the zero id)
    /// smooth curve points.
    static func warped(_ contour: DistortContour, _ warp: Warp) -> DistortContour {
        let points = contour.points
        let segments = contour.segments
        guard !segments.isEmpty else { return mapped(contour, warp.map) }
        let pieces = segments.map { warp.touches($0) ? warpedPieces($0, warp) : nil }
        var result: [VectorPoint] = []
        for index in points.indices {
            var point = points[index]
            point.anchor = warp.map(point.anchor)
            let arriving = index > 0 ? index - 1 : (contour.closed ? segments.count - 1 : nil)
            if let arriving {
                if let last = pieces[arriving]?.last { point.inHandle = last.p2 - last.p3 }
            } else {
                point.inHandle = point.inHandle == .zero ? .zero : warp.map(points[index].anchor + point.inHandle) - point.anchor
            }
            if index < segments.count {
                if let first = pieces[index]?.first { point.outHandle = first.p1 - first.p0 }
            } else {
                point.outHandle = point.outHandle == .zero ? .zero : warp.map(points[index].anchor + point.outHandle) - point.anchor
            }
            result.append(point)
            guard index < segments.count, let cut = pieces[index] else { continue }
            for (previous, piece) in zip(cut, cut.dropFirst()) {
                let inHandle = previous.p2 - previous.p3, outHandle = piece.p1 - piece.p0
                result.append(VectorPoint(anchor: piece.p0, inHandle: inHandle, outHandle: outHandle,
                                          kind: ContourPoints.smooth(inHandle, outHandle) ? .curve : .corner))
            }
        }
        return DistortContour(points: result, closed: contour.closed)
    }

    /// `segment` through `warp` as mapped pieces, in order.
    static func warpedPieces(_ segment: CubicBezier, _ warp: Warp) -> [CubicBezier] {
        // The parameter ranges, and whether the warp moves each.
        var ranges: [(t0: Double, t1: Double, moved: Bool)] = []
        func visit(_ t0: Double, _ t1: Double, depth: Int) {
            let piece = segment.subdivide(from: t0, to: t1)
            guard warp.touches(piece) else {
                if let last = ranges.last, !last.moved, last.t1 == t0 { ranges[ranges.count - 1].t1 = t1 } else { ranges.append((t0, t1, false)) }
                return
            }
            let length = piece.controlPolygonLength
            let divisible = depth < 16 && length > warp.minimum
            if divisible, length > warp.spacing || strays(segment, t0, t1, warp) {
                let middle = (t0 + t1) / 2
                visit(t0, middle, depth: depth + 1)
                visit(middle, t1, depth: depth + 1)
            } else {
                ranges.append((t0, t1, true))
            }
        }
        visit(0, 1, depth: 0)
        return ranges.map { $0.moved ? mappedPiece(segment, $0.t0, $0.t1, warp) : segment.subdivide(from: $0.t0, to: $0.t1) }
    }

    /// The cubic from the mapped point at `t0` to the one at `t1` with the mapped tangents there.
    static func mappedPiece(_ segment: CubicBezier, _ t0: Double, _ t1: Double, _ warp: Warp) -> CubicBezier {
        let span = t1 - t0
        let start = warp.map(segment.evaluate(t0)), end = warp.map(segment.evaluate(t1))
        return CubicBezier(start, start + mappedTangent(segment, t0, warp) * (span / 3), end - mappedTangent(segment, t1, warp) * (span / 3), end)
    }

    /// The derivative of the mapped curve at `t`: the map's derivative along the curve's tangent
    /// (a central difference of `warp.step`), times the curve's speed.
    static func mappedTangent(_ segment: CubicBezier, _ t: Double, _ warp: Warp) -> Vector {
        let velocity = segment.derivative(t)
        let speed = velocity.length
        guard speed > 1e-12 else { return Vector(dx: 0, dy: 0) }
        let unit = velocity / speed, point = segment.evaluate(t)
        return (warp.map(point + unit * warp.step) - warp.map(point - unit * warp.step)) * (speed / (2 * warp.step))
    }

    /// Whether the mapped piece strays from the true mapped curve by more than the tolerance
    /// (checked at its quarters).
    static func strays(_ segment: CubicBezier, _ t0: Double, _ t1: Double, _ warp: Warp) -> Bool {
        let piece = mappedPiece(segment, t0, t1, warp)
        return [0.25, 0.5, 0.75].contains { s in
            piece.evaluate(s).distance(to: warp.map(segment.evaluate(t0 + (t1 - t0) * s))) > warp.tolerance
        }
    }

    /// Whether the convex hull of `points` meets the open disk of `radius` about `center`.
    static func hullMeetsDisk(_ points: [Point], center: Point, radius: Double) -> Bool {
        if points.contains(where: { $0.distance(to: center) < radius }) { return true }
        for (i, a) in points.enumerated() {
            for b in points[(i + 1)...] where distance(from: center, toSegment: a, b) < radius { return true }
        }
        // The disk wholly inside the hull: the centre inside one of its triangles.
        for i in points.indices {
            for j in (i + 1)..<points.count {
                for k in (j + 1)..<points.count where inside(center, points[i], points[j], points[k]) { return true }
            }
        }
        return false
    }

    static func distance(from p: Point, toSegment a: Point, _ b: Point) -> Double {
        let ab = b - a
        let lengthSquared = ab.lengthSquared
        guard lengthSquared > 0 else { return p.distance(to: a) }
        let t = min(max((p - a).dot(ab) / lengthSquared, 0), 1)
        return p.distance(to: a + ab * t)
    }

    static func inside(_ p: Point, _ a: Point, _ b: Point, _ c: Point) -> Bool {
        guard abs((b - a).cross(c - a)) > 1e-12 else { return false }
        let d1 = (b - a).cross(p - a), d2 = (c - b).cross(p - b), d3 = (a - c).cross(p - c)
        return (d1 >= 0 && d2 >= 0 && d3 >= 0) || (d1 <= 0 && d2 <= 0 && d3 <= 0)
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
