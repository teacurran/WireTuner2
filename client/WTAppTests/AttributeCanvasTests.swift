import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// ATTR-022 (the lens centerpoint handle) and ATTR-028 (swatches dropped with a gradient modifier).
@Suite(.serialized) @MainActor struct AttributeCanvasTests {
    typealias HandleFixture = CanvasHandleTests.Fixture

    /// A 100 × 100 square at (100, 100) with a lens fill showing its centerpoint.
    static func lens() async -> HandleFixture {
        let attributes = AttributeFixture()
        attributes.ids = await attributes.document.addRectangles([Rect(x: 100, y: 100, width: 100, height: 100)])
        let fixture = HandleFixture(attributes)
        fixture.manager.handleLayers = [LensCenterHandles()]
        let pairs = attributes.list().rows.first { $0.list == .fills }!.targets.map(\.pair)
        _ = await attributes.document.perform(SetAttributeKind(pairs, fill: .lens)).value
        _ = await attributes.document.perform(EditAttribute.fill(pairs, "Centerpoint", [AttributeFields.Lens.centerpointShown]) { $0.lens.centerpointShown = true }).value
        await fixture.settle()
        return fixture
    }

    static func lensSettings(_ fixture: HandleFixture) -> Wiretuner_Doc_V1_LensFill {
        fixture.attributes.stack().first { $0.row.list == .fills }!.fill.settings.lens
    }

    @Test func theCenterpointHandleDragsAsOneStepAndShiftClickClearsIt() async throws {
        let fixture = await Self.lens()
        let layer = try #require(fixture.manager.handleLayers[0] as? LensCenterHandles)
        let handles = layer.handles(fixture.manager.context)
        #expect(handles.count == 1 && handles[0].center == Point(x: 50, y: 50), "unset: the bounds' centre")
        fixture.manager.drawOverlay(in: CanvasHandleTests.context(), viewport: CanvasHandleTests.viewport)
        await fixture.drag(Point(x: 150, y: 150), Point(x: 170, y: 130))
        let moved = Self.lensSettings(fixture)
        #expect(moved.hasCenterpoint && moved.centerpoint.x == 70 && moved.centerpoint.y == 30)
        #expect(fixture.document.undoTitle == "Undo Move lens centerpoint")
        _ = await fixture.document.undo().value
        #expect(!Self.lensSettings(fixture).hasCenterpoint, "the drag undoes in one step")
        _ = await fixture.document.redo().value
        // Shift-click returns it to the centre.
        #expect(layer.press(TestEvents.point(170, 130, [.shift]), context: fixture.manager.context))
        await fixture.settle()
        #expect(!Self.lensSettings(fixture).hasCenterpoint && fixture.document.undoTitle == "Undo Reset lens centerpoint")
        // A press away from the handle is the tool's; Esc during a drag undoes it.
        #expect(!layer.press(TestEvents.point(10, 10), context: fixture.manager.context))
        #expect(layer.press(TestEvents.point(150, 150), context: fixture.manager.context))
        layer.drag(TestEvents.point(160, 160), context: fixture.manager.context)
        await fixture.document.settle()
        layer.cancel(context: fixture.manager.context)
        await fixture.settle()
        #expect(!Self.lensSettings(fixture).hasCenterpoint)
        layer.cancel(context: fixture.manager.context)
        layer.release(TestEvents.point(0, 0), context: fixture.manager.context)
        // Deselected: no handle.
        fixture.controller.model.set(Selection([]))
        #expect(layer.handles(fixture.manager.context).isEmpty)
        // Hidden or not showing its centerpoint: none either.
        #expect(LensCenterHandles.handles(OpID(counter: 3, replica: 3), in: fixture.document).isEmpty)
    }

    @Test func twoReplicasDraggingTheHandleConvergeOnTheLaterPosition() async throws {
        let fixture = await Self.lens()
        let handle = try #require(LensCenterHandles.handles(fixture.node, in: fixture.document).first)
        _ = await fixture.document.perform(LensCenterHandles.command(dragging: handle, to: TestEvents.point(120, 120))).value
        try await fixture.attributes.receive(LensCenterHandles.command(dragging: handle, to: TestEvents.point(180, 180)))
        await fixture.settle()
        let settings = Self.lensSettings(fixture)
        #expect(settings.centerpoint.x == 80 && settings.centerpoint.y == 80, "the later write wins")
    }

