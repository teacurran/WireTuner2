// The path geometry carried by display-list items.  Renderer-agnostic: the Core Graphics
// renderer converts it to a CGPath, the Metal renderer (REND-006) flattens it at the shared
// tolerance.

/// A multi-contour path of lines and Bézier curves in the item's local space.
import WTGeometry

public struct DisplayPath: Hashable, Sendable {
    /// One drawing instruction.
    public enum Element: Hashable, Sendable {
        case move(to: Point)
        case line(to: Point)
        case quadCurve(control: Point, end: Point)
        case cubicCurve(control1: Point, control2: Point, end: Point)
        case close

        /// Every point the element mentions; the control-point hull of a path is the
        /// bounding box of these.
        var points: [Point] {
            switch self {
            case .move(let point), .line(let point):
                return [point]
            case .quadCurve(let control, let end):
                return [control, end]
            case .cubicCurve(let control1, let control2, let end):
                return [control1, control2, end]
            case .close:
                return []
            }
        }

        /// The element with every point transformed.
        func applying(_ transform: AffineTransform) -> Element {
            switch self {
            case .move(let point):
                return .move(to: transform.apply(point))
            case .line(let point):
                return .line(to: transform.apply(point))
            case .quadCurve(let control, let end):
                return .quadCurve(control: transform.apply(control), end: transform.apply(end))
            case .cubicCurve(let control1, let control2, let end):
                return .cubicCurve(
                    control1: transform.apply(control1),
                    control2: transform.apply(control2),
                    end: transform.apply(end)
                )
            case .close:
                return .close
            }
        }
    }

    public var elements: [Element]

    public init(elements: [Element] = []) {
        self.elements = elements
    }

    /// A closed rectangle contour.
    public init(rect: Rect) {
        elements = [
            .move(to: Point(x: rect.minX, y: rect.minY)),
            .line(to: Point(x: rect.maxX, y: rect.minY)),
            .line(to: Point(x: rect.maxX, y: rect.maxY)),
            .line(to: Point(x: rect.minX, y: rect.maxY)),
            .close,
        ]
    }

    /// An ellipse inscribed in `rect`, as four cubic Béziers (the usual κ ≈ 0.5523 fit).
    public init(ellipseIn rect: Rect) {
        let kappa = 0.552_284_749_831
        let cx = rect.midX
        let cy = rect.midY
        let rx = rect.width / 2
        let ry = rect.height / 2
        let ox = rx * kappa
        let oy = ry * kappa
        elements = [
            .move(to: Point(x: cx + rx, y: cy)),
            .cubicCurve(control1: Point(x: cx + rx, y: cy + oy), control2: Point(x: cx + ox, y: cy + ry), end: Point(x: cx, y: cy + ry)),
            .cubicCurve(control1: Point(x: cx - ox, y: cy + ry), control2: Point(x: cx - rx, y: cy + oy), end: Point(x: cx - rx, y: cy)),
            .cubicCurve(control1: Point(x: cx - rx, y: cy - oy), control2: Point(x: cx - ox, y: cy - ry), end: Point(x: cx, y: cy - ry)),
            .cubicCurve(control1: Point(x: cx + ox, y: cy - ry), control2: Point(x: cx + rx, y: cy - oy), end: Point(x: cx + rx, y: cy)),
            .close,
        ]
    }

    /// A polygon through `points`, closed when `closed` is true.
    public init(polygon points: [Point], closed: Bool = true) {
        elements = []
        for (index, point) in points.enumerated() {
            elements.append(index == 0 ? .move(to: point) : .line(to: point))
        }
        if closed, !points.isEmpty {
            elements.append(.close)
        }
    }

    public var isEmpty: Bool { elements.isEmpty }

    public mutating func move(to point: Point) {
        elements.append(.move(to: point))
    }

    public mutating func addLine(to point: Point) {
        elements.append(.line(to: point))
    }

    public mutating func addQuadCurve(control: Point, to end: Point) {
        elements.append(.quadCurve(control: control, end: end))
    }

    public mutating func addCubicCurve(control1: Point, control2: Point, to end: Point) {
        elements.append(.cubicCurve(control1: control1, control2: control2, end: end))
    }

    public mutating func close() {
        elements.append(.close)
    }

    /// The bounding box of every anchor and control point: a conservative bound on the
    /// drawn geometry (a curve never leaves its control hull).  Nil when the path has no points.
    public var controlBounds: Rect? {
        Rect(boundingPoints: elements.flatMap(\.points)).nonNull
    }

    /// The path with every point transformed.
    public func applying(_ transform: AffineTransform) -> DisplayPath {
        DisplayPath(elements: elements.map { $0.applying(transform) })
    }
}
