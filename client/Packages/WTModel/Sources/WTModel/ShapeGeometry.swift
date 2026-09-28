import Foundation
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

    /// The derived path of an ellipse, or of its arc (DRAW-061).
    public static func path(_ ellipse: Wiretuner_Doc_V1_EllipseProps) -> VectorPath {
        let arc = EllipseArc(ellipse)
        return arc.isWhole ? ellipsePath(size: size(ellipse.size)) : arcPath(size: size(ellipse.size), arc: arc)
    }

    /// An arc of the ellipse inscribed in `size` (rectangles-ellipses-lines.adoc, "Arcs"): from
    /// `arc.start` counterclockwise on screen to `arc.end`, as cubic pieces of at most 90° (handle
    /// length 4/3·tan(θ/4) of the radius), then -- closed -- the centre, so the contour is a wedge.
    /// Empty for a zero or negative dimension.
    public static func arcPath(size: Size, arc: EllipseArc) -> VectorPath {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return VectorPath(contours: []) }
        let rx = size.width / 2, ry = size.height / 2
        let sweep = arc.sweep * .pi / 180
        let start = arc.start * .pi / 180
        let pieces = max(1, Int((sweep / (.pi / 2)).rounded(.up)))
        let step = sweep / Double(pieces)
        let k = 4.0 / 3.0 * tan(step / 4)
        // Counterclockwise on screen with y down: (cos a, -sin a); its tangent (-sin a, -cos a).
        func point(_ a: Double) -> Point { Point(x: rx + rx * cos(a), y: ry - ry * sin(a)) }
        func tangent(_ a: Double) -> Vector { Vector(dx: -rx * sin(a) * k, dy: -ry * cos(a) * k) }
        var points: [VectorPoint] = []
        for index in 0...pieces {
            let a = start + step * Double(index)
            let inHandle = index == 0 ? Vector(dx: 0, dy: 0) : -tangent(a)
            let outHandle = index == pieces ? Vector(dx: 0, dy: 0) : tangent(a)
            let smooth = index > 0 && index < pieces
            points.append(VectorPoint(anchor: point(a), inHandle: inHandle, outHandle: outHandle, kind: smooth ? .curve : .corner))
        }
        if !arc.open {
            points.append(VectorPoint(anchor: Point(x: rx, y: ry)))
        }
        return VectorPath(contours: [VectorContour(closed: !arc.open, points: numbered(points))])
    }

    /// The derived path of a polygon or star.
    public static func path(_ polygon: Wiretuner_Doc_V1_PolygonProps) -> VectorPath {
        polygonPath(PolygonShape(polygon))
    }

    /// A regular polygon or star centred on the origin (polygons-stars.adoc, "Client"): `sides`
    /// corner points (twice as many for a star, alternating peak and valley), clockwise on screen
    /// from the first vertex at `rotation`.  Empty when the radius is not positive.
    public static func polygonPath(_ shape: PolygonShape) -> VectorPath {
        guard shape.radius > 0, shape.radius.isFinite else { return VectorPath(contours: []) }
        let n = shape.sides
        var points: [VectorPoint] = []
        for k in 0..<n {
            let peak = shape.rotation + 2 * .pi * Double(k) / Double(n)
            points.append(VectorPoint(anchor: Point(x: shape.radius * cos(peak), y: shape.radius * sin(peak))))
            if shape.star {
                let valley = peak + .pi / Double(n) + shape.valleyOffset
                points.append(VectorPoint(anchor: Point(x: shape.innerRadius * cos(valley), y: shape.innerRadius * sin(valley))))
            }
        }
        return VectorPath(contours: [VectorContour(closed: true, points: numbered(points))])
    }
}

/// An ellipse's arc after the read-time rules (DRAW-061, rectangles-ellipses-lines.adoc "Arcs"):
/// angles in degrees modulo 360 (a non-finite value reads as 0), counterclockwise on screen from 3
/// o'clock; equal angles are the whole ellipse, where `open` does nothing.
public struct EllipseArc: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var open: Bool

    public init(start: Double = 0, end: Double = 0, open: Bool = false) {
        self.start = Self.normalized(start)
        self.end = Self.normalized(end)
        self.open = open
    }

    public init(_ props: Wiretuner_Doc_V1_EllipseProps) {
        self.init(start: props.startAngle, end: props.endAngle, open: props.open)
    }

    /// `degrees` in 0 ..< 360; a non-finite value reads as 0.
    public static func normalized(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let value = degrees.truncatingRemainder(dividingBy: 360)
        let positive = value < 0 ? value + 360 : value
        return abs(positive - 360) < 1e-9 ? 0 : positive
    }

    /// Whether this is the whole ellipse (no arc).
    public var isWhole: Bool { abs(start - end) < 1e-9 }

    /// How far the arc runs from `start`, degrees (360 for the whole ellipse).
    public var sweep: Double {
        isWhole ? 360 : (end > start ? end - start : end + 360 - start)
    }
}

