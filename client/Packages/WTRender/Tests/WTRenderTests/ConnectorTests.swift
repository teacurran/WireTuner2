import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// DRAW-035 and DRAW-037: connector routing, rendering and invalidation.
@Suite struct ConnectorTests {
    static let a = NodeID(counter: 1, replica: 9)
    static let b = NodeID(counter: 2, replica: 9)
    static let connectorID = NodeID(counter: 3, replica: 9)
    static let rects: [NodeID: Rect] = [
        a: Rect(x: 0, y: 0, width: 40, height: 30),
        b: Rect(x: 120, y: 90, width: 40, height: 30),
    ]

    static func spec(_ startSide: ConnectorSide?, _ endSide: ConnectorSide?, routing: ConnectorRouting = .orthogonal, offsets: [Double] = []) -> ConnectorSpec {
        ConnectorSpec(id: connectorID, start: ConnectorEnd(node: a, side: startSide, point: Point(x: -5, y: -5)), end: ConnectorEnd(node: b, side: endSide, point: Point(x: 500, y: 500)), routing: routing, runOffsets: offsets)
    }

    static func route(_ spec: ConnectorSpec, rects: [NodeID: Rect] = rects) -> ConnectorRoute {
        ConnectorRouter.route(spec, bounds: { rects[$0] })
    }

    static func isOrthogonal(_ points: [Point]) -> Bool {
        zip(points, points.dropFirst()).allSatisfy { abs($0.x - $1.x) < 1e-9 || abs($0.y - $1.y) < 1e-9 }
    }

    /// All 16 side pairs: the route is orthogonal, starts and ends at the side midpoints, leaves
    /// along the start side's normal and arrives against the end side's.
    @Test(arguments: ConnectorSide.allCases)
    func everySidePairRoutesOrthogonally(start: ConnectorSide) {
        for end in ConnectorSide.allCases {
            for (first, second) in [(Self.rects[Self.a]!, Self.rects[Self.b]!), (Self.rects[Self.b]!, Self.rects[Self.a]!), (Rect(x: 0, y: 0, width: 40, height: 30), Rect(x: 10, y: 45, width: 40, height: 30))] {
                let route = Self.route(Self.spec(start, end), rects: [Self.a: first, Self.b: second])
                let points = route.points
                #expect(Self.isOrthogonal(points), "\(start)→\(end): \(points)")
                #expect(approx(points.first!, start.midpoint(of: first)))
                #expect(approx(points.last!, end.midpoint(of: second)))
                let leaving = points[1] - points[0]
                #expect(leaving.dot(start.normal) > 0, "\(start)→\(end) leaves along its side")
                let arriving = points[points.count - 1] - points[points.count - 2]
                #expect(arriving.dot(end.normal) < 0, "\(start)→\(end) arrives against its side")
                #expect(route.runCount == max(points.count - 3, 0))
                #expect(!route.path.isEmpty)
            }
        }
    }

    @Test func freeEndsRouteBetweenTheirPoints() {
        let spec = ConnectorSpec(id: Self.connectorID, start: ConnectorEnd(point: Point(x: 0, y: 0)), end: ConnectorEnd(point: Point(x: 50, y: 20)))
        let route = Self.route(spec)
        #expect(route.points.first == Point(x: 0, y: 0) && route.points.last == Point(x: 50, y: 20))
        #expect(Self.isOrthogonal(route.points))
        #expect(route.startSide == nil && route.endSide == nil)
        let tall = Self.route(ConnectorSpec(id: Self.connectorID, start: ConnectorEnd(point: Point(x: 0, y: 0)), end: ConnectorEnd(point: Point(x: 10, y: 80))))
        #expect(Self.isOrthogonal(tall.points))
        let back = Self.route(ConnectorSpec(id: Self.connectorID, start: ConnectorEnd(point: Point(x: 50, y: 80)), end: ConnectorEnd(point: Point(x: 0, y: 0))))
        #expect(Self.isOrthogonal(back.points))
        // One attached end, one free: the attached end picks the side facing the free point.
        let half = Self.route(ConnectorSpec(id: Self.connectorID, start: ConnectorEnd(node: Self.a, point: .zero), end: ConnectorEnd(point: Point(x: 200, y: 15))))
        #expect(half.startSide == .right)
        #expect(Self.isOrthogonal(half.points))
        let halfVertical = Self.route(ConnectorSpec(id: Self.connectorID, start: ConnectorEnd(point: Point(x: 20, y: 200)), end: ConnectorEnd(node: Self.a, side: .bottom, point: .zero)))
        #expect(Self.isOrthogonal(halfVertical.points))
    }

