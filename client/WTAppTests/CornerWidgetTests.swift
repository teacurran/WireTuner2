import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// FX-047's remainder: the Subselect tool's corner widgets, the rectangle's dimmed radius and
/// menu:View[Show Corner Widgets].
@Suite(.serialized) @MainActor struct CornerWidgetTests {
    typealias Fixture = PointerMoveTests.Fixture

    static func triangle(_ f: Fixture) async throws -> SelectionID {
        try #require(await f.document.addPath([Point(x: 100, y: 100), Point(x: 200, y: 100), Point(x: 150, y: 180)], closed: true))
    }

    static func context(_ f: Fixture) -> ToolContext {
        ToolContext(document: f.document, host: f.host, selection: f.controller)
    }

    static func effect(_ f: Fixture, _ id: SelectionID) -> EffectEntry? {
        CornerWidgetLayer.effect(id.opID, in: f.document.state)
    }

    /// Drags the widget of corner `index` inward by `distance` along its bisector.
    static func drag(_ layer: CornerWidgetLayer, _ f: Fixture, index: Int = 0, distance: Double, _ modifiers: KeyModifiers = []) async {
        let context = Self.context(f)
        let widget = CornerWidgetLayer.widgets(context)[index]
        let target = widget.corner.anchor + widget.corner.bisector * distance
        #expect(layer.press(TestEvents.point(widget.at.x, widget.at.y, modifiers), context: context))
        layer.drag(TestEvents.point((widget.at.x + target.x) / 2, (widget.at.y + target.y) / 2, modifiers), context: context)
        layer.release(TestEvents.point(target.x, target.y, modifiers), context: context)
        await layer.settle()
        await f.document.settle()
    }

