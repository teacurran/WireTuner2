import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// An object a connector end can attach to under the pointer (connectors.adoc, "Drawing a
/// connector"): the object, its rendered bounds (what an end sits on) and the side whose edge is
/// nearest the pointer, which the Connector tool highlights.
struct ConnectorTarget: Equatable {
    let node: OpID
    /// The object's rendered bounds, pasteboard space (`Connectors.attachmentBounds`).
    let bounds: Rect
    let side: ConnectorSide

    /// Where an end attached here sits: the midpoint of the side.
    var point: Point { side.midpoint(of: bounds) }

    /// The end the tool writes: node, side and point together (the point is the free position
    /// should the object be deleted).
    var end: ConnectorEnd { ConnectorEnd(node: NodeID(node), side: side, point: point) }

    /// The highlighted side's edge, pasteboard space.
    var edge: (Point, Point) {
        switch side {
        case .top: (Point(x: bounds.minX, y: bounds.minY), Point(x: bounds.maxX, y: bounds.minY))
        case .bottom: (Point(x: bounds.minX, y: bounds.maxY), Point(x: bounds.maxX, y: bounds.maxY))
        case .left: (Point(x: bounds.minX, y: bounds.minY), Point(x: bounds.minX, y: bounds.maxY))
        case .right: (Point(x: bounds.maxX, y: bounds.minY), Point(x: bounds.maxX, y: bounds.maxY))
        }
    }

    /// The side of `bounds` whose edge is nearest `point` (ties: top, bottom, left, right).
    static func nearestSide(to point: Point, of bounds: Rect) -> ConnectorSide {
        let distances: [(side: ConnectorSide, distance: Double)] = [
            (.top, abs(point.y - bounds.minY)), (.bottom, abs(point.y - bounds.maxY)),
            (.left, abs(point.x - bounds.minX)), (.right, abs(point.x - bounds.maxX)),
        ]
        return distances.min { $0.distance < $1.distance }!.side
    }

    /// The top-most object an end may attach to (`Connectors.isAttachable`: not a connector, a
    /// guide or anything deleted) whose rendered bounds, grown by `tolerance` (pasteboard units),
    /// contain `point`.  An object is hovered anywhere over its box, filled or not, so an outlined
    /// flowchart box connects as readily as a filled one.
    @MainActor
    static func find(at point: Point, tolerance: Double, in document: DocumentHandle) -> ConnectorTarget? {
        let scene = document.scene
        let state = document.state
        var layers: LayerOrder?
        for id in document.selectableIDs().reversed() {
            guard let object = scene.objects[id.node], object.bounds?.expanded(by: tolerance).contains(point) == true,
                  let bounds = Connectors.attachmentBounds(of: object.item), bounds.expanded(by: tolerance).contains(point) else { continue }
            let order = layers ?? LayerOrder(state)
            layers = order
            guard Connectors.isAttachable(id.opID, in: state, layers: order) else { continue }
            return ConnectorTarget(node: id.opID, bounds: bounds, side: nearestSide(to: point, of: bounds))
        }
        return nil
    }
}

/// The handles the Connector tool shows on a selected connector (connectors.adoc, "To move a
/// connector's end" and "To reshape a connector by hand"): one on each end, and one at the middle
/// of each intermediate straight run -- the route's segments other than the first and last, which
/// `run_offsets` addresses in route order.
struct ConnectorHandles: Equatable {
    enum Handle: Hashable {
        case end(ConnectorEndName)
        case run(Int)
    }

    let node: OpID
    /// The connector's route as drawn, pasteboard space.
    let route: ConnectorRoute
    /// The offsets a run drag starts from: the stored ones while the route uses them, else zero
    /// for every run (the automatic route).
    let baseOffsets: [Double]

    init(node: OpID, route: ConnectorRoute, storedOffsets: [Double]) {
        self.node = node
        self.route = route
        baseOffsets = route.offsetsApplied ? storedOffsets : Array(repeating: 0, count: route.runCount)
    }

    /// The handles of connector `node` as `document` draws it; nil when it is not a drawn connector.
    @MainActor
    static func make(_ node: OpID, in document: DocumentHandle) -> ConnectorHandles? {
        let state = document.state
        guard let route = Connectors.route(node, in: state, scene: document.scene) else { return nil }
        return ConnectorHandles(node: node, route: route, storedOffsets: Connectors.props(node, in: state).runOffsets)
    }

    /// Every handle: the two ends, then the runs in route order.
    var handles: [Handle] {
        [.end(.start), .end(.end)] + (0..<runCount).map(Handle.run)
    }

    /// How many runs have a handle (the route's intermediate runs).
    var runCount: Int { route.runCount }

    /// Run `index`'s segment, start to end.
    func run(_ index: Int) -> (Point, Point) {
        (route.points[index + 1], route.points[index + 2])
    }

    /// The unit normal a positive offset moves run `index` along: to the right of its direction
    /// (y down), as `ConnectorRouter` applies it.
    func normal(ofRun index: Int) -> Vector {
        let (a, b) = run(index)
        let direction = b - a
        let length = direction.length
        guard length > 0 else { return Vector(0, 0) }
        return Vector(-direction.dy / length, direction.dx / length)
    }

    /// Where `handle` sits, pasteboard space.
    func position(_ handle: Handle) -> Point {
        switch handle {
        case .end(.start): return route.points.first ?? .zero
        case .end(.end): return route.points.last ?? .zero
        case .run(let index):
            let (a, b) = run(index)
            return Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
    }

    /// The handle within `radius` view points of `viewPoint`, ends before runs.
    func handle(at viewPoint: Point, viewport: Viewport, radius: Double) -> Handle? {
        handles.first { viewport.toView(position($0)).distance(to: viewPoint) <= radius }
    }

    /// The whole `run_offsets` list after dragging run `index` by `delta` (pasteboard space): the
    /// drag's component along the run's normal is added to that run's offset.
    func offsets(draggingRun index: Int, by delta: Vector) -> [Double] {
        var offsets = baseOffsets
        offsets[index] += delta.dot(normal(ofRun: index))
        return offsets
    }
}
