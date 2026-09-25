import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The edges of the type, drawing, export and typeface UI of TYPE-011 ... FONT-021: the paths the
/// main tests do not take (no document, nothing selected, fallbacks and the views' own actions).
@Suite(.serialized) @MainActor struct TypeDrawingEdgeTests {
    @Test func paragraphSectionActionsAndEditingProps() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("One\nTwo")
        await world.edit(node, select: 5..<5)
        let model = TypeLayoutUITests.model(world, [node])
        let section = try #require(model.paragraph)
        #expect(section.editing && model.paragraphProps.count == 1)
        var closed = 0
        ParagraphSectionView.hyphenationCommit(model) { closed += 1 }(.with { $0.language = "fr" })
        ParagraphSectionView.inhibiting(model)(true)
        ParagraphSectionView.ruleCommit(model) { closed += 1 }(.with { $0.widthPercent = 60 }, false)
        ParagraphSectionView.alignmentCommit(model) { closed += 1 }(90, 10)
        ParagraphSectionView.hyphenate(section, model).wrappedValue = true
        ParagraphSectionView.hangPunctuation(section, model).wrappedValue = true
        await world.settle()
        #expect(closed == 3)
        let props = try #require(world.state.textNode(node)?.paragraphs[1].props)
        #expect(props.hyphenation.language == "fr" && props.rule.widthPercent == 60 && props.raggedWidth == 90 && props.hangPunctuation && props.hyphenation.enabled)
        #expect(ParagraphSectionView.raggedWidth(.init()) == 100 && ParagraphSectionView.raggedWidth(.with { $0.raggedWidth = 70 }) == 70)
        #expect(!ParagraphSectionView.hangPunctuation(section, model).wrappedValue)
    }

    @Test func rulerWithoutABlockAndTheViewsPressOnTheWell() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let pending = TextEditingSession(document: world.document, sink: world.window.objectEditing, target: .pending(.point(.zero)))
        let model = TextRulerModel(session: pending, viewport: world.window.viewport)
        #expect(model.node == nil && model.paragraph == nil && model.stops.isEmpty && model.inset == Wiretuner_Doc_V1_Inset())
        #expect(model.leftIndent == 0 && model.firstLine == 0 && model.rightIndent == model.width)
        #expect(model.place(.left, at: 1) == nil && model.dragStop(from: 1, to: 2, offRuler: false, duplicate: false) == nil && model.dragIndent(.left, by: 1) == nil)
        // A duplicate of a place with no stop is a left stop.
        let node = try #require(await world.document.perform(CreateTextBlock(.area(Rect(x: 40, y: 40, width: 300, height: 100)), text: "x")).value?.createdObjects.first)
        await world.document.settle()
        await world.edit(node, select: 0..<0)
        let live = TextRulerModel(session: try #require(world.session), viewport: world.window.viewport)
        let duplicate = try #require(live.dragStop(from: 77, to: 80, offRuler: false, duplicate: true) as? AddTabStop)
        #expect(duplicate.stop.kind == .left)
        // A kind from the well dropped off the ruler places nothing.
        let view = TextRulerView()
        view.model = live
        view.begin(at: NSPoint(x: -TextRulerView.wellWidth + 2, y: 10))
        #expect(view.end(at: NSPoint(x: 50, y: 80)) == nil)
    }

    @Test func styleBehaviorFieldsWithoutNormalTextAndWithANextStyle() async throws {
        let world = TypeWorld()
        defer { world.close() }
        // Only a character style: no Normal Text, so program defaults are empty.
        _ = await world.document.perform(CreateTextStyle(.character, attrs: .init())).value
        let character = try #require(world.state.textStyles.styles(.character).first)
        #expect(TextStyleBehaviorModel(style: character, in: world.state).defaults == Wiretuner_Doc_V1_TextStyleAttrs())
        _ = await world.document.perform(CreateTextStyle(.paragraph, attrs: .init())).value
        let style = try #require(world.state.textStyles.styles(.paragraph).first)
        _ = await world.document.perform(EditTextStyle(style.id, attrs: .with { $0.next = .with { $0.id = style.id.proto } }, fields: [[1]], name: style.name)).value
        let model = TextStyleBehaviorModel(style: try #require(world.state.textStyles.style(style.id)), in: world.state)
        #expect(model.original.hasNext)
        model.apply(.noSettings)
        #expect(model.attrs.hasNext)
        model.apply(.defaults)
        #expect(model.attrs.hasNext)
        for binding in [model.spaceAbove, model.spaceBelow, model.leftIndent, model.rightIndent, model.firstLineIndent] {
            binding.wrappedValue = "4"
            #expect(binding.wrappedValue == "4")
            binding.wrappedValue = ""
            #expect(binding.wrappedValue == "")
        }
        #expect(model.faces.isEmpty == false)
        model.family.wrappedValue = "Helvetica"
        model.face.wrappedValue = "Bold"
        #expect(model.faces.contains("Bold"))
        PanelRendering.host(TextStyleBehaviorSheet(model: model, commit: { _ in }, cancel: {}))
    }

    @Test func findSpellingAndTheirWindowsEdges() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("teh cat teh dog. the End")
        world.window.selection.model.clear()
        let find = FindTextModel()
        find.find = "teh"
        find.replacement = "the"
        // The shown match with Selection scope searches the block, not the match alone.
        _ = find.findNext(in: world.window)
        find.scope = .selection
        world.window.selection.model.set(Selection([SelectionID(node)]))
        #expect(find.matches(in: world.window).count == 2)
        // The current match goes away: Find Next starts over.
        let text = try #require(world.state.textNode(node))
        await world.document.receiveRemote(DeleteText(node: node, from: text.anchor(at: 0), to: text.anchor(at: 4)))
        await world.settle()
        find.scope = .document
        #expect(find.findNext(in: world.window) != nil)
        #expect(SpellingModel.rank(OpID(counter: 999, replica: 9), in: []) == 0)
        _ = await find.replaceAll(in: world.window)?.value
        find.find = "the"
        _ = await find.replaceAll(in: world.window)?.value
        #expect(find.message == "2 replaced")
        FindTextView.replaceAll(find, world.window)
        FindTextView.replace(find, world.window)
        FindTextView.replaceAndFind(find, world.window)
        FindTextView.findNext(find, world.window)
        await world.settle()
        // Spelling: the capitalization issue, guesses that come back empty, wrapping.
        final class NoGuesses: SpellingService {
            func isCorrect(_ word: String, language: String?) -> Bool { word != "cat" }
            func guesses(for word: String, language: String?) -> [String] { [] }
            func learn(_ word: String) {}
            func unlearn(_ word: String) {}
            func hasLearned(_ word: String) -> Bool { false }
        }
        let spelling = SpellingModel(service: NoGuesses())
        world.window.selection.model.clear()
        world.window.objectEditing.textSession = nil
        let first = try #require(spelling.findNext(in: world.window))
        #expect(first.word == "cat" && spelling.correction == "cat", "no guesses: the word itself")
        let second = try #require(spelling.findNext(in: world.window))
        #expect(second.kind == .capitalization && spelling.guesses == [second.suggestion!])
        #expect(spelling.findNext(in: world.window)?.word == "cat", "past the last issue it wraps")
        let binding = SpellingView.selection(spelling)
        binding.wrappedValue = "cot"
        binding.wrappedValue = nil
        #expect(binding.wrappedValue == "cot")
        SpellingView.findNext(spelling, world.window)
        SpellingView.ignore(spelling, world.window)
        SpellingView.learn(spelling, world.window)
        SpellingView.change(spelling, world.window)
        await world.settle()
    }

    @Test func styleOperationsEdges() async throws {
        let world = TypeWorld()
        defer { world.close() }
        _ = await world.document.perform(CreateNormalTextStyle()).value
        let empty = try await world.block("")
        let model = TypeLayoutUITests.model(world, [empty])
        #expect(model.styleAttributes(firstParagraph: true) == SharedTextAttributes.attrs(runs: [[]], paragraphs: [try #require(world.state.textNode(empty)).paragraphs[0].props]))
        _ = await world.document.perform(CreateTextStyle(.character, attrs: .init())).value
        let character = try #require(world.state.textStyles.styles(.character).first)
        #expect(TextStyleOperations.redefine(character.id, model: model, firstParagraph: false) == nil, "nothing to take")
        let node = try await world.block("One\nTwo", at: Point(x: 50, y: 200))
        _ = await TextStyleOperations.newStyle(.paragraph, model: TypeLayoutUITests.model(world, [node]), firstParagraph: true)?.value
        let style = try #require(world.state.textStyles.styles(.paragraph).first { !$0.isNormalText })
        let bounds = try #require(world.document.object(for: SelectionID(node))?.bounds)
        _ = await TextStyleOperations.drop(style.id, at: Point(x: bounds.minX + 3, y: bounds.maxY - 3), on: world.window, wholeBlock: false)?.value
        let paragraphs = try #require(world.state.textNode(node)).paragraphs
        #expect(world.state.textStyles.paragraphStyle(paragraphs[1].props).style == style.id)
    }

    @Test func chartSheetEdges() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let chart = try #require(await world.document.perform(CreateChart(size: Size(width: 100, height: 100))).value?.createdObjects.first)
        let model = ChartSheetModel(chart: chart, document: world.document, sink: world.window.objectEditing)
        #expect(ChartSheetModel.storedType(.init()) == .groupedColumn && model.undo() == nil)
        // A table past the op limit is refused with a message.
        let big = (0..<10_001).map { "\($0)" }.joined(separator: "\n")
        await model.importText(big).value
        #expect(model.message?.contains("too large") == true)
        PanelRendering.host(ChartSheetView(model: model) {})
        await model.importText("").value
        // The views with a message, a selection and each action.
        model.select(ChartSheetModel.Position(row: 0, column: 0))
        model.select(ChartSheetModel.Position(row: 0, column: 1), extending: true)
        PanelRendering.host(ChartSheetView(model: model) {})
        _ = ChartSheetView.importing(model)
    }

    @Test func kerningAndAutoKernEdges() async throws {
        let fixture = await TypefaceWindowFixture.typeface(nil)
        defer { fixture.close() }
        let document = fixture.document
        let model = KerningClassesModel(document: document) { document.perform($0) }
        defer { model.stop() }
        #expect(model.name(of: OpID(counter: 999, replica: 9)) == "?")
        model.guess()
        #expect(model.proposal.isEmpty && model.message == "No classes to propose")
        for action in KerningClassesSheet.Action.allCases { KerningClassesSheet.run(action, model)() }
        let auto = AutoKernModel(document: document, glyphs: []) { document.perform($0) }
        #expect(auto.separation == 100)
        auto.showPreview()
        #expect(auto.preview.isEmpty)
    }

    @Test func quickExportAndDragEdges() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let exports = ExportController(defaults: TestDefaults().defaults)
        let quick = QuickExport(exports: exports, preferences: world.setup.environment.preferences)
        #expect(quick.desktop().hasDirectoryPath || !quick.desktop().path.isEmpty)
        if case .perform(let run) = quick.commands(window: { nil })[0].action { run() }
        let store = ExportPresetStore(defaults: TestDefaults().defaults)
        let manager = ExportPresetManager(store: store)
        manager.selected = ExportPreset.shipped[0].id
        ExportPresetManagerView.duplicating(manager)()
        let data = manager.exported()
        manager.selected = store.userPresets.first?.id
        manager.delete()
        #expect(manager.importPresets(data) == 1 && manager.message == "1 preset imported")
        if case .perform(let run) = ExportPresetManagerView.command(store: store, window: { nil }).action { run() }
        // Drag export: a window gone makes nothing; a promise whose format has no UTType uses data.
        let dragging = ObjectDragging(editing: world.window.objectEditing)
        var window: DocumentWindowController? = world.window
        window?.canvas.objectDrop = dragging
        DragExport.attach(world.window, preferences: world.setup.environment.preferences)
        window = nil
        _ = window
        let promise = SnapshotPromise(name: "x", scene: ExportScene(pages: []), format: .targa) { nil }
        #expect(!promise.fileType.isEmpty)
        promise.optionHeld = { true }
        #expect(promise.filePromiseProvider(promise, fileNameForType: promise.fileType) == "x.tga")
    }

    @Test func theAppDelegateInstallsTheseFeatures() async throws {
        let suite = TestDefaults()
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(delegate.quickExport === delegate.quickExport)
        for id in [GraphicReplaceCommands.id, TypefaceTools.ID.findProblems] {
            if case .perform(let run)? = delegate.commands.command(id)?.action { run() }
        }
        #expect(delegate.commands.contains(TextStyleOperations.ID.behavior) && delegate.panels.contains(TypefaceTools.panelID))
        let window = try #require(delegate.activeDocumentWindow)
        _ = delegate.preferences.set("srgb", for: PreferenceCatalog.Colors.defaultColorSpace)
        let node = try #require(await window.documentHandle.addText("spell chek"))
        window.selection.model.set(Selection([SelectionID(node)]))
        window.toolManager.select(TextTool.id)
        (window.toolManager.activeTool as? TextTool)?.edit(node, at: .zero)
        window.canvas.drawOverlay(in: DrawingToolTests.bitmap())
        let board = NSPasteboard(name: NSPasteboard.Name("uid-install-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        #expect(window.canvas.textColorDrop?(board, .zero) == false)
        try await Task.sleep(for: .milliseconds(50))
        window.close()
    }

    @Test func toolAndSheetDefaults() async throws {
        #expect(CalligraphicPen().settings().angle == 45 && EraserTool().settings().max == 12)
        let chart = ChartTool()
        chart.openSheet(OpID(counter: 1, replica: 1))
        let f = DrawingToolTests.Fixture(ChartTool())
        f.tool.mouseDown(TestEvents.point(100, 100))
        f.tool.mouseDragged(TestEvents.point(40, 60, .shift))
        #expect(f.tool.rect == Rect(x: 40, y: 40, width: 60, height: 60))
        f.tool.cancel()
        // The calligraphic outline's overlay at a variable nib.
        var variable = CalligraphicSettings()
        variable.variable = true
        let nib = variable
        let pen = DrawingToolTests.Fixture(CalligraphicPen { nib })
        pen.tool.mouseDown(TestEvents.point(0, 0))
        pen.tool.mouseDragged(TestEvents.point(1, 0))
        pen.tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: pen.host.viewport)
        _ = pen.tool.command()
        #expect(TextWrapFeatures.current([], in: EngineState()) == (false, 0))
        #expect(HyphenationSheet.languages.count > 1)
    }
}
