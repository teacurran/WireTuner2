import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The controls' actions and the edge cases of the effects, brush, gradient and colour UI: every
/// button's closure and every fallback, called as the views call them.
@Suite @MainActor struct EffectUIEdgeTests {
    @Test func theBrushSheetsActionsAndDraftEdges() async throws {
        let fixture = await BrushEditorTests.Fixture.make()
        let brush = await fixture.createBrush()
        // An unknown brush reads empty; a non-symbol reads "Symbol".
        let unknown = BrushEditorModel(document: fixture.document, purpose: .edit(OpID(counter: 99, replica: 99), strokes: []))
        #expect(unknown.name.isEmpty && unknown.symbols.isEmpty && BrushEditorModel.name(of: OpID(counter: 99, replica: 99), in: fixture.document.state) == "Symbol")
        #expect(BrushEditorModel(document: fixture.document, purpose: .create([])).users.isEmpty)
        let model = BrushEditorModel(document: fixture.document, purpose: .edit(brush, strokes: []))
        model.moveSymbol(up: true)
        model.selectedSymbol = model.symbols.first
        model.moveSymbolUp()
        model.moveSymbolDown()
        model.selectedSymbol = OpID(counter: 7, replica: 7)
        model.moveSymbol(up: true)
        model.removeSymbol()
        #expect(model.symbols.count == 1)
        model.paint = true
        model.paint = false
        #expect(!model.paint && model.props.mode == .spray)
        model.modeBinding(.angle).wrappedValue = .random
        #expect(model.modeBinding(.angle).wrappedValue == .random)
        model.setVariation(.angle) { $0.mode = .unspecified }
        #expect(model.modeBinding(.angle).wrappedValue == .fixed)
        model.valueBinding(.scaling).wrappedValue = 150
        #expect(model.valueBinding(.scaling).wrappedValue == 150)
        model.rangeSetter(.offset, min: true)(-10)
        model.rangeSetter(.offset, min: false)(10)
        #expect(model.props.offset.min == -10 && model.props.offset.max == 10)
        var finished: [(any WTModel.Command)?] = []
        BrushEditorSheet.cancelling { finished.append($0) }()
        BrushEditorSheet.resolving(model, change: true) { finished.append($0) }()
        BrushEditorSheet.resolving(model, change: false) { finished.append($0) }()
        #expect(finished.count == 3 && finished[0] == nil && finished[1] != nil)
        let symbol = try #require(model.symbolChoices.first?.id)
        BrushEditorSheet.adding(symbol, model: model)()
        #expect(model.symbols.last == symbol)
        for kind in BrushVariationKind.allCases { model.setMode(kind, .variable) }
        AttributeFixture.render(BrushEditorSheet(model: model) { _ in })
        // The picker.
        var picked: [[OpID]] = []
        BrushPickerSheet.cancelling { picked.append($0) }()
        BrushPickerSheet.choosing([brush], from: Brushes.list(fixture.document.state)) { picked.append($0) }()
        #expect(picked == [[], [brush]])
        #expect(BrushStrokes.brush(of: []) == nil)
    }

