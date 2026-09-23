import AppKit
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

@Suite @MainActor struct ViewToolTests {
    private func context(_ host: RecordingHost) -> ToolContext {
        ToolContext(document: .memory(title: "View"), host: host)
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
        var context = ToolContext(document: .memory(title: "U"), host: host)
        context.commandSink = sink
        tool.activate(in: context)
        tool.mouseDown(TestEvents.point(0, 0))
        tool.mouseDragged(TestEvents.point(5, 5))
        tool.mouseUp(TestEvents.point(5, 5))
        tool.flagsChanged(TestEvents.point(5, 5))
        tool.cancel()
        tool.drawOverlay(in: BitmapSurface(width: 2, height: 2)!.context, viewport: host.viewport)
        #expect(!tool.keyDown(TestEvents.key("a", keyCode: 0)))
        #expect(host.messages == ["The Pen tool is coming soon"])
        #expect(tool.pressCount == 1)
        #expect(sink.commands.isEmpty)
        #expect(tool.toolID == "pen")
        #expect(UnimplementedTool.id == "unimplemented")
        #expect(RectangleTool.id == .rectangle && PanTool.id == .hand && ZoomTool.id == .zoom)
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
        let context = ToolContext(document: .memory(title: "S"), host: host)
        #expect(context.viewport == host.viewport)
    }
}