/// Register paths of `EllipseProps` (DRAW-061).
public enum EllipseFields {
    public static let kind = NodeKind.ellipse.rawValue
    public static let startAngle = RegisterPath([kind, 4])
    public static let endAngle = RegisterPath([kind, 5])
    public static let open = RegisterPath([kind, 6])
}

/// A polygon's fields after the read-time rules (polygons-stars.adoc, "Read-time
/// normalizations"): `sides` clamped to 3...360, the automatic inner radius applied, non-finite
/// values read as 0.
public struct PolygonShape: Hashable, Sendable {
    public static let sidesRange = 3...360

    public var sides: Int
    public var star: Bool
    public var radius: Double
    /// The inner radius as read: the automatic value when `autoInner`.
    public var innerRadius: Double
    public var autoInner: Bool
    public var sharpness: Double
    public var rotation: Double
    public var valleyOffset: Double

    public init(sides: Int, star: Bool = false, radius: Double, innerRadius: Double = 0, autoInner: Bool = false, sharpness: Double = 0,
                rotation: Double = 0, valleyOffset: Double = 0) {
        self.sides = min(max(sides, Self.sidesRange.lowerBound), Self.sidesRange.upperBound)
        self.star = star
        self.radius = radius.isFinite ? radius : 0
        self.autoInner = autoInner
        self.sharpness = sharpness.isFinite ? min(max(sharpness, 0), 1) : 0
        self.rotation = rotation.isFinite ? rotation : 0
        self.valleyOffset = valleyOffset.isFinite ? valleyOffset : 0
        let inner = innerRadius.isFinite ? max(innerRadius, 0) : 0
        self.innerRadius = autoInner ? Self.automaticInnerRadius(sides: self.sides, radius: self.radius) : inner
    }

    public init(_ props: Wiretuner_Doc_V1_PolygonProps) {
        self.init(sides: Int(props.sides), star: props.star, radius: props.radius, innerRadius: props.innerRadius, autoInner: props.autoInner,
                  sharpness: props.sharpness, rotation: props.rotation, valleyOffset: props.valleyOffset)
    }

    /// The classic star's inner radius: `radius · cos(2π/n) / cos(π/n)` for odd counts (the
    /// pentagram construction), half the radius for even ones.  Deviation: clamped at 0, since the
    /// formula is negative for a triangle.
    public static func automaticInnerRadius(sides: Int, radius: Double) -> Double {
        let n = Double(sides)
        guard sides % 2 == 1 else { return radius * 0.5 }
        return max(0, radius * cos(2 * .pi / n) / cos(.pi / n))
    }

    /// The inner radius a manual star of `sharpness` (0 acute ... 1 obtuse) seeds: from 10% of
    /// the radius to the radius of the polygon's edge midpoints.
    public static func innerRadius(sharpness: Double, sides: Int, radius: Double) -> Double {
        let flat = radius * cos(.pi / Double(sides))
        let acute = radius * 0.1
        return acute + (flat - acute) * min(max(sharpness, 0), 1)
    }
}

/// Register paths of `RectProps` (21) and `EllipseProps` (22).
public enum ShapeFields {
    public static func size(_ kind: NodeKind) -> RegisterPath { RegisterPath([kind.rawValue, 2]) }
    public static func transform(_ kind: NodeKind) -> RegisterPath { RegisterPath([kind.rawValue, 1, 4]) }
    public static let corners = RegisterPath([NodeKind.rect.rawValue, 3])
    public static let uniform = corners.child(1)
    public static let topLeft = corners.child(2)
    public static let topRight = corners.child(3)
    public static let bottomRight = corners.child(4)
    public static let bottomLeft = corners.child(5)
}

/// Register paths of `PolygonProps` (23).
public enum PolygonFields {
    public static let kind = NodeKind.polygon.rawValue
    public static let sides = RegisterPath([kind, 2])
    public static let star = RegisterPath([kind, 3])
    public static let radius = RegisterPath([kind, 4])
    public static let innerRadius = RegisterPath([kind, 5])
    public static let autoInner = RegisterPath([kind, 6])
    public static let sharpness = RegisterPath([kind, 7])
    public static let rotation = RegisterPath([kind, 8])
    public static let valleyOffset = RegisterPath([kind, 9])
}

/// Register paths of `CommonProps` on any kind.
public enum CommonFields {
    public static func name(_ kind: NodeKind) -> RegisterPath { RegisterPath([kind.rawValue, 1, 1]) }
    public static func note(_ kind: NodeKind) -> RegisterPath { RegisterPath([kind.rawValue, 1, 2]) }
    public static func locked(_ kind: NodeKind) -> RegisterPath { RegisterPath([kind.rawValue, 1, 3]) }
    public static func transform(_ kind: NodeKind) -> RegisterPath { RegisterPath([kind.rawValue, 1, 4]) }
    public static func originLayer(_ kind: NodeKind) -> RegisterPath { RegisterPath([kind.rawValue, 1, 14]) }
}
