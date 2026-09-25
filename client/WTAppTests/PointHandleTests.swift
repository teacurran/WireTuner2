import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// DRAW-025's remainder: handle drags per point type, the neighbours' near handles, kbd:[Option]-click
/// type toggling, kbd:[Option]-drag handle extension and *Smoother editing*.
@Suite(.serialized) @MainActor struct PointHandleTests {
    typealias Fixture = PointerMoveTests.Fixture

    /// A path through (100,200) corner, (150,200) of `kind` with handles ±20 along x, (200,200)
    /// corner with retracted handles.
    static func path(_ f: Fixture, kind: PointKind) async throws -> SelectionID {
        let points = [
            VectorPoint(anchor: Point(x: 100, y: 200)),
            VectorPoint(anchor: Point(x: 150, y: 200), inHandle: Vector(dx: -20, dy: 0), outHandle: Vector(dx: 20, dy: 0), kind: kind),
            VectorPoint(anchor: Point(x: 200, y: 200)),
        ]
        let change = await f.document.perform(CreatePath(contours: [NewContour(points: points)], appearance: Appearances.standard)).value
        await f.document.settle()
        return SelectionID(try #require(change?.createdObjects.first))
    }

    static func select(_ f: Fixture, _ path: SelectionID, _ indices: [Int]) {
        let contour = f.document.path(path)!.contours[0]
        let chosen = Set(indices.map { PointReference(node: path.node, contour: contour.id, point: contour.drawn[$0].id) })
        f.controller.model.set(Selection([path]).applying([path], sub: [path: .points(chosen)], mode: .add))
    }

    static func context(_ f: Fixture) -> ToolContext {
        ToolContext(document: f.document, host: f.host, selection: f.controller)
    }

    static func point(_ f: Fixture, _ path: SelectionID, _ index: Int) -> VectorPoint {
        f.document.path(path)!.contours[0].drawn[index]
    }

    @Test func draggingAHandleFollowsThePointType() async throws {
        for kind in [PointKind.curve, .corner, .connector] {
            let f = await Fixture.make(subselect: true)
            let path = try await Self.path(f, kind: kind)
            Self.select(f, path, [1])
            let layer = PointHandleLayer()
            let context = Self.context(f)
            #expect(PointHandleLayer.grabs(context).filter { !$0.neighbour }.count == 2)
            #expect(layer.press(TestEvents.point(170, 200), context: context))
            layer.drag(TestEvents.point(170, 180), context: context)
            layer.release(TestEvents.point(170, 170), context: context)
            await f.document.settle()
            try await Task.sleep(for: .milliseconds(20))
            let moved = Self.point(f, path, 1)
            switch kind {
            case .curve:
                #expect(moved.outHandle == Vector(dx: 20, dy: -30))
                #expect(abs(moved.inHandle.length - 20) < 1e-9 && abs(moved.inHandle.normalized.dot(moved.outHandle.normalized) + 1) < 1e-9, "the other handle pivots")
            case .corner:
                #expect(moved.outHandle == Vector(dx: 20, dy: -30) && moved.inHandle == Vector(dx: -20, dy: 0))
            case .connector:
                #expect(moved.outHandle.dy == 0 || moved.inHandle == Vector(dx: -20, dy: 0))
            }
            #expect(f.document.undoTitle == "Undo Move Handle")
            _ = await f.document.undo().value
            #expect(Self.point(f, path, 1).outHandle == Vector(dx: 20, dy: 0), "the drag is one undo step")
        }
    }

    @Test func optionMovesOneHandleAloneAndEscapeUndoes() async throws {
        let f = await Fixture.make(subselect: true)
        let path = try await Self.path(f, kind: .curve)
        Self.select(f, path, [1])
        let layer = PointHandleLayer()
        let context = Self.context(f)
        #expect(layer.press(TestEvents.point(130, 200), context: context))
        layer.release(TestEvents.point(130, 220, .option), context: context)
        await f.document.settle()
        try await Task.sleep(for: .milliseconds(20))
        #expect(Self.point(f, path, 1).inHandle == Vector(dx: -20, dy: 20) && Self.point(f, path, 1).outHandle == Vector(dx: 20, dy: 0))
        // Esc after writing undoes the drag; before writing it writes nothing.
        #expect(layer.press(TestEvents.point(170, 200), context: context))
        layer.drag(TestEvents.point(170, 230), context: context)
        layer.cancel(context: context)
        await f.document.settle()
        try await Task.sleep(for: .milliseconds(30))
        #expect(Self.point(f, path, 1).outHandle == Vector(dx: 20, dy: 0))
        #expect(layer.press(TestEvents.point(170, 200), context: context))
        layer.cancel(context: context)
        layer.cancel(context: context)
        layer.drag(TestEvents.point(170, 230), context: context)
        // Nowhere near a handle, or nearer the point than the handle's end: the tool's.
        #expect(!layer.press(TestEvents.point(10, 10), context: context))
    }

    @Test func theNeighboursNearHandlesShowAndDrag() async throws {
        let f = await Fixture.make(subselect: true)
        let path = try await Self.path(f, kind: .curve)
        Self.select(f, path, [0])
        let context = Self.context(f)
        let grabs = PointHandleLayer.grabs(context)
        #expect(grabs.count == 1 && grabs[0].neighbour && !grabs[0].out)
        let layer = PointHandleLayer()
        layer.draw(in: DrawingToolTests.bitmap(), viewport: SelectionFixture.viewport, context: context)
        #expect(layer.press(TestEvents.point(130, 200), context: context))
        layer.release(TestEvents.point(130, 190), context: context)
        await f.document.settle()
        try await Task.sleep(for: .milliseconds(20))
        #expect(Self.point(f, path, 1).inHandle == Vector(dx: -20, dy: -10))
        // The last point's neighbour handle too; a closed contour wraps.
        Self.select(f, path, [2])
        #expect(PointHandleLayer.grabs(context).map(\.out) == [true])
        let closed = try #require(await f.document.addPath([Point(x: 10, y: 250), Point(x: 60, y: 250), Point(x: 30, y: 290)], closed: true))
        Self.select(f, closed, [0])
        #expect(PointHandleLayer.grabs(context).isEmpty, "retracted handles give nothing to drag")
        f.controller.model.set(Selection([f.selection.a]))
        #expect(PointHandleLayer.grabs(context).isEmpty)
        layer.draw(in: DrawingToolTests.bitmap(), viewport: SelectionFixture.viewport, context: context)
        // A handle whose end sits on its point is left to the point.
        let tiny = try await Self.path(f, kind: .corner)
        _ = await f.document.perform(SetHandles(node: tiny.opID, contour: f.document.path(tiny)!.contours[0].id,
                                                point: Self.point(f, tiny, 1).id, in: Vector(dx: -1, dy: 0), out: Vector(dx: 1, dy: 0))).value
        Self.select(f, tiny, [1])
        #expect(!layer.press(TestEvents.point(151, 200), context: context))
    }

    @Test func optionClickTogglesTheTypeAndOptionDragExtendsARetractedHandle() async throws {
        let f = await Fixture.make()
        let path = try await Self.path(f, kind: .curve)
        Self.select(f, path, [1])
        f.tool.mouseDown(TestEvents.point(150, 200, .option))
        f.tool.mouseUp(TestEvents.point(150, 200, .option))
        await f.document.settle()
        #expect(Self.point(f, path, 1).kind == .corner && f.document.undoTitle == "Undo Set Point Type")
        f.tool.mouseDown(TestEvents.point(150, 200, .option))
        f.tool.mouseUp(TestEvents.point(150, 200, .option))
        await f.document.settle()
        #expect(Self.point(f, path, 1).kind == .curve)
        // Option-drag from the corner end point, whose handles are retracted: the outgoing one.
        Self.select(f, path, [2])
        f.drag(Point(x: 200, y: 200), Point(x: 230, y: 180), .option)
        await f.document.settle()
        let end = Self.point(f, path, 2)
        #expect(end.outHandle == Vector(dx: 30, dy: -20) && end.anchor == Point(x: 200, y: 200))
        #expect(f.document.undoTitle == "Undo Move Handle")
        // A point with an incoming handle retracted only: that one.
        let context = Self.context(f)
        _ = await f.document.perform(RetractHandles(node: path.opID, points: [(f.document.path(path)!.contours[0].id, Self.point(f, path, 1).id)])).value
        _ = await f.document.perform(SetHandles(node: path.opID, contour: f.document.path(path)!.contours[0].id, point: Self.point(f, path, 1).id,
                                                out: Vector(dx: 10, dy: 0), linked: false)).value
        Self.select(f, path, [1])
        let extend = try #require(PointEditing.extendCommand(from: TestEvents.point(150, 200, .option), delta: Vector(dx: -5, dy: 5), context: context))
        #expect(extend.inHandle == Vector(dx: -5, dy: 5) && extend.outHandle == nil)
        // Not without Option, not on an unselected point, not with both handles out.
        #expect(PointEditing.extendCommand(from: TestEvents.point(150, 200), delta: .zero, context: context) == nil)
        #expect(PointEditing.toggleCommand(at: TestEvents.point(150, 200), context: context) == nil)
        #expect(PointEditing.toggleCommand(at: TestEvents.point(100, 200, .option), context: context) == nil)
        _ = await f.document.perform(SetHandles(node: path.opID, contour: f.document.path(path)!.contours[0].id, point: Self.point(f, path, 1).id,
                                                in: Vector(dx: -10, dy: 0), linked: false)).value
        #expect(PointEditing.extendCommand(from: TestEvents.point(150, 200, .option), delta: Vector(dx: 1, dy: 1), context: context) == nil)
    }

    @Test func smootherEditingChoosesWhatAPointDragPreviews() async throws {
        let f = await Fixture.make(subselect: true)
        let path = try #require(await f.document.addPath([Point(x: 100, y: 200), Point(x: 150, y: 200), Point(x: 200, y: 200), Point(x: 250, y: 200),
                                                             Point(x: 300, y: 200), Point(x: 350, y: 200)]))
        let vector = try #require(f.document.path(path))
        let middle: Set<OpID> = [vector.contours[0].drawn[1].id]
        let whole = PointEditing.preview(vector, moved: middle, smoother: true)
        let part = PointEditing.preview(vector, moved: middle, smoother: false)
        #expect(part.elements.count < whole.elements.count && part.elements.count == 4)
        var closedPath = vector
        closedPath.contours[0].closed = true
        closedPath.contours.append(VectorContour(points: [VectorPoint(anchor: .zero)]))
        #expect(PointEditing.preview(closedPath, moved: [vector.contours[0].drawn[0].id], smoother: false).elements.count == 4)
        // The tool's preview follows the preference.
        Self.select(f, path, [1])
        PointEditing.smoother = { false }
        defer { PointEditing.smoother = { true } }
        f.tool.mouseDown(TestEvents.point(150, 200))
        f.tool.mouseDragged(TestEvents.point(150, 220))
        #expect(f.tool.movePreview.first?.elements.count == 4)
        f.tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: SelectionFixture.viewport)
        f.tool.cancel()
    }

    @Test func dragging500PointsPreviewsWithinTheEventBudget() async throws {
        let f = await Fixture.make(subselect: true)
        let points = (0..<500).map { Point(x: 10 + Double($0 % 50) * 7, y: 10 + Double($0 / 50) * 25) }
        let path = try #require(await f.document.addPath(points))
        Self.select(f, path, Array(0..<500))
        let changes = f.document.changeCount
        f.tool.mouseDown(TestEvents.point(10, 10))
        var times: [Double] = []
        for step in 1...60 {
            let start = DispatchTime.now().uptimeNanoseconds
            f.tool.mouseDragged(TestEvents.point(10 + Double(step), 10))
            _ = f.tool.movePreview
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        f.tool.mouseUp(TestEvents.point(70, 10))
        await f.document.settle()
        #expect(f.document.changeCount == changes + 1)
        let stats = CanvasPerformanceTests.Stats(samples: times)
        print("DRAW-025 drag of 500 points, per event: \(stats)")
        PerfBudget.expect(.seconds(stats.p95), within: .milliseconds(8), "500-point drag",
                          enforcedInDebug: "the app's tests build Debug only; a Debug figure within the budget is a Release one too")
    }
}
