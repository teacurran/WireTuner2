// Connector lines (DRAW-035, DRAW-037; docs/_includes/drawing/connectors.adoc).  A connector's
// geometry is never stored: it is derived on read from its two ends and the rendered bounds of
// the objects they are attached to, so a remote move of a connected object reroutes it with
// no connector op.  An attached end sits at the midpoint of the chosen side of the node's
// painted bounds (transform and stroke widths included -- the display list's item bounds); a
// dangling or free end sits at its stored point.  The router joins the ends straight, with
// right-angle bends (the classic flowchart elbow: a 12 pt stub off each side, then one or two
// bends, no obstacle avoidance) or with one cubic curve; `run_offsets` slide the orthogonal
// route's intermediate runs sideways.  The route is stroked by the connector's own strokes
// (arrowheads, widths and dashes from REND-002), and `DependencyIndex` makes a change to an
// attached node repaint the connector.

import WTGeometry

/// `Side`: which side of the attached object an end leaves from.
public enum ConnectorSide: Hashable, Sendable, CaseIterable {
    case top
    case bottom
    case left
    case right

    /// The outward unit normal, y down.
    public var normal: Vector {
        switch self {
        case .top: return Vector(0, -1)
        case .bottom: return Vector(0, 1)
        case .left: return Vector(-1, 0)
        case .right: return Vector(1, 0)
        }
    }

    /// The midpoint of this side of `rect`.
    public func midpoint(of rect: Rect) -> Point {
        switch self {
        case .top: return Point(x: rect.midX, y: rect.minY)
        case .bottom: return Point(x: rect.midX, y: rect.maxY)
        case .left: return Point(x: rect.minX, y: rect.midY)
        case .right: return Point(x: rect.maxX, y: rect.midY)
        }
    }

    /// The side of `rect` facing `point` most directly.
    public static func facing(_ point: Point, from rect: Rect) -> ConnectorSide {
        let dx = (point.x - rect.midX) / max(rect.width, 1e-9)
        let dy = (point.y - rect.midY) / max(rect.height, 1e-9)
        if abs(dx) >= abs(dy) {
            return dx >= 0 ? .right : .left
        }
        return dy >= 0 ? .bottom : .top
    }

    var isHorizontal: Bool { self == .left || self == .right }
}

/// How a connector is routed.
public enum ConnectorRouting: Hashable, Sendable {
    case straight
    /// Right-angle bends (the connector tool's default).
    case orthogonal
    case curved
}

/// One end of a connector (`ConnectorEnd`).
public struct ConnectorEnd: Hashable, Sendable {
    /// The attached object; nil for a free end.
    public var node: NodeID?
    /// The side it leaves from; nil picks the side facing the other end.
    public var side: ConnectorSide?
    /// The free position, and the fallback when `node` dangles.
    public var point: Point

    public init(node: NodeID? = nil, side: ConnectorSide? = nil, point: Point) {
        self.node = node
        self.side = side
        self.point = point
    }
}

/// A connector as WTModel reads it (`ConnectorProps`).
public struct ConnectorSpec: Hashable, Sendable {
    public var id: NodeID
    public var start: ConnectorEnd
    public var end: ConnectorEnd
    public var routing: ConnectorRouting
    /// Sideways offsets of the orthogonal route's intermediate runs, in route order; read as
    /// automatic when the count differs from the route's.
    public var runOffsets: [Double]
    /// The connector's strokes (fills are ignored).
    public var appearance: Appearance

    public init(id: NodeID, start: ConnectorEnd, end: ConnectorEnd, routing: ConnectorRouting = .orthogonal, runOffsets: [Double] = [], appearance: Appearance = Appearance([.stroke(StrokePaint(paint: .solid(.black)))])) {
        self.id = id
        self.start = start
        self.end = end
        self.routing = routing
        self.runOffsets = runOffsets
        self.appearance = appearance
    }

    /// The reverse index entries: the connector depends on each attached node.
    public func addDependencies(to index: inout DependencyIndex) {
        for node in [start.node, end.node].compactMap({ $0 }) {
            index.add(id, dependsOn: node)
        }
    }
}

/// A connector's derived geometry.
public struct ConnectorRoute: Hashable, Sendable {
    /// The route's corner points (orthogonal, straight) or its two ends (curved).
    public var points: [Point]
    /// The drawn path.
    public var path: DisplayPath
    /// The side each end leaves from, when attached (or free with a chosen direction).
    public var startSide: ConnectorSide?
    public var endSide: ConnectorSide?
    /// How many intermediate runs `run_offsets` addresses.
    public var runCount: Int
    /// Whether `run_offsets` applied (its count matched).
    public var offsetsApplied: Bool
}

public enum ConnectorRouter {
    /// The stub that leaves each attached side before the first bend.
    public static let stub = 12.0

