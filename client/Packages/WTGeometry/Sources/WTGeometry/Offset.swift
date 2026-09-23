import Foundation

/// Offsetting: curves at a fixed distance from a path, the outline of a stroke, and inset paths
/// (GEO-003; `expand-stroke`, `inset-path`, and the stroke outlines of `stroke-attributes`).
///
/// **Offset curves.**  The exact offset of a cubic is not a cubic, so each offset is a chain of
/// cubics within `tolerance` of it.  The source curve is first split where its derivative
/// vanishes (cusps: the offset jumps from one side to the other there, and the pieces are joined
/// like corners), at its inflections, and, for each distance, where the offset itself has a
/// cusp (`1 − d·κ = 0`, the radius of curvature equal to the distance).  Each piece `P` on
/// `u0...u1` is then approximated by the cubic Hermite interpolant of the exact offset
/// `O(u) = P(u) + d·N(u)`: the same end points, and end derivatives `P′·(1 − d·κ)`, which is
/// `O′` exactly.  The error is sampled against `O` at the same parameters (an upper bound on the
/// geometric error), and a piece that misses `tolerance` is halved, recursively.  Straight pieces
/// are translated exactly.
///
/// **Stroke outlines.**  ``strokeOutline(_:style:tolerance:)-(Contour,_,_)`` traces each side of
/// each contour with its offset, connects consecutive pieces with the style's join on the outer
/// side of a corner and through the corner point itself on the inner side, and closes open
/// contours with caps.  The stroke is the region swept by the normal segments of the path (plus
/// caps and joins), and the traced outline is the boundary of that sweep counted with
/// orientation, so its non-zero fill is the stroke -- as long as the sweep never folds over.  It
/// folds where the curve turns tighter than the half-width: past the center of curvature the
/// offset runs backwards, and the backward part would cancel the forward part under the non-zero
/// rule and leave holes.  So each side stops at the centers of curvature (the evolute) there, and
/// the regions beyond them, bounded by the evolute and the backward offset, are a second operand.
/// ``Boolean/union(_:_:options:)`` of the two (or ``Boolean/normalize(_:options:)`` when nothing
/// folds) cleans the result up.
///
/// **Insets.**  ``inset(_:by:join:miterLimit:tolerance:)`` removes (or, for a negative distance,
/// adds) the stroke of the region's boundary at twice the distance, which is exactly the set of
/// points at least the distance inside (outside) the region, with the join deciding the shape of
/// corners that turn away from the offset.  A result whose pieces have no area (the signed area
/// of each is compared with its perimeter) has collapsed and comes back empty.
///
/// No input crashes or hangs: non-finite coordinates contribute nothing, every recursion and
/// loop is capped, and the boolean cleanup inherits the caps of ``Boolean``.
public enum Offset {
    /// The default approximation tolerance, in pasteboard points: a hundredth of a point is far
    /// below a device pixel at any zoom the renderer draws outlines at.
    public static let defaultTolerance = 0.01

    /// Recursion cap on halving one offset piece.
    static let maxDepth = 20

    /// The offset of `curve` at signed `distance` along its ``CubicBezier/normal(_:)`` (the
    /// ``Vector/perpendicular`` of the tangent), within `tolerance`.  One open contour per stretch
    /// of the curve between cusps (the offset is discontinuous at a cusp); empty for a degenerate
    /// or non-finite curve.
    public static func offset(_ curve: CubicBezier, by distance: Double, tolerance: Double = defaultTolerance) -> [Contour] {
        guard distance.isFinite, curve.isFiniteCurve else {
            return []
        }
        let tol = effectiveTolerance(tolerance, extent: curve.extent)
        return sourceChains(curve).map { chain in
            var segments: [CubicBezier] = []
            for piece in chain {
                let offsets = offsetPiece(piece, distance: distance, tolerance: tol)
                if let last = segments.last, let first = offsets.first, last.p3 != first.p0 {
                    segments.append(Line(start: last.p3, end: first.p0).elevated())
                }
                segments.append(contentsOf: offsets)
            }
            return Contour(segments: segments, closed: false)
        }
    }

    // MARK: Source pieces

    /// A stretch of a source curve free of cusps and inflections, with its end directions
    /// (the arrival direction at the end, the departure direction at the start).
    struct SourcePiece {
        var curve: CubicBezier
        var startTangent: Vector
        var endTangent: Vector
        /// The join drawn at the start of this piece in a stroke.
        var join: LineJoin = .round
    }

