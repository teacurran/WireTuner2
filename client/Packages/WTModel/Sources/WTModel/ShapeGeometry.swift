import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Corner radii after the read-time rules (rectangles-ellipses-lines.adoc, "Read-time
/// normalizations"): `uniform` reads every corner as `top_left`, and each radius is clamped to
/// half the shorter side.
public struct CornerRadii: Hashable, Sendable {
    public var topLeft: Double
    public var topRight: Double
    public var bottomRight: Double
    public var bottomLeft: Double

    public init(topLeft: Double = 0, topRight: Double = 0, bottomRight: Double = 0, bottomLeft: Double = 0) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// Every corner `radius`.
    public static func uniform(_ radius: Double) -> CornerRadii {
        CornerRadii(topLeft: radius, topRight: radius, bottomRight: radius, bottomLeft: radius)
    }

    /// The radii `corners` hold for a rectangle of `size`: Uniform applied, negatives and
    /// non-finite values read as 0, each clamped to half of the shorter side.
    public init(_ corners: Wiretuner_Doc_V1_CornerRadii, size: Size) {
        let limit = max(0, min(size.width, size.height) / 2)
        func clamp(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), limit) : 0 }
        if corners.uniform {
            self = .uniform(clamp(corners.topLeft))
        } else {
            self.init(topLeft: clamp(corners.topLeft), topRight: clamp(corners.topRight),
                      bottomRight: clamp(corners.bottomRight), bottomLeft: clamp(corners.bottomLeft))
        }
    }
}

/// The paths rectangles and ellipses read as (rectangles-ellipses-lines.adoc, "Geometry"):
/// every consumer sees a `VectorPath`; only the shape editors care about the kind.  Derived points carry
/// synthetic ids (replica 0, counter = index + 1) so selections can name them.
///
/// Deviation (DRAW-008): the spec places `rectPath` and `ellipsePath` in `WTGeometry`; they live
/// here because they produce WTModel's `VectorPath` with point kinds and ids, which WTGeometry has no
/// type for.
public enum ShapeGeometry {
    /// The cubic approximation constant for a quarter circle.
    public static let kappa = 0.5522847498

    /// A rectangle of `size` with its top-left corner at the origin: four corner points clockwise
    /// from the top-left, a rounded corner becoming two points joined by a quarter-circle cubic.
    /// Empty for a zero or negative dimension (it renders nothing).
    public static func rectPath(size: Size, radii: CornerRadii = CornerRadii()) -> VectorPath {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return VectorPath(contours: []) }
        let w = size.width, h = size.height
        var points: [VectorPoint] = []
        func corner(_ at: Point, radius: Double, arrive: Vector, leave: Vector) {
            // `arrive`: direction of travel along the edge reaching the corner; `leave`: along the next edge.
            if radius <= 0 {
                points.append(VectorPoint(anchor: at))
                return
            }
            let k = kappa * radius
            points.append(VectorPoint(anchor: at - arrive * radius, outHandle: arrive * k))
            points.append(VectorPoint(anchor: at + leave * radius, inHandle: -(leave * k)))
        }
        let right = Vector(dx: 1, dy: 0), down = Vector(dx: 0, dy: 1)
        corner(Point(x: 0, y: 0), radius: radii.topLeft, arrive: -down, leave: right)
        corner(Point(x: w, y: 0), radius: radii.topRight, arrive: right, leave: down)
        corner(Point(x: w, y: h), radius: radii.bottomRight, arrive: down, leave: -right)
        corner(Point(x: 0, y: h), radius: radii.bottomLeft, arrive: -right, leave: -down)
        return VectorPath(contours: [VectorContour(closed: true, points: numbered(points))])
    }

    /// An ellipse inscribed in `size` at the origin: four curve points clockwise from the top.
    public static func ellipsePath(size: Size) -> VectorPath {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return VectorPath(contours: []) }
        let rx = size.width / 2, ry = size.height / 2
        let kx = kappa * rx, ky = kappa * ry
        let points = [
            VectorPoint(anchor: Point(x: rx, y: 0), inHandle: Vector(dx: -kx, dy: 0), outHandle: Vector(dx: kx, dy: 0), kind: .curve),
            VectorPoint(anchor: Point(x: 2 * rx, y: ry), inHandle: Vector(dx: 0, dy: -ky), outHandle: Vector(dx: 0, dy: ky), kind: .curve),
            VectorPoint(anchor: Point(x: rx, y: 2 * ry), inHandle: Vector(dx: kx, dy: 0), outHandle: Vector(dx: -kx, dy: 0), kind: .curve),
            VectorPoint(anchor: Point(x: 0, y: ry), inHandle: Vector(dx: 0, dy: ky), outHandle: Vector(dx: 0, dy: -ky), kind: .curve),
        ]
        return VectorPath(contours: [VectorContour(closed: true, points: numbered(points))])
    }

    private static func numbered(_ points: [VectorPoint]) -> [VectorPoint] {
        points.enumerated().map { index, point in
            var copy = point
            copy.id = OpID(counter: UInt64(index + 1), replica: 0)
            return copy
        }
    }

    /// The size a stored `Size` reads as.
    static func size(_ size: Wiretuner_Doc_V1_Size) -> Size {
        Size(width: size.width, height: size.height)
    }

    /// The derived path of a rectangle.
    public static func path(_ rect: Wiretuner_Doc_V1_RectProps) -> VectorPath {
        let size = size(rect.size)
        return rectPath(size: size, radii: CornerRadii(rect.corners, size: size))
    }

    /// The derived path of an ellipse.
    public static func path(_ ellipse: Wiretuner_Doc_V1_EllipseProps) -> VectorPath {
        ellipsePath(size: size(ellipse.size))
    }
}

/// Register paths of `RectProps` (21) and `EllipseProps` (22).
public enum ShapeFields {
    public static func size(_ kind: NodeKind) -> RegisterPath { RegisterPath([kind.rawValue, 2]) }
    public static func transform(_ kind: NodeKind) -> RegisterPath { RegisterPath([kind.rawValue, 1, 4]) }
    public static let corners = RegisterPath([NodeKind.rect.rawValue, 3])
}
