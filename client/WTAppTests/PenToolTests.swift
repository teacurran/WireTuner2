import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// Drawing settings a test changes while a tool reads them.
@MainActor
final class SettingsBox {
    var value = DrawingSettings()
}

/// DRAW-021: the Pen tool and its path-building session.
@Suite @MainActor struct PenToolTests {
    @MainActor
    final class Fixture {
        let tool = PenTool()
        let host = RecordingHost(viewport: Viewport(size: Size(width: 400, height: 300)))
        let document = DocumentHandle.memory(title: "Pen")
        let context: ToolContext
        private let box = SettingsBox()

        var settings: DrawingSettings {
            get { box.value }
            set { box.value = newValue }
        }

        init() {
            var context = ToolContext(document: document, host: host)
            let box = box
            context.drawing = { box.value }
            self.context = context
            tool.activate(in: context)
        }

        /// A click (press and release without moving) at `x, y`.
        func click(_ x: Double, _ y: Double, _ modifiers: KeyModifiers = [], count: Int = 1) async {
            let event = CanvasEvent(pasteboardPoint: Point(x: x, y: y), viewPoint: Point(x: x, y: y), modifiers: modifiers, clickCount: count)
            tool.mouseDown(event)
            tool.mouseUp(event)
            await tool.settle()
            await document.settle()
        }

        /// A press at `from` dragged to `to`.
        func drag(_ from: Point, _ to: Point, _ modifiers: KeyModifiers = []) async {
            tool.mouseDown(TestEvents.point(from.x, from.y, modifiers))
            tool.mouseDragged(TestEvents.point((from.x + to.x) / 2, (from.y + to.y) / 2, modifiers))
            tool.mouseUp(TestEvents.point(to.x, to.y, modifiers))
            await tool.settle()
            await document.settle()
        }

        /// The session's contour, drawn order.
        var drawn: [VectorPoint] {
            guard let session = tool.session else { return [] }
            return path(session.node)?.contour(session.contour)?.drawn ?? []
        }

        func path(_ node: OpID) -> VectorPath? {
            let state = document.state
            guard state.isLive(node) else { return nil }
            return VectorPath(state.props(node).path, node: node, state: state)
        }
    }

    @Test func clicksPlaceCornerPointsOneChangeEach() async throws {
        let fixture = Fixture()
        #expect(fixture.host.messages == [PenTool.statusMessage])
        #expect(fixture.tool.intent == .start)
        await fixture.click(10, 10)
        let session = try #require(fixture.tool.session)
        #expect(fixture.drawn.map(\.anchor) == [Point(x: 10, y: 10)])
        #expect(fixture.document.undoTitle == "Undo Pen")
        #expect(fixture.tool.intent == .add)
        await fixture.click(60, 10)
        await fixture.click(60, 60)
        #expect(fixture.drawn.map(\.anchor) == [Point(x: 10, y: 10), Point(x: 60, y: 10), Point(x: 60, y: 60)])
        #expect(fixture.drawn.allSatisfy { $0.kind == .corner && $0.inHandle == .zero && $0.outHandle == .zero })
        #expect(fixture.tool.session?.activeEnd == fixture.drawn.last?.id)
        #expect(fixture.document.undoTitle == "Undo Add Point")
        #expect(fixture.document.changeCount == 3, "each placed point is one change")
        #expect(fixture.context.selection.model.ids == [SelectionID(session.node)], "the path being drawn is selected")
        // Undoing every point removes the path: the creation is grouped with the first point.
        for _ in 0..<3 { _ = await fixture.document.undo().value }
        #expect(!fixture.document.state.isLive(session.node))
        #expect(fixture.document.selectableIDs().isEmpty)
    }

