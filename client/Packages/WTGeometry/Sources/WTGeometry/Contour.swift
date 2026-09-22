/// How a self-overlapping contour, or the contours of one path, decide what is inside
/// (`vector-basics`, "Even/odd fill").
public enum FillRule: Hashable, Sendable {
    /// Inside where the winding number is not zero (the default).
    case nonZero
    /// Inside where the ray crossing count is odd.
    case evenOdd
}

/// A place on a contour: which segment, and where on it.
public struct ContourLocation: Hashable, Sendable {
    public var segmentIndex: Int
    public var t: Double
    public var point: Point
    public var distance: Double

    public init(segmentIndex: Int, t: Double, point: Point, distance: Double) {
        self.segmentIndex = segmentIndex
        self.t = t
        self.point = point
        self.distance = distance
    }
}

/// One contour of a path: a sequence of cubic segments, each starting where the previous one
/// ended, open or closed.  `WTModel` builds these from `Contour.points` (a retracted handle is a
/// control point on its anchor); everything here is pure geometry on the result.
///
/// Containment treats an open contour as closed by a straight segment from its end back to its
/// start, which is how an open path's fill paints.
public struct Contour: Hashable, Sendable {
    public var segments: [CubicBezier]
    public var isClosed: Bool

    public init(segments: [CubicBezier], closed: Bool) {
        self.segments = segments
        self.isClosed = closed
    }

    /// A polygon: straight segments between consecutive points.  Fewer than two points make an
    /// empty contour.
    public init(polygon points: [Point], closed: Bool = true) {
        var segments: [CubicBezier] = []
        if points.count >= 2 {
            segments.reserveCapacity(points.count)
            for i in 1..<points.count {
                segments.append(Line(start: points[i - 1], end: points[i]).elevated())
            }
            if closed && points[points.count - 1] != points[0] {
                segments.append(Line(start: points[points.count - 1], end: points[0]).elevated())
            }
        }
        self.segments = segments
        self.isClosed = closed
    }

    public var isEmpty: Bool { segments.isEmpty }

    public var startPoint: Point? { segments.first?.p0 }

    public var endPoint: Point? { segments.last?.p3 }

    /// The straight segment that closes the contour for filling, or nil when the end already
    /// meets the start (or the contour is empty).
    public var closingSegment: CubicBezier? {
        guard let start = startPoint, let end = endPoint, start != end else {
            return nil
        }
        return Line(start: end, end: start).elevated()
    }

    /// Tight bounds of the segments; `Rect.null` for an empty contour.  The closing segment of a
    /// closed contour whose end does not meet its start is included.
    public var bounds: Rect {
        var result = Rect.null
        for segment in segments {
            result.formUnion(segment.bounds)
        }
        return result
    }

    /// Union of the segments' control hulls.
    public var controlBounds: Rect {
        var result = Rect.null
        for segment in segments {
            result.formUnion(segment.controlBounds)
        }
        return result
    }

    /// Total arc length of the segments, plus the closing segment when the contour is closed and
    /// its end does not meet its start.
    public func length(tolerance: Double = 1e-6) -> Double {
        var total = 0.0
        for segment in segments {
            total += segment.length(tolerance: tolerance)
        }
        if isClosed, let closing = closingSegment {
            total += closing.chordLength
        }
        return total
    }

    /// The winding number of `point`: how many times the (implicitly closed) contour winds
    /// around it, positive for the coordinate system's positive rotation.  Zero outside.
    public func windingNumber(at point: Point) -> Int {
        var winding = 0
        for segment in segments {
            winding += segment.windingContribution(at: point)
        }
        if let closing = closingSegment {
            winding += closing.windingContribution(at: point)
        }
        return winding
    }

    /// How many times a ray from `point` toward +x crosses the (implicitly closed) contour.
    public func crossingCount(at point: Point) -> Int {
        var count = 0
        for segment in segments {
            count += segment.crossingCount(at: point)
        }
        if let closing = closingSegment {
            count += closing.crossingCount(at: point)
        }
        return count
    }

    /// Whether `point` is inside the contour under `rule`.
    public func contains(_ point: Point, rule: FillRule = .nonZero) -> Bool {
        switch rule {
        case .nonZero:
            return windingNumber(at: point) != 0
        case .evenOdd:
            return crossingCount(at: point) % 2 == 1
        }
    }

