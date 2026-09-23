import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

@Suite @MainActor struct TransformHandlesTests {
    let viewport = SelectionFixture.viewport
    let handles = TransformHandles(bounds: Rect(x: 10, y: 10, width: 50, height: 50))
    let constraint = AngleConstraint.degrees(0)

    @Test func zonesAreInScreenSpace() {
        #expect(handles.center == Point(x: 35, y: 35))
        #expect(handles.zone(at: Point(x: 35, y: 35), viewport: viewport) == .center)
        #expect(handles.zone(at: Point(x: 10, y: 10), viewport: viewport) == .scale(.topLeft))
        #expect(handles.zone(at: Point(x: 61, y: 36), viewport: viewport) == .scale(.right))
        #expect(handles.zone(at: Point(x: 2, y: 2), viewport: viewport) == .rotate(.topLeft))
        #expect(handles.zone(at: Point(x: 22, y: 10), viewport: viewport) == .skew(.top))
        #expect(handles.zone(at: Point(x: 10, y: 25), viewport: viewport) == .skew(.left))
        #expect(handles.zone(at: Point(x: 30, y: 45), viewport: viewport) == .move)
        #expect(handles.zone(at: Point(x: 200, y: 200), viewport: viewport) == nil)
        #expect(TransformHandles.opposite(.topLeft) == .bottomRight && TransformHandles.opposite(.left) == .right)
        #expect(HandleAnchor.allCases.filter(\.isCorner).count == 4 && HandleEdge.allCases.filter(\.isHorizontal).count == 2)
        #expect(TransformHandles.distance(from: Point(x: 3, y: 4), toSegment: .zero, .zero) == 5)
        #expect(TransformHandles(bounds: Rect(x: 0, y: 0, width: 10, height: 10), center: Point(x: 1, y: 1)).center == Point(x: 1, y: 1))
    }

    @Test func eachZoneMakesItsMatrix() throws {
        let move = try #require(handles.matrix(.move, from: Point(x: 30, y: 30), to: Point(x: 40, y: 33), constrained: false, constraint: constraint))
        #expect(move.apply(Point(x: 0, y: 0)) == Point(x: 10, y: 3))
        let constrained = try #require(handles.matrix(.move, from: Point(x: 30, y: 30), to: Point(x: 40, y: 33), constrained: true, constraint: constraint))
        #expect(constrained.apply(Point(x: 0, y: 0)).y == 0)
        let corner = try #require(handles.matrix(.scale(.topLeft), from: Point(x: 10, y: 10), to: Point(x: 0, y: 0), constrained: false, constraint: constraint))
        #expect(abs(corner.a - 1.4) < 1e-9 && abs(corner.d - 1.4) < 1e-9)
        let side = try #require(handles.matrix(.scale(.right), from: Point(x: 60, y: 35), to: Point(x: 85, y: 35), constrained: false, constraint: constraint))
        #expect(abs(side.a - 2) < 1e-9 && side.d == 1)
        let top = try #require(handles.matrix(.scale(.top), from: Point(x: 35, y: 10), to: Point(x: 35, y: 0), constrained: true, constraint: constraint))
        #expect(abs(top.d - 1.4) < 1e-9 && abs(top.a - 1.4) < 1e-9)
        let sideUniform = try #require(handles.matrix(.scale(.right), from: Point(x: 60, y: 35), to: Point(x: 10, y: 35), constrained: true, constraint: constraint))
        #expect(sideUniform.a == -1 && sideUniform.d == 1)
        let proportional = try #require(handles.matrix(.scale(.bottomRight), from: Point(x: 60, y: 60), to: Point(x: 85, y: 70), constrained: true, constraint: constraint))
        #expect(abs(proportional.a - proportional.d) < 1e-9)
        let collapsed = try #require(handles.matrix(.scale(.right), from: Point(x: 60, y: 35), to: Point(x: 35, y: 35), constrained: false, constraint: constraint))
        #expect(collapsed.a == TransformHandles.minimumScale)
        let flipped = try #require(handles.matrix(.scale(.right), from: Point(x: 60, y: 35), to: Point(x: 34.99999, y: 35), constrained: false, constraint: constraint))
        #expect(flipped.a == -TransformHandles.minimumScale)
        let flat = TransformHandles(bounds: Rect(x: 10, y: 10, width: 0, height: 0))
        #expect(flat.matrix(.scale(.right), from: Point(x: 10, y: 10), to: Point(x: 20, y: 20), constrained: false, constraint: constraint)?.a == 1)
        let rotate = try #require(handles.matrix(.rotate(.topRight), from: Point(x: 60, y: 10), to: Point(x: 60, y: 60), constrained: false, constraint: constraint))
        #expect(abs(rotate.apply(Point(x: 1, y: 0)).y - 1) < 1e-9)
        let snapped = try #require(handles.matrix(.rotate(.topRight), from: Point(x: 60, y: 10), to: Point(x: 62, y: 60), constrained: true, constraint: constraint))
        #expect(abs(snapped.apply(Point(x: 1, y: 0)).x) < 1e-9)
        let skew = try #require(handles.matrix(.skew(.top), from: Point(x: 22, y: 10), to: Point(x: 32, y: 10), constrained: false, constraint: constraint))
        #expect(abs(skew.c + 0.4) < 1e-9 || abs(skew.b + 0.4) < 1e-9)
        #expect(handles.matrix(.skew(.left), from: Point(x: 10, y: 25), to: Point(x: 10, y: 35), constrained: false, constraint: constraint) != nil)
        #expect(handles.matrix(.skew(.top), from: Point(x: 22, y: 35), to: Point(x: 32, y: 35), constrained: false, constraint: constraint) == nil)
        #expect(handles.matrix(.skew(.left), from: Point(x: 35, y: 25), to: Point(x: 35, y: 35), constrained: false, constraint: constraint) == nil)
        #expect(handles.matrix(.center, from: .zero, to: Point(x: 1, y: 1), constrained: false, constraint: constraint) == nil)
        #expect([TransformHandles.Zone.move, .center, .scale(.top), .rotate(.top), .skew(.top)].map(TransformHandles.kind) == [.move, .move, .scale, .rotate, .skew])
    }