    @Test func dragsPlaceCurveConnectorAndBrokenPoints() async throws {
        let fixture = Fixture()
        await fixture.click(0, 0)
        await fixture.drag(Point(x: 50, y: 0), Point(x: 70, y: 10))
        var points = fixture.drawn
        #expect(points[1].kind == .curve)
        #expect(points[1].outHandle == Vector(dx: 20, dy: 10))
        #expect(points[1].inHandle == Vector(dx: -20, dy: -10), "a curve point's handles are a collinear pair")
        await fixture.drag(Point(x: 100, y: 0), Point(x: 100, y: 30), .control)
        points = fixture.drawn
        #expect(points[2].kind == .connector || points[2].kind == .corner, "a connector without one straight side reads as a corner")
        #expect(points[2].outHandle == Vector(dx: 0, dy: 30))
        #expect(points[2].inHandle == .zero)
        await fixture.drag(Point(x: 150, y: 0), Point(x: 160, y: 20), .option)
        points = fixture.drawn
        #expect(points[3].kind == .corner, "Option breaks the pair")
        #expect(points[3].outHandle == Vector(dx: 10, dy: 20))
        #expect(points[3].inHandle == .zero)
        // Cmd-drag moves the point itself.
        #expect(fixture.tool.info == ToolInfo())
        fixture.tool.mouseDown(TestEvents.point(200, 0))
        fixture.tool.mouseDragged(TestEvents.point(204, 3))
        #expect(fixture.tool.info == ToolInfo(delta: Vector(dx: 4, dy: 3)))
        fixture.tool.mouseDragged(TestEvents.point(210, 5, .command))
        fixture.tool.mouseUp(TestEvents.point(220, 10, .command))
        await fixture.tool.settle()
        await fixture.document.settle()
        #expect(fixture.drawn.last?.anchor == Point(x: 216, y: 7), "Cmd moved the point by the pointer's travel, handles and all")
        #expect(fixture.drawn.last?.kind == .curve)
        #expect(fixture.drawn.last?.outHandle == Vector(dx: 4, dy: 3))
    }

    @Test func shiftConstrainsTheSegmentAndTheHandle() async {
        let fixture = Fixture()
        await fixture.click(0, 0)
        await fixture.click(50, 4, .shift)
        #expect(fixture.drawn.last?.anchor.isApproximatelyEqual(to: Point(x: 50, y: 0), tolerance: 1e-9) == true)
        fixture.settings.constrainAngle = 90
        await fixture.drag(Point(x: 50, y: 50), Point(x: 53, y: 80), .shift)
        let handle = fixture.drawn.last?.outHandle ?? .zero
        #expect(abs(handle.dx) < 1e-9 && abs(handle.dy - 30) < 1e-9, "the handle snaps to the constrain angle")
    }

    @Test func clickingTheFirstPointClosesAndEndsTheSession() async throws {
        let fixture = Fixture()
        await fixture.click(10, 10)
        await fixture.click(60, 10)
        await fixture.click(60, 60)
        let session = try #require(fixture.tool.session)
        fixture.tool.pointerMoved(TestEvents.point(11, 11))
        #expect(fixture.tool.intent == .close)
        #expect(fixture.tool.cursor === PenCursors.close)
        await fixture.click(11, 11)
        #expect(fixture.tool.session == nil)
        let contour = try #require(fixture.path(session.node)?.contour(session.contour))
        #expect(contour.closed && contour.points.count == 3)
        #expect(fixture.document.undoTitle == "Undo Close Path")
    }

    @Test func tabEscapeAndDoubleClickEndThePath() async {
        let fixture = Fixture()
        await fixture.click(10, 10)
        #expect(!fixture.tool.keyDown(TestEvents.key("a", keyCode: 0)))
        #expect(fixture.tool.keyDown(TestEvents.key("\t", keyCode: PenTool.tabKeyCode)))
        #expect(fixture.tool.session == nil)
        #expect(!fixture.tool.keyDown(TestEvents.key("\t", keyCode: PenTool.tabKeyCode)), "no session, Tab is not the Pen's")
        await fixture.click(20, 20)
        fixture.tool.cancel()
        #expect(fixture.tool.session == nil)
        await fixture.click(30, 30)
        await fixture.click(40, 40)
        await fixture.click(40, 40, count: 2)
        #expect(fixture.tool.session == nil)
        #expect(fixture.document.selectableIDs().count == 1, "only the two-point path renders")
        fixture.tool.flagsChanged(TestEvents.point(0, 0, .shift))
        fixture.tool.deactivate()
        #expect(fixture.tool.context == nil)
    }

