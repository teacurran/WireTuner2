/// A location in pasteboard coordinates: points, y down (`doc/v1/common.proto` `Point`).
///
/// `Point` and ``Vector`` are distinct types so positions and displacements cannot be mixed up:
/// a point minus a point is a vector, a point plus a vector is a point, and a vector never picks
/// up a translation when passed through an ``AffineTransform``.  Both are plain `Double` pairs
/// and free to copy; nothing in this package allocates to handle them.
public struct Point: Hashable, Sendable {
    public var x: Double
    public var y: Double

    @inlinable
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    @inlinable
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)

    /// Whether both coordinates are finite (neither NaN nor infinite).
    @inlinable
    public var isFinite: Bool { x.isFinite && y.isFinite }

    @inlinable
    public func distance(to other: Point) -> Double {
        (self - other).length
    }

    @inlinable
    public func distanceSquared(to other: Point) -> Double {
        (self - other).lengthSquared
    }

    /// Linear interpolation: `a` at `t == 0`, `b` at `t == 1`.  `t` is not clamped.
    @inlinable
    public static func lerp(_ a: Point, _ b: Point, _ t: Double) -> Point {
        Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Whether the two points are within `tolerance` of each other (Euclidean distance).
    @inlinable
    public func isApproximatelyEqual(to other: Point, tolerance: Double = 1e-9) -> Bool {
        distanceSquared(to: other) <= tolerance * tolerance
    }

    @inlinable
    public static func + (point: Point, vector: Vector) -> Point {
        Point(x: point.x + vector.dx, y: point.y + vector.dy)
    }

    @inlinable
    public static func - (point: Point, vector: Vector) -> Point {
        Point(x: point.x - vector.dx, y: point.y - vector.dy)
    }

    @inlinable
    public static func - (a: Point, b: Point) -> Vector {
        Vector(dx: a.x - b.x, dy: a.y - b.y)
    }

    @inlinable
    public static func += (point: inout Point, vector: Vector) {
        point = point + vector
    }

    @inlinable
    public static func -= (point: inout Point, vector: Vector) {
        point = point - vector
    }
}

/// A displacement or direction in pasteboard coordinates.
public struct Vector: Hashable, Sendable {
    public var dx: Double
    public var dy: Double

    @inlinable
    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }

    @inlinable
    public init(_ dx: Double, _ dy: Double) {
        self.dx = dx
        self.dy = dy
    }

    public static let zero = Vector(dx: 0, dy: 0)

    @inlinable
    public var isFinite: Bool { dx.isFinite && dy.isFinite }

    @inlinable
    public var length: Double { lengthSquared.squareRoot() }

    @inlinable
    public var lengthSquared: Double { dx * dx + dy * dy }

    /// The unit vector in this direction; the zero vector normalizes to itself.
    @inlinable
    public var normalized: Vector {
        let l = length
        return l > 0 ? Vector(dx: dx / l, dy: dy / l) : self
    }

    /// This vector rotated a quarter turn in the direction of positive rotation of the
    /// coordinate system: `(dx, dy)` becomes `(-dy, dx)`.  In y-down pasteboard coordinates
    /// that is clockwise on screen.
    @inlinable
    public var perpendicular: Vector { Vector(dx: -dy, dy: dx) }

    @inlinable
    public func dot(_ other: Vector) -> Double {
        dx * other.dx + dy * other.dy
    }

    /// The z component of the 3-D cross product, positive when `other` is a positive rotation
    /// away from `self`.
    @inlinable
    public func cross(_ other: Vector) -> Double {
        dx * other.dy - dy * other.dx
    }

    /// Whether the two vectors are within `tolerance` of each other.
    @inlinable
    public func isApproximatelyEqual(to other: Vector, tolerance: Double = 1e-9) -> Bool {
        (self - other).lengthSquared <= tolerance * tolerance
    }

    @inlinable
    public static prefix func - (vector: Vector) -> Vector {
        Vector(dx: -vector.dx, dy: -vector.dy)
    }

    @inlinable
    public static func + (a: Vector, b: Vector) -> Vector {
        Vector(dx: a.dx + b.dx, dy: a.dy + b.dy)
    }

    @inlinable
    public static func - (a: Vector, b: Vector) -> Vector {
        Vector(dx: a.dx - b.dx, dy: a.dy - b.dy)
    }

    @inlinable
    public static func * (vector: Vector, scalar: Double) -> Vector {
        Vector(dx: vector.dx * scalar, dy: vector.dy * scalar)
    }

    @inlinable
    public static func * (scalar: Double, vector: Vector) -> Vector {
        Vector(dx: vector.dx * scalar, dy: vector.dy * scalar)
    }

    @inlinable
    public static func / (vector: Vector, scalar: Double) -> Vector {
        Vector(dx: vector.dx / scalar, dy: vector.dy / scalar)
    }

    @inlinable
    public static func += (a: inout Vector, b: Vector) {
        a = a + b
    }

    @inlinable
    public static func -= (a: inout Vector, b: Vector) {
        a = a - b
    }

    @inlinable
    public static func *= (vector: inout Vector, scalar: Double) {
        vector = vector * scalar
    }
}