    // MARK: ATTR-028

    @Test func theGradientModifiersPickTheirTypeAndAxis() {
        #expect(GradientDrop.type(for: [.control]) == .linear && GradientDrop.type(for: [.option]) == .radial)
        #expect(GradientDrop.type(for: [.command, .option]) == .contour && GradientDrop.type(for: [.command]) == nil && GradientDrop.type(for: []) == nil)
        let swatch = Wiretuner_Doc_V1_ColorRef.with { $0.swatch.id = OpID(counter: 4, replica: 4).proto }
        #expect(GradientDrop.applies(swatch, modifiers: [.control]) && !GradientDrop.applies(ColorResolver.inline(.black), modifiers: [.control]))
        let bounds = Rect(x: 0, y: 0, width: 100, height: 50)
        let linear = GradientDrop.gradient(.linear, swatch: swatch, current: ColorResolver.inline(.white), drop: Point(x: 10, y: 25), bounds: bounds)
        #expect(linear.axis.end.x == 90 && linear.axis.end.y == 25 && linear.stops.map(\.offset) == [0, 1] && linear.stops[0].color == swatch)
        let centred = GradientDrop.gradient(.linear, swatch: swatch, current: swatch, drop: Point(x: 50, y: 25), bounds: bounds)
        #expect(centred.axis.end.x == 100, "a drop on the centre runs left to right")
        let radial = GradientDrop.gradient(.radial, swatch: swatch, current: swatch, drop: Point(x: 0, y: 0), bounds: bounds)
        #expect(radial.type == .radial && abs(radial.axis.end.x - (100 * 100 + 50 * 50).squareRoot()) < 1e-9)
    }

    @Test func swatchDropsWithModifiersMakeGradientsOnTheMemberUnderThePointer() async throws {
        let canvas = ColorDropTests.Canvas()
        defer { canvas.world.close() }
        await canvas.build()
        let document = canvas.world.document
        let grape = ColorWellActions.created(by: (await document.perform(AddSwatch(RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape")).value)!)
        let ref = SwatchList(document.state).resolver.reference(to: grape)
        ColorDrag.write(ColorRefPasteboard(ref: ref, color: RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape", document: document.id), to: canvas.pasteboard)
        func gradient(_ node: OpID) -> Wiretuner_Doc_V1_GradientFill? {
            AppearanceEditing.entries(node, in: document.state).first { $0.row.list == .fills && $0.fill.settings.kind == .gradient }?.fill.settings.gradient
        }
        // Control: linear, from the swatch to the fill's white, on the lone square.
        await canvas.drop(at: 110, 120, [.control])
        let linear = try #require(gradient(canvas.lone))
        #expect(linear.type == .linear && linear.stops.first?.color.swatch.id == grape.proto && document.undoTitle == "Undo Apply gradient")
        // Option on the group: radial on the member under the pointer only.
        await canvas.drop(at: 380, 120, [.option])
        #expect(gradient(canvas.members[1])?.type == .radial && gradient(canvas.members[0]) == nil)
        // Cmd+Option: contour.
        await canvas.drop(at: 320, 120, [.command, .option])
        #expect(gradient(canvas.members[0])?.type == .contour)
        #expect(GradientDrop.command(ref, on: OpID(counter: 9, replica: 9), at: .zero, modifiers: [.option], document: document) == nil)
        // Onto a gradient fill (no Basic fill: white at the far end) and onto a fill of None.
        let again = try #require(GradientDrop.command(ref, on: canvas.lone, at: Point(x: 120, y: 120), modifiers: [.option], document: document) as? ApplyGradient)
        #expect(again.gradient.stops.last?.color == ColorResolver.inline(.white))
        _ = await document.perform(ApplyColor([canvas.members[1]], target: .fill, color: ColorResolver.none)).value
        await document.settle()
        let none = try #require(GradientDrop.command(ref, on: canvas.members[1], at: Point(x: 380, y: 120), modifiers: [.control], document: document) as? ApplyGradient)
        #expect(none.gradient.stops.last?.color == ColorResolver.inline(.white))
    }
}
