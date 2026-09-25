import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// COLOR-012: the Eyedropper lifts a colour as the document holds it and drops it as one change; a
/// click sets the current colour and the Mixer; sampling writes nothing.
@Suite(.serialized) @MainActor struct EyedropperTests {
    @MainActor
    final class Fixture {
        let colors = ColorPanelFixture(title: "Eyedropper")
        let host = RecordingHost()
        let context: ToolContext
        var picks: [EyedropperSample] = []
        lazy var tool = EyedropperTool(defaultSpace: { .sRGB }) { [unowned self] in self.picks.append($0) }

        init() {
            context = ToolContext(document: colors.document, host: host, selection: SelectionController(document: colors.document))
            tool.activate(in: context)
        }

        var document: DocumentHandle { colors.document }

        /// A 40 × 40 square at (`x`, 100).
        func square(_ x: Double) async -> OpID {
            await document.addRectangles([Rect(x: x, y: 100, width: 40, height: 40)])[0].opID
        }

        func drag(_ from: Point, _ to: Point, _ modifiers: KeyModifiers = []) async {
            tool.mouseDown(TestEvents.point(from.x, from.y, modifiers))
            tool.mouseDragged(TestEvents.point(to.x, to.y, modifiers))
            tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: context.viewport)
            tool.mouseUp(TestEvents.point(to.x, to.y, modifiers))
            await document.settle()
        }
    }

    @Test func aNamedFillDropsAsItsSwatchReference() async throws {
        let f = Fixture()
        let grape = await f.colors.add(RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        let source = await f.square(0)
        _ = await f.document.perform(ApplyColor([source], target: .fill, color: f.colors.list.resolver.reference(to: grape))).value
        let target = await f.square(100)
        await f.document.settle()
        let before = f.document.undoTitle
        f.tool.mouseDown(TestEvents.point(20, 120))
        #expect(f.tool.sample?.name == "Grape" && f.tool.sample?.ref.swatch.id == grape.proto)
        #expect(f.document.undoTitle == before, "sampling writes nothing")
        f.tool.mouseDragged(TestEvents.point(21, 120))
        #expect(!f.tool.isDragging && f.tool.dropTarget == nil)
        f.tool.cancel()
        await f.drag(Point(x: 20, y: 120), Point(x: 120, y: 120))
        #expect(f.colors.fill(target)?.swatch.id == grape.proto, "a swatch reference, not an inline copy")
        #expect(f.document.undoTitle == "Undo Apply \"Grape\"")
    }

    @Test func aDisplayP3FillStaysP3AndOptionPicksTheStroke() async throws {
        let f = Fixture()
        let p3 = RenderColor(displayP3Red: 0.9, green: 0.2, blue: 0.1)
        let source = await f.square(0)
        _ = await f.document.perform(ApplyColor([source], target: .fill, color: ColorResolver.inline(p3))).value
        await f.document.settle()
        f.tool.mouseDown(TestEvents.point(20, 120))
        #expect(f.tool.sample?.color == p3 && f.tool.sample?.ref.inline.space == .displayP3)
        f.tool.mouseUp(TestEvents.point(20, 120))
        #expect(f.picks.last?.color == p3, "a click picks")
        // Option: the stroke (black) though the press is on the fill.
        f.tool.mouseDown(TestEvents.point(20, 120, [.option]))
        #expect(f.tool.sample?.color?.converted(to: .sRGB).components.x ?? 1 < 0.01)
        // The stroke's modifier on the drop colours the target's stroke.
        let target = await f.square(100)
        f.tool.mouseDragged(TestEvents.point(120, 120, [.command]))
        #expect(f.tool.dropTarget?.target == .stroke && f.tool.dropTarget?.node == target)
        f.tool.flagsChanged(TestEvents.point(0, 0))
        #expect(f.tool.dropTarget?.target == .fill)
        f.tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.context.viewport)
        f.tool.mouseUp(TestEvents.point(120, 120))
        await f.document.settle()
        #expect(f.document.undoTitle == "Undo Apply color")
    }

    @Test func aGradientIsSampledAsTheColourDrawnThere() async throws {
        let f = Fixture()
        let source = await f.square(0)
        let list = AttributesListModel(document: f.document, selection: Selection([SelectionID(source)]))
        let pairs = list.rows.first { $0.list == .fills }!.targets.map(\.pair)
        _ = await f.document.perform(ChooseGradient(pairs)).value
        await f.document.settle()
        f.tool.mouseDown(TestEvents.point(20, 120))
        let sample = try #require(f.tool.sample)
        #expect(sample.name.isEmpty && sample.ref.inline.space == .srgb)
        f.tool.cancel()
        // Nothing under the pointer: nothing lifted, and a release there does nothing.
        await f.drag(Point(x: 300, y: 20), Point(x: 20, y: 120))
        #expect(f.tool.sample == nil && f.picks.isEmpty)
        _ = EyedropperSampling.pixel(at: Point(x: 900, y: 900), in: f.document.displayList)
        // A drop on empty pasteboard does nothing.
        f.tool.mouseDown(TestEvents.point(20, 120))
        f.tool.mouseDragged(TestEvents.point(300, 20))
        f.tool.mouseUp(TestEvents.point(300, 20))
        #expect(!f.tool.hasSomethingToCancel && !f.tool.keyDown(TestEvents.escape))
        _ = EyedropperTool.cursor(for: nil)
        _ = f.tool.cursor
        f.tool.deactivate()
    }

    @Test func textIsSampledFromItsGlyphFill() async throws {
        let f = Fixture()
        let text = try #require(await f.document.addText("Hello", at: Point(x: 20, y: 20)))
        let red = RenderColor(red: 1, green: 0, blue: 0)
        _ = await f.document.perform(TextColor.fill(node: text, from: .start, to: .end, ColorResolver.inline(red))).value
        await f.document.settle()
        let bounds = try #require(f.document.object(for: SelectionID(text))?.bounds)
        f.tool.mouseDown(TestEvents.point(bounds.minX + 4, bounds.midY))
        #expect(f.tool.sample?.color == red)
        #expect(EyedropperSampling.textFill([[]]) == nil)
    }

    @Test func unfilledTextNoneStrokesAndAToolOutsideAWindow() async throws {
        let f = Fixture()
        let loose = EyedropperTool(defaultSpace: { .sRGB }) { _ in }
        loose.mouseDown(TestEvents.point(0, 0))
        loose.flagsChanged(TestEvents.point(0, 0))
        #expect(!loose.isDragging && loose.sample == nil)
        // Text without a fill mark reads black; a run of other marks before the fill is passed over.
        let text = try #require(await f.document.addText("Plain", at: Point(x: 20, y: 20)))
        let bounds = try #require(f.document.object(for: SelectionID(text))?.bounds)
        f.tool.mouseDown(TestEvents.point(bounds.minX + 4, bounds.midY))
        #expect(f.tool.sample?.color == .black)
        f.tool.cancel()
        let red = ColorResolver.inline(RenderColor(red: 1, green: 0, blue: 0))
        #expect(EyedropperSampling.textFill([[.with { $0.size = 12 }, .with { $0.fill = red }]]) == red)
        // A stroke of None lifts no colour: the chip is clear.
        let source = await f.square(0)
        _ = await f.document.perform(ApplyColor([source], target: .stroke, color: ColorResolver.none)).value
        await f.document.settle()
        f.tool.mouseDown(TestEvents.point(20, 120, [.option]))
        #expect(f.tool.sample?.color == nil)
        let target = await f.square(100)
        _ = target
        f.tool.mouseDragged(TestEvents.point(99, 120, [.command]))
        f.tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.context.viewport)
        f.tool.cancel()
    }

    @Test func aClickSetsTheCurrentColourAndTheMixer() async throws {
        let colors = ColorPanelFixture()
        let palette = ToolPaletteModel()
        let mixer = ColorMixerModel(workspace: colors.workspace, defaults: colors.suite.defaults)
        let grape = await colors.add(RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        let sample = EyedropperSampling.sample(colors.list.resolver.reference(to: grape), in: colors.state)
        palette.activeWell = .stroke
        EyedropperFeatures.pick(palette: palette, mixer: mixer)(sample)
        #expect(palette.wells.stroke == .solid(RenderColor(red: 0.5, green: 0, blue: 0.5)) && palette.currentChoices.stroke == .color(sample.ref))
        #expect(mixer.original == RenderColor(red: 0.5, green: 0, blue: 0.5))
        EyedropperFeatures.pick(palette: palette, mixer: mixer)(EyedropperSample(ref: ColorResolver.none, color: nil, name: ""))
        #expect(palette.wells.stroke == .none)
        let descriptor = EyedropperFeatures.descriptor(palette: palette, mixer: mixer) { .sRGB }
        #expect(descriptor.make() is EyedropperTool)
    }
}