    @Test func aPathDeletedElsewhereMakesTheNextClickStartANewOne() async throws {
        let fixture = Fixture()
        await fixture.click(10, 10)
        await fixture.click(20, 10)
        let first = try #require(fixture.tool.session)
        _ = await fixture.document.perform(DeleteNodes([first.node])).value
        await fixture.click(30, 30)
        let second = try #require(fixture.tool.session)
        #expect(second.node != first.node)
        #expect(fixture.drawn.map(\.anchor) == [Point(x: 30, y: 30)])
    }

    @Test func aDeletedStartPointIsNotOfferedForClosing() async throws {
        let fixture = Fixture()
        await fixture.click(10, 10)
        await fixture.click(60, 10)
        await fixture.click(60, 60)
        let session = try #require(fixture.tool.session)
        let start = try #require(fixture.drawn.first)
        _ = await fixture.document.perform(DeletePoints(node: session.node, points: [(session.contour, start.id)])).value
        #expect(!fixture.tool.closesPath(at: Point(x: 10, y: 10)))
        await fixture.click(10, 10)
        #expect(fixture.tool.session != nil, "the click placed an ordinary point")
        #expect(fixture.drawn.map(\.anchor) == [Point(x: 60, y: 10), Point(x: 60, y: 60), Point(x: 10, y: 10)])
    }

    @Test func thePreviewFollowsThePointerAndCanBeTurnedOff() async {
        let fixture = Fixture()
        let surface = BitmapSurface(width: 100, height: 100)!
        fixture.tool.drawOverlay(in: surface.context, viewport: fixture.host.viewport)
        #expect(fixture.tool.previewSegment == nil, "no session, no preview")
        await fixture.click(10, 10)
        fixture.tool.pointerMoved(TestEvents.point(50, 50))
        #expect(fixture.tool.previewSegment?.elements.count == 2)
        fixture.tool.drawOverlay(in: surface.context, viewport: fixture.host.viewport)
        await fixture.drag(Point(x: 40, y: 10), Point(x: 50, y: 20))
        fixture.tool.pointerMoved(TestEvents.point(80, 80))
        if case .cubicCurve? = fixture.tool.previewSegment?.elements.last {} else {
            Issue.record("after a curve point the preview is a curve")
        }
        fixture.tool.mouseDown(TestEvents.point(90, 90))
        fixture.tool.mouseDragged(TestEvents.point(95, 95))
        fixture.tool.drawOverlay(in: surface.context, viewport: fixture.host.viewport)
        fixture.tool.cancel()
        fixture.settings.penPreview = false
        await fixture.click(10, 50)
        fixture.tool.pointerMoved(TestEvents.point(50, 50))
        #expect(fixture.tool.previewSegment == nil, "Pen tool preview off")
        #expect(fixture.host.cursorChanges > 0)
        #expect(PenCursors.cursor(for: .start) === PenCursors.start && PenCursors.cursor(for: .add) === PenCursors.add)
    }