    @Test func cursorsShowWhatADragDoes() {
        #expect(TransformHandles.cursor(nil, copying: false) == .arrow)
        #expect(TransformHandles.cursor(.move, copying: false) == .openHand)
        #expect(TransformHandles.cursor(.move, copying: true) == .dragCopy)
        #expect(TransformHandles.cursor(.center, copying: true) == .pointingHand)
        #expect(TransformHandles.cursor(.scale(.top), copying: false) == .resizeUpDown)
        #expect(TransformHandles.cursor(.scale(.left), copying: false) == .resizeLeftRight)
        #expect(TransformHandles.cursor(.scale(.topLeft), copying: false) == .crosshair)
        #expect(TransformHandles.cursor(.rotate(.topLeft), copying: false) == .crosshair)
        #expect(TransformHandles.cursor(.skew(.top), copying: false) == .resizeLeftRight)
        #expect(TransformHandles.cursor(.skew(.left), copying: false) == .resizeUpDown)
        handles.draw(in: bitmap(), viewport: viewport, color: CGColor(gray: 0, alpha: 1))
    }

    @Test func theCommandIsOneChangePerDrag() async throws {
        let fixture = await SelectionFixture.make()
        let selection = Selection([fixture.a])
        let scale = try #require(TransformHandles.command(.scale(.right), matrix: .scale(x: 2, y: 1), about: Point(x: 35, y: 35), selection: selection, copy: false) as? TransformObjects)
        #expect(scale.kind == .scale && scale.copies == 0 && scale.center == Point(x: 35, y: 35))
        let copy = try #require(TransformHandles.command(.move, matrix: .translation(x: 5, y: 0), about: .zero, selection: selection, copy: true) as? TransformObjects)
        #expect(copy.copies == 1 && copy.center == nil && copy.kind == .move)
        #expect(TransformHandles.command(.scale(.right), matrix: .scale(x: 0, y: 1), about: .zero, selection: selection, copy: false) == nil)
        #expect(TransformHandles.command(.move, matrix: .identity, about: .zero, selection: .empty, copy: false) == nil)
        let path = try #require(await fixture.document.addPath([Point(x: 10, y: 200), Point(x: 60, y: 220), Point(x: 90, y: 200)]))
        let contour = try #require(fixture.document.path(path)?.contours.first)
        let points = Selection().applying([path], sub: [path: .points([
            PointReference(node: path.node, contour: contour.id, point: contour.points[0].id),
            PointReference(node: path.node, contour: contour.id, point: contour.points[1].id),
        ])], mode: .replace)
        let batch = TransformHandles.command(.rotate(.top), matrix: .rotation(radians: 0.5), about: .zero, selection: points, copy: false)
        #expect(batch is CommandBatch)
        #expect(TransformHandles.bounds(of: points, document: fixture.document) == Rect(x: 10, y: 200, width: 50, height: 20))
        #expect(TransformHandles.bounds(of: .empty, document: fixture.document) == nil)
        #expect(TransformHandles.bounds(of: Selection([fixture.a, fixture.b]), document: fixture.document) == Rect(x: 10, y: 10, width: 140, height: 50))
    }
}

