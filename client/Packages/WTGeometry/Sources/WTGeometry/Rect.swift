/// An axis-aligned rectangle in pasteboard coordinates, stored as its extremes.
///
/// `Rect.null` is the identity for ``union(_:)-(Rect)``: every union with it yields the other
/// operand, and it intersects and contains nothing.  Bounds computations start from it so an
/// empty contour has null bounds rather than a spurious rectangle at the origin.
public struct Rect: Hashable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    @inlinable
    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    /// A rectangle from an origin and a size; a negative size is normalized.
    @inlinable
    public init(x: Double, y: Double, width: Double, height: Double) {
        minX = min(x, x + width)
        maxX = max(x, x + width)
        minY = min(y, y + height)
        maxY = max(y, y + height)
    }

    /// The smallest rectangle containing both points.
    @inlinable
    public init(_ a: Point, _ b: Point) {
        minX = min(a.x, b.x)
        maxX = max(a.x, b.x)
        minY = min(a.y, b.y)
        maxY = max(a.y, b.y)
    }

    /// The bounding box of a sequence of points; `null` when the sequence is empty.
    public init<S: Sequence>(boundingPoints points: S) where S.Element == Point {
        self = .null
        for point in points {
            formUnion(point)
        }
    }

    /// The empty set; the identity for union.
    public static let null = Rect(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)

    /// The degenerate rectangle at the origin.
    public static let zero = Rect(minX: 0, minY: 0, maxX: 0, maxY: 0)

    /// Whether this is the empty set (an extreme is inverted).
    @inlinable
    public var isNull: Bool { maxX < minX || maxY < minY }

    /// Whether the rectangle encloses no area: null, or zero width or height.
    @inlinable
    public var isEmpty: Bool { isNull || maxX == minX || maxY == minY }

    @inlinable
    public var width: Double { isNull ? 0 : maxX - minX }

    @inlinable
    public var height: Double { isNull ? 0 : maxY - minY }

    @inlinable
    public var midX: Double { (minX + maxX) / 2 }

    @inlinable
    public var midY: Double { (minY + maxY) / 2 }

    @inlinable
    public var origin: Point { Point(x: minX, y: minY) }

    @inlinable
    public var center: Point { Point(x: midX, y: midY) }

    @inlinable
    public var minPoint: Point { Point(x: minX, y: minY) }

    @inlinable
    public var maxPoint: Point { Point(x: maxX, y: maxY) }

    /// The length of the diagonal; 0 for a null rectangle.
    @inlinable
    public var diagonal: Double { (width * width + height * height).squareRoot() }

    /// Whether the point lies in the closed rectangle.
    @inlinable
    public func contains(_ point: Point) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    /// Whether `other` lies entirely within this rectangle.  A null `other` is contained by
    /// everything; a null receiver contains only null.
    @inlinable
    public func contains(_ other: Rect) -> Bool {
        if other.isNull {
            return true
        }
        return other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
    }

    /// Whether the two closed rectangles, each grown by `tolerance` on every side, share a point.
    @inlinable
    public func intersects(_ other: Rect, tolerance: Double = 0) -> Bool {
        maxX + tolerance >= other.minX - tolerance
            && other.maxX + tolerance >= minX - tolerance
            && maxY + tolerance >= other.minY - tolerance
            && other.maxY + tolerance >= minY - tolerance
    }

    @inlinable
    public func union(_ other: Rect) -> Rect {
        Rect(
            minX: min(minX, other.minX), minY: min(minY, other.minY),
            maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY))
    }

    @inlinable
    public func union(_ point: Point) -> Rect {
        Rect(
            minX: min(minX, point.x), minY: min(minY, point.y),
            maxX: max(maxX, point.x), maxY: max(maxY, point.y))
    }

    @inlinable
    public mutating func formUnion(_ other: Rect) {
        self = union(other)
    }

    @inlinable
    public mutating func formUnion(_ point: Point) {
        self = union(point)
    }

    /// The overlap of the two rectangles; `null` when they are disjoint.
    @inlinable
    public func intersection(_ other: Rect) -> Rect {
        let result = Rect(
            minX: max(minX, other.minX), minY: max(minY, other.minY),
            maxX: min(maxX, other.maxX), maxY: min(maxY, other.maxY))
        return result.isNull ? .null : result
    }

    /// The rectangle shrunk by `dx` on the left and right and `dy` on the top and bottom.
    /// Negative insets grow it.  A null rectangle stays null.
    @inlinable
    public func insetBy(dx: Double, dy: Double) -> Rect {
        if isNull {
            return self
        }
        return Rect(minX: minX + dx, minY: minY + dy, maxX: maxX - dx, maxY: maxY - dy)
    }

    /// The rectangle grown by `amount` on every side.
    @inlinable
    public func expanded(by amount: Double) -> Rect {
        insetBy(dx: -amount, dy: -amount)
    }

    @inlinable
    public func offset(by vector: Vector) -> Rect {
        if isNull {
            return self
        }
        return Rect(minX: minX + vector.dx, minY: minY + vector.dy, maxX: maxX + vector.dx, maxY: maxY + vector.dy)
    }

    /// The bounding box of this rectangle's four corners after `transform`.
    public func applying(_ transform: AffineTransform) -> Rect {
        if isNull {
            return self
        }
        var result = Rect(transform.apply(Point(x: minX, y: minY)), transform.apply(Point(x: maxX, y: maxY)))
        result.formUnion(transform.apply(Point(x: minX, y: maxY)))
        result.formUnion(transform.apply(Point(x: maxX, y: minY)))
        return result
    }
}
