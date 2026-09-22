import Foundation

/// A 2-D affine transform in the Core Graphics layout:
///
///     x' = a·x + c·y + tx
///     y' = b·x + d·y + ty
///
/// so that `CommonProps.transform` from the document and `CGAffineTransform` in the renderers
/// convert field for field.  ``concatenating(_:)`` and `*` apply the receiver first and the
/// argument second, as `CGAffineTransformConcat` does.
public struct AffineTransform: Hashable, Sendable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    @inlinable
    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public static let identity = AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public static func translation(_ vector: Vector) -> AffineTransform {
        AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: vector.dx, ty: vector.dy)
    }

    public static func translation(x: Double, y: Double) -> AffineTransform {
        AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
    }

    public static func scale(_ factor: Double) -> AffineTransform {
        AffineTransform(a: factor, b: 0, c: 0, d: factor, tx: 0, ty: 0)
    }

    public static func scale(x: Double, y: Double) -> AffineTransform {
        AffineTransform(a: x, b: 0, c: 0, d: y, tx: 0, ty: 0)
    }

    /// Rotation about the origin by `radians`, in the coordinate system's positive direction
    /// (clockwise on screen for y-down pasteboard coordinates).
    public static func rotation(radians: Double) -> AffineTransform {
        let s = sin(radians)
        let co = cos(radians)
        return AffineTransform(a: co, b: s, c: -s, d: co, tx: 0, ty: 0)
    }

    /// Rotation by `radians` about `center`.
    public static func rotation(radians: Double, around center: Point) -> AffineTransform {
        translation(Point.zero - center)
            .concatenating(rotation(radians: radians))
            .concatenating(translation(center - Point.zero))
    }

    @inlinable
    public var isIdentity: Bool {
        a == 1 && b == 0 && c == 0 && d == 1 && tx == 0 && ty == 0
    }

    @inlinable
    public var determinant: Double { a * d - b * c }

    /// The translation part.
    @inlinable
    public var translation: Vector { Vector(dx: tx, dy: ty) }

    /// Whether the linear part is invertible: its determinant is not (numerically) zero.
    @inlinable
    public var isInvertible: Bool {
        let det = determinant
        return det.isFinite && abs(det) > 1e-300
    }

    /// The inverse, or nil when the transform collapses the plane.
    public func inverted() -> AffineTransform? {
        guard isInvertible else {
            return nil
        }
        let det = determinant
        return AffineTransform(
            a: d / det, b: -b / det,
            c: -c / det, d: a / det,
            tx: (c * ty - d * tx) / det,
            ty: (b * tx - a * ty) / det)
    }

    /// The transform that applies `self` first and then `other`.
    @inlinable
    public func concatenating(_ other: AffineTransform) -> AffineTransform {
        AffineTransform(
            a: other.a * a + other.c * b,
            b: other.b * a + other.d * b,
            c: other.a * c + other.c * d,
            d: other.b * c + other.d * d,
            tx: other.a * tx + other.c * ty + other.tx,
            ty: other.b * tx + other.d * ty + other.ty)
    }

    /// `lhs` applied first, then `rhs`.
    @inlinable
    public static func * (lhs: AffineTransform, rhs: AffineTransform) -> AffineTransform {
        lhs.concatenating(rhs)
    }

    @inlinable
    public func apply(_ point: Point) -> Point {
        Point(x: a * point.x + c * point.y + tx, y: b * point.x + d * point.y + ty)
    }

    /// Applies the linear part only; a direction has no position to translate.
    @inlinable
    public func apply(_ vector: Vector) -> Vector {
        Vector(dx: a * vector.dx + c * vector.dy, dy: b * vector.dx + d * vector.dy)
    }
}