@Suite @MainActor struct PointerHandlesTests {
    @MainActor
    final class Fixture {
        let tool = PointerTool()
        let host = RecordingHost(viewport: SelectionFixture.viewport)
        let objects: SelectionFixture
        let selection: SelectionController
        var enabled = true

        private init(_ objects: SelectionFixture) {
            self.objects = objects
            selection = SelectionController(document: objects.document)
            var context = ToolContext(document: objects.document, host: host, selection: selection)
            context.transformHandles = { [unowned self] in self.enabled }
            tool.activate(in: context)
        }

        static func make() async -> Fixture {
            Fixture(await SelectionFixture.make())
        }

        func click(_ x: Double, _ y: Double, _ modifiers: KeyModifiers = [], count: Int = 1) {
            let event = CanvasEvent(pasteboardPoint: Point(x: x, y: y), viewPoint: Point(x: x, y: y), modifiers: modifiers, clickCount: count)
            tool.mouseDown(event)
            tool.mouseUp(event)
        }

        func drag(from: (Double, Double), to: (Double, Double), _ modifiers: KeyModifiers = []) {
            tool.mouseDown(TestEvents.point(from.0, from.1, modifiers))
            tool.mouseDragged(TestEvents.point(to.0, to.1, modifiers))
            tool.drawOverlay(in: bitmap(), viewport: host.viewport)
            tool.mouseUp(TestEvents.point(to.0, to.1, modifiers))
        }
    }

    @Test func doubleClickShowsTheHandlesAndDragsTransform() async throws {
        let fixture = await Fixture.make()
        let tool = fixture.tool
        let document = fixture.objects.document
        let a = fixture.objects.a
        fixture.click(30, 30)
        #expect(!tool.handlesShown && !tool.hasSomethingToCancel)
        fixture.enabled = false
        fixture.click(30, 30, count: 2)
        #expect(!tool.handlesShown)
        fixture.enabled = true
        fixture.click(30, 30, count: 2)
        #expect(tool.handlesShown && tool.hasSomethingToCancel && fixture.host.messages.last == PointerTool.handlesMessage)
        #expect(tool.handles?.bounds == Rect(x: 10, y: 10, width: 50, height: 50))
        tool.drawOverlay(in: bitmap(), viewport: fixture.host.viewport)

        // Hovering shows the zone's cursor; Option adds the plus.
        tool.pointerMoved(TestEvents.point(10, 10))
        #expect(tool.hoverZone == .scale(.topLeft) && tool.cursor == .crosshair)
        tool.pointerMoved(TestEvents.point(10, 10))
        tool.pointerMoved(TestEvents.point(30, 45, .option))
        #expect(tool.cursor == .dragCopy)
        tool.flagsChanged(TestEvents.point(30, 45))
        #expect(tool.cursor == .openHand)

        // A handle drag scales about the centre: one change.
        let before = document.changeCount
        fixture.drag(from: (60, 35), to: (85, 35))
        await document.settle()
        #expect(document.changeCount == before + 1)
        let scaled = try #require(Objects.bounds(of: a.opID, in: document.state))
        #expect(abs(scaled.width - 100) < 0.001 && abs(scaled.midX - 35) < 0.001)
        #expect(document.undoTitle.hasPrefix("Undo Scale"))

        // The centre moves by dragging it; Shift-click puts it back.
        let center = try #require(tool.handles?.center)
        fixture.drag(from: (center.x, center.y), to: (100, 100))
        #expect(tool.handleCenter == Point(x: 100, y: 100))
        tool.mouseDown(TestEvents.point(100, 100, .shift))
        tool.mouseUp(TestEvents.point(100, 100, .shift))
        #expect(tool.handleCenter == nil)

        // Moving inside carries a set centre along; a click inside without a drag selects.
        fixture.drag(from: (tool.handles!.center.x, tool.handles!.center.y), to: (50, 50))
        fixture.drag(from: (30, 45), to: (40, 45))
        await document.settle()
        #expect(tool.handleCenter == Point(x: 60, y: 50))
        fixture.click(30, 45)
        #expect(fixture.selection.selection.ids == [a])

        // Rotate outside a corner; Option-drag makes a transformed copy that gets the handles.
        let bounds = try #require(tool.handles?.bounds)
        fixture.drag(from: (bounds.maxX + 5, bounds.minY - 5), to: (bounds.maxX + 5, bounds.maxY), .option)
        await document.settle()
        #expect(await eventually { fixture.selection.selection.ids != [a] })
        #expect(tool.handlesShown)

        // A drag that goes nowhere performs nothing; Esc puts the handles away.
        let count = document.changeCount
        fixture.drag(from: (tool.handles!.bounds.maxX, tool.handles!.bounds.midY), to: (tool.handles!.bounds.maxX, tool.handles!.bounds.midY))
        #expect(document.changeCount == count)
        #expect(!tool.keyDown(TestEvents.key("x", keyCode: 7)))
        tool.cancel()
        #expect(!tool.handlesShown)
        tool.cancel()
    }

