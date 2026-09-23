import Foundation

// GEO-003: stroke outlines (Expand Stroke, the Expand Stroke live effect, and the outlines the
// Pattern and Calligraphic strokes fill).

extension Offset {
    /// The region a stroke of `style` paints along `contour`, as a normalized filled path
    /// (non-crossing contours, outer ones positive, holes negative).
    ///
    /// Open contours get caps; closed ones (and the closing segment of a closed contour whose
    /// end does not meet its start) get a join at the start point instead.  Corners between
    /// segments get the style's join; the smooth splits the offsetting introduces (cusps of a
    /// single segment included) are joined round, which is exact.  Zero-length segments are
    /// skipped; a contour of nothing but zero-length segments paints a dot for round and square
    /// caps and nothing for butt caps.  A dashed style strokes each dash as an open contour.
    /// A non-positive or non-finite width paints nothing.
    public static func strokeOutline(_ contour: Contour, style: StrokeStyle, tolerance: Double = defaultTolerance) -> FilledPath {
        strokeOutline([contour], style: style, tolerance: tolerance)
    }

    /// The stroke of every contour of `path` (the fill rule plays no part).
    public static func strokeOutline(_ path: FilledPath, style: StrokeStyle, tolerance: Double = defaultTolerance) -> FilledPath {
        strokeOutline(path.contours, style: style, tolerance: tolerance)
    }

    /// The stroke of several contours as one region.
    public static func strokeOutline(_ contours: [Contour], style: StrokeStyle, tolerance: Double = defaultTolerance) -> FilledPath {
        let raw = rawStrokeOutline(contours, style: style, tolerance: tolerance)
        guard !raw.main.isEmpty else {
            return .empty
        }
        let options = booleanOptions(tolerance)
        let main = FilledPath(contours: raw.main, fillRule: .nonZero)
        guard !raw.folds.isEmpty else {
            return Boolean.normalize(main, options: options)
        }
        return Boolean.union(main, FilledPath(contours: raw.folds, fillRule: .nonZero), options: options)
    }

    /// The boolean cleanup's tolerance: its default, lowered for artwork so small that the
    /// caller asked for a finer offset tolerance than that.
    static func booleanOptions(_ tolerance: Double) -> Boolean.Options {
        let requested = tolerance.isFinite && tolerance > 0 ? tolerance : defaultTolerance
        return Boolean.Options(tolerance: min(Boolean.Options.standard.tolerance, requested * 1e-3))
    }

    /// The traced outline before cleanup, in two parts whose non-zero fills together make up
    /// the stroke: `main`, the outline with each side stopped at the centers of curvature where
    /// the curve turns tighter than the half-width, and `folds`, the regions beyond those centers
    /// (see ``strokeSide(_:distance:tolerance:)``).  Each part is swept with one orientation, so
    /// overlaps within it reinforce instead of cancelling; the two parts have opposite
    /// orientations, so they are united as separate operands rather than filled together.
    static func rawStrokeOutline(_ contours: [Contour], style: StrokeStyle, tolerance: Double) -> (main: [Contour], folds: [Contour]) {
        let half = style.width / 2
        guard half > 0, half.isFinite else {
            return ([], [])
        }
        let miterLimit = style.miterLimit.isNaN ? 4 : max(1, style.miterLimit)
        var main: [Contour] = []
        var folds: [Contour] = []
        for contour in contours where !contour.isEmpty {
            guard contour.segments.allSatisfy(\.isFiniteCurve) else {
                continue
            }
            let extent = max(contour.segments.reduce(0) { max($0, $1.extent) }, half)
            let tol = effectiveTolerance(tolerance, extent: extent)
            let tracer = Tracer(half: half, join: style.join, cap: style.cap, miterLimit: miterLimit, tolerance: tol)
            let parts = style.normalizedDash.map { pattern in
                dashes(of: contour, pattern: pattern, phase: style.dashPhase).map { ($0.contour, Optional($0.direction)) }
            } ?? [(contour, nil)]
            for (part, direction) in parts {
                let traced = tracer.outline(part, direction: direction)
                main.append(contentsOf: traced.main)
                folds.append(contentsOf: traced.folds)
            }
        }
        return (main, folds)
    }

