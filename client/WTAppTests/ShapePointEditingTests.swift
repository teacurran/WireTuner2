import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// Live shapes edited like paths (D-078; rectangles-ellipses-lines.adoc "Editing a shape's points",
/// polygons-stars.adoc "Editing a polygon's points"): the Subselect tool, or the Pointer with
/// kbd:[Option], drags a shape's points and handles, and the edit converts the shape to a path in
/// the same change; the Pointer keeps the live handles.
@Suite(.serialized) @MainActor struct ShapePointEditingTests {
    enum Shape: String, CaseIterable, CustomTestStringConvertible {
        case rectangle, roundedRectangle, ellipse, arc, polygon, star

        var testDescription: String { rawValue }
    }

    /// A grey fill and the standard stroke.
    static var look: Wiretuner_Doc_V1_AppearanceProps {
        var appearance = Appearances.standard
        appearance.fills = [Appearances.basicFill(red: 0.35, green: 0.55, blue: 0.75)]
        return appearance
    }

    /// Draws `shape` around (150, 150), a little rotated, filled and stroked, with a shadow.
    static func draw(_ shape: Shape, in document: DocumentHandle) async throws -> OpID {
        let placed = AffineTransform.rotation(radians: .pi / 12).concatenating(.translation(x: 100, y: 110))
        let node: OpID
        switch shape {
        case .rectangle, .roundedRectangle:
            let radii = shape == .rectangle ? CornerRadii() : .uniform(14)
            node = try #require(await document.perform(CreateShape(.rectangle(radii), size: Size(width: 110, height: 70), transform: placed,
                                                                   appearance: look)).value?.createdObjects.first)
        case .ellipse, .arc:
            node = try #require(await document.perform(CreateShape(.ellipse, size: Size(width: 110, height: 70), transform: placed,
                                                                   appearance: look)).value?.createdObjects.first)
            if shape == .arc { _ = await document.perform(SetEllipseArc([node], start: 20, end: 250)).value }
        case .polygon, .star:
            let polygon = PolygonShape(sides: shape == .star ? 5 : 6, star: shape == .star, radius: 60, innerRadius: 26, rotation: 0.2)
            node = try #require(await document.perform(CreatePolygon(polygon, center: Point(x: 150, y: 150), appearance: look)).value?.createdObjects.first)
        }
        _ = await document.perform(AddEffect([node], kind: .shadow)).value
        await document.settle()
        return node
    }

    /// The Subselect tool over `world`'s window, viewing the pasteboard 1:1.
    static func subselect(_ world: GlueWorld, host: RecordingHost) -> PointerTool {
        let tool = PointerTool(subselect: true)
        tool.activate(in: world.context(host))
        return tool
    }

    static func host() -> RecordingHost { RecordingHost(viewport: Viewport(size: Size(width: 300, height: 300))) }

    /// A point of `node`'s derived path, pasteboard space.
    static func anchor(_ world: GlueWorld, _ node: OpID, _ index: Int) throws -> (reference: VectorPoint, at: Point) {
        let object = try #require(world.document.object(for: SelectionID(node)))
        let point = try #require(object.path?.contours[0].drawn[index])
        return (point, object.transform.apply(point.anchor))
    }

    /// The live paths on the default layer, bottom first.
    static func paths(_ state: EngineState) -> [OpID] {
        let order = LayerOrder(state)
        return order.defaultLayer.map { order.objects(on: $0, in: state).filter { state.nodeKind($0) == .path } } ?? []
    }

    static func waitForPath(_ world: GlueWorld) async -> OpID? {
        await world.waitForSelection(.path)
    }

    // MARK: Dragging a point

    @Test(arguments: Shape.allCases)
    func draggingAPointWithTheSubselectToolConvertsTheShapeInOneChange(_ shape: Shape) async throws {
        let world = GlueWorld()
        defer { world.close() }
        let node = try await Self.draw(shape, in: world.document)
        let before = DistortToolTests.pixels(world.document)
        let host = Self.host()
        let tool = Self.subselect(world, host: host)
        let (point, at) = try Self.anchor(world, node, 1)
        let changes = world.document.changeCount
        tool.mouseDown(TestEvents.point(at.x, at.y))
        #expect(tool.gesture == .movePoints, "a press on the shape's point takes the point")
        #expect(world.window.selection.selection.subSelection(of: SelectionID(node)) != nil)
        tool.mouseDragged(TestEvents.point(at.x + 6, at.y + 4))
        #expect(!tool.movePreview.isEmpty, "the drag previews the shape with the point moved")
        tool.mouseUp(TestEvents.point(at.x + 12, at.y + 8))
        await world.document.settle()
        #expect(world.document.changeCount == changes + 1, "one change")
        #expect(world.document.undoTitle == "Undo Edit Points")
        #expect(!world.state.isLive(node))
        let path = try #require(await Self.waitForPath(world), "the path is selected in the shape's place")
        let object = try #require(world.document.object(for: SelectionID(path)))
        let moved = try #require(object.path?.contours[0].drawn[1])
        #expect(object.transform.apply(moved.anchor).distance(to: Point(x: at.x + 12, y: at.y + 8)) < 1e-6, "the point moved with the pointer")
        #expect(moved.inHandle == point.inHandle && moved.outHandle == point.outHandle)
        guard case .points(let selected)? = world.window.selection.selection.subSelection(of: SelectionID(path)) else {
            Issue.record("the dragged point stays selected")
            return
        }
        #expect(selected.map(\.point) == [moved.id])
        let dragged = DistortToolTests.pixels(world.document)
        // One undo brings the live shape back, drawn as before.
        _ = await world.document.undo().value
        await world.document.settle()
        #expect(world.state.isLive(node) && !world.state.isLive(path))
        #expect(DistortToolTests.pixels(world.document) == before)
        // The conversion alone draws exactly what the shape drew; the same move on it draws what the drag did.
        _ = await world.document.perform(Ungroup([node])).value
        await world.document.settle()
        #expect(DistortToolTests.pixels(world.document) == before, "appearance preserved exactly")
        let converted = try #require(Self.paths(world.state).first)
        let contour = try #require(world.document.path(SelectionID(converted))?.contours[0])
        _ = await world.document.perform(MovePoints(node: converted, contour: contour.id, point: contour.points[1].id,
                                                    to: moved.anchor)).value
        await world.document.settle()
        #expect(DistortToolTests.pixels(world.document) == dragged)
    }

    @Test func draggingAHandleOfARoundedCornerConvertsTheRectangle() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let node = try await Self.draw(.roundedRectangle, in: world.document)
        let host = Self.host()
        let context = world.context(host)
        let object = try #require(world.document.object(for: SelectionID(node)))
        let contour = try #require(object.path?.contours[0])
        world.window.selection.model.set(Selection([SelectionID(node)]).applying([SelectionID(node)], sub: [
            SelectionID(node): .points([PointReference(node: NodeID(node), contour: contour.id, point: contour.points[0].id)]),
        ], mode: .add))
        let layer = PointHandleLayer()
        let grabs = PointHandleLayer.grabs(context)
        let grab = try #require(grabs.first { !$0.neighbour })
        let end = grab.transform.apply(grab.end)
        #expect(layer.press(TestEvents.point(end.x, end.y), context: context))
        layer.drag(TestEvents.point(end.x + 5, end.y - 5), context: context)
        #expect(layer.preview(context) != nil)
        layer.release(TestEvents.point(end.x + 10, end.y - 10), context: context)
        await world.document.settle()
        #expect(!world.state.isLive(node))
        #expect(world.document.undoTitle == "Undo Edit Points")
        let path = try #require(await Self.waitForPath(world))
        let point = try #require(world.document.path(SelectionID(path))?.contours[0].drawn[0])
        #expect(point.outHandle != contour.points[0].outHandle, "the handle moved")
        _ = await world.document.undo().value
        #expect(world.state.isLive(node))
    }

    @Test func optionClickNudgeAndDeleteConvertToo() async throws {
        let world = GlueWorld()
        defer { world.close() }
        // Option-click toggles an ellipse's curve point to a corner.
        let ellipse = try await Self.draw(.ellipse, in: world.document)
        let host = Self.host()
        let tool = Self.subselect(world, host: host)
        let (_, at) = try Self.anchor(world, ellipse, 0)
        tool.mouseDown(TestEvents.point(at.x, at.y))
        tool.mouseUp(TestEvents.point(at.x, at.y))
        tool.mouseDown(TestEvents.point(at.x, at.y, .option))
        tool.mouseUp(TestEvents.point(at.x, at.y, .option))
        await world.document.settle()
        #expect(!world.state.isLive(ellipse))
        let path = try #require(await Self.waitForPath(world))
        #expect(world.document.path(SelectionID(path))?.contours[0].drawn[0].kind == .corner)
        // Arrow keys nudge a polygon's selected point: one change once the burst ends.
        let polygon = try await Self.draw(.polygon, in: world.document)
        let (_, vertex) = try Self.anchor(world, polygon, 2)
        tool.mouseDown(TestEvents.point(vertex.x, vertex.y))
        tool.mouseUp(TestEvents.point(vertex.x, vertex.y))
        #expect(world.editing.nudge(by: Vector(dx: 3, dy: 0)))
        #expect(world.editing.nudge(by: Vector(dx: 3, dy: 0)))
        _ = await world.editing.endNudging()?.value
        await world.document.settle()
        #expect(!world.state.isLive(polygon) && world.document.undoTitle == "Undo Edit Points")
        let nudged = try #require(await Self.waitForPath(world))
        let object = try #require(world.document.object(for: SelectionID(nudged)))
        #expect(object.transform.apply(object.path!.contours[0].drawn[2].anchor).distance(to: vertex + Vector(dx: 6, dy: 0)) < 1e-6)
        // Clear deletes a star's selected point.
        let star = try await Self.draw(.star, in: world.document)
        let (_, peak) = try Self.anchor(world, star, 4)
        tool.mouseDown(TestEvents.point(peak.x, peak.y))
        tool.mouseUp(TestEvents.point(peak.x, peak.y))
        let clear = try #require(world.window.deletionCommand())
        _ = await world.document.perform(clear).value
        await world.document.settle()
        #expect(!world.state.isLive(star))
        let cleared = try #require(Self.paths(world.state).last)
        #expect(world.document.path(SelectionID(cleared))?.contours[0].points.count == 9)
    }

    // MARK: Live handles with the Pointer

    @Test func thePointerKeepsThePolygonsLiveHandlesAndOptionReachesThePoint() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let star = try await Self.draw(.star, in: world.document)
        world.select([star])
        let host = Self.host()
        let context = world.context(host)
        let layer = PolygonShapeHandles()
        let tool = TestBox<ToolID>("subselect")
        layer.activeTool = { tool.value }
        #expect(layer.polygons(context).isEmpty, "the Subselect tool shows the points instead")
        tool.value = .pointer
        #expect(layer.polygons(context) == [star])
        let peak = try #require(PolygonHandles.positions(of: star, in: world.state)?.peak)
        #expect(!layer.press(TestEvents.point(peak.x, peak.y, .option), context: context), "Option is the Pointer's subselect")
        #expect(layer.press(TestEvents.point(peak.x, peak.y), context: context))
        layer.release(TestEvents.point(peak.x + 10, peak.y), context: context)
        await world.document.settle()
        #expect(world.state.isLive(star), "the star stays live")
        #expect(world.state.props(star).polygon.radius != 60)
        // A polygon with a point selected shows no handles.
        let contour = try #require(world.document.path(SelectionID(star))?.contours[0])
        world.window.selection.model.set(Selection([SelectionID(star)]).applying([SelectionID(star)], sub: [
            SelectionID(star): .points([PointReference(node: NodeID(star), contour: contour.id, point: contour.points[0].id)]),
        ], mode: .add))
        #expect(layer.polygons(context).isEmpty)
    }

    @Test func thePointerRoundsARectanglesCornersByItsRadiusHandles() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let rect = try #require(await world.document.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 100, height: 60),
                                                                          transform: .translation(x: 50, y: 50), appearance: Self.look)).value?.createdObjects.first)
        world.select([rect])
        let host = Self.host()
        let context = world.context(host)
        let layer = RectangleRadiusHandles()
        #expect(layer.rectangles(context).isEmpty, "no tool: no handles")
        layer.activeTool = { .pointer }
        #expect(layer.rectangles(context) == [rect])
        layer.draw(in: world.bitmap(), viewport: host.viewport, context: context)
        #expect(!layer.press(TestEvents.point(58, 58, .option), context: context))
        #expect(!layer.press(TestEvents.point(100, 80), context: context), "not on a handle")
        #expect(layer.press(TestEvents.point(58, 58), context: context))
        layer.drag(TestEvents.point(64, 66), context: context)
        layer.release(TestEvents.point(66, 70), context: context)
        await world.document.settle()
        #expect(world.state.isLive(rect), "the rectangle stays live")
        #expect(CornerRadii(world.state.props(rect).rect.corners, size: Size(width: 100, height: 60)) == .uniform(18))
        #expect(world.document.undoTitle == "Undo Change corner radius")
        // Esc drops a drag.
        #expect(layer.press(TestEvents.point(68, 68), context: context))
        layer.drag(TestEvents.point(80, 80), context: context)
        layer.cancel(context: context)
        await world.document.settle()
        #expect(CornerRadii(world.state.props(rect).rect.corners, size: Size(width: 100, height: 60)) == .uniform(18))
        layer.drag(TestEvents.point(0, 0), context: context)
    }

    // MARK: Path commands

    @Test func pathCommandsTakeShapesAndConvertThemInTheSameChange() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let rect = try await Self.draw(.rectangle, in: world.document)
        world.select([rect])
        #expect(world.editing.hasSelectedPaths)
        #expect(DistortFeatures.paths(world.editing) == [rect])
        #expect(PathAlterFeatures.closedPaths(world.editing) == [rect])
        // Remove Overlap has nothing to do on a rectangle: it stays live and nothing is written.
        let changes = world.document.changeCount
        PathAlterFeatures.removeOverlap(world.editing)
        await world.document.settle()
        #expect(world.state.isLive(rect) && world.document.changeCount == changes)
        // Add Points converts it and doubles its points, and the path is selected.
        _ = await world.editing.addPoints()?.value
        await world.document.settle()
        #expect(!world.state.isLive(rect) && world.document.undoTitle == "Undo Add Points")
        let path = try #require(await Self.waitForPath(world))
        #expect(world.document.path(SelectionID(path))?.contours[0].points.count == 8)
        _ = await world.document.undo().value
        await world.document.settle()
        #expect(world.state.isLive(rect))
        // Reverse Direction from the menu reverses the rectangle as a path.
        world.select([rect])
        let reverse = try #require(ReachabilityFeatures.reverseCommand(world.window))
        _ = await world.document.perform(reverse).value
        await world.document.settle()
        #expect(!world.state.isLive(rect) && world.document.undoTitle == "Undo Reverse Direction")
        let reversed = try #require(await Self.waitForPath(world))
        #expect(world.document.path(SelectionID(reversed))?.contours[0].reversed == true)
    }

    @Test func theStatusLineSaysWhenAShapeWasConverted() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let notice = ShapeConversionNotice(window: world.window)
        defer { notice.stop() }
        #expect(ShapeConversionNotice.message([]) == nil)
        #expect(ShapeConversionNotice.message(["Rectangle"]) == "Rectangle converted to a path. Undo brings the live rectangle back.")
        #expect(ShapeConversionNotice.message(["Star", "Ellipse"]) == "2 shapes converted to paths. Undo brings the live shapes back.")
        let star = try await Self.draw(.star, in: world.document)
        // Ungroup asks for the conversion by name: no note.
        _ = await world.document.perform(Ungroup([star])).value
        await world.document.settle()
        #expect(notice.shown == nil)
        _ = await world.document.undo().value
        _ = await world.document.perform(AddPoints([star])).value
        await world.document.settle()
        #expect(notice.shown == "Star converted to a path. Undo brings the live star back.")
        notice.documentDidChange(nil)
    }
}
