/// A quadratic Bézier segment.  The document stores only cubics; quadratics arrive from
/// imports (TrueType outlines, SVG `Q`) and are elevated on the way in.
public struct QuadraticBezier: Hashable, Sendable {
    public var p0: Point
    public var p1: Point
    public var p2: Point

    @inlinable
    public init(p0: Point, p1: Point, p2: Point) {
        self.p0 = p0
        self.p1 = p1
        self.p2 = p2
    }

    @inlinable
    public init(_ p0: Point, _ p1: Point, _ p2: Point) {
        self.p0 = p0
        self.p1 = p1
        self.p2 = p2
    }

    @inlinable
    public func evaluate(_ t: Double) -> Point {
        let mt = 1 - t
        let a = mt * mt
        let b = 2 * mt * t
        let c = t * t
        return Point(
            x: a * p0.x + b * p1.x + c * p2.x,
            y: a * p0.y + b * p1.y + c * p2.y)
    }

    @inlinable
    public func derivative(_ t: Double) -> Vector {
        let mt = 1 - t
        return Vector(
            dx: 2 * (mt * (p1.x - p0.x) + t * (p2.x - p1.x)),
            dy: 2 * (mt * (p1.y - p0.y) + t * (p2.y - p1.y)))
    }

    /// The identical curve as a cubic (degree elevation preserves the parametrization).
    @inlinable
    public func elevated() -> CubicBezier {
        let twoThirds = 2.0 / 3.0
        return CubicBezier(
            p0: p0,
            p1: p0 + (p1 - p0) * twoThirds,
            p2: p2 + (p1 - p2) * twoThirds,
            p3: p2)
    }

    @inlinable
    public var controlBounds: Rect {
        Rect(p0, p2).union(p1)
    }

    /// The tight bounding box.
    public var bounds: Rect { elevated().bounds }

    @inlinable
    public func reversed() -> QuadraticBezier {
        QuadraticBezier(p0: p2, p1: p1, p2: p0)
    }

    public func applying(_ transform: AffineTransform) -> QuadraticBezier {
        QuadraticBezier(p0: transform.apply(p0), p1: transform.apply(p1), p2: transform.apply(p2))
    }
}