    @Test func theBrushMenusActions() async throws {
        let fixture = await BrushEditorTests.Fixture.make()
        let brush = await fixture.createBrush()
        _ = await fixture.document.perform(SetAttributeKind(fixture.controls().context.pairs, stroke: .brush)).value
        let state = BrushControlsState()
        BrushControls.applying(brush, model: fixture.controls())()
        await fixture.document.settle()
        let controls = fixture.controls()
        BrushControls.editing(controls, state: state)()
        #expect(state.sheet?.id == "edit")
        if case .edit(let editor)? = state.sheet { AttributeFixture.render(BrushControls.sheet(.edit(editor), model: controls, state: state)) }
        BrushControls.finishing(controls, state: state)(nil)
        #expect(state.sheet == nil)
        BrushControls.askingToRemove(state)()
        #expect(state.removing)
        BrushControls.pickingExport(state)()
        #expect(state.sheet?.id == "export")
        var files = BrushFiles()
        files.runOpenPanel = { _, _ in [] }
        files.runSavePanel = { _, _ in nil }
        let quiet = fixture.controls(files: files)
        BrushControls.importing(quiet, state: state)()
        BrushControls.finishingExport(quiet, state: state)([brush])
        BrushControls.finishingImport(EngineState(), model: quiet, state: state)([])
        BrushControls.duplicating(controls)()
        await fixture.document.settle()
        BrushControls.removing(controls, release: false, state: state)()
        await fixture.document.settle()
        #expect(!state.removing)
        // A brush named "" titles "Brush"; strokes that differ title "Mixed"; a removed brush reads none.
        let other = await BrushEditorTests.Fixture.make()
        let nameless = await other.createBrush(name: "")
        _ = await other.document.perform(SetAttributeKind(other.controls().context.pairs, stroke: .brush)).value
        BrushControls.apply(nameless, model: other.controls())
        await other.document.settle()
        #expect(other.controls().title == "Brush")
        let second = try #require(await other.document.addPath([Point(x: 0, y: 90), Point(x: 50, y: 90)]))
        other.attributes.ids = [other.path, second]
        let list = other.attributes.list()
        if let index = list.rows.firstIndex(where: { $0.list == .strokes }) {
            #expect(BrushControlsModel(context: other.attributes.context(index)).title == "Mixed")
        }
    }

    @Test func theFeatureSheetsFinishThroughTheirViews() async throws {
        let fixture = await BlendUITests.Fixture.make()
        fixture.controller.model.set(Selection([fixture.squares[0], fixture.squares[1]]))
        _ = await BlendMenu.blend(fixture.editing)?.value
        let blend = try #require(fixture.blends.first)
        let presenter = SheetPresenter()
        presenter.present = { _ in }
        let features = EffectFeatures(target: { fixture.editing }, sheets: presenter)
        #expect(EffectFeatures.noTools() == nil && features.extensionDescriptors(existing: ExtensionRegistry(descriptors: [])).isEmpty)
        presenter.dismiss("nothing")
        // Blend Steps from its menu command, finished through the sheet's own closure.
        fixture.controller.model.set(Selection([SelectionID(blend)]))
        let steps = try #require(features.commands().first { $0.id == ContextMenuCatalog.ID.blendSteps })
        if case .perform(let run) = steps.action { run() }
        let stepsSheet = try #require(presenter.sheets[EffectFeatures.blendSteps]?.contentViewController as? NSHostingController<BlendStepsSheet>)
        stepsSheet.rootView.finish(40)
        await fixture.document.settle()
        #expect(fixture.document.state.props(blend).blend.steps == 40 && presenter.sheets[EffectFeatures.blendSteps] == nil)
        features.showBlendSteps([blend])
        (presenter.sheets[EffectFeatures.blendSteps]?.contentViewController as? NSHostingController<BlendStepsSheet>)?.rootView.finish(nil)
        var answers: [Double?] = []
        BlendStepsSheet.cancelling { answers.append($0) }()
        BlendStepsSheet.confirming(nil, steps: 12) { answers.append($0) }()
        BlendStepsSheet.confirming(5000, steps: 12) { answers.append($0) }()
        #expect(answers == [nil, 12, 1000])
        // Create Brush from its menu command; the sheet's finish performs and closes.
        fixture.controller.model.set(Selection([fixture.squares[2]]))
        let create = try #require(features.commands().first { $0.id == EffectFeatures.ID.createBrush })
        if case .perform(let run) = create.action { run() }
        let brushSheet = try #require(presenter.sheets[EffectFeatures.createBrush]?.contentViewController as? NSHostingController<BrushEditorSheet>)
        guard case .perform(let command) = brushSheet.rootView.model.ok() else { Issue.record("asked"); return }
        brushSheet.rootView.finish(command)
        await fixture.document.settle()
        #expect(Brushes.list(fixture.document.state).count == 1 && presenter.sheets[EffectFeatures.createBrush] == nil)
        features.showCreateBrush()
        (presenter.sheets[EffectFeatures.createBrush]?.contentViewController as? NSHostingController<BrushEditorSheet>)?.rootView.finish(nil)
        // Color Control closes through its sheet.
        features.showColorControl(fixture.editing)
        (presenter.sheets[ColorControlModel.sheet]?.contentViewController as? NSHostingController<ColorControlSheet>)?.rootView.close()
        #expect(presenter.sheets[ColorControlModel.sheet] == nil)
        let model = ColorControlModel(document: fixture.document, nodes: [])
        model.setter(0)(20)
        #expect(model.values.x == 20)
        model.cancel()
    }

