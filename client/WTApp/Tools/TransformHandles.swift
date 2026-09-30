import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The eight handles around a selection, by their place on its bounds.
enum HandleAnchor: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Where on the bounds, 0...1 across and down (y down, as the pasteboard).
    var unit: (x: Double, y: Double) {
        switch self {
        case .topLeft: (0, 0)
        case .top: (0.5, 0)
        case .topRight: (1, 0)
        case .right: (1, 0.5)
        case .bottomRight: (1, 1)
        case .bottom: (0.5, 1)
        case .bottomLeft: (0, 1)
        case .left: (0, 0.5)
        }
    }

    var isCorner: Bool { unit.x != 0.5 && unit.y != 0.5 }
}

/// An edge between two corner handles (the skew zone).
enum HandleEdge: CaseIterable, Sendable {
    case top, right, bottom, left

    var isHorizontal: Bool { self == .top || self == .bottom }
}

/// The handles overlay of the Pointer tool (transforming.adoc, "Transform handles"; OBJ-034):
/// the selection's pasteboard bounds and the transformation centre, the hit zones in screen space
/// -- handles 8 px, the rotate zone 12 px outside a corner handle, the skew zone along the dotted
/// edges, the centre circle, and inside the bounds -- and the matrix each zone's drag makes.
struct TransformHandles: Equatable, Sendable {
    /// What a press at a point would drag.
    enum Zone: Equatable, Sendable {
        case move
        case center
        case scale(HandleAnchor)
        case rotate(HandleAnchor)
        case skew(HandleEdge)
    }

    static let handleSize = 8.0
    static let rotateReach = 12.0
    static let skewReach = 4.0
    static let centerRadius = 5.0
    /// Scale factors never collapse past ±0.01% (transforming.adoc, "Read-time normalization").
    static let minimumScale = 0.0001

    /// The selection's bounds, pasteboard space.
    var bounds: Rect
    /// The centre of rotation, scaling and skewing, pasteboard space.
    var center: Point

    init(bounds: Rect, center: Point? = nil) {
        self.bounds = bounds
        self.center = center ?? bounds.center
    }

    /// A handle's pasteboard point.
    func point(_ anchor: HandleAnchor) -> Point {
        Point(x: bounds.minX + bounds.width * anchor.unit.x, y: bounds.minY + bounds.height * anchor.unit.y)
    }

    /// The handle's opposite (the other end of its diagonal or axis).
    static func opposite(_ anchor: HandleAnchor) -> HandleAnchor {
        let all = HandleAnchor.allCases
        return all[(all.firstIndex(of: anchor)! + 4) % all.count]
    }

    /// The corners an edge runs between.
    static func corners(_ edge: HandleEdge) -> (HandleAnchor, HandleAnchor) {
        switch edge {
        case .top: (.topLeft, .topRight)
        case .right: (.topRight, .bottomRight)
        case .bottom: (.bottomRight, .bottomLeft)
        case .left: (.bottomLeft, .topLeft)
        }
    }

    /// The zone under `viewPoint`, nil outside every zone.
    func zone(at viewPoint: Point, viewport: Viewport) -> Zone? {
        let toView = viewport.pasteboardToView
        if toView.apply(center).distance(to: viewPoint) <= Self.centerRadius { return .center }
        let half = Self.handleSize / 2
        for anchor in HandleAnchor.allCases {
            let handle = toView.apply(point(anchor))
            if abs(handle.x - viewPoint.x) <= half, abs(handle.y - viewPoint.y) <= half { return .scale(anchor) }
        }
        let inside = viewport.toPasteboard(viewPoint)
        let contained = bounds.contains(inside)
        for anchor in HandleAnchor.allCases where anchor.isCorner && !contained {
            let distance = toView.apply(point(anchor)).distance(to: viewPoint)
            if distance <= half + Self.rotateReach { return .rotate(anchor) }
        }
        for edge in HandleEdge.allCases {
            let (a, b) = Self.corners(edge)
            if Self.distance(from: viewPoint, toSegment: toView.apply(point(a)), toView.apply(point(b))) <= Self.skewReach { return .skew(edge) }
        }
        return contained ? .move : nil
    }

