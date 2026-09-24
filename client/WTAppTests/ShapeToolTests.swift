import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// DRAW-007: the Rectangle, Ellipse and Line tools.
@Suite @MainActor struct ShapeToolTests {
    /// Holds the host: a tool's context refers to it `unowned`, as the canvas's does.
    @MainActor
    final class Fixture {
        let tool: ShapeDragTool
        let host: RecordingHost
        let document: DocumentHandle
        let sink: RecordingSink?

        init(_ tool: ShapeDragTool, sink: RecordingSink? = nil, constrainAngle: Double = 0) {
            self.tool = tool
            host = RecordingHost()
            document = .memory(title: "Shapes")
            self.sink = sink
            var context = ToolContext(document: document, host: host)
            if let sink { context.commandSink = sink }
            context.drawing = { DrawingSettings(constrainAngle: constrainAngle) }
            tool.activate(in: context)
        }

        /// Drags from `from` to `to` with `modifiers` held throughout.
        func drag(_ from: Point, _ to: Point, _ modifiers: KeyModifiers = []) {
            tool.mouseDown(TestEvents.point(from.x, from.y, modifiers))
            tool.mouseDragged(TestEvents.point((from.x + to.x) / 2, (from.y + to.y) / 2, modifiers))
            tool.mouseUp(TestEvents.point(to.x, to.y, modifiers))
        }
    }

    @Test func aDragEmitsExactlyOneCommandOnMouseUp() throws {
        let sink = RecordingSink()
        let fixture = Fixture(RectangleTool(), sink: sink)
        let tool = fixture.tool
        #expect(fixture.host.messages.first?.hasPrefix("Drag to draw a rectangle") == true)
        #expect(tool.cursor == NSCursor.crosshair)
        tool.mouseDown(TestEvents.point(10, 10))
        for step in 1...20 {
            tool.mouseDragged(TestEvents.point(10 + Double(step) * 3, 10 + Double(step) * 2))
            #expect(sink.commands.isEmpty, "nothing is emitted while dragging")
        }
        #expect(tool.frame?.size == Size(width: 60, height: 40))
        #expect(tool.info == ToolInfo(delta: Vector(dx: 60, dy: 40)), "the Info toolbar shows the drag")
        tool.mouseUp(TestEvents.point(70, 50))
        #expect(tool.info == ToolInfo())
        #expect(sink.commands.count == 1)
        let command = try #require(sink.commands.first as? CreateShape)
        #expect(command.label == "Rectangle")
        #expect(command.size == Size(width: 60, height: 40))
        #expect(command.transform == .translation(x: 10, y: 10))
        #expect(tool.frame == nil)
        tool.mouseUp(TestEvents.point(90, 90))
        #expect(sink.commands.count == 1, "a stray mouse-up emits nothing")
    }

    @Test func tinyAndCancelledDragsEmitNothing() {
        let sink = RecordingSink()
        let fixture = Fixture(EllipseTool(), sink: sink)
        let tool = fixture.tool
        fixture.drag(Point(x: 10, y: 10), Point(x: 10.5, y: 10.5))
        fixture.drag(Point(x: 10, y: 10), Point(x: 40, y: 10))
        tool.mouseDown(TestEvents.point(10, 10))
        tool.mouseDragged(TestEvents.point(50, 50))
        tool.cancel()
        tool.mouseDragged(TestEvents.point(60, 60))
        tool.mouseUp(TestEvents.point(60, 60))
        #expect(sink.commands.isEmpty)
        #expect(!tool.keyDown(TestEvents.key("a", keyCode: 0)))
        tool.flagsChanged(TestEvents.point(0, 0, .shift))
        tool.spaceChanged(down: true)
        #expect(tool.frame == nil && tool.preview == nil)
        let line = Fixture(LineTool(), sink: sink)
        line.drag(Point(x: 0, y: 0), Point(x: 0.5, y: 0.5))
        #expect(sink.commands.isEmpty, "a line under 1 pt is nothing")
    }

