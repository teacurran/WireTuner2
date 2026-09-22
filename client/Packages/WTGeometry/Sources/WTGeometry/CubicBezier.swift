/// A cubic Bézier segment: the curve every path segment in the document reduces to
/// (`vector-basics`: a retracted handle is a control point on its anchor, and a segment with both
/// handles retracted is a straight line).
///
/// Evaluation, derivatives, splitting and bounds are allocation-free: the type is four `Point`s
/// and every result is a fixed-size value.
public struct CubicBezier: Hashable, Sendable {
    public var p0: Point
    public var p1: Point
    public var p2: Point
    public var p3: Point

    @inlinable
    public init(p0: Point, p1: Point, p2: Point, p3: Point) {
        self.p0 = p0
        self.p1 = p1
        self.p2 = p2
        self.p3 = p3
    }

    @inlinable
    public init(_ p0: Point, _ p1: Point, _ p2: Point, _ p3: Point) {
        self.p0 = p0
        self.p1 = p1
        self.p2 = p2
        self.p3 = p3
    }

    /// A straight segment with the control points at thirds.
    @inlinable
    public init(line: Line) {
        self = line.elevated()
    }

    /// The quadratic elevated to a cubic.
    @inlinable
    public init(quadratic: QuadraticBezier) {
        self = quadratic.elevated()
    }

    /// The segment between two anchors given their handles as offsets, as the path model stores
    /// them: `outHandle` leaves `start`, `inHandle` arrives at `end`.  Zero offsets are retracted
    /// handles.
    @inlinable
    public init(from start: Point, outHandle: Vector, inHandle: Vector, to end: Point) {
        p0 = start
        p1 = start + outHandle
        p2 = end + inHandle
        p3 = end
    }

    @inlinable
    public var startPoint: Point { p0 }

    @inlinable
    public var endPoint: Point { p3 }

    /// The straight-line distance from start to end.
    @inlinable
    public var chordLength: Double { p0.distance(to: p3) }

    /// The length of the control polygon, an upper bound on the arc length.
    @inlinable
    public var controlPolygonLength: Double {
        p0.distance(to: p1) + p1.distance(to: p2) + p2.distance(to: p3)
    }

    /// Whether all four control points coincide.
    @inlinable
    public var isDegenerate: Bool {
        p0 == p1 && p1 == p2 && p2 == p3
    }