    @Test func automaticSidesFaceTheOtherEnd() {
        let rect = Rect(x: 0, y: 0, width: 10, height: 10)
        #expect(ConnectorSide.facing(Point(x: 50, y: 5), from: rect) == .right)
        #expect(ConnectorSide.facing(Point(x: -50, y: 5), from: rect) == .left)
        #expect(ConnectorSide.facing(Point(x: 5, y: 50), from: rect) == .bottom)
        #expect(ConnectorSide.facing(Point(x: 5, y: -50), from: rect) == .top)
        let route = Self.route(Self.spec(nil, nil))
        #expect(route.startSide == .right && route.endSide == .left)
    }

    @Test func runOffsetsSlideTheirRunAndFallBackOnMismatch() {
        let automatic = Self.route(Self.spec(.right, .left))
        #expect(automatic.runCount == 1)
        let slid = Self.route(Self.spec(.right, .left, offsets: [10]))
        #expect(slid.offsetsApplied)
        #expect(Self.isOrthogonal(slid.points))
        // The one intermediate run is the vertical middle run: it moves 10 pt sideways.
        let before = automatic.points[2].x, after = slid.points[2].x
        #expect(abs(abs(after - before) - 10) < 1e-9)
        #expect(slid.points[1].y == automatic.points[1].y)
        let mismatch = Self.route(Self.spec(.right, .left, offsets: [10, 5]))
        #expect(!mismatch.offsetsApplied && mismatch.points == automatic.points)
        #expect(ConnectorRouter.offsetting([.zero, .zero, .zero, Point(x: 1, y: 0)], by: [3]) == [.zero, .zero, .zero, Point(x: 1, y: 0)], "a zero-length run stays")
    }

    @Test func danglingNodesReadAsFreeEndsAtTheirPoints() {
        let route = Self.route(Self.spec(.right, .left), rects: [Self.a: Self.rects[Self.a]!])
        #expect(route.points.last == Point(x: 500, y: 500))
        #expect(route.endSide == nil)
        let neither = Self.route(Self.spec(.right, .left), rects: [:])
        #expect(neither.points.first == Point(x: -5, y: -5) && neither.points.last == Point(x: 500, y: 500))
    }

    @Test func bothEndsOnOneNodeLoopOrStub() {
        let same = ConnectorSpec(id: Self.connectorID, start: ConnectorEnd(node: Self.a, side: .top, point: .zero), end: ConnectorEnd(node: Self.a, side: .top, point: .zero))
        let stub = Self.route(same)
        #expect(stub.points == [Point(x: 20, y: 0), Point(x: 20, y: -ConnectorRouter.stub)])
        let loop = Self.route(ConnectorSpec(id: Self.connectorID, start: ConnectorEnd(node: Self.a, side: .top, point: .zero), end: ConnectorEnd(node: Self.a, side: .right, point: .zero)))
        #expect(Self.isOrthogonal(loop.points))
        #expect(loop.points.count >= 3)
    }

    @Test func straightAndCurvedRoutes() {
        let straight = Self.route(Self.spec(.right, .left, routing: .straight))
        #expect(straight.points == [Point(x: 40, y: 15), Point(x: 120, y: 105)])
        let curved = Self.route(Self.spec(.bottom, .top, routing: .curved))
        #expect(curved.path.elements.count == 2)
        let free = Self.route(ConnectorSpec(id: Self.connectorID, start: ConnectorEnd(point: Point(x: 5, y: 5)), end: ConnectorEnd(point: Point(x: 5, y: 5)), routing: .curved))
        #expect(!free.path.isEmpty)
        #expect(ConnectorRouter.simplified([.zero, .zero, Point(x: 1, y: 0), Point(x: 2, y: 0), Point(x: 2, y: 3)]) == [.zero, Point(x: 2, y: 0), Point(x: 2, y: 3)])
    }

    // MARK: Rendering

