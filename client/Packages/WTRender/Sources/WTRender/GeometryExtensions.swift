// WTRender's small additions to WTGeometry's `Point`, `Vector`, `Rect` and `AffineTransform`
// (GEO-001), which the display list, viewport and tile maths are built on.  Pasteboard and
// view space are both y-down.

import WTGeometry

/// WTGeometry's transform, named here so that files importing Foundation (which has its own
/// `AffineTransform`) resolve to the pasteboard one.
public typealias AffineTransform = WTGeometry.AffineTransform

/// A width and height in view points or device pixels.  Not a pasteboard quantity, so it
/// lives here rather than in WTGeometry.
public struct Size: Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = Size(width: 0, height: 0)
}

extension Rect {
    /// A rectangle from an origin and a size; a negative size is normalized.
    public init(origin: Point, size: Size) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public var size: Size { Size(width: width, height: height) }

    /// The bounding box as an optional: nil for the null rectangle, which paints nothing.
    var nonNull: Rect? { isNull ? nil : self }
}

extension AffineTransform {
    /// Rotation about the origin by `degrees`, in the coordinate system's positive direction
    /// (clockwise on screen for y-down coordinates).
    public static func rotation(degrees: Double) -> AffineTransform {
        rotation(radians: degrees * .pi / 180)
    }

    /// The uniform scale factor: the square root of the area scaling.
    public var scaleFactor: Double { abs(determinant).squareRoot() }

    /// The inverse, or the identity for a transform that collapses the plane (a viewport's
    /// zoom is never zero, so this arises only from malformed input).
    var invertedOrIdentity: AffineTransform { inverted() ?? .identity }
}