    @Test func effectFormActionsAndReadDefaults() async throws {
        let fixture = await AttributeFixture.make()
        await EffectEditorTests.add(.ragged, fixture)
        var model = EffectEditorTests.model(fixture)
        let seed = EffectEditorTests.settings(fixture).ragged.seed
        EffectEditorView.reseeding(model)()
        await fixture.document.settle()
        #expect(EffectEditorTests.settings(fixture).ragged.seed != seed)
        await EffectEditorTests.perform(model.setRaggedSmooth(false), fixture)
        #expect(EffectEditorTests.model(fixture).raggedSmooth == false)
        // Unset style and operation read their defaults.
        let pairs = model.pairs
        await EffectEditorTests.perform(SetEffectKind(pairs, kind: .corners), fixture)
        await EffectEditorTests.perform(EditEffect(pairs, label: "Clear", fields: [EffectField.corners(2), EffectField.combine(1)]) { _ in }, fixture)
        model = EffectEditorTests.model(fixture)
        #expect(model.cornerStyle == .round && EffectEditorView.cornersAll(model).wrappedValue)
        EffectEditorView.cornersAll(model).wrappedValue = true
        EffectEditorView.changingCorners(model, adding: true)()
        EffectEditorView.changingCorners(model, adding: false)()
        await EffectEditorTests.perform(SetEffectKind(pairs, kind: .combine), fixture)
        #expect(EffectEditorTests.model(fixture).operation == .union)
        // Two objects whose effects differ: mixed values, no notice from a missing row.
        let two = await AttributeFixture.make(2)
        let list = two.list()
        _ = await list.perform(list.addEffect(.transform, above: nil))?.value
        let context = two.context(two.list().rows.count - 1)
        _ = await two.document.perform(EditEffect([context.pairs[0]], label: "One", fields: [EffectField.transform(3)]) { $0.transform.uniform = false }).value
        let mixed = EffectEditorModel(context: two.context(two.list().rows.count - 1))
        #expect(mixed.uniform == nil)
        _ = await two.document.perform(mixed.setScaleX(50)).value
        _ = await two.document.perform(EffectEditorModel(context: two.context(two.list().rows.count - 1)).setScaleY(60)).value
        let gone = EffectEditorModel(context: AttributeEditorContext(document: two.document, item: context.item, entries: []))
        #expect(gone.expandWidthOutOfRange == false && gone.cornerPoints.count == 2)
        let stale = AttributeRowItem(index: 0, list: .effects, kind: nil, summary: "", hidden: .off,
                                     targets: [AttributeTarget(node: OpID(counter: 5, replica: 5), row: context.item.targets[0].row)])
        #expect(EffectEditorModel(context: AttributeEditorContext(document: two.document, item: stale, entries: [])).notice == nil)
    }