    /// The route of `spec`, with `bounds` giving each attached node's rendered bounds (nil for
    /// a node that dangles, which reads as a free end at its point).
    public static func route(_ spec: ConnectorSpec, bounds: (NodeID) -> Rect?) -> ConnectorRoute {
        let startRect = spec.start.node.flatMap(bounds)
        let endRect = spec.end.node.flatMap(bounds)
        let startTarget = endRect.map { Point(x: $0.midX, y: $0.midY) } ?? spec.end.point
        let endTarget = startRect.map { Point(x: $0.midX, y: $0.midY) } ?? spec.start.point
        let startSide = startRect.map { spec.start.side ?? ConnectorSide.facing(startTarget, from: $0) }
        let endSide = endRect.map { spec.end.side ?? ConnectorSide.facing(endTarget, from: $0) }
        let startPoint = startRect.map { startSide!.midpoint(of: $0) } ?? spec.start.point
        let endPoint = endRect.map { endSide!.midpoint(of: $0) } ?? spec.end.point
        // Both ends on one node's same side: a short stub outside it.
        if let startNode = spec.start.node, startRect != nil, startNode == spec.end.node, let side = startSide, side == endSide {
            let tip = startPoint + side.normal * stub
            return ConnectorRoute(points: [startPoint, tip], path: DisplayPath(polygon: [startPoint, tip], closed: false), startSide: side, endSide: side, runCount: 0, offsetsApplied: false)
        }
        switch spec.routing {
        case .straight:
            return ConnectorRoute(points: [startPoint, endPoint], path: DisplayPath(polygon: [startPoint, endPoint], closed: false), startSide: startSide, endSide: endSide, runCount: 0, offsetsApplied: false)
        case .curved:
            return curved(from: startPoint, startSide, to: endPoint, endSide)
        case .orthogonal:
            var points = orthogonal(from: startPoint, startSide: startSide, to: endPoint, endSide: endSide)
            let runs = max(points.count - 3, 0)
            let applies = !spec.runOffsets.isEmpty && spec.runOffsets.count == runs
            if applies {
                points = offsetting(points, by: spec.runOffsets)
            }
            return ConnectorRoute(points: points, path: DisplayPath(polygon: points, closed: false), startSide: startSide, endSide: endSide, runCount: runs, offsetsApplied: applies)
        }
    }

    /// The orthogonal route's corners from `start` to `end`: each attached end leaves its side
    /// by the stub; the stubs' tips are joined with one or two bends chosen by the ends'
    /// relative position.  A free end has no stub and takes the direction the route arrives
    /// in.  Collinear corners are merged.
    public static func orthogonal(from start: Point, startSide: ConnectorSide?, to end: Point, endSide: ConnectorSide?) -> [Point] {
        let p1 = startSide.map { start + $0.normal * stub } ?? start
        let p2 = endSide.map { end + $0.normal * stub } ?? end
        var middle: [Point]
        let horizontalStart = startSide?.isHorizontal ?? (abs(p2.x - p1.x) >= abs(p2.y - p1.y))
        let horizontalEnd = endSide?.isHorizontal ?? horizontalStart
        switch (horizontalStart, horizontalEnd) {
        case (true, true):
            middle = sameAxis(p1, p2, startDirection: startSide?.normal.dx ?? (p2.x >= p1.x ? 1 : -1), endDirection: endSide?.normal.dx ?? (p1.x >= p2.x ? 1 : -1), horizontal: true)
        case (false, false):
            middle = sameAxis(p1, p2, startDirection: startSide?.normal.dy ?? (p2.y >= p1.y ? 1 : -1), endDirection: endSide?.normal.dy ?? (p1.y >= p2.y ? 1 : -1), horizontal: false)
        case (true, false):
            let corner = Point(x: p2.x, y: p1.y)
            let ahead = (corner.x - p1.x) * (startSide?.normal.dx ?? 1) >= 0
            let entering = (p2.y - corner.y) * -(endSide?.normal.dy ?? -1) >= 0 || endSide == nil
            middle = ahead && entering ? [corner] : [Point(x: (p1.x + p2.x) / 2, y: p1.y), Point(x: (p1.x + p2.x) / 2, y: p2.y)]
        case (false, true):
            let corner = Point(x: p1.x, y: p2.y)
            let ahead = (corner.y - p1.y) * (startSide?.normal.dy ?? 1) >= 0
            let entering = (p2.x - corner.x) * -(endSide?.normal.dx ?? -1) >= 0 || endSide == nil
            middle = ahead && entering ? [corner] : [Point(x: p1.x, y: (p1.y + p2.y) / 2), Point(x: p2.x, y: (p1.y + p2.y) / 2)]
        }
        return simplified([start, p1] + middle + [p2, end])
    }