    @Test func theCornersAreThePointsWhereSegmentsMeetAtAnAngle() async throws {
        let f = await Fixture.make(subselect: true)
        let triangle = try await Self.triangle(f)
        let corners = CornerWidgetLayer.corners(of: try #require(f.document.object(for: triangle)))
        #expect(corners.count == 3 && corners.allSatisfy { $0.point != nil && $0.half > 0 && $0.half < .pi / 2 })
        #expect(abs(corners[0].bisector.dx - cos(atan2(80, 50) / 2)) < 1e-6, "halfway between the two edges")
        // An open path's ends, straight points and curve points have none; a rectangle's four do.
        let open = try #require(await f.document.addPath([Point(x: 10, y: 200), Point(x: 60, y: 200), Point(x: 110, y: 200), Point(x: 110, y: 250)]))
        #expect(CornerWidgetLayer.corners(of: try #require(f.document.object(for: open))).count == 1)
        let rect = try #require(f.document.object(for: f.selection.a))
        let rectCorners = CornerWidgetLayer.corners(of: rect)
        #expect(rectCorners.count == 4 && rectCorners.allSatisfy { $0.point == nil })
        #expect(CornerWidgetLayer.corners(of: try #require(f.document.object(for: f.selection.group))).isEmpty)
        let curve = CreatePath(contours: [NewContour(closed: true, points: [
            VectorPoint(anchor: Point(x: 0, y: 0), inHandle: Vector(dx: -5, dy: 0), outHandle: Vector(dx: 5, dy: 0), kind: .curve),
            VectorPoint(anchor: Point(x: 20, y: 20)), VectorPoint(anchor: Point(x: 0, y: 20)),
        ])], appearance: Appearances.standard)
        let curved = try #require(await f.document.perform(curve).value?.createdObjects.first)
        await f.document.settle()
        #expect(CornerWidgetLayer.corners(of: try #require(f.document.object(for: SelectionID(curved)))).count == 2)
        #expect(CornerWidgetLayer.radius(corners[0], draggedTo: corners[0].anchor - corners[0].bisector) == 0)
        #expect(CornerWidgetLayer.nextStyle(.unspecified) == .invertedRound && CornerWidgetLayer.nextStyle(.chamfer) == .round)
    }

    @Test func aDragWithNothingSelectedAddsTheEffectForEveryCornerInOneUndoStep() async throws {
        let f = await Fixture.make(subselect: true)
        let triangle = try await Self.triangle(f)
        f.controller.model.set(Selection([triangle]))
        let layer = CornerWidgetLayer()
        layer.draw(in: DrawingToolTests.bitmap(), viewport: SelectionFixture.viewport, context: Self.context(f))
        let corner = CornerWidgetLayer.widgets(Self.context(f))[0].corner
        await Self.drag(layer, f, distance: 20)
        let entry = try #require(Self.effect(f, triangle))
        #expect(abs(entry.effect.settings.corners.radius - 20 * sin(corner.half)) < 1e-6 && entry.effect.settings.corners.points.isEmpty)
        // The widgets now sit at the roundings' centres.
        let moved = CornerWidgetLayer.widgets(Self.context(f))[0].at
        #expect(moved.distance(to: corner.anchor + corner.bisector * 20) < 1e-6)
        // A second drag adjusts it; each drag is one undo step.
        await Self.drag(layer, f, distance: 10)
        #expect(abs(Self.effect(f, triangle)!.effect.settings.corners.radius - 10 * sin(corner.half)) < 1e-6)
        _ = await f.document.undo().value
        #expect(abs(Self.effect(f, triangle)!.effect.settings.corners.radius - 20 * sin(corner.half)) < 1e-6)
        _ = await f.document.undo().value
        #expect(Self.effect(f, triangle) == nil, "the first drag, effect and radius, undoes at once")
        // A press that does not move writes nothing; Esc after a drag undoes it.
        let changes = f.document.changeCount
        let widget = CornerWidgetLayer.widgets(Self.context(f))[0]
        #expect(layer.press(TestEvents.point(widget.at.x, widget.at.y), context: Self.context(f)))
        layer.drag(TestEvents.point(widget.at.x + 1, widget.at.y), context: Self.context(f))
        layer.release(TestEvents.point(widget.at.x + 1, widget.at.y), context: Self.context(f))
        await layer.settle()
        await f.document.settle()
        #expect(f.document.changeCount == changes && Self.effect(f, triangle) == nil)
        #expect(layer.press(TestEvents.point(widget.at.x, widget.at.y), context: Self.context(f)))
        layer.drag(TestEvents.point(widget.at.x + 20, widget.at.y + 20), context: Self.context(f))
        layer.cancel(context: Self.context(f))
        layer.cancel(context: Self.context(f))
        layer.drag(TestEvents.point(0, 0), context: Self.context(f))
        await layer.settle()
        await f.document.settle()
        #expect(Self.effect(f, triangle) == nil)
        #expect(!layer.press(TestEvents.point(0, 0), context: Self.context(f)))
    }

    @Test func aDragWithPointsSelectedTreatsOnlyThose() async throws {
        let f = await Fixture.make(subselect: true)
        let triangle = try await Self.triangle(f)
        let contour = f.document.path(triangle)!.contours[0]
        let chosen = Set([0, 1].map { PointReference(node: triangle.node, contour: contour.id, point: contour.drawn[$0].id) })
        f.controller.model.set(Selection([triangle]).applying([triangle], sub: [triangle: .points(chosen)], mode: .add))
        let layer = CornerWidgetLayer()
        await Self.drag(layer, f, distance: 12)
        let entry = try #require(Self.effect(f, triangle))
        #expect(Set(entry.effect.settings.corners.points.compactMap { OpID(element: $0) }) == Set(chosen.map(\.point)))
        // The untreated corner's widget stays inside its sharp corner.
        let third = CornerWidgetLayer.widgets(Self.context(f))[2]
        #expect(CornerWidgetLayer.radius(third.corner, in: f.document.state) == 0)
        // Merge: another replica adds the third point at the same time; the set is the union.
        await f.document.receiveRemote(SetCornerPoints([(triangle.opID, entry.row)], points: [contour.drawn[2].id], adding: true))
        #expect(Self.effect(f, triangle)!.effect.settings.corners.points.count == 3)
    }

    @Test func optionClickCyclesTheStyleAndDoubleClickShowsTheEffect() async throws {
        let f = await Fixture.make(subselect: true)
        let triangle = try await Self.triangle(f)
        f.controller.model.set(Selection([triangle]))
        let layer = CornerWidgetLayer()
        // Without an effect an Option-click writes nothing.
        let context = Self.context(f)
        var widget = CornerWidgetLayer.widgets(context)[0]
        #expect(layer.press(TestEvents.point(widget.at.x, widget.at.y, .option), context: context))
        layer.release(TestEvents.point(widget.at.x, widget.at.y, .option), context: context)
        await layer.settle()
        await Self.drag(layer, f, distance: 15)
        var styles: [Wiretuner_Doc_V1_CornerStyle] = []
        for _ in 0..<3 {
            widget = CornerWidgetLayer.widgets(context)[0]
            #expect(layer.press(TestEvents.point(widget.at.x, widget.at.y, .option), context: context))
            layer.release(TestEvents.point(widget.at.x, widget.at.y, .option), context: context)
            await layer.settle()
            await f.document.settle()
            styles.append(Self.effect(f, triangle)!.effect.settings.corners.style)
        }
        #expect(styles == [.invertedRound, .chamfer, .round])
        // A double-click asks the Object panel to select the effect and shows the panel.
        var shown = 0
        CornerWidgetLayer.showPanel = { shown += 1 }
        defer { CornerWidgetLayer.showPanel = {} }
        widget = CornerWidgetLayer.widgets(context)[0]
        #expect(layer.press(CanvasEvent(pasteboardPoint: widget.at, viewPoint: widget.at, modifiers: [], clickCount: 2), context: context))
        let pending = try #require(InspectorRowRequest.shared.pending)
        #expect(shown == 1 && pending.row == Self.effect(f, triangle)!.row && pending.targets == [triangle.opID])
        let state = AttributesState(focus: InspectorFocus())
        InspectorRowRequest.shared.apply(to: state)
        #expect(state.selected == pending.row && InspectorRowRequest.shared.pending == nil)
        InspectorRowRequest.shared.apply(to: state)
        // The panel applies a request when it draws.
        InspectorRowRequest.shared.request(pending.row, targets: [triangle.opID])
        let active = ActiveSelection(model: f.controller.model, document: f.document)
        PanelRendering.host(ObjectPanelBody(selection: active))
        // A double-click on a widget of an object without the effect only takes the press.
        let other = try #require(await f.document.addPath([Point(x: 250, y: 100), Point(x: 300, y: 100), Point(x: 280, y: 150)], closed: true))
        f.controller.model.set(Selection([other]))
        widget = CornerWidgetLayer.widgets(context)[0]
        #expect(layer.press(CanvasEvent(pasteboardPoint: widget.at, viewPoint: widget.at, modifiers: [], clickCount: 2), context: context))
        #expect(shown == 1)
    }

    @Test func theRectangleDimsItsRadiusAndTheMenuHidesTheWidgets() async throws {
        let f = await Fixture.make(subselect: true)
        f.controller.model.set(Selection([f.selection.a]))
        let model = ObjectPanelModel(document: f.document, selection: f.controller.selection)
        #expect(!model.rectangleCornersEffect)
        let layer = CornerWidgetLayer()
        await Self.drag(layer, f, distance: 30)
        let dimmed = ObjectPanelModel(document: f.document, selection: f.controller.selection)
        #expect(dimmed.rectangleCornersEffect && Self.effect(f, f.selection.a)?.effect.settings.corners.points.isEmpty == true)
        PanelRendering.host(RectangleSectionView(section: try #require(dimmed.rectangle), model: dimmed))
        // The View menu item, kept in this Mac's defaults.
        let suite = TestDefaults()
        var redraws = 0
        let registry = CommandRegistry()
        registry.replace(CornerWidgetCommands.command(defaults: suite.defaults) { redraws += 1 })
        #expect(registry.validate(CornerWidgetCommands.id)?.isChecked == true)
        #expect(registry.perform(CornerWidgetCommands.id))
        #expect(registry.validate(CornerWidgetCommands.id)?.isChecked == false && redraws == 1)
        CornerWidgetLayer.isShown = { CornerWidgetCommands.isShown(suite.defaults) }
        defer { CornerWidgetLayer.isShown = { true } }
        #expect(CornerWidgetLayer.widgets(Self.context(f)).isEmpty)
        layer.draw(in: DrawingToolTests.bitmap(), viewport: SelectionFixture.viewport, context: Self.context(f))
        // The layer works with the Subselect tool only.
        #expect(layer.applies(to: PointerTool.subselectID) && !layer.applies(to: .pointer) && PointHandleLayer().applies(to: .pointer))
    }
}
