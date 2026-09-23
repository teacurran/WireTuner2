import Foundation

// GEO-003: dashing by arc length, ahead of stroke expansion ("Dashed strokes are expanded as
// their dashes", `expand-stroke`).

extension Offset {
    /// Upper bound on the dashes one contour is split into; a pattern that would make more
    /// stops there.
    static let maxDashes = 20_000

    /// One dash: the stretch of the contour it covers, and the direction of travel at its start
    /// (which orients the cap of a zero-length dash).
    struct Dash {
        var contour: Contour
        var direction: Vector
    }

    /// The dashes of `contour` under `pattern` (on, off, on, off... lengths along the path) and
    /// `phase` (how far into the pattern the start point sits), as open contours.  A closed
    /// contour's closing segment is dashed too.  A zero-length "on" entry gives a contour of one
    /// zero-length segment (a dot once stroked with round or square caps).  A pattern the
    /// stroke would read as solid (see ``StrokeStyle/normalizedDash``) returns the contour
    /// unchanged.
    public static func dash(_ contour: Contour, pattern: [Double], phase: Double = 0) -> [Contour] {
        guard let normalized = StrokeStyle(width: 1, dash: pattern).normalizedDash else {
            return [contour]
        }
        return dashes(of: contour, pattern: normalized, phase: phase).map(\.contour)
    }

    /// Dashing with a normalized pattern (even count, non-negative, positive sum).
    static func dashes(of contour: Contour, pattern: [Double], phase: Double) -> [Dash] {
        var segments = contour.segments.filter(\.isFiniteCurve)
        guard segments.count == contour.segments.count, !segments.isEmpty else {
            return []
        }
        let extent = segments.reduce(0) { max($0, $1.extent) }
        if contour.isClosed, let closing = contour.closingSegment, closing.chordLength > degenerateLength(extent: extent) {
            segments.append(closing)
        }
        let lengthTolerance = 1e-9 * max(1, extent)
        let lengths = segments.map { $0.length(tolerance: lengthTolerance) }
        var starts = [0.0]
        for length in lengths {
            starts.append(starts[starts.count - 1] + length)
        }
        let total = starts[starts.count - 1]
        let period = pattern.reduce(0, +)
        guard total > 0, total.isFinite, period.isFinite else {
            return []
        }

        // Where in the pattern the start point falls.
        var position = phase.isFinite ? phase.truncatingRemainder(dividingBy: period) : 0
        if position < 0 {
            position += period
        }
        var index = 0
        // A phase exactly at the end of an entry starts the next one, except that a
        // zero-length entry at the very start of the pattern is still drawn.
        while index < pattern.count - 1 && (position > pattern[index] || (position == pattern[index] && pattern[index] > 0)) {
            position -= pattern[index]
            index += 1
        }
        var remaining = max(0, pattern[index] - position)

        /// The contour covering arc lengths `from...to`.
        func stretch(from: Double, to: Double) -> Dash {
            var pieces: [CubicBezier] = []
            var heading: Vector?
            for k in segments.indices where starts[k + 1] >= from && starts[k] <= to && lengths[k] > 0 {
                let a = max(from, starts[k]) - starts[k]
                let b = min(to, starts[k + 1]) - starts[k]
                let ta = segments[k].parameter(atLength: a, tolerance: lengthTolerance)
                if heading == nil {
                    heading = direction(of: segments[k], at: ta, forward: true)
                }
                if b > a {
                    let tb = segments[k].parameter(atLength: b, tolerance: lengthTolerance)
                    pieces.append(segments[k].subdivide(from: ta, to: tb))
                } else if pieces.isEmpty && from == to {
                    let p = segments[k].evaluate(ta)
                    pieces.append(CubicBezier(p, p, p, p))
                }
            }
            return Dash(contour: Contour(segments: pieces, closed: false), direction: heading ?? Vector(1, 0))
        }

        var result: [Dash] = []
        var at = 0.0
        var steps = 0
        // Arc lengths are only good to the quadrature tolerance: a dash that would start within
        // a few tolerances of the end is rounding, not a dash.
        let end = total - 16 * lengthTolerance * Double(segments.count)
        while at < end && result.count < maxDashes && steps < 4 * maxDashes {
            steps += 1
            let stop = min(total, at + remaining)
            if index % 2 == 0 {
                let dash = stretch(from: at, to: stop)
                if !dash.contour.isEmpty {
                    result.append(dash)
                }
            }
            at = stop
            index = (index + 1) % pattern.count
            remaining = pattern[index]
        }
        return result
    }
}