    /// Joins two stub tips whose stubs run along the same axis (`horizontal`: x).  Facing
    /// each other with room between: a run across the middle.  Facing the same way: a run
    /// beyond the further tip.  Facing away (or overlapping): around through the middle of
    /// the other axis.
    static func sameAxis(_ p1: Point, _ p2: Point, startDirection: Double, endDirection: Double, horizontal: Bool) -> [Point] {
        func along(_ p: Point) -> Double { horizontal ? p.x : p.y }
        func across(_ p: Point) -> Double { horizontal ? p.y : p.x }
        func make(_ a: Double, _ c: Double) -> Point { horizontal ? Point(x: a, y: c) : Point(x: c, y: a) }
        if startDirection == endDirection {
            let beyond = startDirection > 0 ? max(along(p1), along(p2)) : min(along(p1), along(p2))
            return [make(beyond, across(p1)), make(beyond, across(p2))]
        }
        let gap = (along(p2) - along(p1)) * startDirection
        if gap >= 0 {
            let mid = (along(p1) + along(p2)) / 2
            return [make(mid, across(p1)), make(mid, across(p2))]
        }
        let mid = (across(p1) + across(p2)) / 2
        return [make(along(p1), mid), make(along(p2), mid)]
    }

    /// `points` with repeated points and collinear middle points removed.
    static func simplified(_ points: [Point]) -> [Point] {
        var result: [Point] = []
        for point in points {
            if let last = result.last, last.distance(to: point) < 1e-9 {
                continue
            }
            if result.count >= 2 {
                let a = result[result.count - 2], b = result[result.count - 1]
                if abs((b - a).cross(point - b)) < 1e-9, (b - a).dot(point - b) >= 0 {
                    result[result.count - 1] = point
                    continue
                }
            }
            result.append(point)
        }
        return result
    }

    /// The route with intermediate run `i` (segment `i + 1`) moved sideways by `offsets[i]`
    /// along its normal (right of its direction); neighbouring runs stretch to stay joined.
    static func offsetting(_ points: [Point], by offsets: [Double]) -> [Point] {
        var result = points
        for (run, offset) in offsets.enumerated() {
            let a = run + 1, b = run + 2
            let direction = points[b] - points[a]
            let length = direction.length
            guard length > 0 else { continue }
            let normal = Vector(-direction.dy / length, direction.dx / length)
            result[a] = result[a] + normal * offset
            result[b] = result[b] + normal * offset
        }
        return result
    }

    /// One cubic from `start` to `end`, leaving each attached side along its normal (a free end
    /// toward the other end), handles half the distance long.
    static func curved(from start: Point, _ startSide: ConnectorSide?, to end: Point, _ endSide: ConnectorSide?) -> ConnectorRoute {
        let reach = max(start.distance(to: end) / 2, stub)
        let towardEnd = (end - start).length > 0 ? (end - start) * (1 / (end - start).length) : Vector(1, 0)
        let c1 = start + (startSide?.normal ?? towardEnd) * reach
        let c2 = end + (endSide?.normal ?? towardEnd * -1) * reach
        var path = DisplayPath()
        path.move(to: start)
        path.addCubicCurve(control1: c1, control2: c2, to: end)
        return ConnectorRoute(points: [start, end], path: path, startSide: startSide, endSide: endSide, runCount: 0, offsetsApplied: false)
    }
}

public enum ConnectorRendering {
    /// The connector drawn through the stroke pipeline: its route stroked by its strokes
    /// (arrowheads included), fills dropped.
    public static func item(_ spec: ConnectorSpec, route: ConnectorRoute) -> DisplayItem {
        let strokes = spec.appearance.items.filter { if case .stroke = $0 { return true } else { return false } }
        return .path(PathItem(path: route.path, appearance: Appearance(strokes), transform: .identity))
    }

    /// The connector of `spec` against the display list its nodes are drawn in.
    public static func item(_ spec: ConnectorSpec, in displayList: DisplayList) -> DisplayItem {
        item(spec, route: ConnectorRouter.route(spec, bounds: { attachmentBounds(of: $0, in: displayList) }))
    }

    /// The rendered bounds an end attaches to: the item's geometry grown by half its widest
    /// stroke (the painted edge), not the conservative culling bounds, which allow for miters.
    public static func attachmentBounds(of node: NodeID, in displayList: DisplayList) -> Rect? {
        guard let index = displayList.index(of: node), let own = displayList.items[index].ownBounds else {
            return nil
        }
        guard case .path(let path) = displayList.items[index], let widest = path.appearance.widestStroke, !widest.style.isHairline else {
            return own
        }
        return own.expanded(by: widest.style.width / 2 * path.transform.scaleFactor)
    }

    /// A selection outline (or a remote collaborator's selection tint) along the route, for
    /// the overlay: `width` view pixels in `color` under `viewport`.
    public static func selectionOutline(_ route: ConnectorRoute, color: Color, width: Double = 1, viewport: Viewport) -> DisplayItem {
        .path(PathItem(
            path: route.path,
            appearance: Appearance([.stroke(StrokePaint(paint: .solid(color), style: StrokeStyle(width: width / max(viewport.zoom, 1e-9), cap: .round, join: .round)))])
        ))
    }
}