    @Test func toolAndMenuEdges() async throws {
        #expect(BlendTool.descriptor.make().toolID == BlendTool.id && ExtrudeTool.descriptor.make().toolID == ExtrudeTool.id)
        // Tools without a context do nothing.
        let blendTool = BlendTool()
        blendTool.mouseDown(TestEvents.point(0, 0))
        blendTool.mouseDragged(TestEvents.point(1, 1))
        blendTool.mouseUp(TestEvents.point(1, 1))
        #expect(!blendTool.isDragging && blendTool.preview() == nil && blendTool.command(releasedAt: TestEvents.point(0, 0)) == nil)
        #expect(blendTool.refusal(for: .create(from: OpID(counter: 1, replica: 1)), target: nil) == nil)
        let extrudeTool = ExtrudeTool()
        extrudeTool.mouseDown(TestEvents.point(0, 0))
        extrudeTool.mouseDragged(TestEvents.point(1, 1))
        extrudeTool.mouseUp(TestEvents.point(1, 1))
        #expect(!extrudeTool.isDragging && extrudeTool.selectedHandles.isEmpty)
        // A blend tool drag from an object to itself, or to nothing, writes nothing.
        let blends = await BlendUITests.Fixture.make()
        await blends.drag(Point(x: 30, y: 110), Point(x: 50, y: 130))
        #expect(blends.blends.isEmpty)
        blends.tool.mouseDown(TestEvents.point(40, 120))
        blends.tool.mouseDragged(TestEvents.point(40, 120))
        #expect(blends.tool.refusal(for: .create(from: blends.squares[0].opID), target: blends.squares[0].opID) == nil)
        #expect(blends.tool.command(releasedAt: TestEvents.point(390, 290)) == nil)
        blends.tool.cancel()
        // Blend and Extrude from the menu refuse without a selection.
        #expect(BlendMenu.blendCommand(blends.editing) == nil && BlendMenu.blend(blends.editing) == nil)
        #expect(ExtrudeMenu.extrude(blends.editing) == nil)
        // A vanishing point on the centre points the depth control straight up.
        let extrusions = await ExtrudeUITests.Fixture.make()
        extrusions.controller.model.set(Selection([extrusions.squares[0]]))
        _ = await ExtrudeMenu.extrude(extrusions.editing)?.value
        let wrapper = try #require(extrusions.extrusion(of: extrusions.squares[0]))
        let center = try #require(ExtrudeTool.frontBounds(wrapper, in: extrusions.document)).center
        _ = await extrusions.document.perform(ShareVanishingPoints([wrapper], at: center)).value
        let handles = try #require(ExtrudeTool.handles(wrapper, in: extrusions.document))
        #expect(handles.axis == Vector(dx: 0, dy: -1) && handles.depth == center + Vector(dx: 0, dy: -36))
        #expect(ExtrudeTool.handles(OpID(counter: 9, replica: 9), in: extrusions.document) == nil)
        // The Extrude pages render each page, and the light and position setters.
        let panel = ObjectPanelModel(document: extrusions.document, selection: Selection([SelectionID(wrapper)]))
        let section = try #require(ExtrudeSectionModel(panel))
        for page in ExtrudeSectionModel.Page.allCases { AttributeFixture.render(ExtrudeSectionView(model: section, page: page)) }
        _ = await extrusions.document.perform(section.directionSetter(second: false)(.top)).value
        _ = await extrusions.document.perform(section.intensitySetter(second: true)(40)).value
        _ = await extrusions.document.perform(try #require(section.setPositionY(50))).value
        let now = try #require(ExtrudeSectionModel(panel))
        #expect(now.direction(false) == .top && now.intensity(true) == 40 && abs((now.positionY ?? 0) - 50) < 1e-6)
    }

    @Test func theRampViewsDefaultsAndANoneStop() async throws {
        let fixture = await GradientEditorTests.fixture()
        let model = GradientEditorTests.model(fixture)
        let view = GradientRampView(controller: GradientRampController())
        view.frame = NSRect(x: 0, y: 0, width: 208, height: GradientRampController.height)
        GradientRamp(model: model) { _ in }.update(view)
        let stop = model.stops[0].id
        view.perform(model.recolor(stop, ColorBridge.none)!)
        await fixture.document.settle()
        #expect(view.readColor(NSPasteboard(name: NSPasteboard.Name("WireTunerTests.none.\(UUID().uuidString)"))) == nil)
        GradientRamp(model: GradientEditorTests.model(fixture)) { _ in }.update(view)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 208, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        AttributeFixture.render(GradientEditorView(model: GradientEditorTests.model(fixture), stop: stop))
        let empty = GradientRampController()
        #expect(empty.shownStops.isEmpty && empty.drop(ColorBridge.none, x: 0, y: 0) == nil)
    }
}
