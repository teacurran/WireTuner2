import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// DRAW-022 (Bezigon), DRAW-023 (continue, auto-join), DRAW-024 (preview preference) and DRAW-026
/// (Pen click on a segment).
@Suite @MainActor struct PenBezigonTests {
    @MainActor
    final class Fixture {
        let host = RecordingHost(viewport: Viewport(size: Size(width: 400, height: 300)))
        let document = DocumentHandle.memory(title: "Bezigon")
        let selection: SelectionController
        let editing: ObjectEditing
        var context: ToolContext
        var settings = DrawingSettings()

        init() {
            selection = SelectionController(document: document)
            editing = ObjectEditing(document: document, selection: selection,
                                    pasteboard: SystemObjectPasteboard(NSPasteboard(name: NSPasteboard.Name("pen.\(UUID().uuidString)"))))
            context = ToolContext(document: document, host: host, selection: selection)
            context.objectEditing = editing
            context.commandSink = editing
        }

        func activate(_ tool: PenTool, autoJoin: Bool = true) {
            var context = context
            let settings = DrawingSettings(autoJoin: autoJoin)
            context.drawing = { settings }
            tool.activate(in: context)
        }

        func click(_ tool: PenTool, _ x: Double, _ y: Double, _ modifiers: KeyModifiers = []) async {
            let event = CanvasEvent(pasteboardPoint: Point(x: x, y: y), viewPoint: Point(x: x, y: y), modifiers: modifiers)
            tool.mouseDown(event)
            tool.mouseUp(event)
            await tool.settle()
            await document.settle()
        }

        func drawn(_ session: PathBuildingSession?) -> [VectorPoint] {
            guard let session else { return [] }
            return document.object(for: SelectionID(session.node))?.path?.contour(session.contour)?.drawn ?? []
        }
    }

    @Test func bezigonClicksPlaceCornerAutomaticAndConnectorPoints() async throws {
        let f = Fixture()
        let tool = PenTool(bezigon: true)
        #expect(tool.toolID == PenTool.bezigonID && tool.isBezigon)
        f.activate(tool)
        #expect(f.host.messages.last == PenTool.bezigonStatusMessage)
        await f.click(tool, 10, 10)
        #expect(f.document.undoTitle == "Undo Bezigon")
        await f.click(tool, 50, 40, .option)
        await f.click(tool, 90, 10, .control)
        await f.click(tool, 130, 40, .option)
        let points = f.drawn(tool.session)
        let session = try #require(tool.session)
        let stored = f.document.object(for: SelectionID(session.node))?.path?.contour(session.contour)?.points.map(\.kind)
        #expect(stored == [.corner, .curve, .connector, .curve], "a connector between two curves reads as a corner, but is stored as one")
        #expect(points[1].automatic && points[3].automatic)
        // The automatic point's handles come from its neighbours.
        #expect(points[1].outHandle == (Point(x: 90, y: 10) - Point(x: 10, y: 10)) / 6)
        // A drag places no handles; Cmd-drag moves the point being placed.
        tool.mouseDown(TestEvents.point(170, 10))
        tool.mouseDragged(TestEvents.point(190, 30))
        #expect(tool.placement?.outHandle == .zero)
        tool.mouseDragged(TestEvents.point(195, 35, .command))
        #expect(tool.placement?.anchor == Point(x: 175, y: 15))
        tool.mouseUp(TestEvents.point(195, 35, .command))
        await tool.settle()
        await f.document.settle()
        #expect(f.drawn(tool.session).last?.anchor == Point(x: 175, y: 15))
    }

    @Test func switchingBetweenPenAndBezigonContinuesTheContour() async throws {
        let f = Fixture()
        let pen = PenTool()
        f.activate(pen)
        await f.click(pen, 10, 10)
        await f.click(pen, 50, 10)
        let session = try #require(pen.session)
        pen.deactivate()
        #expect(f.editing.pathSession == session, "the window keeps the session")
        let bezigon = PenTool(bezigon: true)
        f.activate(bezigon)
        #expect(bezigon.session == session)
        await f.click(bezigon, 90, 30, .option)
        #expect(f.drawn(bezigon.session).count == 3)
        bezigon.deactivate()
        f.activate(pen)
        await f.click(pen, 130, 10)
        #expect(f.drawn(pen.session).count == 4)
        // A tool without a window ends its own session.
        let lone = PenTool()
        var context = ToolContext(document: f.document, host: f.host)
        context.drawing = { DrawingSettings() }
        lone.activate(in: context)
        await f.click(lone, 10, 200)
        #expect(lone.session != nil)
        lone.deactivate()
        lone.activate(in: context)
        #expect(lone.session == nil)
    }

