import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// ATTR-009: the brush pop-up and its action menu, the Edit Brush sheet with its preview and both
/// prompts, Create Brush from the Modify menu, and brush files -- create, edit (Change and
/// Create), duplicate, remove (Release and Delete), import and export.
@Suite @MainActor struct BrushEditorTests {
    /// A document with a small square (the brush's artwork) and a path whose stroke row is
    /// switched to Brush.
    @MainActor
    final class Fixture {
        let attributes = AttributeFixture()
        var tip = SelectionID(OpID(counter: 0, replica: 0))
        var path = SelectionID(OpID(counter: 0, replica: 0))

        static func make() async -> Fixture {
            let fixture = Fixture()
            let document = fixture.attributes.document
            fixture.tip = await document.addRectangles([Rect(x: 400, y: 400, width: 8, height: 8)])[0]
            fixture.path = await document.addPath([Point(x: 0, y: 50), Point(x: 100, y: 20), Point(x: 200, y: 50)])!
            fixture.attributes.ids = [fixture.path]
            return fixture
        }

        var document: DocumentHandle { attributes.document }

        /// The Brush stroke editor's controls of the path's stroke.
        func controls(files: BrushFiles = BrushFiles()) -> BrushControlsModel {
            let list = attributes.list()
            let index = list.rows.firstIndex { $0.list == .strokes }!
            return BrushControlsModel(context: attributes.context(index), files: files)
        }

        func stroke() -> Wiretuner_Doc_V1_StrokeSettings {
            attributes.stack().first { $0.row.list == .strokes }!.stroke.settings
        }

        /// Makes a brush from the square through the Create Brush sheet's model.
        func createBrush(name: String = "Dots") async -> OpID {
            let model = BrushEditorModel(document: document, purpose: .create([tip.opID]))
            model.name = name
            guard case .perform(let command) = model.ok() else { return OpID(counter: 0, replica: 0) }
            _ = await document.perform(command).value
            return Brushes.list(document.state).first { $0.name == name }!.id
        }
    }

    @Test func createFromTheSelectionThenApplyFromThePopUp() async throws {
        let fixture = await Fixture.make()
        // Create Brush from the Modify menu opens the sheet over the window.
        let editing = ObjectEditing(document: fixture.document, selection: SelectionController(document: fixture.document))
        editing.selection.model.set(Selection([fixture.tip]))
        let presenter = SheetPresenter()
        var presented: [NSWindow] = []
        presenter.present = { presented.append($0) }
        let features = EffectFeatures(target: { editing }, sheets: presenter)
        features.showCreateBrush()
        #expect(presented.count == 1 && presenter.sheets[EffectFeatures.createBrush] != nil)
        presenter.dismiss(EffectFeatures.createBrush)
        #expect(presenter.sheets.isEmpty)
        let menu = features.commands().first { $0.id == EffectFeatures.ID.createBrush }!
        #expect(menu.validation().isEnabled && menu.menuPath == MenuPath("Modify", "Brush", section: 4))
        // The sheet's draft: Copy or Convert, the name, the settings, a preview.
        let model = BrushEditorModel(document: fixture.document, purpose: .create([fixture.tip.opID]))
        #expect(model.isCreating && model.name == "Brush" && model.symbols.isEmpty && model.preview != nil)
        model.setPaint(true)
        model.setCount(900)
        #expect(model.props.mode == .paint && model.props.count == 500)
        AttributeFixture.render(BrushEditorSheet(model: model) { _ in })
        let brush = await fixture.createBrush()
        #expect(fixture.document.undoTitle == "Undo Create Brush" && Brushes.list(fixture.document.state).count == 1)
        // The stroke becomes a Brush stroke from the pop-up.
        _ = await fixture.document.perform(SetAttributeKind(fixture.controls().context.pairs, stroke: .brush)).value
        var controls = fixture.controls()
        #expect(controls.current == nil && controls.title == "Choose Brush" && controls.brushes.map(\.id) == [brush])
        BrushControls.apply(brush, model: controls)
        await fixture.document.settle()
        controls = fixture.controls()
        #expect(controls.current == brush && controls.title == "Dots" && fixture.stroke().brush.seed != 0)
        AttributeFixture.render(StrokeEditorView(model: StrokeEditorModel(context: controls.context)))
        AttributeFixture.render(BrushControls(model: controls))
        #expect(BrushStrokes.users(of: brush, in: fixture.document.state) == [fixture.path.opID])
    }