    /// The curve split at its cusps (between chains) and inflections (within a chain).
    /// Degenerate pieces are dropped.
    static func sourceChains(_ curve: CubicBezier) -> [[SourcePiece]] {
        let scale = curve.controlPolygonLength
        guard scale > degenerateLength(extent: curve.extent) else {
            return []
        }
        let a = (curve.p3 - curve.p0) + 3 * (curve.p1 - curve.p2)
        let b = 2 * ((curve.p0 - curve.p1) + (curve.p2 - curve.p1))
        let c = curve.p1 - curve.p0
        // P′/3 = a·t² + b·t + c;  P″/3 = 2a·t + b.
        var cusps: [Double] = []
        let stationary = Polynomial.cubicRoots(2 * a.dot(a), 3 * a.dot(b), b.dot(b) + 2 * a.dot(c), b.dot(c))
        for t in stationary where t > 0 && t < 1 {
            if curve.speed(t) <= 1e-7 * scale {
                cusps.append(t)
            }
        }
        var inflections: [Double] = []
        for t in Polynomial.quadraticRoots(-a.cross(b), 2 * c.cross(a), c.cross(b)) where t > 0 && t < 1 {
            inflections.append(t)
        }
        var cuts: [(t: Double, cusp: Bool)] = cusps.map { ($0, true) } + inflections.map { ($0, false) }
        cuts.sort { $0.t < $1.t }
        cuts.append((1, true))
        var chains: [[SourcePiece]] = []
        var chain: [SourcePiece] = []
        var start = 0.0
        for cut in cuts {
            if cut.t - start > 1e-9 {
                let piece = curve.subdivide(from: start, to: cut.t)
                if piece.controlPolygonLength > degenerateLength(extent: curve.extent) {
                    chain.append(SourcePiece(
                        curve: piece,
                        startTangent: direction(of: curve, at: start, forward: true),
                        endTangent: direction(of: curve, at: cut.t, forward: false)))
                }
                start = cut.t
            }
            if cut.cusp && !chain.isEmpty {
                chains.append(chain)
                chain = []
            }
        }
        return chains
    }

    /// The unit direction of travel at `t`: leaving it when `forward`, arriving at it otherwise.
    /// Where the derivative (nearly) vanishes the direction comes from a short chord on the
    /// requested side, which is the direction the curve actually moves there.
    static func direction(of curve: CubicBezier, at t: Double, forward: Bool) -> Vector {
        let d = curve.derivative(t)
        if d.length > 1e-9 * curve.controlPolygonLength {
            return d.normalized
        }
        for step in [1e-4, 1e-3, 1e-2, 0.1] {
            let chord = forward
                ? curve.evaluate(min(1, t + step)) - curve.evaluate(t)
                : curve.evaluate(t) - curve.evaluate(max(0, t - step))
            if chord.lengthSquared > 0 {
                return chord.normalized
            }
        }
        return curve.tangent(t)
    }

    // MARK: Offset pieces

    /// The offset of one cusp- and inflection-free piece: split where the offset has a cusp,
    /// then fitted by halving.  Where the offset runs backwards (past the center of curvature)
    /// it is included as it is, loops and all.
    static func offsetPiece(_ piece: SourcePiece, distance d: Double, tolerance: Double) -> [CubicBezier] {
        if let straight = straightOffset(piece, distance: d) {
            return [straight]
        }
        let cuts = offsetCusps(piece.curve, distance: d)
        var result: [CubicBezier] = []
        for k in 1..<cuts.count {
            fitOffset(piece, distance: d, u0: cuts[k - 1], u1: cuts[k], tolerance: tolerance, into: &result)
        }
        return result
    }

