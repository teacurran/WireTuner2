import AppKit
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

@Suite @MainActor struct RectangleSketchToolTests {
    /// Holds the host: a tool's context refers to it `unowned`, as the canvas's does.
    @MainActor
    final class Fixture {
        let tool: RectangleSketchTool
        let host: RecordingHost
        let document: DocumentHandle
        init(_ tool: RectangleSketchTool, _ host: RecordingHost, _ document: DocumentHandle) {
            self.tool = tool
            self.host = host
            self.document = document
        }
    }

    private func activeTool(sink: RecordingSink? = nil) -> Fixture {
        let host = RecordingHost()
        let document: DocumentHandle
        if let sink {
            document = DocumentHandle(title: "Sink", commandSink: sink) { DisplayList(canvas: "sink", items: []) }
        } else {
            document = .placeholder(title: "Rectangles")
        }
        let tool = RectangleSketchTool()
        tool.activate(in: ToolContext(document: document, host: host))
        return Fixture(tool, host, document)
    }

    @Test func aDragEmitsExactlyOneEditOnMouseUp() {
        let sink = RecordingSink()
        let fixture = activeTool(sink: sink)
        defer { withExtendedLifetime(fixture) {} }
        let tool = fixture.tool
        let host = fixture.host
        #expect(host.messages.first?.hasPrefix("Drag to draw a rectangle") == true)
        #expect(tool.cursor == NSCursor.crosshair)
        tool.mouseDown(TestEvents.point(10, 10))
        for step in 1...20 {
            tool.mouseDragged(TestEvents.point(10 + Double(step) * 3, 10 + Double(step) * 2))
            #expect(sink.edits.isEmpty, "nothing is emitted while dragging")
        }
        #expect(tool.previewRect == Rect(x: 10, y: 10, width: 60, height: 40))
        tool.mouseUp(TestEvents.point(70, 50))
        #expect(sink.edits.count == 1)
        #expect(sink.edits[0].label == "Rectangle")
        #expect(sink.edits[0].insertedItems == RectangleSketchTool.items(for: Rect(x: 10, y: 10, width: 60, height: 40)))
        #expect(sink.edits[0].dirtyRect?.contains(Rect(x: 10, y: 10, width: 60, height: 40)) == true)
        #expect(tool.previewRect == nil)
        tool.mouseUp(TestEvents.point(90, 90))
        #expect(sink.edits.count == 1, "a stray mouse-up emits nothing")
    }

    @Test func clicksAndCancelledDragsEmitNothing() {
        let sink = RecordingSink()
        let fixture = activeTool(sink: sink)
        defer { withExtendedLifetime(fixture) {} }
        let tool = fixture.tool
        tool.mouseDown(TestEvents.point(10, 10))
        tool.mouseUp(TestEvents.point(10, 10))
        tool.mouseDown(TestEvents.point(10, 10))
        tool.mouseDragged(TestEvents.point(40, 10))
        tool.mouseUp(TestEvents.point(40, 10))
        tool.mouseDown(TestEvents.point(10, 10))
        tool.mouseDragged(TestEvents.point(50, 50))
        tool.cancel()
        tool.mouseDragged(TestEvents.point(60, 60))
        tool.mouseUp(TestEvents.point(60, 60))
        #expect(sink.edits.isEmpty)
        #expect(!tool.keyDown(TestEvents.key("a", keyCode: 0)))
        tool.flagsChanged(TestEvents.point(0, 0, .shift))
        #expect(tool.previewRect == nil)
    }

    @Test func modifiersChangeThePreviewMidDrag() {
        let fixture = activeTool(sink: RecordingSink())
        defer { withExtendedLifetime(fixture) {} }
        let tool = fixture.tool
        tool.mouseDown(TestEvents.point(100, 100))
        tool.mouseDragged(TestEvents.point(130, 110))
        #expect(tool.previewRect == Rect(x: 100, y: 100, width: 30, height: 10))
        tool.flagsChanged(TestEvents.point(0, 0, .shift))
        #expect(tool.previewRect == Rect(x: 100, y: 100, width: 30, height: 30), "Shift: a square")
        tool.flagsChanged(TestEvents.point(0, 0, [.shift, .option]))
        #expect(tool.previewRect == Rect(x: 70, y: 70, width: 60, height: 60), "Option: from the centre")
        tool.flagsChanged(TestEvents.point(0, 0, []))
        #expect(tool.previewRect == Rect(x: 100, y: 100, width: 30, height: 10))
        #expect(RectangleSketchTool.rect(anchor: Point(x: 0, y: 0), to: Point(x: -10, y: 4), modifiers: .shift) == Rect(x: -10, y: 0, width: 10, height: 10))
        #expect(RectangleSketchTool.rect(anchor: Point(x: 0, y: 0), to: Point(x: 3, y: -8), modifiers: .shift) == Rect(x: 0, y: -8, width: 8, height: 8))
    }