    @Test func editAskingChangeOrCreate() async throws {
        let fixture = await Fixture.make()
        let brush = await fixture.createBrush()
        let state = BrushControlsState()
        // Not in use yet: OK changes it.
        _ = await fixture.document.perform(SetAttributeKind(fixture.controls().context.pairs, stroke: .brush)).value
        #expect(fixture.controls().editor() == nil, "no brush on the stroke: nothing to edit")
        let unused = BrushEditorModel(document: fixture.document, purpose: .edit(brush, strokes: []))
        unused.name = "Sparse"
        unused.setValue(.spacing, 500)
        guard case .perform(let command) = unused.ok() else { Issue.record("asked"); return }
        _ = await fixture.document.perform(command).value
        #expect(Brushes.list(fixture.document.state)[0].name == "Sparse" && Brushes.list(fixture.document.state)[0].props.spacing.value == 200)
        // In use: OK asks; Change rewrites it, Create makes a copy for these strokes.
        BrushControls.apply(brush, model: fixture.controls())
        await fixture.document.settle()
        BrushControls.edit(fixture.controls(), state: state)
        guard case .edit(let editor)? = state.sheet else { Issue.record("no sheet"); return }
        #expect(editor.users == [fixture.path.opID] && editor.preview != nil && BrushControlsState.Sheet.edit(editor).id == "edit")
        var asked = false
        BrushEditorSheet.confirm(editor, ask: { asked = true }) { _ in }
        #expect(asked)
        editor.setMode(.angle, .random)
        editor.setRange(.angle, min: 10, max: 50)
        editor.setMode(.scaling, .flare)
        #expect(editor.props.scaling.mode == .fixed, "Flare scales Paint brushes only")
        editor.setMode(.offset, .flare)
        #expect(editor.props.offset.mode == .flare)
        editor.setPaint(true)
        #expect(editor.props.offset.mode == .fixed, "Flare offsets Spray brushes only")
        BrushControls.finish(editor.resolve(change: true), model: fixture.controls(), state: state)
        await fixture.document.settle()
        var entry = Brushes.list(fixture.document.state)[0]
        #expect(entry.props.angle.min == 10 && entry.props.angle.max == 50 && entry.props.mode == .paint && fixture.document.undoTitle == "Undo Edit Brush")
        let copy = BrushEditorModel(document: fixture.document, purpose: .edit(brush, strokes: fixture.controls().strokes))
        copy.props.foldCorners = true
        _ = await fixture.document.perform(copy.resolve(change: false)!).value
        #expect(Brushes.list(fixture.document.state).count == 2 && fixture.controls().current != brush)
        entry = Brushes.list(fixture.document.state)[0]
        #expect(!entry.props.foldCorners, "the original is left alone")
        #expect(BrushEditorModel(document: fixture.document, purpose: .create([])).resolve(change: true) == nil)
        // The symbol list: add, move, remove.
        let symbols = BrushEditorModel(document: fixture.document, purpose: .edit(brush, strokes: []))
        let symbol = try #require(symbols.symbolChoices.first?.id)
        symbols.addSymbol(symbol)
        #expect(symbols.symbols.count == 2 && symbols.selectedSymbol == symbol)
        symbols.moveSymbol(up: false)
        #expect(symbols.symbols.first == symbol)
        symbols.moveSymbol(up: false)
        symbols.removeSymbol()
        symbols.removeSymbol()
        symbols.removeSymbol()
        #expect(symbols.symbols.isEmpty && symbols.preview == nil)
        AttributeFixture.render(BrushEditorSheet(model: symbols) { _ in })
        var finished: [(any WTModel.Command)?] = []
        BrushEditorSheet.confirm(BrushEditorModel(document: fixture.document, purpose: .create([fixture.tip.opID])), ask: {}) { finished.append($0) }
        #expect(finished.count == 1)
        #expect(BrushVariationKind.offset.range == -200...200 && BrushVariationKind.angle.range == 0...359)
    }

