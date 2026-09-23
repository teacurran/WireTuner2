// Display paths as WTGeometry contours, and the stroke geometry both the renderer and hit
// testing derive from them: the centreline trimmed under arrowheads and the heads placed by
// (width, endpoint, tangent) (docs/_includes/appearance/stroke-attributes.adoc, "Client").

import WTGeometry
import Foundation

/// An anchor or control point of a display path, by element index.
public struct PathPoint: Hashable, Sendable {
    /// The index into `DisplayPath.elements` of the element that owns the point.
    public var element: Int
    /// 0 for an anchor (the element's end point); 1 or 2 for a curve's control points.
    public var control: Int
    public var point: Point

    public init(element: Int, control: Int, point: Point) {
        self.element = element
        self.control = control
        self.point = point
    }
}

extension DisplayPath {
    /// The path as WTGeometry contours: lines and quadratics elevated to cubics, one contour
    /// per subpath.  As in Core Graphics, drawing after `close` starts a new subpath at the
    /// closed one's start, and a drawing element with no current point acts as a move.
    /// Subpaths without segments are dropped.
    public var contours: [Contour] {
        var result: [Contour] = []
        var segments: [CubicBezier] = []
        var start: Point?
        var current: Point?

        func flush(closed: Bool) {
            if !segments.isEmpty {
                result.append(Contour(segments: segments, closed: closed))
            }
            segments = []
        }

        for element in elements {
            switch element {
            case .move(let point):
                flush(closed: false)
                start = point
                current = point
            case .line(let point):
                if let from = current {
                    segments.append(Line(start: from, end: point).elevated())
                } else {
                    start = point
                }
                current = point
            case .quadCurve(let control, let end):
                if let from = current {
                    segments.append(QuadraticBezier(p0: from, p1: control, p2: end).elevated())
                } else {
                    start = end
                }
                current = end
            case .cubicCurve(let control1, let control2, let end):
                if let from = current {
                    segments.append(CubicBezier(p0: from, p1: control1, p2: control2, p3: end))
                } else {
                    start = end
                }
                current = end
            case .close:
                flush(closed: true)
                current = start
            }
        }
        flush(closed: false)
        return result
    }

    /// A path of cubic segments tracing `contours`.
    public init(contours: [Contour]) {
        var elements: [Element] = []
        for contour in contours {
            guard let start = contour.startPoint else {
                continue
            }
            elements.append(.move(to: start))
            for segment in contour.segments {
                elements.append(.cubicCurve(control1: segment.p1, control2: segment.p2, end: segment.p3))
            }
            if contour.isClosed {
                elements.append(.close)
            }
        }
        self.init(elements: elements)
    }

    /// Every anchor (control 0) and, when `includeControls`, every curve control point, in
    /// element order.
    public func points(includeControls: Bool) -> [PathPoint] {
        var result: [PathPoint] = []
        for (index, element) in elements.enumerated() {
            switch element {
            case .move(let point), .line(let point):
                result.append(PathPoint(element: index, control: 0, point: point))
            case .quadCurve(let control, let end):
                if includeControls {
                    result.append(PathPoint(element: index, control: 1, point: control))
                }
                result.append(PathPoint(element: index, control: 0, point: end))
            case .cubicCurve(let control1, let control2, let end):
                if includeControls {
                    result.append(PathPoint(element: index, control: 1, point: control1))
                    result.append(PathPoint(element: index, control: 2, point: control2))
                }
                result.append(PathPoint(element: index, control: 0, point: end))
            case .close:
                break
            }
        }
        return result
    }
}

/// An arrowhead placed on a path end: `transform` maps arrowhead units into the path's local
/// space.
struct PlacedArrowhead: Hashable, Sendable {
    let arrowhead: Arrowhead
    let transform: AffineTransform
}

/// What a stroke paints: its centreline (trimmed under arrowheads) and the placed heads.
struct StrokeGeometry: Sendable {
    let body: DisplayPath
    let heads: [PlacedArrowhead]

    /// Arrowheads go on open ends only: the start of the first contour and the end of the last.
    /// A closed contour at either end carries none; a hairline carries none.
    init(path: DisplayPath, stroke: StrokePaint) {
        guard stroke.hasArrowheads else {
            body = path
            heads = []
            return
        }
        let original = path.contours
        var contours = original
        let width = stroke.style.width
        var heads: [PlacedArrowhead] = []
        if let head = stroke.startArrowhead, let first = contours.first, !first.isClosed,
           let placement = StrokeGeometry.startPlacement(of: first) {
            heads.append(PlacedArrowhead(arrowhead: head, transform: StrokeGeometry.transform(width: width, at: placement.point, direction: placement.direction)))
            contours[0] = StrokeGeometry.trimmingStart(of: first, by: head.pathTrim * width)
        }
        if let head = stroke.endArrowhead, let last = contours.last, !last.isClosed,
           let placement = StrokeGeometry.endPlacement(of: original[original.count - 1]) {
            heads.append(PlacedArrowhead(arrowhead: head, transform: StrokeGeometry.transform(width: width, at: placement.point, direction: placement.direction)))
            contours[contours.count - 1] = StrokeGeometry.trimmingEnd(of: last, by: head.pathTrim * width)
        }
        body = heads.isEmpty ? path : DisplayPath(contours: contours)
        self.heads = heads
    }

    /// scale(width) · rotation(direction) · translation(point).
    static func transform(width: Double, at point: Point, direction: Vector) -> AffineTransform {
        AffineTransform.scale(width)
            .concatenating(.rotation(radians: atan2(direction.dy, direction.dx)))
            .concatenating(.translation(x: point.x, y: point.y))
    }

    /// The start point and the direction pointing back past it (the reversed start tangent of
    /// the first segment that has one).  Nil for a contour with no extent.
    static func startPlacement(of contour: Contour) -> (point: Point, direction: Vector)? {
        guard let segment = contour.segments.first(where: { !$0.isDegenerate }) else {
            return nil
        }
        return (contour.segments[0].p0, -segment.tangent(0))
    }

    /// The end point and the direction the path leaves it in.
    static func endPlacement(of contour: Contour) -> (point: Point, direction: Vector)? {
        guard let segment = contour.segments.last(where: { !$0.isDegenerate }) else {
            return nil
        }
        return (contour.segments[contour.segments.count - 1].p3, segment.tangent(1))
    }

    /// `contour` with `length` of arc removed from its start (GEO-001 arc-length split); an
    /// empty contour when the trim covers it all.
    static func trimmingStart(of contour: Contour, by length: Double) -> Contour {
        guard length > 0 else {
            return contour
        }
        var remaining = length
        var kept: [CubicBezier] = []
        for (index, segment) in contour.segments.enumerated() {
            let segmentLength = segment.length()
            if remaining >= segmentLength {
                remaining -= segmentLength
                continue
            }
            let t = segment.parameter(atLength: remaining)
            kept.append(segment.split(at: t).1)
            kept.append(contentsOf: contour.segments[(index + 1)...])
            break
        }
        return Contour(segments: kept, closed: false)
    }

    /// `contour` with `length` of arc removed from its end.
    static func trimmingEnd(of contour: Contour, by length: Double) -> Contour {
        trimmingStart(of: contour.reversed(), by: length).reversed()
    }
}