    /// One side of the stroke of a piece, split into the two consistently oriented parts the
    /// stroke region is built from.  With `N` the normal and `κ` the curvature, the stroke is
    /// swept by the normal segments `P(u) + s·N(u)`, `|s| ≤ half`, and that sweep folds over where
    /// `1 − s·κ` changes sign, at the center of curvature.  `main` is the side up to the fold:
    /// the offset where the radius of curvature exceeds the distance and the evolute (the
    /// centers of curvature) where it does not.  `folds` are the regions beyond the fold, each
    /// bounded by the evolute and the backward-running offset, which meet where the radius of
    /// curvature equals the distance.  Every part is swept with one orientation, so each fills
    /// correctly under the non-zero rule however it overlaps itself; `main` and `folds` have
    /// opposite orientations and are united, not filled together.
    static func strokeSide(_ piece: SourcePiece, distance d: Double, tolerance: Double) -> (main: [CubicBezier], folds: [Contour]) {
        if let straight = straightOffset(piece, distance: d) {
            return ([straight], [])
        }
        let curve = piece.curve
        let cuts = offsetCusps(curve, distance: d)
        var main: [CubicBezier] = []
        var folds: [Contour] = []
        for k in 1..<cuts.count {
            let u0 = cuts[k - 1]
            let u1 = cuts[k]
            guard foldFactor(curve, distance: d, at: (u0 + u1) / 2) < 0 else {
                fitOffset(piece, distance: d, u0: u0, u1: u1, tolerance: tolerance, into: &main)
                continue
            }
            // The signed radius of curvature |P′|³ / (P′ × P″), clamped between 0 and the
            // distance.  At a stationary point the curvature is unbounded and the radius tends to
            // 0 (the evolute meets the curve there), which the formula gives as 0 / 0.
            func radius(_ u: Double) -> Double {
                let d1 = curve.derivative(u)
                let speed = d1.length
                let cross = d1.cross(curve.secondDerivative(u))
                guard speed > 1e-9 * curve.controlPolygonLength else {
                    return 0
                }
                // Inside a fold `d · cross > speed³ > 0`, so the quotient is finite there.
                let rho = speed * speed * speed / cross
                return d > 0 ? min(d, max(0, rho)) : max(d, min(0, rho))
            }
            func evolute(_ u: Double) -> Point {
                curve.evaluate(u) + normal(of: piece, at: u) * radius(u)
            }
            var centers: [CubicBezier] = []
            fit(u0: u0, u1: u1, tolerance: tolerance, depth: 0, into: &centers, point: evolute) { u in
                numericVelocity(evolute, at: u, from: u0, to: u1)
            }
            var beyond: [CubicBezier] = []
            fitOffset(piece, distance: d, u0: u0, u1: u1, tolerance: tolerance, into: &beyond)
            main.append(contentsOf: centers)
            var boundary = Builder(start: centers[0].p0)
            boundary.append(centers)
            boundary.append(Contour(segments: beyond, closed: false).reversed().segments)
            boundary.line(to: boundary.start)
            folds.append(Contour(segments: boundary.segments, closed: true))
        }
        return (main, folds)
    }

    /// The exact offset of a straight piece, or nil when the piece is not straight.
    private static func straightOffset(_ piece: SourcePiece, distance d: Double) -> CubicBezier? {
        let curve = piece.curve
        guard d == 0 || curve.isLinear(tolerance: 1e-12 * max(1, curve.extent)) else {
            return nil
        }
        let n = piece.startTangent.perpendicular * d
        return CubicBezier(curve.p0 + n, curve.p1 + n, curve.p2 + n, curve.p3 + n)
    }

    /// `|P′|³ − d·(P′ × P″)`: positive where the offset at `d` runs with the curve, negative where
    /// it runs backwards (the sign of `1 − d·κ`, without the division).
    static func foldFactor(_ curve: CubicBezier, distance d: Double, at u: Double) -> Double {
        let d1 = curve.derivative(u)
        let speed = d1.length
        return speed * speed * speed - d * d1.cross(curve.secondDerivative(u))
    }

    /// `0`, the parameters where the offset at `d` has a cusp (sign changes of
    /// ``foldFactor(_:distance:at:)``, sampled and bisected), and `1`.
    static func offsetCusps(_ curve: CubicBezier, distance d: Double) -> [Double] {
        let samples = 48
        var cuts: [Double] = [0]
        var previous = foldFactor(curve, distance: d, at: 0)
        for k in 1...samples {
            let u = Double(k) / Double(samples)
            let value = foldFactor(curve, distance: d, at: u)
            if (value < 0) != (previous < 0) && previous != 0 && value != 0 {
                var low = Double(k - 1) / Double(samples)
                var high = u
                let lowNegative = previous < 0
                for _ in 0..<60 {
                    let mid = (low + high) / 2
                    if (foldFactor(curve, distance: d, at: mid) < 0) == lowNegative {
                        low = mid
                    } else {
                        high = mid
                    }
                }
                let root = (low + high) / 2
                if root - cuts[cuts.count - 1] > 1e-9 && root < 1 - 1e-9 {
                    cuts.append(root)
                }
            }
            previous = value
        }
        cuts.append(1)
        return cuts
    }

