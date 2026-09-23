import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// OBJ-005 and OBJ-008 in the Pointer and Subselect tools (moving by drag, points by drag), and the
/// Lasso.
@Suite @MainActor struct PointerMoveTests {
    @MainActor
    final class Fixture {
        let selection: SelectionFixture
        let host = RecordingHost(viewport: SelectionFixture.viewport)
        let controller: SelectionController
        let tool: PointerTool
        var document: DocumentHandle { selection.document }

        init(_ selection: SelectionFixture, subselect: Bool = false, optionCopies: Bool = true, constrainAngle: Double = 0) {
            self.selection = selection
            controller = SelectionController(document: selection.document)
            tool = PointerTool(subselect: subselect)
            var context = ToolContext(document: selection.document, host: host, selection: controller)
            context.optionDragCopies = { optionCopies }
            context.drawing = { DrawingSettings(constrainAngle: constrainAngle) }
            tool.activate(in: context)
        }

        static func make(subselect: Bool = false, optionCopies: Bool = true) async -> Fixture {
            Fixture(await SelectionFixture.make(), subselect: subselect, optionCopies: optionCopies)
        }

        func drag(_ from: Point, _ to: Point, _ modifiers: KeyModifiers = []) {
            tool.mouseDown(TestEvents.point(from.x, from.y, modifiers))
            tool.mouseDragged(TestEvents.point((from.x + to.x) / 2, (from.y + to.y) / 2, modifiers))
            tool.mouseDragged(TestEvents.point(to.x, to.y, modifiers))
            tool.mouseUp(TestEvents.point(to.x, to.y, modifiers))
        }

        func bounds(_ id: SelectionID) -> Rect? { document.object(for: id)?.bounds }
    }

    @Test func draggingAnObjectSelectsAndMovesItInOneChange() async throws {
        let f = await Fixture.make()
        let before = f.bounds(f.selection.a)!
        let changes = f.document.changeCount
        f.tool.mouseDown(TestEvents.point(30, 30))
        #expect(f.tool.gesture == .move)
        #expect(f.controller.selection.ids == [f.selection.a], "the press selects it")
        f.tool.mouseDragged(TestEvents.point(40, 35))
        #expect(f.tool.moveDelta == Vector(dx: 10, dy: 5))
        #expect(f.tool.movePreview.count == 1)
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        f.tool.drawOverlay(in: context, viewport: SelectionFixture.viewport)
        f.tool.mouseUp(TestEvents.point(40, 35))
        await f.document.settle()
        #expect(f.document.changeCount == changes + 1)
        #expect(f.document.undoTitle == "Undo Move")
        let after = f.bounds(f.selection.a)!
        #expect(abs(after.minX - before.minX - 10) < 1e-9 && abs(after.minY - before.minY - 5) < 1e-9)
    }

    @Test func shiftConstrainsAndEscapeCancels() async throws {
        let f = await Fixture.make()
        let before = f.bounds(f.selection.a)!
        f.tool.mouseDown(TestEvents.point(30, 30))
        f.tool.mouseDragged(TestEvents.point(60, 33))
        f.tool.flagsChanged(TestEvents.point(0, 0, .shift))
        #expect(f.tool.moveDelta?.dy == 0)
        f.tool.cancel()
        f.tool.mouseUp(TestEvents.point(60, 33))
        await f.document.settle()
        #expect(f.bounds(f.selection.a) == before)
    }

    @Test func optionDragMovesACopy() async throws {
        let f = await Fixture.make()
        let before = f.bounds(f.selection.a)!
        f.drag(Point(x: 30, y: 30), Point(x: 30, y: 230), .option)
        await f.document.settle()
        try await Task.sleep(for: .milliseconds(20))
        #expect(f.bounds(f.selection.a) == before)
        let copy = try #require(f.controller.selection.ids.first)
        #expect(copy != f.selection.a)
        #expect(abs(f.bounds(copy)!.minY - before.minY - 200) < 1e-9)
        // Without *Option-drag copies paths* the original moves.
        let g = await Fixture.make(optionCopies: false)
        g.drag(Point(x: 30, y: 30), Point(x: 30, y: 60), .option)
        await g.document.settle()
        #expect(abs(g.bounds(g.selection.a)!.minY - before.minY - 30) < 1e-9)
    }

    @Test func clicksStillSelectAndMarqueesStillWork() async throws {
        let f = await Fixture.make()
        f.drag(Point(x: 30, y: 30), Point(x: 30.5, y: 30))
        #expect(f.controller.selection.ids == [f.selection.a])
        // Shift-click on the selected object removes it.
        f.drag(Point(x: 30, y: 30), Point(x: 30, y: 30), .shift)
        #expect(f.controller.selection.isEmpty)
        // Shift-click adds.
        f.drag(Point(x: 30, y: 30), Point(x: 30, y: 30), .shift)
        f.drag(Point(x: 120, y: 30), Point(x: 120, y: 30), .shift)
        #expect(Set(f.controller.selection.ids) == [f.selection.a, f.selection.b])
        // A click on a selected object keeps the selection; a click on nothing clears it.
        f.drag(Point(x: 30, y: 30), Point(x: 30, y: 30))
        #expect(f.controller.selection.count == 2)
        f.drag(Point(x: 380, y: 280), Point(x: 380, y: 280))
        #expect(f.controller.selection.isEmpty)
        // A marquee from nothing.
        f.tool.mouseDown(TestEvents.point(0, 0))
        f.tool.mouseDragged(TestEvents.point(160, 70))
        #expect(f.tool.marqueeRect == Rect(x: 0, y: 0, width: 160, height: 70))
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        f.tool.drawOverlay(in: context, viewport: SelectionFixture.viewport)
        f.tool.mouseUp(TestEvents.point(160, 70))
        #expect(Set(f.controller.selection.ids) == [f.selection.a, f.selection.b])
        #expect(f.tool.moveDelta == nil && f.tool.movePreview.isEmpty)
        f.tool.mouseDragged(TestEvents.point(1, 1))
        f.tool.flagsChanged(TestEvents.point(0, 0, .shift))
        f.tool.mouseUp(TestEvents.point(1, 1))
        f.tool.forceClick(TestEvents.point(210, 20))
        #expect(f.controller.selection.ids == [f.selection.member])
        #expect(!f.tool.keyDown(TestEvents.key("a", keyCode: 0)))
        f.tool.deactivate()
        f.tool.forceClick(TestEvents.point(30, 30))
    }