    static func distance(from p: Point, toSegment a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return p.distance(to: a) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / length, 0), 1)
        return p.distance(to: Point(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// The matrix (about the origin; the centre is applied by the command) of a drag of `zone`
    /// from `start` to `current` (pasteboard points); `constrained` is kbd:[Shift].  Nil for a
    /// drag that makes no transformation (the centre, or no movement yet).
    func matrix(_ zone: Zone, from start: Point, to current: Point, constrained: Bool, constraint: AngleConstraint) -> WTGeometry.AffineTransform? {
        let from = start - center, to = current - center
        switch zone {
        case .center:
            return nil
        case .move:
            let delta = current - start
            return .translation(constrained ? constraint.constrain(delta) : delta)
        case .scale(let anchor):
            func factor(_ a: Double, _ b: Double) -> Double {
                guard abs(a) > 1e-9 else { return 1 }
                let value = b / a
                return abs(value) < Self.minimumScale ? (value < 0 ? -Self.minimumScale : Self.minimumScale) : value
            }
            var sx = anchor.unit.x == 0.5 ? 1 : factor(from.dx, to.dx)
            var sy = anchor.unit.y == 0.5 ? 1 : factor(from.dy, to.dy)
            if constrained {
                let uniform = anchor.isCorner ? max(abs(sx), abs(sy)) : (anchor.unit.x == 0.5 ? abs(sy) : abs(sx))
                sx = uniform * (sx < 0 ? -1 : 1)
                sy = uniform * (sy < 0 ? -1 : 1)
            }
            return .scale(x: sx, y: sy)
        case .rotate:
            var angle = to.angle - from.angle
            if constrained { angle = constraint.snappedRotation(angle) }
            return .rotation(radians: angle)
        case .skew(let edge):
            if edge.isHorizontal {
                guard abs(from.dy) > 1e-9 else { return nil }
                return .shear(x: (to.dx - from.dx) / from.dy, y: 0)
            }
            guard abs(from.dx) > 1e-9 else { return nil }
            return .shear(x: 0, y: (to.dy - from.dy) / from.dx)
        }
    }

    /// The command kind a zone's drag performs.
    static func kind(_ zone: Zone) -> TransformKind {
        switch zone {
        case .move, .center: .move
        case .scale: .scale
        case .rotate: .rotate
        case .skew: .skew
        }
    }

    /// The bounds of the selection the handles surround: the selected points when points are
    /// selected, else the selected objects' geometry.
    @MainActor
    static func bounds(of selection: Selection, document: DocumentHandle) -> Rect? {
        var points: [Point] = []
        for id in selection.ids {
            guard case .points(let references)? = selection.subSelection(of: id), let object = document.object(for: id), let path = object.path else { continue }
            for contour in path.contours {
                for point in contour.points where references.contains(PointReference(node: id.node, contour: contour.id, point: point.id)) {
                    points.append(object.transform.apply(point.anchor))
                }
            }
        }
        if let first = points.first {
            return points.dropFirst().reduce(Rect(x: first.x, y: first.y, width: 0, height: 0)) { $0.union(Rect(x: $1.x, y: $1.y, width: 0, height: 0)) }
        }
        let state = document.state
        let rects = selection.ids.compactMap { Objects.bounds(of: $0.opID, in: state) }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// The one change a drag makes (one per gesture): the selected points of each path, or the
    /// objects -- with kbd:[Option] a transformed copy.
    @MainActor
    static func command(_ zone: Zone, matrix: WTGeometry.AffineTransform, about center: Point, selection: Selection, copy: Bool,
                        options: TransformOptions = TransformOptions()) -> (any WTModel.Command)? {
        guard matrix.isInvertible else { return nil }
        let kind = kind(zone)
        let about: Point? = kind == .move ? nil : center
        var pointCommands: [any WTModel.Command] = []
        for id in selection.ids {
            if case .points(let points)? = selection.subSelection(of: id), !points.isEmpty {
                pointCommands.append(TransformPoints(node: id.opID, points: points.sorted().map { ($0.contour, $0.point) }, matrix: matrix, about: about ?? center, kind: kind))
            }
        }
        if !pointCommands.isEmpty { return CommandBatch(pointCommands[0].label, pointCommands) }
        let nodes = selection.ids.map(\.opID)
        guard !nodes.isEmpty else { return nil }
        return TransformObjects(nodes, matrix: matrix, about: about, kind: kind, options: options, copies: copy ? 1 : 0)
    }

    /// The cursor a zone shows (the plus sign while kbd:[Option] copies).
    static func cursor(_ zone: Zone?, copying: Bool) -> NSCursor {
        if copying, zone != nil, zone != .center { return .dragCopy }
        switch zone {
        case .move?: return .openHand
        case .center?: return .pointingHand
        case .scale(let anchor)?: return anchor.unit.x == 0.5 ? .resizeUpDown : (anchor.unit.y == 0.5 ? .resizeLeftRight : .crosshair)
        case .rotate?: return .crosshair
        case .skew(let edge)?: return edge.isHorizontal ? .resizeLeftRight : .resizeUpDown
        case nil: return .arrow
        }
    }

    // MARK: Drawing

    /// Draws the dotted edges, the eight handles and the centre, in view points.
    func draw(in ctx: CGContext, viewport: Viewport, color: CGColor) {
        let toView = viewport.pasteboardToView
        let corners = [HandleAnchor.topLeft, .topRight, .bottomRight, .bottomLeft].map { toView.apply(point($0)).cgPoint }
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [2, 2])
        ctx.addLines(between: corners + [corners[0]])
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        let half = Self.handleSize / 2
        for anchor in HandleAnchor.allCases {
            let p = toView.apply(point(anchor))
            let rect = CGRect(x: p.x - half, y: p.y - half, width: Self.handleSize, height: Self.handleSize)
            ctx.setFillColor(CGColor.white)
            ctx.fill(rect)
            ctx.stroke(rect)
        }
        let c = toView.apply(center)
        ctx.strokeEllipse(in: CGRect(x: c.x - Self.centerRadius, y: c.y - Self.centerRadius, width: 2 * Self.centerRadius, height: 2 * Self.centerRadius))
        ctx.restoreGState()
    }
}