    /// The point at `t` (Bernstein form; `t` is not clamped).
    @inlinable
    public func evaluate(_ t: Double) -> Point {
        let mt = 1 - t
        let mt2 = mt * mt
        let t2 = t * t
        let a = mt2 * mt
        let b = 3 * mt2 * t
        let c = 3 * mt * t2
        let d = t2 * t
        return Point(
            x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
            y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    /// The point at `t` by repeated linear interpolation.  Numerically the most stable form;
    /// ``evaluate(_:)`` is the fast one and the tests hold the two to each other.
    @inlinable
    public func evaluateDeCasteljau(_ t: Double) -> Point {
        let p01 = Point.lerp(p0, p1, t)
        let p12 = Point.lerp(p1, p2, t)
        let p23 = Point.lerp(p2, p3, t)
        let p012 = Point.lerp(p01, p12, t)
        let p123 = Point.lerp(p12, p23, t)
        return Point.lerp(p012, p123, t)
    }

    /// The first derivative with respect to `t`.
    @inlinable
    public func derivative(_ t: Double) -> Vector {
        let mt = 1 - t
        let a = 3 * mt * mt
        let b = 6 * mt * t
        let c = 3 * t * t
        return Vector(
            dx: a * (p1.x - p0.x) + b * (p2.x - p1.x) + c * (p3.x - p2.x),
            dy: a * (p1.y - p0.y) + b * (p2.y - p1.y) + c * (p3.y - p2.y))
    }

    /// The second derivative with respect to `t`.
    @inlinable
    public func secondDerivative(_ t: Double) -> Vector {
        let mt = 1 - t
        return Vector(
            dx: 6 * (mt * (p2.x - 2 * p1.x + p0.x) + t * (p3.x - 2 * p2.x + p1.x)),
            dy: 6 * (mt * (p2.y - 2 * p1.y + p0.y) + t * (p3.y - 2 * p2.y + p1.y)))
    }

    /// The unit tangent at `t`.  Where the derivative vanishes (a cusp, or coincident control
    /// points at an end) the second derivative's direction is used, then the chord; a fully
    /// degenerate curve has the zero vector for its tangent.
    public func tangent(_ t: Double) -> Vector {
        let d = derivative(t)
        if d.lengthSquared > 0 {
            return d.normalized
        }
        let dd = secondDerivative(t)
        if dd.lengthSquared > 0 {
            // Approaching a cusp from the left the velocity reverses; the second derivative
            // points the way the curve continues, which is what a caller wants at t = 0 and
            // the reverse of it at t = 1.
            return t < 1 ? dd.normalized : -dd.normalized
        }
        return (p3 - p0).normalized
    }

    /// The unit normal at `t`: the tangent turned by ``Vector/perpendicular``.
    @inlinable
    public func normal(_ t: Double) -> Vector {
        tangent(t).perpendicular
    }

    /// Signed curvature at `t`: positive where the curve turns toward the normal.  A stationary
    /// point (zero derivative) has no defined curvature and reports 0.
    public func curvature(_ t: Double) -> Double {
        let d1 = derivative(t)
        let speedSquared = d1.lengthSquared
        guard speedSquared > 0 else {
            return 0
        }
        let d2 = secondDerivative(t)
        return d1.cross(d2) / (speedSquared * speedSquared.squareRoot())
    }

    /// The curve split at `t` by de Casteljau: the first part covers the original `0...t`, the
    /// second `t...1`, each reparametrized to `0...1`.
    @inlinable
    public func split(at t: Double) -> (CubicBezier, CubicBezier) {
        let p01 = Point.lerp(p0, p1, t)
        let p12 = Point.lerp(p1, p2, t)
        let p23 = Point.lerp(p2, p3, t)
        let p012 = Point.lerp(p01, p12, t)
        let p123 = Point.lerp(p12, p23, t)
        let p0123 = Point.lerp(p012, p123, t)
        return (
            CubicBezier(p0: p0, p1: p01, p2: p012, p3: p0123),
            CubicBezier(p0: p0123, p1: p123, p2: p23, p3: p3)
        )
    }

    /// The portion of the curve between two parameters, reparametrized to `0...1`.  Parameters
    /// are clamped to `0...1`; when `t0 > t1` the portion runs backwards.
    public func subdivide(from t0: Double, to t1: Double) -> CubicBezier {
        if t0 > t1 {
            return subdivide(from: t1, to: t0).reversed()
        }
        let a = max(0, t0)
        let b = min(1, t1)
        if a >= 1 {
            return CubicBezier(p0: p3, p1: p3, p2: p3, p3: p3)
        }
        let tail = a <= 0 ? self : split(at: a).1
        if b >= 1 {
            return tail
        }
        let local = (b - a) / (1 - a)
        return tail.split(at: local).0
    }

    /// The bounding box of the four control points: cheap, and it contains the curve.
    @inlinable
    public var controlBounds: Rect {
        Rect(p0, p3).union(p1).union(p2)
    }

    /// The tight bounding box: the extreme points of the curve itself, from the roots of the
    /// derivative on each axis.  Allocation-free.
    @inlinable
    public var bounds: Rect {
        var result = Rect(p0, p3)
        let rx = Polynomial.quadraticRoots(
            3 * (-p0.x + 3 * p1.x - 3 * p2.x + p3.x),
            6 * (p0.x - 2 * p1.x + p2.x),
            3 * (p1.x - p0.x))
        for i in 0..<rx.count {
            let t = rx[i]
            if t > 0 && t < 1 {
                let x = evaluate(t).x
                result.minX = min(result.minX, x)
                result.maxX = max(result.maxX, x)
            }
        }
        let ry = Polynomial.quadraticRoots(
            3 * (-p0.y + 3 * p1.y - 3 * p2.y + p3.y),
            6 * (p0.y - 2 * p1.y + p2.y),
            3 * (p1.y - p0.y))
        for i in 0..<ry.count {
            let t = ry[i]
            if t > 0 && t < 1 {
                let y = evaluate(t).y
                result.minY = min(result.minY, y)
                result.maxY = max(result.maxY, y)
            }
        }
        return result
    }

    /// Whether the control points lie within `tolerance` of the chord's line, so the curve is a
    /// straight segment for any purpose that tolerates that error.  A degenerate chord tests the
    /// control points' distance from the start.
    public func isLinear(tolerance: Double = 1e-9) -> Bool {
        let chord = Line(start: p0, end: p3)
        if chord.length == 0 {
            return p0.distance(to: p1) <= tolerance && p0.distance(to: p2) <= tolerance
        }
        return abs(chord.signedDistance(to: p1)) <= tolerance && abs(chord.signedDistance(to: p2)) <= tolerance
    }

    @inlinable
    public func reversed() -> CubicBezier {
        CubicBezier(p0: p3, p1: p2, p2: p1, p3: p0)
    }

    public func applying(_ transform: AffineTransform) -> CubicBezier {
        CubicBezier(
            p0: transform.apply(p0), p1: transform.apply(p1),
            p2: transform.apply(p2), p3: transform.apply(p3))
    }
}