    @Test func throughTheManagerTheModifierReachesTheCommittedRectangle() {
        let environment = TestEnvironment()
        let host = RecordingHost()
        defer { withExtendedLifetime(host) {} }
        let content = PlaceholderDocumentContent.blank(canvas: "doc")
        let document = DocumentHandle.placeholder(title: "Doc", content: content)
        var dirty: [Rect?] = []
        document.observe { dirty.append($0) }
        let manager = ToolManager(registry: environment.tools, context: ToolContext(document: document, host: host), initialTool: .rectangle)
        manager.mouseDown(TestEvents.point(0, 0))
        manager.mouseDragged(TestEvents.point(20, 10))
        manager.flagsChanged(.shift)
        manager.mouseUp(TestEvents.point(20, 10, .shift))
        #expect(content.edits.count == 1)
        #expect(content.edits[0].insertedItems == RectangleSketchTool.items(for: Rect(x: 0, y: 0, width: 20, height: 20)))
        #expect(content.displayList.count == 4, "the page's fill and stroke plus the rectangle's")
        #expect(document.displayList == content.displayList)
        #expect(dirty.count == 1)
    }

    @Test func drawsThePreviewOnlyWhileDragging() {
        let fixture = activeTool(sink: RecordingSink())
        defer { withExtendedLifetime(fixture) {} }
        let tool = fixture.tool
        let host = fixture.host
        let surface = BitmapSurface(width: 50, height: 50)!
        tool.drawOverlay(in: surface.context, viewport: host.viewport)
        #expect(surface.pixel(x: 10, y: 10).alpha == 0)
        tool.mouseDown(TestEvents.point(5, 5))
        tool.mouseDragged(TestEvents.point(40, 40))
        tool.drawOverlay(in: surface.context, viewport: host.viewport)
        tool.deactivate()
        #expect(tool.previewRect == nil)
    }
}

@Suite @MainActor struct ViewToolTests {
    private func context(_ host: RecordingHost) -> ToolContext {
        ToolContext(document: .placeholder(title: "View"), host: host)
    }

    @Test func theHandScrollsByTheDragAndSwapsItsCursor() {
        let host = RecordingHost(viewport: Viewport(scrollOrigin: Point(x: 500, y: 500), size: Size(width: 400, height: 300)))
        defer { withExtendedLifetime(host) {} }
        let tool = PanTool()
        tool.activate(in: context(host))
        #expect(tool.cursor == NSCursor.openHand)
        tool.mouseDragged(TestEvents.point(0, 0))
        tool.mouseDown(TestEvents.point(100, 100))
        #expect(tool.cursor == NSCursor.closedHand)
        tool.mouseDragged(TestEvents.point(90, 80))
        #expect(host.viewport.scrollOrigin == Point(x: 510, y: 520))
        tool.mouseUp(TestEvents.point(90, 80))
        #expect(tool.cursor == NSCursor.openHand)
        #expect(host.cursorChanges == 2)
        tool.flagsChanged(TestEvents.point(0, 0))
        #expect(!tool.keyDown(TestEvents.key("a", keyCode: 0)))
        tool.drawOverlay(in: BitmapSurface(width: 2, height: 2)!.context, viewport: host.viewport)
        tool.mouseDown(TestEvents.point(1, 1))
        tool.cancel()
        #expect(tool.lastViewPoint == nil)
        tool.deactivate()
    }