    @Test func connectorsStrokeTheirRouteWithArrowheads() throws {
        let arrow = Appearance([
            .fill(FillPaint(paint: .solid(.black))),
            .stroke(StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 2), endArrowhead: .triangle)),
        ])
        var spec = Self.spec(.right, .left)
        spec.appearance = arrow
        var builder = DisplayListBuilder(canvas: "c")
        for (node, rect) in Self.rects.sorted(by: { $0.key < $1.key }) {
            builder.add(.path(PathItem(path: DisplayPath(rect: rect), appearance: Appearance([.fill(FillPaint(paint: .solid(.white)))]))), node: node)
        }
        let nodes = builder.build()
        let item = ConnectorRendering.item(spec, in: nodes)
        guard case .path(let path) = item else {
            Issue.record("a connector is a path")
            return
        }
        #expect(path.appearance.fills.isEmpty, "fills are ignored")
        #expect(path.appearance.strokes.first?.hasArrowheads == true)
        let outline = ConnectorRendering.selectionOutline(Self.route(spec), color: .black, width: 2, viewport: Viewport(zoom: 2, size: Size(width: 10, height: 10)))
        guard case .path(let selection) = outline else { return }
        #expect(selection.appearance.strokes.first?.style.width == 1)
        #expect(ConnectorSpec(id: Self.connectorID, start: ConnectorEnd(point: .zero), end: ConnectorEnd(point: .zero)).appearance.strokes.count == 1)
    }

    /// A remote transform change to a connected node repaints the node's and the connector's
    /// tiles; deleting it leaves the connector at the fallback point; restoring reconnects.
    @Test func referencedNodeChangesRepaintTheConnector() throws {
        var index = DependencyIndex()
        let spec = Self.spec(.right, .left)
        spec.addDependencies(to: &index)
        func list(_ rects: [NodeID: Rect]) -> DisplayList {
            var builder = DisplayListBuilder(canvas: "c")
            for (node, rect) in rects.sorted(by: { $0.key < $1.key }) {
                builder.add(.path(PathItem(path: DisplayPath(rect: rect), appearance: Appearance([.fill(FillPaint(paint: .solid(.black)))]))), node: node)
            }
            let nodes = builder.build()
            return DisplayList(canvas: "c", items: nodes.items + [ConnectorRendering.item(spec, in: nodes)], nodeIDs: nodes.nodeIDs + [Self.connectorID])
        }
        let before = list(Self.rects)
        var moved = Self.rects
        moved[Self.b] = Rect(x: 120, y: 200, width: 40, height: 30)
        let after = list(moved)
        var summary = ChangeSummary(origin: .remote)
        summary.record(Self.b, old: NodeBounds(canvas: "c", rect: Self.rects[Self.b]!), new: NodeBounds(canvas: "c", rect: moved[Self.b]!))
        let expanded = summary.touchingDependents(in: index)
        #expect(expanded.touchedNodes == [Self.b, Self.connectorID])
        let region = InvalidationMapper().dirtyRegion(for: expanded, before: [before], after: [after])
        let rects = region.rects(for: "c")
        #expect(rects.contains { $0.contains(before.bounds(of: Self.connectorID)!) || $0.intersects(before.bounds(of: Self.connectorID)!) })
        #expect(!rects.contains { $0.intersects(Self.rects[Self.a]!.insetBy(dx: 2, dy: 2)) && !$0.intersects(before.bounds(of: Self.connectorID)!) }, "the untouched node is not repainted on its own")
        // Deleting B: the end falls back to its point; restoring brings the route back.
        let deleted = list([Self.a: Self.rects[Self.a]!])
        let fallback = ConnectorRouter.route(spec) { deleted.bounds(of: $0) }
        #expect(fallback.points.last == Point(x: 500, y: 500))
        let restored = ConnectorRouter.route(spec) { before.bounds(of: $0) }
        #expect(restored.points.last == ConnectorSide.left.midpoint(of: before.bounds(of: Self.b)!))
    }

    /// Moving a node with 1,000 attached connectors reroutes and invalidates them within one
    /// frame (release builds; debug reports).
    @Test func aThousandConnectorsRerouteWithinAFrame() {
        var index = DependencyIndex()
        let hub = NodeID(counter: 50_000, replica: 9)
        var specs: [ConnectorSpec] = []
        var builder = DisplayListBuilder(canvas: "c")
        builder.add(.path(PathItem(path: DisplayPath(rect: Rect(x: 500, y: 500, width: 40, height: 40)), appearance: Appearance([.fill(FillPaint(paint: .solid(.black)))]))), node: hub)
        for index in 0..<1000 {
            let node = NodeID(counter: UInt64(index + 1), replica: 9)
            builder.add(.path(PathItem(path: DisplayPath(rect: Rect(x: Double(index % 40) * 30, y: Double(index / 40) * 30, width: 10, height: 10)), appearance: Appearance([.fill(FillPaint(paint: .solid(.black)))]))), node: node)
            specs.append(ConnectorSpec(id: NodeID(counter: UInt64(10_000 + index), replica: 9), start: ConnectorEnd(node: node, point: .zero), end: ConnectorEnd(node: hub, point: .zero)))
        }
        for spec in specs {
            spec.addDependencies(to: &index)
        }
        let nodes = builder.build()
        let start = Date()
        var summary = ChangeSummary(origin: .remote)
        summary.touch(hub)
        let touched = summary.touchingDependents(in: index)
        let items = specs.filter { touched.touchedNodes.contains($0.id) }.map { ConnectorRendering.item($0, in: nodes) }
        let list = DisplayList(canvas: "c", items: nodes.items + items, nodeIDs: nodes.nodeIDs + specs.map(\.id))
        let region = InvalidationMapper().dirtyRegion(for: touched, before: [list], after: [list])
        let milliseconds = Date().timeIntervalSince(start) * 1000
        print("PERF connectors: 1,000 connectors rerouted and invalidated in \(String(format: "%.1f", milliseconds)) ms")
        #expect(items.count == 1000)
        #expect(!region.isEmpty)
        #if !DEBUG
        #expect(milliseconds < 16.7)
        #endif
    }
}