    @Test func handlesComeAndGo() async {
        let fixture = await Fixture.make()
        let tool = fixture.tool
        fixture.click(30, 30)
        fixture.click(30, 30, count: 2)
        #expect(tool.handlesShown)
        // A double-click away puts them away.
        fixture.click(380, 280, count: 2)
        #expect(!tool.handlesShown)
        fixture.click(30, 30, count: 2)
        #expect(tool.handlesShown)
        // The handles follow a new selection; an empty selection puts them away.
        fixture.selection.model.set(Selection([fixture.objects.b]))
        fixture.click(380, 280)
        #expect(!tool.handlesShown)
        tool.showHandles()
        #expect(!tool.handlesShown, "nothing is selected")
        fixture.click(120, 30)
        fixture.click(120, 30, count: 2)
        tool.deactivate()
        #expect(!tool.handlesShown)
        tool.showHandles()
        tool.superselect()
        tool.pointerMoved(TestEvents.point(0, 0))
        tool.hideHandles()
    }

    @Test func tildeGoesUpToTheGroupKeepingTheCentre() async {
        let fixture = await Fixture.make()
        let tool = fixture.tool
        // Option-click a member, then show its handles and move the centre.
        fixture.click(220, 30, .option)
        #expect(fixture.selection.selection.ids == [fixture.objects.member])
        fixture.click(220, 30, count: 2)
        #expect(tool.handlesShown)
        let center = tool.handles!.center
        fixture.drag(from: (center.x, center.y), to: (225, 25))
        #expect(tool.handleCenter == Point(x: 225, y: 25))
        #expect(tool.keyDown(TestEvents.key("~", keyCode: 50)))
        #expect(fixture.selection.selection.ids == [fixture.objects.group] && tool.handles?.center == Point(x: 225, y: 25))
        // Already at the top: nothing to go up to.
        #expect(tool.keyDown(TestEvents.key("`", keyCode: 50)))
        #expect(fixture.selection.selection.ids == [fixture.objects.group])
        // Option-click inside the handles picks the member; the handles belong to it.
        fixture.click(220, 30, .option)
        #expect(fixture.selection.selection.ids == [fixture.objects.member])
        #expect(tool.handles?.bounds.width == 40)
    }

    @Test func pointSubsetHandlesTransformOnlyThePoints() async throws {
        let fixture = await Fixture.make()
        let tool = fixture.tool
        let document = fixture.objects.document
        let path = try #require(await document.addPath([Point(x: 100, y: 200), Point(x: 150, y: 220), Point(x: 200, y: 200)]))
        let contour = try #require(document.path(path)?.contours.first)
        let transformBefore = document.object(for: path)?.transform
        fixture.selection.model.set(Selection().applying([path], sub: [path: .points([
            PointReference(node: path.node, contour: contour.id, point: contour.points[0].id),
            PointReference(node: path.node, contour: contour.id, point: contour.points[1].id),
        ])], mode: .replace))
        tool.showHandles()
        #expect(tool.handles?.bounds == Rect(x: 100, y: 200, width: 50, height: 20))
        fixture.drag(from: (150, 210), to: (175, 210))
        await document.settle()
        #expect(document.object(for: path)?.transform == transformBefore)
        let after = try #require(document.path(path)?.contours.first)
        #expect(after.points[2].anchor == contour.points[2].anchor && after.points[0].anchor != contour.points[0].anchor)
    }
}