    @Test func duplicateAndRemoveWithBothChoices() async throws {
        let fixture = await Fixture.make()
        let brush = await fixture.createBrush()
        _ = await fixture.document.perform(SetAttributeKind(fixture.controls().context.pairs, stroke: .brush)).value
        BrushControls.apply(brush, model: fixture.controls())
        await fixture.document.settle()
        BrushControls.duplicate(fixture.controls())
        await fixture.document.settle()
        #expect(Brushes.list(fixture.document.state).map(\.name) == ["Dots", "Copy of Dots"] && fixture.document.undoTitle == "Undo Duplicate Brush")
        // Release keeps the path, grouped with its baked brush strokes.
        let state = BrushControlsState()
        state.removing = true
        BrushControls.remove(fixture.controls(), release: true, state: state)
        await fixture.document.settle()
        #expect(!state.removing && Brushes.list(fixture.document.state).map(\.name) == ["Copy of Dots"])
        #expect(fixture.document.state.isLive(fixture.path.opID))
        _ = await fixture.document.undo().value
        BrushControls.remove(fixture.controls(), release: false, state: state)
        await fixture.document.settle()
        #expect(!fixture.document.state.isLive(fixture.path.opID), "Delete removes the paths using it")
        let bare = await AttributeFixture.make()
        let none = BrushControlsModel(context: bare.context(1))
        #expect(none.duplicate() == nil && none.remove(release: true) == nil && none.importing([], from: EngineState()) == nil)
    }

    @Test func importAndExportBrushFiles() async throws {
        let fixture = await Fixture.make()
        let brush = await fixture.createBrush()
        let url = TestEnvironment.temporaryDirectory().appending(path: "Brushes.wiretuner")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var alerts: [String] = []
        var files = BrushFiles()
        files.runSavePanel = { _, _ in url }
        files.runOpenPanel = { _, _ in [url] }
        files.showAlert = { message, _, _ in alerts.append(message) }
        let controls = fixture.controls(files: files)
        // Export: the picker, then the save panel.
        let state = BrushControlsState()
        #expect(await BrushControls.export([brush], model: controls, state: state).value)
        #expect(await files.export([], from: fixture.document.state) == false)
        let file = try BrushFiles.read(url)
        #expect(Brushes.list(file).map(\.name) == ["Dots"])
        // Import into another document: the file panel, then the picker.
        let other = await Fixture.make()
        let importing = other.controls(files: files)
        await BrushControls.startImport(importing, state: state).value
        guard case .pickImport(let opened)? = state.sheet else { Issue.record("no picker"); return }
        #expect(BrushControlsState.Sheet.pickImport(opened).id == "import" && BrushControlsState.Sheet.pickExport.id == "export")
        AttributeFixture.render(BrushControls.sheet(.pickImport(opened), model: importing, state: state))
        AttributeFixture.render(BrushControls.sheet(.pickExport, model: importing, state: state))
        BrushControls.finish(importing.importing(Brushes.list(opened).map(\.id), from: opened), model: importing, state: state)
        await other.document.settle()
        #expect(Brushes.list(other.document.state).map(\.name) == ["Dots"] && other.document.undoTitle == "Undo Import Brush")
        // Unreadable and cancelled files.
        let junk = url.deletingLastPathComponent().appending(path: "junk.wiretuner")
        try Data("junk".utf8).write(to: junk)
        files.runOpenPanel = { _, _ in [junk] }
        #expect(await files.chooseFile() == nil && alerts.count == 1)
        files.runOpenPanel = { _, _ in [] }
        #expect(await files.chooseFile() == nil)
        files.runSavePanel = { _, _ in nil }
        #expect(await files.export([brush], from: fixture.document.state) == false)
        files.runSavePanel = { _, _ in URL(fileURLWithPath: "/nonexistent/dir/b.wiretuner") }
        #expect(await files.export([brush], from: fixture.document.state) == false && alerts.count == 2)
        AttributeFixture.render(BrushPickerSheet(title: "Import", brushes: Brushes.list(file)) { _ in })
    }
}