    @Test func aTinyDragLeavesNoNodeAndNothingToUndo() async {
        let fixture = Fixture(RectangleTool())
        fixture.drag(Point(x: 10, y: 10), Point(x: 10.4, y: 10.9))
        await fixture.document.settle()
        let store = fixture.document.state.store
        #expect(store.nodes.allSatisfy { !store.isCreated($0) || [SwatchFields.kind, PageFields.kind].contains(store.kind($0)) },
                "only the new document's default swatches and page")
        #expect(!fixture.document.canUndo)
        #expect(fixture.document.changeCount == 0)
    }

    @Test func rectangleModifiersGiveSizeAndTransform() {
        let anchor = Point(x: 100, y: 100)
        let pointer = Point(x: 130, y: 110)
        func frame(_ modifiers: KeyModifiers, angle: Double = 0, to point: Point = pointer) -> (Size, WTGeometry.AffineTransform) {
            let result = ShapeDragTool.frame(anchor: anchor, pointer: point, modifiers: modifiers, constrainAngle: angle)
            return (result.size, result.transform)
        }
        #expect(frame([]) == (Size(width: 30, height: 10), .translation(x: 100, y: 100)))
        #expect(frame(.shift) == (Size(width: 30, height: 30), .translation(x: 100, y: 100)), "Shift: a square")
        #expect(frame(.option) == (Size(width: 60, height: 20), .translation(x: 70, y: 90)), "Option: from the centre")
        #expect(frame([.shift, .option]) == (Size(width: 60, height: 60), .translation(x: 70, y: 70)))
        #expect(frame([], to: Point(x: 90, y: 80)) == (Size(width: 10, height: 20), .translation(x: 90, y: 80)), "dragging up and left")
        #expect(frame(.shift, to: Point(x: 97, y: 80)) == (Size(width: 20, height: 20), .translation(x: 80, y: 80)))
        let (size, rotated) = frame([], angle: 90, to: Point(x: 110, y: 70))
        #expect(abs(size.width - 30) < 1e-9 && abs(size.height - 10) < 1e-9, "the constrain angle rotates the frame")
        #expect(rotated.apply(Point(x: 0, y: 0)).isApproximatelyEqual(to: Point(x: 110, y: 70), tolerance: 1e-9))
        #expect(rotated.apply(Point(x: 30, y: 10)).isApproximatelyEqual(to: Point(x: 100, y: 100), tolerance: 1e-9))
        #expect(rotated.apply(Point(x: 30, y: 0)).isApproximatelyEqual(to: Point(x: 110, y: 100), tolerance: 1e-9))
    }

    @Test func lineModifiersSnapAndCenter() {
        let anchor = Point(x: 0, y: 0)
        #expect(ShapeDragTool.line(anchor: anchor, pointer: Point(x: 10, y: 3), modifiers: [], constrainAngle: 0) == (anchor, Point(x: 10, y: 3)))
        let snapped = ShapeDragTool.line(anchor: anchor, pointer: Point(x: 10, y: 3), modifiers: .shift, constrainAngle: 0)
        #expect(snapped.end.isApproximatelyEqual(to: Point(x: 10, y: 0), tolerance: 1e-9), "Shift: to 0°")
        let diagonal = ShapeDragTool.line(anchor: anchor, pointer: Point(x: 10, y: 9), modifiers: .shift, constrainAngle: 0)
        #expect(abs(diagonal.end.x - diagonal.end.y) < 1e-9, "and every 45°")
        let centered = ShapeDragTool.line(anchor: anchor, pointer: Point(x: 10, y: 3), modifiers: .option, constrainAngle: 0)
        #expect(centered == (Point(x: -10, y: -3), Point(x: 10, y: 3)))
        let both = ShapeDragTool.line(anchor: anchor, pointer: Point(x: 10, y: 3), modifiers: [.shift, .option], constrainAngle: 0)
        #expect(both.start.isApproximatelyEqual(to: Point(x: -10, y: 0), tolerance: 1e-9))
        let tilted = ShapeDragTool.line(anchor: anchor, pointer: Point(x: 10, y: 3), modifiers: .shift, constrainAngle: 15)
        #expect(abs(atan2(tilted.end.y, tilted.end.x) - 15 * .pi / 180) < 1e-9, "the constrain angle tilts the snap")
    }

    @Test func modifiersAndSpaceChangeTheDragMidway() {
        let fixture = Fixture(RectangleTool(), sink: RecordingSink())
        let tool = fixture.tool
        tool.mouseDown(TestEvents.point(100, 100))
        tool.mouseDragged(TestEvents.point(130, 110))
        #expect(tool.isDragging)
        tool.flagsChanged(TestEvents.point(0, 0, .shift))
        #expect(tool.frame?.size == Size(width: 30, height: 30))
        tool.flagsChanged(TestEvents.point(0, 0, []))
        tool.spaceChanged(down: true)
        tool.mouseDragged(TestEvents.point(150, 120))
        #expect(tool.frame?.size == Size(width: 30, height: 10), "Space moves the shape, keeping its size")
        #expect(tool.frame?.transform == .translation(x: 120, y: 110))
        tool.spaceChanged(down: false)
        tool.mouseDragged(TestEvents.point(160, 140))
        #expect(tool.frame?.size == Size(width: 40, height: 30), "released, the drag sizes again")
    }

    @Test func throughTheManagerARectangleIsCreatedSelectedAndUndoable() async throws {
        let environment = TestEnvironment()
        let host = RecordingHost()
        defer { withExtendedLifetime(host) {} }
        let document = DocumentHandle.memory(title: "Doc")
        let context = ToolContext(document: document, host: host)
        let manager = ToolManager(registry: environment.tools, context: context, initialTool: .rectangle)
        manager.mouseDown(TestEvents.point(0, 0))
        manager.mouseDragged(TestEvents.point(20, 10))
        manager.keyDown(TestEvents.space)
        manager.mouseDragged(TestEvents.point(25, 15))
        manager.keyUp(TestEvents.spaceUp)
        manager.flagsChanged(.shift)
        manager.mouseUp(TestEvents.point(25, 15, .shift))
        await document.settle()
        #expect(document.displayList.count == 2, "the pages group plus the rectangle")
        let id = try #require(document.selectableIDs().first)
        let props = document.state.props(id.opID).rect
        #expect(props.size.width == 20 && props.size.height == 20)
        #expect(props.common.transform.tx == 5 && props.common.transform.ty == 5)
        #expect(document.undoTitle == "Undo Rectangle")
        await Task.yield()
        #expect(context.selection.model.ids == [id], "the new shape is selected")
        _ = await document.undo().value
        #expect(document.selectableIDs().isEmpty)
        #expect(document.redoTitle == "Redo Rectangle")
    }

    @Test func ellipsesAndLinesBecomeNodes() async throws {
        let ellipse = Fixture(EllipseTool())
        ellipse.drag(Point(x: 10, y: 10), Point(x: 50, y: 30), .option)
        await ellipse.document.settle()
        let id = try #require(ellipse.document.selectableIDs().first)
        let props = ellipse.document.state.props(id.opID).ellipse
        #expect(props.size.width == 80 && props.size.height == 40)
        #expect(props.common.transform.tx == -30 && props.common.transform.ty == -10)
        #expect(ellipse.document.path(id)?.contours.first?.points.count == 4)

        let line = Fixture(LineTool())
        line.drag(Point(x: 0, y: 0), Point(x: 30, y: 4), .shift)
        await line.document.settle()
        let lineID = try #require(line.document.selectableIDs().first)
        let points = try #require(line.document.path(lineID)?.contours.first?.drawn)
        #expect(points.map(\.anchor) == [Point(x: 0, y: 0), Point(x: 30, y: 0)])
        #expect(points.allSatisfy { $0.kind == .corner })
        #expect(line.document.undoTitle == "Undo Line")
    }

    @Test func drawsThePreviewOnlyWhileDragging() {
        for tool in [RectangleTool(), EllipseTool(), LineTool()] as [ShapeDragTool] {
            let fixture = Fixture(tool, sink: RecordingSink())
            let surface = BitmapSurface(width: 50, height: 50)!
            tool.drawOverlay(in: surface.context, viewport: fixture.host.viewport)
            #expect(tool.preview == nil)
            tool.mouseDown(TestEvents.point(5, 5))
            tool.mouseDragged(TestEvents.point(40, 40))
            #expect(tool.preview != nil)
            tool.drawOverlay(in: surface.context, viewport: fixture.host.viewport)
            #expect(fixture.host.messages.first?.hasPrefix("Drag to draw") == true)
            tool.deactivate()
            #expect(tool.preview == nil)
        }
    }

    @Test func anInactiveToolStillMeasuresButPerformsNothing() {
        let line = LineTool()
        line.mouseDown(TestEvents.point(0, 0))
        line.mouseDragged(TestEvents.point(10, 0))
        #expect(line.line?.end == Point(x: 10, y: 0))
        #expect((line.command() as? CreatePath)?.fillWhenOpen == false)
        line.mouseUp(TestEvents.point(10, 0))
        let rectangle = RectangleTool()
        rectangle.mouseDown(TestEvents.point(0, 0))
        rectangle.mouseDragged(TestEvents.point(10, 5))
        #expect(rectangle.frame?.size == Size(width: 10, height: 5))
    }

    @Test func linesTakeTheOpenPathFillPreference() throws {
        let sink = RecordingSink()
        let host = RecordingHost()
        var context = ToolContext(document: .memory(title: "Fill"), host: host)
        context.commandSink = sink
        context.drawing = { DrawingSettings(fillWhenOpen: true) }
        let line = LineTool()
        line.activate(in: context)
        line.mouseDown(TestEvents.point(0, 0))
        line.mouseUp(TestEvents.point(10, 10))
        #expect((sink.commands.first as? CreatePath)?.fillWhenOpen == true)
    }

    @Test func theCatalogDeliversTheThreeTools() {
        let registry = ToolRegistry()
        registry.registerBuiltIn()
        #expect(registry.makeTool(.rectangle) is RectangleTool)
        #expect(registry.makeTool(.ellipse) is EllipseTool)
        #expect(registry.makeTool(.line) is LineTool)
        #expect(registry.makeTool(.pen) is PenTool)
        #expect(EllipseTool.id == .ellipse && LineTool.id == .line && ShapeDragTool.id == .rectangle)
    }
}