    /// The unit normal of the piece at `u`, using the piece's own end directions at its ends.
    private static func normal(of piece: SourcePiece, at u: Double) -> Vector {
        if u == 0 {
            return piece.startTangent.perpendicular
        }
        if u == 1 {
            return piece.endTangent.perpendicular
        }
        return piece.curve.normal(u)
    }

    /// The constant-distance offset of `piece` on `u0...u1`, fitted into `result`.
    private static func fitOffset(
        _ piece: SourcePiece, distance d: Double, u0: Double, u1: Double, tolerance: Double, into result: inout [CubicBezier]
    ) {
        let curve = piece.curve
        fit(u0: u0, u1: u1, tolerance: tolerance, depth: 0, into: &result) { u in
            curve.evaluate(u) + normal(of: piece, at: u) * d
        } velocity: { u in
            // O′ = P′·(1 − d·κ), zero where the curve is stationary (its handle vanishes anyway).
            guard curve.speed(u) > 1e-9 * curve.controlPolygonLength else {
                return .zero
            }
            return curve.derivative(u) * (1 - d * curve.curvature(u))
        }
    }

    /// The central-difference derivative of `point`, one-sided at the ends of `lower...upper`.
    private static func numericVelocity(_ point: (Double) -> Point, at u: Double, from lower: Double, to upper: Double) -> Vector {
        let step = max(1e-7, (upper - lower) * 1e-4)
        let a = max(lower, u - step)
        let b = min(upper, u + step)
        return (point(b) - point(a)) / (b - a)
    }

    /// Hermite approximation of the curve `point` on `u0...u1` (with derivative `velocity`),
    /// halved until the samples at eighths are within `tolerance` of `point` at the same
    /// parameters.
    private static func fit(
        u0: Double, u1: Double, tolerance: Double, depth: Int, into result: inout [CubicBezier],
        point: (Double) -> Point, velocity: (Double) -> Vector
    ) {
        let o0 = point(u0)
        let o3 = point(u1)
        let span = (u1 - u0) / 3
        var candidate = CubicBezier(o0, o0 + velocity(u0) * span, o3 - velocity(u1) * span, o3)
        if !candidate.isFiniteCurve {
            // Only at coordinates near the limits of Double.
            candidate = Line(start: o0, end: o3).elevated()
        }
        if depth >= maxDepth || u1 - u0 < 1e-12 {
            result.append(candidate)
            return
        }
        var error = 0.0
        for k in 1...7 {
            let v = Double(k) / 8
            error = max(error, point(u0 + (u1 - u0) * v).distance(to: candidate.evaluate(v)))
        }
        if error <= tolerance {
            result.append(candidate)
            return
        }
        let mid = (u0 + u1) / 2
        fit(u0: u0, u1: mid, tolerance: tolerance, depth: depth + 1, into: &result, point: point, velocity: velocity)
        fit(u0: mid, u1: u1, tolerance: tolerance, depth: depth + 1, into: &result, point: point, velocity: velocity)
    }

    // MARK: Scale

    /// The tolerance actually used: the caller's, raised to a floor proportional to the
    /// coordinates so that it stays above rounding.
    static func effectiveTolerance(_ tolerance: Double, extent: Double) -> Double {
        let requested = tolerance.isFinite && tolerance > 0 ? tolerance : defaultTolerance
        return max(requested, 1e-9 * max(1, extent))
    }

    /// Segments whose control polygon is no longer than this are zero-length.
    static func degenerateLength(extent: Double) -> Double {
        1e-10 * max(1, extent)
    }
}

extension CubicBezier {
    /// Whether every control point is finite.
    var isFiniteCurve: Bool {
        p0.isFinite && p1.isFinite && p2.isFinite && p3.isFinite
    }

    /// The largest coordinate magnitude of the control points.
    var extent: Double {
        max(abs(p0.x), abs(p0.y), abs(p1.x), abs(p1.y), abs(p2.x), abs(p2.y), abs(p3.x), abs(p3.y))
    }
}