    @Test func aClickOnASelectedEndContinuesThatPath() async throws {
        let f = Fixture()
        let line = try #require(await f.document.addPath([Point(x: 0, y: 100), Point(x: 50, y: 100)]))
        let pen = PenTool()
        f.activate(pen)
        f.selection.model.set(Selection([line]))
        await f.click(pen, 50, 100)
        #expect(pen.session?.node == line.opID && pen.session?.end == .end)
        await f.click(pen, 90, 120)
        #expect(f.document.path(line)?.contours[0].drawn.map(\.anchor).last == Point(x: 90, y: 120))
        pen.finish()
        // Option: any path's end, from its start.
        f.selection.model.clear()
        await f.click(pen, 0, 100, .option)
        #expect(pen.session?.end == .start)
        await f.click(pen, -40, 100)
        #expect(f.document.path(line)?.contours[0].drawn.first?.anchor == Point(x: -40, y: 100))
    }

    @Test func autoJoinJoinsAnotherPathsEnd() async throws {
        let f = Fixture()
        let other = try #require(await f.document.addPath([Point(x: 200, y: 50), Point(x: 250, y: 50)]))
        let pen = PenTool()
        f.activate(pen)
        await f.click(pen, 10, 50)
        await f.click(pen, 100, 50)
        let node = try #require(pen.session?.node)
        pen.pointerMoved(TestEvents.point(250, 50))
        #expect(pen.intent == .join)
        #expect(pen.cursor == PenCursors.join)
        await f.click(pen, 250, 50)
        #expect(f.document.undoTitle == "Undo Join")
        #expect(pen.session == nil)
        #expect(f.document.object(for: other) == nil)
        let anchors = f.document.path(SelectionID(node))?.contours[0].drawn.map(\.anchor)
        #expect(anchors == [Point(x: 10, y: 50), Point(x: 100, y: 50), Point(x: 250, y: 50), Point(x: 200, y: 50)], "joined at its end, reversed")
        // Auto-join off: a normal point.
        let g = Fixture()
        let target = try #require(await g.document.addPath([Point(x: 200, y: 50), Point(x: 250, y: 50)]))
        let plain = PenTool()
        g.activate(plain, autoJoin: false)
        await g.click(plain, 10, 50)
        await g.click(plain, 200, 50)
        #expect(g.document.object(for: target) != nil)
        #expect(g.drawn(plain.session).count == 2)
    }

    @Test func aClickOnASelectedSegmentAddsAPoint() async throws {
        let f = Fixture()
        let line = try #require(await f.document.addPath([Point(x: 0, y: 100), Point(x: 100, y: 100)]))
        let pen = PenTool()
        f.activate(pen)
        f.selection.model.set(Selection([line]))
        await f.click(pen, 40, 100)
        #expect(pen.session == nil)
        #expect(f.document.path(line)?.contours[0].drawn.map(\.anchor) == [Point(x: 0, y: 100), Point(x: 40, y: 100), Point(x: 100, y: 100)])
        #expect(f.document.undoTitle == "Undo Add Point")
    }

    @Test func thePreviewFollowsThePreferenceLive() async throws {
        let f = Fixture()
        let pen = PenTool()
        var context = f.context
        let box = SettingsBox()
        context.drawing = { box.value }
        pen.activate(in: context)
        await f.click(pen, 10, 10)
        pen.pointerMoved(TestEvents.point(60, 60))
        #expect(pen.previewSegment != nil)
        box.value.penPreview = false
        #expect(pen.previewSegment == nil, "no restart needed")
    }

    @Test func switchingToAnotherKindOfToolEndsTheWindowsSession() async throws {
        let environment = TestEnvironment()
        DrawingTools.install(into: environment.tools)
        let controller = DocumentWindowController(document: .memory(title: "Session"), environment: environment.document)
        controller.objectEditing.pathSession = PathBuildingSession(node: OpID(counter: 1, replica: 1), contour: .zero, activeEnd: .zero, end: .end)
        controller.toolManager.select(PenTool.bezigonID)
        #expect(controller.objectEditing.pathSession != nil)
        controller.toolManager.select(.rectangle)
        #expect(controller.objectEditing.pathSession == nil)
        controller.close()
    }
}