    /// The closest point of any segment to `point`; nil for an empty contour.
    public func nearestPoint(to point: Point) -> ContourLocation? {
        var best: ContourLocation?
        for (index, segment) in segments.enumerated() {
            let nearest = segment.nearestPoint(to: point)
            if best == nil || nearest.distance < best!.distance {
                best = ContourLocation(segmentIndex: index, t: nearest.t, point: nearest.point, distance: nearest.distance)
            }
        }
        return best
    }

    /// The same contour traversed the other way.
    public func reversed() -> Contour {
        Contour(segments: segments.reversed().map { $0.reversed() }, closed: isClosed)
    }

    public func applying(_ transform: AffineTransform) -> Contour {
        Contour(segments: segments.map { $0.applying(transform) }, closed: isClosed)
    }
}

extension CubicBezier {
    /// The signed number of times the horizontal ray from `point` toward +x crosses this curve:
    /// +1 for each crossing where the curve's y increases through the ray, −1 where it
    /// decreases.  Crossings at a segment end count for exactly one of the two segments sharing
    /// that end (half-open rule on y), so summing over a contour gives its winding number.
    /// Allocation-free.
    public func windingContribution(at point: Point) -> Int {
        var winding = 0
        forEachRayCrossing(at: point) { direction in
            winding += direction
        }
        return winding
    }

    /// The number of times the horizontal ray from `point` toward +x crosses this curve, with
    /// the same end-point rule as ``windingContribution(at:)``.
    public func crossingCount(at point: Point) -> Int {
        var count = 0
        forEachRayCrossing(at: point) { _ in
            count += 1
        }
        return count
    }

    /// Splits the curve at its y-extrema into y-monotone pieces and reports each crossing of the
    /// ray with `+1` (y increasing) or `-1` (y decreasing).
    private func forEachRayCrossing(at point: Point, _ body: (Int) -> Void) {
        let hull = controlBounds
        // The half-open rule counts a piece only when its lower end is at or below the ray and
        // its upper end strictly above, so a ray at or above the hull's top crosses nothing.
        if point.y < hull.minY || point.y >= hull.maxY || point.x >= hull.maxX {
            return
        }
        let extrema = Polynomial.quadraticRoots(
            3 * (-p0.y + 3 * p1.y - 3 * p2.y + p3.y),
            6 * (p0.y - 2 * p1.y + p2.y),
            3 * (p1.y - p0.y))
        var ta = 0.0
        var ya = p0.y
        // Piece boundaries: interior extrema in ascending order, then 1.
        for i in 0...extrema.count {
            let tb: Double
            let yb: Double
            if i < extrema.count {
                tb = extrema[i]
                if tb <= ta || tb >= 1 {
                    continue
                }
                yb = evaluate(tb).y
            } else {
                tb = 1
                yb = p3.y
            }
            if ya < yb {
                if ya <= point.y && point.y < yb {
                    let t = monotoneParameter(forY: point.y, from: ta, to: tb, increasing: true)
                    if evaluate(t).x > point.x {
                        body(1)
                    }
                }
            } else if yb < ya {
                if yb <= point.y && point.y < ya {
                    let t = monotoneParameter(forY: point.y, from: ta, to: tb, increasing: false)
                    if evaluate(t).x > point.x {
                        body(-1)
                    }
                }
            }
            ta = tb
            ya = yb
        }
    }

    /// The parameter in `ta...tb`, on which y is monotone, where y equals `target`.
    /// Safeguarded Newton: a step that leaves the bracket becomes a bisection.
    private func monotoneParameter(forY target: Double, from ta: Double, to tb: Double, increasing: Bool) -> Double {
        var low = ta
        var high = tb
        let ya = evaluate(ta).y
        let yb = evaluate(tb).y
        var t = yb != ya ? ta + (tb - ta) * ((target - ya) / (yb - ya)) : (ta + tb) / 2
        t = min(high, max(low, t))
        for _ in 0..<64 {
            let f = evaluate(t).y - target
            if f == 0 {
                return t
            }
            if (f < 0) == increasing {
                low = t
            } else {
                high = t
            }
            let dy = derivative(t).dy
            var next = dy != 0 ? t - f / dy : (low + high) / 2
            if !(next > low && next < high) {
                next = (low + high) / 2
            }
            if abs(next - t) <= 1e-15 || high - low <= 1e-15 {
                return next
            }
            t = next
        }
        return t
    }
}