    /// Traces the outline of one contour for a fixed stroke.
    struct Tracer {
        var half: Double
        var join: LineJoin
        var cap: LineCap
        var miterLimit: Double
        var tolerance: Double

        /// The outline of `contour` and the fold regions of its sides; `direction` orients a
        /// dot's square cap.
        func outline(_ contour: Contour, direction: Vector?) -> (main: [Contour], folds: [Contour]) {
            let extent = max(contour.segments.reduce(0) { max($0, $1.extent) }, half)
            var segments = contour.segments
            if contour.isClosed, let closing = contour.closingSegment, closing.chordLength > degenerateLength(extent: extent) {
                segments.append(closing)
            }
            var pieces: [SourcePiece] = []
            for segment in segments {
                let chains = sourceChains(segment)
                for (chainIndex, chain) in chains.enumerated() {
                    // The first piece of a segment meets the previous segment at a corner; a
                    // later chain starts at a cusp of the segment.
                    var first = chain[0]
                    first.join = chainIndex == 0 ? join : .round
                    pieces.append(first)
                    pieces.append(contentsOf: chain.dropFirst())
                }
            }
            guard !pieces.isEmpty else {
                guard !contour.isClosed, cap != .butt, let center = contour.startPoint else {
                    return ([], [])
                }
                return ([dot(at: center, direction: direction ?? Vector(1, 0))], [])
            }
            let (left, leftFolds) = side(pieces, sign: 1, closed: contour.isClosed)
            let (rightSide, rightFolds) = side(pieces, sign: -1, closed: contour.isClosed)
            if contour.isClosed {
                return ([Contour(segments: left, closed: true), Contour(segments: rightSide, closed: true).reversed()], leftFolds + rightFolds)
            }
            let right = Contour(segments: rightSide, closed: false).reversed().segments
            var builder = Builder(start: left[0].p0)
            builder.append(left)
            let last = pieces[pieces.count - 1]
            addCap(to: &builder, at: last.curve.p3, direction: last.endTangent)
            builder.append(right)
            let first = pieces[0]
            addCap(to: &builder, at: first.curve.p0, direction: -first.startTangent)
            builder.line(to: left[0].p0)
            return ([Contour(segments: builder.segments, closed: true)], leftFolds + rightFolds)
        }

        /// One side of the stroke, in the contour's direction: the offsets at `sign · half`, with
        /// joins between pieces (and at the start of a closed contour), and the side's folds.
        func side(_ pieces: [SourcePiece], sign: Double, closed: Bool) -> ([CubicBezier], [Contour]) {
            let distance = sign * half
            var builder: Builder?
            var folds: [Contour] = []
            for (index, piece) in pieces.enumerated() {
                let (offsets, pieceFolds) = strokeSide(piece, distance: distance, tolerance: tolerance)
                folds.append(contentsOf: pieceFolds)
                if builder == nil {
                    builder = Builder(start: offsets[0].p0)
                } else {
                    let previous = pieces[index - 1]
                    addJoin(to: &builder!, at: piece.curve.p0, from: previous.endTangent, to: piece.startTangent, sign: sign, style: piece.join)
                }
                builder!.append(offsets)
            }
            var result = builder!
            if closed {
                let first = pieces[0]
                let last = pieces[pieces.count - 1]
                addJoin(to: &result, at: first.curve.p0, from: last.endTangent, to: first.startTangent, sign: sign, style: first.join)
                result.line(to: result.start)
            }
            return (result.segments, folds)
        }

        /// The join at corner `vertex` on the side at `sign · half`, from the current point (the
        /// end of the previous offset) to the start of the next.
        func addJoin(to builder: inout Builder, at vertex: Point, from incoming: Vector, to outgoing: Vector, sign: Double, style: LineJoin) {
            let nIn = incoming.perpendicular * sign
            let nOut = outgoing.perpendicular * sign
            let target = vertex + nOut * half
            let turn = atan2(incoming.cross(outgoing), incoming.dot(outgoing))
            guard abs(turn) > 1e-9 else {
                builder.line(to: target)
                return
            }
            guard sign * turn < 0 else {
                // Inner side: through the corner point, which the other side's join encloses.
                builder.line(to: vertex)
                builder.line(to: target)
                return
            }
            switch style {
            case .bevel:
                builder.line(to: target)
            case .miter:
                let c = cos(abs(turn) / 2)
                if c > 0 && 1 / c <= miterLimit {
                    builder.line(to: vertex + (nIn + nOut).normalized * (half / c))
                }
                builder.line(to: target)
            case .round:
                builder.arc(center: vertex, radius: half, from: nIn, sweep: turn, tolerance: tolerance)
                builder.line(to: target)
            }
        }

