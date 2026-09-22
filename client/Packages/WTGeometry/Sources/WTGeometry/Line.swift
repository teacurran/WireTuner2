/// A straight segment from `start` to `end`, parametrized linearly on `0...1`.
public struct Line: Hashable, Sendable {
    public var start: Point
    public var end: Point

    @inlinable
    public init(start: Point, end: Point) {
        self.start = start
        self.end = end
    }

    @inlinable
    public init(_ start: Point, _ end: Point) {
        self.start = start
        self.end = end
    }

    @inlinable
    public var direction: Vector { end - start }

    @inlinable
    public var length: Double { direction.length }

    @inlinable
    public var midpoint: Point { Point.lerp(start, end, 0.5) }

    @inlinable
    public var bounds: Rect { Rect(start, end) }

    @inlinable
    public func evaluate(_ t: Double) -> Point {
        Point.lerp(start, end, t)
    }

    @inlinable
    public func reversed() -> Line {
        Line(start: end, end: start)
    }

    public func applying(_ transform: AffineTransform) -> Line {
        Line(start: transform.apply(start), end: transform.apply(end))
    }

    /// Distance from `point` to the infinite line through `start` and `end`, positive on the
    /// side the direction's ``Vector/perpendicular`` points to.  Zero for a degenerate segment.
    public func signedDistance(to point: Point) -> Double {
        let d = direction
        let l = d.length
        guard l > 0 else {
            return 0
        }
        return d.cross(point - start) / l
    }

    /// The closest point of the *segment* to `point`.
    public func nearestPoint(to point: Point) -> NearestPoint {
        let d = direction
        let l2 = d.lengthSquared
        var t = 0.0
        if l2 > 0 {
            t = min(1, max(0, (point - start).dot(d) / l2))
        }
        let p = evaluate(t)
        return NearestPoint(t: t, point: p, distance: p.distance(to: point))
    }

    /// Distance from `point` to the segment.
    public func distance(to point: Point) -> Double {
        nearestPoint(to: point).distance
    }

    /// The same segment as a cubic, with the control points at thirds so the parametrization is
    /// unchanged.
    @inlinable
    public func elevated() -> CubicBezier {
        let d = direction
        return CubicBezier(p0: start, p1: start + d / 3, p2: start + d * (2.0 / 3.0), p3: end)
    }

    /// Where the two segments cross, or nil when they do not or are parallel.  Collinear
    /// overlapping segments have no single crossing and report nil.  `tolerance` widens each
    /// segment's parameter range and sets the sine of the angle below which the segments count
    /// as parallel.
    public func intersection(with other: Line, tolerance: Double = 1e-9) -> Intersection? {
        let d1 = direction
        let d2 = other.direction
        let denominator = d1.cross(d2)
        if abs(denominator) <= tolerance * d1.length * d2.length {
            return nil
        }
        let w = other.start - start
        let t = w.cross(d2) / denominator
        let u = w.cross(d1) / denominator
        guard t >= -tolerance, t <= 1 + tolerance, u >= -tolerance, u <= 1 + tolerance else {
            return nil
        }
        let tc = min(1, max(0, t))
        let uc = min(1, max(0, u))
        return Intersection(t: tc, u: uc, point: evaluate(tc))
    }
}

/// The result of a nearest-point query.
public struct NearestPoint: Hashable, Sendable {
    /// The parameter of the closest point on the curve.
    public var t: Double
    /// The closest point itself.
    public var point: Point
    /// Its distance from the query point.
    public var distance: Double

    @inlinable
    public init(t: Double, point: Point, distance: Double) {
        self.t = t
        self.point = point
        self.distance = distance
    }
}