    @Test func zoomToolClickSteps() {
        let start = Viewport(scrollOrigin: Point(x: 7000, y: 7000), zoom: 1, size: Size(width: 400, height: 300))
        let click = TestEvents.point(100, 100)
        #expect(ZoomTool.target(viewport: start, start: click, end: click).zoom == 2)
        let zoomedIn = ZoomTool.target(viewport: start, start: click, end: click)
        #expect(zoomedIn.toPasteboard(click.viewPoint).isApproximatelyEqual(to: start.toPasteboard(click.viewPoint), tolerance: 1e-6), "centred on the click")
        #expect(ZoomTool.target(viewport: start, start: click, end: TestEvents.point(100, 101, .option)).zoom == 0.5)
        #expect(ZoomTool.target(viewport: start, start: click, end: TestEvents.point(100, 100, .control)).zoom == 256)
        #expect(ZoomTool.target(viewport: start, start: click, end: TestEvents.point(100, 100, [.control, .option])).zoom == 0.06)
    }

    @Test func zoomToolDragFitsTheArea() {
        let start = Viewport(scrollOrigin: Point(x: 7000, y: 7000), zoom: 1, size: Size(width: 400, height: 300))
        let from = CanvasEvent(pasteboardPoint: Point(x: 7100, y: 7100), viewPoint: Point(x: 100, y: 100))
        let to = CanvasEvent(pasteboardPoint: Point(x: 7136, y: 7126), viewPoint: Point(x: 136, y: 126))
        let fitted = ZoomTool.target(viewport: start, start: from, end: to)
        #expect(abs(fitted.zoom - 10) < 1e-9, "(400 - 40) / 36")

        let host = RecordingHost(viewport: start)
        defer { withExtendedLifetime(host) {} }
        let tool = ZoomTool()
        tool.activate(in: context(host))
        #expect(tool.cursor == NSCursor.crosshair)
        tool.mouseUp(from)
        #expect(host.viewport == start, "no press, no zoom")
        tool.mouseDown(from)
        tool.mouseDragged(to)
        tool.flagsChanged(TestEvents.point(0, 0, .shift))
        #expect(tool.current?.modifiers == .shift)
        let surface = BitmapSurface(width: 400, height: 300)!
        tool.drawOverlay(in: surface.context, viewport: start)
        tool.mouseUp(to)
        #expect(abs(host.viewport.zoom - 10) < 1e-9)
        #expect(tool.start == nil)
        tool.flagsChanged(TestEvents.point(0, 0, .shift))
        #expect(tool.current == nil)
        tool.drawOverlay(in: surface.context, viewport: start)
        #expect(!tool.keyDown(TestEvents.key("a", keyCode: 0)))
        tool.deactivate()
    }

    @Test func unimplementedToolsSayComingSoonAndWriteNothing() {
        let host = RecordingHost()
        defer { withExtendedLifetime(host) {} }
        let sink = RecordingSink()
        let tool = UnimplementedTool(id: "pen", title: "Pen")
        tool.activate(in: ToolContext(document: DocumentHandle(title: "U", commandSink: sink) { DisplayList(canvas: "u", items: []) }, host: host))
        tool.mouseDown(TestEvents.point(0, 0))
        tool.mouseDragged(TestEvents.point(5, 5))
        tool.mouseUp(TestEvents.point(5, 5))
        tool.flagsChanged(TestEvents.point(5, 5))
        tool.cancel()
        tool.drawOverlay(in: BitmapSurface(width: 2, height: 2)!.context, viewport: host.viewport)
        #expect(!tool.keyDown(TestEvents.key("a", keyCode: 0)))
        #expect(host.messages == ["The Pen tool is coming soon"])
        #expect(tool.pressCount == 1)
        #expect(sink.edits.isEmpty)
        #expect(tool.toolID == "pen")
        #expect(UnimplementedTool.id == "unimplemented")
        #expect(RectangleSketchTool.id == .rectangle && PanTool.id == .hand && ZoomTool.id == .zoom)
        tool.deactivate()
        tool.mouseDown(TestEvents.point(0, 0))
        #expect(host.messages.count == 1)
    }

    @Test func snappingIsAnIdentityPlaceholderReadingThePreferences() {
        let snapping = SnappingContext()
        #expect(snapping.snap(Point(x: 1, y: 2), viewport: Viewport(size: Size(width: 1, height: 1))) == Point(x: 1, y: 2))
        #expect(snapping.snapDistance() == 3)
        #expect(snapping.pickDistance() == 3)
        #expect(snapping.smartGuidesEnabled())
        let host = RecordingHost()
        let context = ToolContext(document: .placeholder(title: "S"), host: host)
        #expect(context.viewport == host.viewport)
    }
}