        /// The cap at `end`, where the stroke leaves in `direction`: from the side at `+half`
        /// to the side at `−half`.
        func addCap(to builder: inout Builder, at end: Point, direction: Vector) {
            let normal = direction.perpendicular
            let target = end - normal * half
            switch cap {
            case .butt:
                break
            case .square:
                builder.line(to: end + (normal + direction) * half)
                builder.line(to: end + (direction - normal) * half)
            case .round:
                builder.arc(center: end, radius: half, from: normal, sweep: -Double.pi, tolerance: tolerance)
            }
            builder.line(to: target)
        }

        /// The cap-shaped mark of a zero-length contour, oriented like every other outline.
        func dot(at center: Point, direction: Vector) -> Contour {
            let t = direction.normalized
            let n = t.perpendicular
            if cap == .square {
                let corners = [(n + t), (t - n), (-t - n), (n - t)].map { center + $0 * half }
                return Contour(polygon: corners, closed: true)
            }
            var builder = Builder(start: center + n * half)
            builder.arc(center: center, radius: half, from: n, sweep: -2 * Double.pi, tolerance: tolerance)
            builder.line(to: builder.start)
            return Contour(segments: builder.segments, closed: true)
        }
    }

    /// Accumulates a chain of segments, bridging gaps with straight lines.
    struct Builder {
        let start: Point
        private(set) var current: Point
        private(set) var segments: [CubicBezier] = []

        init(start: Point) {
            self.start = start
            current = start
        }

        mutating func line(to point: Point) {
            guard point != current else {
                return
            }
            segments.append(Line(start: current, end: point).elevated())
            current = point
        }

        mutating func append(_ curves: [CubicBezier]) {
            for var curve in curves {
                if curve.p0 != current {
                    if curve.p0.distance(to: current) <= 1e-12 * max(1, curve.extent) {
                        curve.p1 = curve.p1 + (current - curve.p0)
                        curve.p0 = current
                    } else {
                        line(to: curve.p0)
                    }
                }
                segments.append(curve)
                current = curve.p3
            }
        }

        /// A circular arc about `center` from `center + radius·from` through `sweep` radians
        /// (positive in the positive rotation direction), within `tolerance`.
        mutating func arc(center: Point, radius: Double, from: Vector, sweep: Double, tolerance: Double) {
            let startAngle = atan2(from.dy, from.dx)
            let count = Self.arcPieceCount(radius: radius, sweep: sweep, tolerance: tolerance)
            let step = sweep / Double(count)
            let k = 4.0 / 3.0 * tan(step / 4)
            for i in 0..<count {
                let a0 = startAngle + Double(i) * step
                let a1 = a0 + step
                let e0 = Vector(cos(a0), sin(a0))
                let e1 = Vector(cos(a1), sin(a1))
                let p0 = center + e0 * radius
                let p3 = center + e1 * radius
                append([CubicBezier(p0, p0 + e0.perpendicular * (k * radius), p3 - e1.perpendicular * (k * radius), p3)])
            }
        }

        /// Enough cubic pieces that each deviates from the circle by at most half `tolerance`:
        /// a cubic arc of angle `φ` is off by at most `r · 4/27 · sin⁶(φ/4) / cos²(φ/4)`.
        static func arcPieceCount(radius: Double, sweep: Double, tolerance: Double) -> Int {
            var count = max(1, Int((abs(sweep) / (Double.pi / 2)).rounded(.up)))
            while count < 256 {
                let quarter = abs(sweep) / Double(count) / 4
                let s = sin(quarter)
                let error = radius * 4 / 27 * pow(s, 6) / (cos(quarter) * cos(quarter))
                if error <= tolerance / 2 {
                    break
                }
                count += 1
            }
            return count
        }
    }
}