    @Test func aResumedSessionExtendsTheStartOfAMovedPath() async throws {
        let fixture = Fixture()
        await fixture.click(10, 10)
        await fixture.click(60, 10)
        let session = try #require(fixture.tool.session)
        let first = try #require(fixture.drawn.first)
        _ = await fixture.document.perform(SetTransforms([(session.node, .translation(x: 100, y: 0))])).value
        fixture.tool.finish()
        fixture.tool.resume(PathBuildingSession(node: session.node, contour: session.contour, activeEnd: first.id, end: .start))
        #expect(fixture.tool.activeAnchor == Point(x: 110, y: 10), "the path's transform places the active end")
        #expect(fixture.tool.closesPath(at: Point(x: 160, y: 10)), "the other end, where it is drawn, closes")
        await fixture.click(100, 50)
        #expect(fixture.drawn.map(\.anchor) == [Point(x: 0, y: 50), Point(x: 10, y: 10), Point(x: 60, y: 10)],
                "extending the start prepends, in the path's own coordinates")
        await fixture.drag(Point(x: 90, y: 90), Point(x: 95, y: 100))
        fixture.tool.pointerMoved(TestEvents.point(40, 40))
        #expect(fixture.tool.previewSegment != nil)
    }

    @Test func aPathDeletedBetweenPressAndReleaseStartsANewOne() async throws {
        let fixture = Fixture()
        await fixture.click(10, 10)
        let first = try #require(fixture.tool.session)
        fixture.tool.mouseDown(TestEvents.point(30, 30))
        _ = await fixture.document.perform(DeleteNodes([first.node])).value
        fixture.tool.mouseUp(TestEvents.point(30, 30))
        await fixture.tool.settle()
        await fixture.document.settle()
        #expect(fixture.tool.session?.node != first.node)
        #expect(fixture.drawn.map(\.anchor) == [Point(x: 30, y: 30)])
    }

    @Test func failedCommitsLeaveTheSessionAlone() async {
        let host = RecordingHost()
        let sink = RecordingSink()
        let document = DocumentHandle.memory(title: "Sink")
        _ = await document.addPath([Point(x: 0, y: 0), Point(x: 10, y: 0)])
        var context = ToolContext(document: document, host: host)
        context.commandSink = sink
        let tool = PenTool()
        tool.activate(in: context)
        tool.mouseDown(TestEvents.point(5, 5))
        tool.mouseUp(TestEvents.point(5, 5))
        await tool.settle()
        #expect(tool.session == nil, "the creation performed nothing")
        let node = document.selectableIDs()[0].opID
        let contour = document.state.liveElements(node, PathFields.contours)[0]
        let end = document.state.liveElements(node, PathFields.points(contour))[1]
        tool.resume(PathBuildingSession(node: node, contour: contour, activeEnd: end, end: .end))
        tool.mouseDown(TestEvents.point(20, 0))
        tool.mouseUp(TestEvents.point(20, 0))
        await tool.settle()
        #expect(tool.session?.activeEnd == end, "an insert that performed nothing does not move the end")
        #expect(sink.commands.count == 2)
    }

    @Test func anInactiveToolPlacesNothingAndTheCursorsDraw() {
        let tool = PenTool()
        tool.mouseDown(TestEvents.point(1, 1))
        tool.mouseDragged(TestEvents.point(5, 5))
        #expect(tool.placement?.anchor == Point(x: 1, y: 1))
        tool.mouseUp(TestEvents.point(5, 5))
        #expect(tool.pending == nil)
        for cursor in [PenCursors.start, PenCursors.add, PenCursors.close] {
            var rect = NSRect(origin: .zero, size: cursor.image.size)
            #expect(cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) != nil)
        }
    }

    @Test func optionMidDragBreaksACurvePoint() async {
        let fixture = Fixture()
        await fixture.click(0, 0)
        fixture.tool.mouseDown(TestEvents.point(50, 0))
        fixture.tool.mouseDragged(TestEvents.point(60, 10))
        fixture.tool.mouseDragged(TestEvents.point(70, 10, .option))
        fixture.tool.mouseUp(TestEvents.point(70, 10, .option))
        await fixture.tool.settle()
        await fixture.document.settle()
        #expect(fixture.drawn.last?.kind == .corner)
        #expect(fixture.drawn.last?.outHandle == Vector(dx: 20, dy: 10))
        #expect(fixture.drawn.last?.inHandle == Vector(dx: -10, dy: -10), "the arriving handle stays where the curve drag left it")
    }

    @Test func aStrayDragOrReleaseDoesNothing() async {
        let fixture = Fixture()
        fixture.tool.mouseDragged(TestEvents.point(5, 5))
        fixture.tool.mouseUp(TestEvents.point(5, 5))
        await fixture.tool.settle()
        #expect(fixture.document.changeCount == 0)
        #expect(fixture.tool.placement == nil)
    }
}
