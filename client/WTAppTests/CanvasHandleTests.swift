import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// FX-003's centre handles and Duet axis, and ATTR-026's gradient handles: drawn over the Pointer
/// and Subselect tools, pressed before the tool, each drag one undo step.
@Suite @MainActor struct CanvasHandleTests {
    static let viewport = Viewport(size: Size(width: 400, height: 300))

    static func context() -> CGContext {
        CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    @MainActor
    final class Fixture {
        let attributes: AttributeFixture
        let host = RecordingHost(viewport: CanvasHandleTests.viewport)
        let controller: SelectionController
        let focus = InspectorFocus()
        let manager: ToolManager

        init(_ attributes: AttributeFixture) {
            self.attributes = attributes
            controller = SelectionController(document: attributes.document)
            let registry = ToolRegistry()
            registry.registerBuiltIn()
            manager = ToolManager(registry: registry, context: ToolContext(document: attributes.document, host: host, selection: controller), focus: focus)
            manager.handleLayers = [EffectCenterHandles(focus: focus), GradientHandles(focus: focus)]
            controller.model.set(Selection(attributes.ids))
        }

        var document: DocumentHandle { attributes.document }
        var node: OpID { attributes.ids[0].opID }

        /// Focuses the top row of `list` in the Object panel.
        func focusTop(_ kind: AppearanceList) {
            let list = attributes.list()
            let row = list.rows.last { $0.list == kind }!
            focus.set(row.id, targets: list.targets)
        }

        func drag(_ from: Point, _ to: Point, _ modifiers: KeyModifiers = []) async {
            manager.mouseDown(TestEvents.point(from.x, from.y))
            manager.mouseDragged(TestEvents.point((from.x + to.x) / 2, (from.y + to.y) / 2, modifiers))
            manager.mouseUp(TestEvents.point(to.x, to.y, modifiers))
            await settle()
        }

        func settle() async {
            await document.settle()
            for _ in 0..<20 { await Task.yield() }
            await document.settle()
        }
    }

    /// A 100 × 100 square at (100, 100) with its fill, stroke and a Bend effect.
    static func bent() async -> Fixture {
        let attributes = AttributeFixture()
        attributes.ids = await attributes.document.addRectangles([Rect(x: 100, y: 100, width: 100, height: 100)])
        let list = attributes.list()
        _ = await list.perform(list.addEffect(.bend, above: nil))?.value
        return Fixture(attributes)
    }

    static func effect(_ fixture: Fixture) -> Wiretuner_Doc_V1_EffectSettings {
        EffectReading.entries(fixture.node, in: fixture.document.state).last!.effect.settings
    }

    @Test func theBendCentreDragsAsOneUndoStep() async throws {
        let fixture = await Self.bent()
        #expect(fixture.manager.handleLayers.count == 2 && CanvasHandleLayers.standard().count == 2)
        let layer = try #require(fixture.manager.handleLayers[0] as? EffectCenterHandles)
        #expect(layer.handles(fixture.manager.context).isEmpty, "no effect focused: no handle")
        fixture.focusTop(.effects)
        #expect(fixture.host.overlayRequests > 0, "the focus redraws the overlay")
        let handles = layer.handles(fixture.manager.context)
        #expect(handles.count == 1 && handles[0].center.distance(to: Point(x: 50, y: 50)) < 1)
        fixture.manager.drawOverlay(in: Self.context(), viewport: Self.viewport)
        // Dragging the centre (at the square's centre) 20 right and 10 down: the offset is y up.
        await fixture.drag(Point(x: 150, y: 150), Point(x: 170, y: 160))
        let settings = Self.effect(fixture)
        #expect(abs(settings.bend.center.x - 20) < 1e-6 && abs(settings.bend.center.y + 10) < 1e-6)
        #expect(fixture.document.undoTitle == "Undo Move bend center" && fixture.manager.handleDrag == nil)
        _ = await fixture.document.undo().value
        #expect(Self.effect(fixture).bend.center.x == 0, "the whole drag undoes in one step")
        // A press away from the handles goes to the tool.
        fixture.manager.mouseDown(TestEvents.point(10, 10))
        #expect(fixture.manager.handleDrag == nil)
        fixture.manager.mouseUp(TestEvents.point(10, 10))
        // Esc during a drag undoes what it wrote.
        fixture.manager.mouseDown(TestEvents.point(150, 150))
        fixture.manager.mouseDragged(TestEvents.point(180, 150))
        await fixture.document.settle()
        fixture.manager.cancel()
        await fixture.settle()
        #expect(Self.effect(fixture).bend.center.x == 0)
        layer.cancel(context: fixture.manager.context)
        layer.drag(TestEvents.point(0, 0), context: fixture.manager.context)
    }

    @Test func theDuetAxisTurnsAndTheTransformCentreMoves() async throws {
        let fixture = await Self.bent()
        let pairs = fixture.attributes.context(fixture.attributes.list().rows.count - 1).pairs
        _ = await fixture.document.perform(SetEffectKind(pairs, kind: .duet)).value
        fixture.focusTop(.effects)
        let layer = try #require(fixture.manager.handleLayers[0] as? EffectCenterHandles)
        let handles = layer.handles(fixture.manager.context)
        #expect(handles.map(\.part) == [.center, .axis])
        // The arm's end sits 40 view points along the axis (90°: straight up).
        let arm = EffectCenterHandles.position(handles[1], viewport: Self.viewport)
        #expect(arm.distance(to: Point(x: 150, y: 110)) < 1e-6)
        await fixture.drag(arm, Point(x: 190, y: 150), [.shift])
        #expect(abs(Self.effect(fixture).duet.axisAngle) < 1e-6 && fixture.document.undoTitle == "Undo Rotate duet axis")
        await fixture.drag(Point(x: 150, y: 150), Point(x: 140, y: 150))
        #expect(abs(Self.effect(fixture).duet.center.x + 10) < 1e-6)
        _ = await fixture.document.perform(SetEffectKind(pairs, kind: .transform)).value
        await fixture.drag(Point(x: 150, y: 150), Point(x: 150, y: 130))
        #expect(abs(Self.effect(fixture).transform.center.y - 20) < 1e-6)
        fixture.manager.drawOverlay(in: Self.context(), viewport: Self.viewport)
        // Kinds without a centre, hidden effects and other tools show no handle.
        _ = await fixture.document.perform(SetEffectKind(pairs, kind: .ragged)).value
        #expect(layer.handles(fixture.manager.context).isEmpty && EffectCenterHandles.centerOffset(Wiretuner_Doc_V1_EffectSettings()) == nil)
        _ = await fixture.document.perform(SetEffectKind(pairs, kind: .bend)).value
        _ = await fixture.document.perform(SetAppearanceHidden(pairs, hidden: true)).value
        #expect(layer.handles(fixture.manager.context).isEmpty)
        fixture.manager.select(.hand)
        #expect(!fixture.manager.handlesApply)
        #expect(EffectCenterHandles.centerPoint(.null, offset: Point(x: 1, y: 1)) == Point(x: 1, y: -1))
        #expect(EffectCenterHandles.offset(.null, point: Point(x: 1, y: 1)) == Point(x: 1, y: -1))
        fixture.focusTop(.fills)
        #expect(layer.handles(fixture.manager.context).isEmpty)
    }

    /// A square with a Linear gradient fill whose axis runs from its left edge to its right.
    static func gradient() async throws -> Fixture {
        let attributes = AttributeFixture()
        attributes.ids = await attributes.document.addRectangles([Rect(x: 100, y: 100, width: 100, height: 100)])
        let fixture = Fixture(attributes)
        let fill = attributes.list().rows.first { $0.list == .fills }!
        let pairs = fill.targets.map(\.pair)
        _ = await attributes.document.perform(ChooseGradient(pairs)).value
        _ = await attributes.document.perform(EditGradient.axis(pairs, start: Point(x: 0, y: 50), end: Point(x: 100, y: 50))).value
        return fixture
    }

    static func axis(_ fixture: Fixture) -> Wiretuner_Doc_V1_GradientAxis {
        fixture.attributes.stack().first { $0.row.list == .fills }!.fill.settings.gradient.axis
    }

    @Test func gradientHandlesMoveTheAxisWithTheirModifiers() async throws {
        let fixture = try await Self.gradient()
        let layer = try #require(fixture.manager.handleLayers[1] as? GradientHandles)
        var handles = layer.handles(fixture.manager.context)
        #expect(handles.map(\.point) == [.start, .end] && handles.allSatisfy { !$0.focused })
        fixture.focusTop(.fills)
        handles = layer.handles(fixture.manager.context)
        #expect(handles.allSatisfy { $0.focused })
        fixture.manager.drawOverlay(in: Self.context(), viewport: Self.viewport)
        // The start moves the whole gradient.
        await fixture.drag(Point(x: 100, y: 150), Point(x: 110, y: 160))
        var axis = Self.axis(fixture)
        #expect(axis.start.x == 10 && axis.start.y == 60 && axis.end.x == 110 && axis.end.y == 60 && fixture.document.undoTitle == "Undo Move gradient handle")
        // Shift snaps the end's angle to 45° steps, its length kept.
        await fixture.drag(Point(x: 210, y: 160), Point(x: 205, y: 205), [.shift])
        axis = Self.axis(fixture)
        let length = hypot(axis.end.x - axis.start.x, axis.end.y - axis.start.y)
        #expect(abs(axis.end.x - axis.start.x - axis.end.y + axis.start.y) < 1e-6 && length > 0)
        // Radial: three handles; Option drags both ends together.
        let pairs = fixture.attributes.list().rows.first { $0.list == .fills }!.targets.map(\.pair)
        _ = await fixture.document.perform(EditGradient.type(pairs, .radial)).value
        _ = await fixture.document.perform(EditGradient.axis(pairs, start: Point(x: 50, y: 50), end: Point(x: 90, y: 50), end2: Point(x: 50, y: 30))).value
        handles = layer.handles(fixture.manager.context)
        #expect(handles.map(\.point) == [.start, .end, .end2])
        await fixture.drag(Point(x: 190, y: 150), Point(x: 230, y: 150), [.option])
        axis = Self.axis(fixture)
        #expect(abs(axis.end.x - 130) < 1e-6 && abs(axis.end2.y - 10) < 1e-6, "the second end doubles with the first")
        await fixture.drag(Point(x: 150, y: 110), Point(x: 150, y: 90), [.option])
        axis = Self.axis(fixture)
        #expect(abs(axis.end2.y + 10) < 1e-6)
        fixture.manager.drawOverlay(in: Self.context(), viewport: Self.viewport)
        // Auto size hides the handles; Esc undoes a drag in progress.
        let before = Self.axis(fixture)
        fixture.manager.mouseDown(TestEvents.point(150, 150))
        fixture.manager.mouseDragged(TestEvents.point(170, 150))
        await fixture.document.settle()
        fixture.manager.cancel()
        await fixture.settle()
        #expect(Self.axis(fixture) == before)
        _ = await fixture.document.perform(EditGradient.behavior(pairs, .autoSize)).value
        #expect(layer.handles(fixture.manager.context).isEmpty)
        let handle = GradientHandles.Handle(node: fixture.node, row: pairs[0].row, type: .linear, point: .end2,
                                            axis: Gradient.Axis(start: .zero, end: Point(x: 1, y: 0), end2: nil), transform: .identity, focused: false)
        #expect(handle.local == Point(x: 1, y: 0))
        let unmoved = GradientHandles.axis(dragging: handle, to: Point(x: 0, y: 2), modifiers: [])
        #expect(unmoved.end2 == Point(x: 0, y: 2))
        layer.cancel(context: fixture.manager.context)
        layer.drag(TestEvents.point(0, 0), context: fixture.manager.context)
    }
}