    @Test func subselectDragsMoveTheSelectedPoints() async throws {
        let f = await Fixture.make(subselect: true)
        #expect(f.tool.toolID == PointerTool.subselectID)
        let path = try #require(await f.document.addPath([Point(x: 100, y: 200), Point(x: 150, y: 200)]))
        // A press on an unselected point selects it and drags it.
        f.drag(Point(x: 150, y: 200), Point(x: 150, y: 220))
        await f.document.settle()
        #expect(f.document.path(path)?.contours[0].drawn.map(\.anchor) == [Point(x: 100, y: 200), Point(x: 150, y: 220)])
        #expect(f.document.undoTitle == "Undo Move Point")
        // Pressing on a selected point drags every selected point.
        let contour = f.document.path(path)!.contours[0]
        let points = Set(contour.points.map { PointReference(node: path.node, contour: contour.id, point: $0.id) })
        f.controller.model.set(Selection([path]).applying([path], sub: [path: .points(points)], mode: .add))
        f.tool.mouseDown(TestEvents.point(100, 200))
        #expect(f.tool.gesture == .movePoints)
        f.tool.mouseDragged(TestEvents.point(105, 200))
        #expect(f.tool.movePreview.count == 1)
        f.tool.mouseUp(TestEvents.point(105, 200))
        await f.document.settle()
        #expect(f.document.path(path)?.contours[0].drawn.map(\.anchor) == [Point(x: 105, y: 200), Point(x: 155, y: 220)])
        // Shift-press on a point toggles it on release, without dragging.
        f.tool.mouseDown(TestEvents.point(105, 200, .shift))
        #expect(f.tool.gesture == .movePoints)
        f.tool.mouseUp(TestEvents.point(105, 200, .shift))
        f.tool.mouseDown(TestEvents.point(105, 200, .shift))
        #expect(f.tool.gesture == .marquee)
        f.tool.mouseUp(TestEvents.point(105, 200, .shift))
    }

    @Test func theLassoSelectsObjectsAndPointsInsideTheLoop() async throws {
        let selection = await SelectionFixture.make()
        let document = selection.document
        let path = try #require(await document.addPath([Point(x: 100, y: 200), Point(x: 150, y: 200), Point(x: 200, y: 200)]))
        let host = RecordingHost(viewport: SelectionFixture.viewport)
        let controller = SelectionController(document: document)
        let tool = LassoTool()
        tool.activate(in: ToolContext(document: document, host: host, selection: controller))
        #expect(host.messages.last == LassoTool.statusMessage && tool.cursor == NSCursor.crosshair)
        // Around the first rectangle only.
        let loop = [Point(x: 0, y: 0), Point(x: 70, y: 0), Point(x: 70, y: 70), Point(x: 0, y: 70)]
        tool.mouseDown(TestEvents.point(loop[0].x, loop[0].y))
        for point in loop.dropFirst() { tool.mouseDragged(TestEvents.point(point.x, point.y)) }
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        tool.drawOverlay(in: context, viewport: SelectionFixture.viewport)
        tool.flagsChanged(TestEvents.point(0, 0))
        tool.mouseUp(TestEvents.point(0, 70))
        #expect(controller.selection.ids == [selection.a])
        // Around two of the path's points: those points.
        let (picked, sub) = LassoTool.pick(loop: [Point(x: 90, y: 190), Point(x: 160, y: 190), Point(x: 160, y: 210), Point(x: 90, y: 210)],
                                           in: document, contactSensitive: false)
        #expect(picked == [path])
        if case let .points(points)? = sub[path] { #expect(points.count == 2) } else { Issue.record("points") }
        // Contact-sensitive: touching is enough.
        let touching = LassoTool.pick(loop: [Point(x: 20, y: 20), Point(x: 90, y: 20), Point(x: 90, y: 30)], in: document, contactSensitive: true)
        #expect(touching.0.contains(selection.a))
        #expect(LassoTool.contains(loop, Point(x: 10, y: 10)) && !LassoTool.contains(loop, Point(x: 80, y: 10)))
        // Too short a loop selects nothing; a stray drag does nothing.
        tool.mouseDragged(TestEvents.point(5, 5))
        tool.mouseDown(TestEvents.point(0, 0))
        tool.mouseUp(TestEvents.point(1, 1))
        #expect(!tool.keyDown(TestEvents.key("a", keyCode: 0)))
        tool.deactivate()
    }
}
