import AppKit
import CoreText
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// Generate Fonts, Install for Testing, the Metrics window, Open Font and the typeface commands
/// (FONT-020, FONT-025, FONT-026, FONT-027 in the app).
@Suite @MainActor struct TypefaceFontTests {
    func host<V: View>(_ view: V, size: NSSize = NSSize(width: 600, height: 700)) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        _ = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds).map { hosting.cacheDisplay(in: hosting.bounds, to: $0) }
    }

    /// A typeface with `A` and `V` drawn and kerned.
    func drawnTypeface() async throws -> TypefaceWindowFixture {
        let fixture = await TypefaceWindowFixture.typeface()
        for name in ["A", "V", "T", "o"] {
            let handle = try #require(GlyphCanvas.handle(for: fixture.glyph(name), of: fixture.document))
            _ = await fixture.box(50, -600, 400, 600, on: handle)
        }
        _ = await fixture.document.perform(SetKernPair(fixture.glyph("A"), fixture.glyph("V"), to: -80)).value
        return fixture
    }

    @Test func generatesOTFTTFAndWOFF2() async throws {
        let fixture = try await drawnTypeface()
        defer { fixture.close() }
        let model = GenerateFontsModel(document: fixture.document, installer: fixture.features.installer)
        host(GenerateFontsSheet(model: model, close: {}))
        #expect(!model.isBlocked && model.baseName == "Marlowe-Regular")
        let folder = FileManager.default.temporaryDirectory.appending(path: "WireTunerGenerate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.ttf = true
        model.woff2 = true
        model.chooseFolder = { folder }
        let urls = await model.generateAsking().value
        #expect(urls.map(\.lastPathComponent) == ["Marlowe-Regular.otf", "Marlowe-Regular.woff2", "Marlowe-Regular.ttf"])
        #expect(model.message == "Generated 3 files" && model.written == urls && !model.isWorking)
        let data = try Data(contentsOf: urls[0])
        #expect(CTFontManagerCreateFontDescriptorFromData(data as CFData) != nil)
        // Only a WOFF2: the OTF is compiled but not written.
        model.otf = false
        model.ttf = false
        #expect(await model.generate(into: folder).value.map(\.lastPathComponent) == ["Marlowe-Regular.woff2"])
        #expect(model.message == "Generated Marlowe-Regular.woff2")
        // Cancelling the folder writes nothing; a folder that is not there fails.
        model.chooseFolder = { nil }
        #expect(await model.generateAsking().value.isEmpty)
        model.generateButton()
        #expect(await model.generate(into: folder.appending(path: "missing/deeper")).value.isEmpty && model.message?.hasPrefix("Generating failed") == true)
        model.addStandardGlyphs = false
        model.addStandardGlyphs = true
        // A problem row opens its glyph.
        var opened: [OpID] = []
        model.openGlyph = { opened.append($0) }
        model.open(FontProblem(.warning, .emptyGlyph, glyph: fixture.glyph("B"), "B is empty"))
        model.openAction(FontProblem(.warning, .emptyGlyph, glyph: fixture.glyph("C"), "C is empty"))()
        model.open(FontProblem(.warning, .missingSpace, "no space"))
        #expect(opened == [fixture.glyph("B"), fixture.glyph("C")])
    }

    @Test func errorsBlockGeneratingAndInstalling() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        _ = await fixture.document.perform(SetFontNames([.family: ""])).value
        let model = GenerateFontsModel(document: fixture.document, installer: fixture.features.installer)
        #expect(model.isBlocked)
        host(GenerateFontsSheet(model: model, close: {}))
        #expect(await model.generate(into: FileManager.default.temporaryDirectory).value.isEmpty && model.message == "Fix the errors in the list first")
        #expect(await model.installForTesting().value == nil)
    }

    @Test func installsAndRemovesTestFonts() async throws {
        let fixture = try await drawnTypeface()
        defer { fixture.close() }
        let model = GenerateFontsModel(document: fixture.document, installer: fixture.features.installer)
        var installed: [URL] = []
        model.didInstall = { installed += $0 }
        let url = try #require(await model.installForTesting().value)
        #expect(installed == [url] && url.lastPathComponent == "MarloweTest-Regular.otf" && FileManager.default.fileExists(atPath: url.path))
        model.installButton()
        var removed = false
        model.removeInstalled = { removed = true }
        model.removeTestFonts()
        #expect(removed && model.message == "Removed the test fonts")
        // A folder that cannot be written fails with a message.
        let blocked = GenerateFontsModel(document: fixture.document, installer: TestFontInstaller(directory: URL(fileURLWithPath: "/dev/null/fonts"), scope: .process))
        #expect(await blocked.installForTesting().value == nil && blocked.message?.hasPrefix("Installing failed") == true)
        fixture.features.installer.remove([url])
    }

    @Test func theMetricsWindowSetsAndKerns() async throws {
        let fixture = try await drawnTypeface()
        defer { fixture.close() }
        let model = MetricsModel(document: fixture.document)
        model.text = "AV☃"
        #expect(model.setting.items.count == 3 && model.setting.items[0].kern == -80 && model.setting.items[2].glyph == nil)
        #expect(model.setting.width == model.setting.items[2].x + 500)
        model.kerningOn = false
        #expect(model.setting.items[0].kern == 0)
        model.kerningOn = true
        #expect(model.pairs.map(\.left) == ["A"] && model.pairs[0].value == -80)
        #expect(model.nudge(by: 10) == nil && model.problem == MetricsModel.noPair)
        model.click(atX: 420)
        #expect(model.selected == 0 && model.kernText == "-80")
        model.kernText = "-100"
        model.submitKern()
        await fixture.document.settle()
        model.nudgeUp()
        await fixture.document.settle()
        model.nudgeDown()
        await fixture.document.settle()
        model.nudgeDown()
        await fixture.document.settle()
        #expect(Kerning(fixture.document.state).value(fixture.glyph("A"), fixture.glyph("V")) == -110)
        model.kernText = "x"
        #expect(model.commitKern() == nil)
        // Class kerning needs both classes.
        model.byClass = true
        model.kernText = "-50"
        #expect(model.commitKern() == nil && model.problem == MetricsModel.noClasses)
        _ = await fixture.document.perform(CreateKernClass("A", side: .left, members: [fixture.glyph("A")])).value
        _ = await fixture.document.perform(CreateKernClass("V", side: .right, members: [fixture.glyph("V")])).value
        _ = await model.commitKern()?.value
        #expect(Kerning(fixture.document.state).classValue(fixture.glyph("A"), fixture.glyph("V")) == -50)
        model.byClass = false
        model.removePairButton()
        await fixture.document.settle()
        #expect(Kerning(fixture.document.state).pair(fixture.glyph("A"), fixture.glyph("V")) == nil)
        model.removeAllButton()
        await fixture.document.settle()
        #expect(Kerning(fixture.document.state).isEmpty)
        // A pair past a missing glyph cannot be selected; nothing selected refuses removal.
        model.select(1)
        #expect(model.selectedPair == nil && model.removePair() == nil)
        model.select(5)
        #expect(model.selected == nil)
        model.text = "A"
        model.click(atX: 0)
        #expect(model.selected == nil)
        // The compiled preview loads with Core Text.
        model.text = "AV"
        #expect(await model.compilePreview().value && model.previewFont != nil)
        model.previewButton()
        host(MetricsView(model: model))
        let paths = model.paths(height: 160)
        #expect(paths.count == 2 && paths[1].x > paths[0].x && paths[0].box == nil)
        let square = DisplayPath(elements: [.move(to: Point(x: 0, y: 0)), .line(to: Point(x: 1, y: 0)), .quadCurve(control: Point(x: 1, y: 1), end: Point(x: 0, y: 1)),
                                             .cubicCurve(control1: Point(x: 0, y: 1), control2: Point(x: 0, y: 0), end: Point(x: 0, y: 0)), .close])
        #expect(MetricsModel.cgPath(square, transform: .identity).boundingBox.width == 1)
    }

    @Test func aFontWithoutGlyphsDoesNotPreview() async throws {
        let fixture = await TypefaceWindowFixture.typeface(nil)
        defer { fixture.close() }
        let model = MetricsModel(document: fixture.document)
        model.compile = { _ in throw FontCompiler.Failure.cancelled }
        let compiled = await model.compilePreview().value
        #expect(!compiled && model.previewStatus == "The font does not compile yet")
        #expect(model.setting.items.allSatisfy { $0.glyph == nil })
    }

    @Test func theSettingViewDrawsAndSelects() async throws {
        let fixture = try await drawnTypeface()
        defer { fixture.close() }
        let controller = MetricsWindowController(document: fixture.document)
        let model = controller.model
        model.text = "AV☃"
        let view = MetricsSettingView(model: model)
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 560, height: 160))
        defer { window.close() }
        window.contentView?.addSubview(view)
        let point = view.convert(NSPoint(x: 12 + 420 * model.pointSize / model.upm, y: 80), to: nil)
        view.mouseDown(with: try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        #expect(model.selected == 0 && view.isFlipped)
        view.cacheDisplay(in: view.bounds, to: try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)))
        // The window follows changes and forgets its observer when it closes.
        var closed = false
        controller.onClose = { closed = true }
        _ = await fixture.document.perform(SetKernPair(fixture.glyph("A"), fixture.glyph("V"), to: -30)).value
        #expect(model.setting.items[0].kern == -30)
        controller.window?.close()
        #expect(closed)
    }

    @Test func opensFontFilesAsTypefaces() async throws {
        let source = try await drawnTypeface()
        defer { source.close() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "WireTunerOpen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let otf = try await FontGeneration.generate(source.document.state, format: .otf).data
        let otfURL = folder.appending(path: "Marlowe.otf")
        try otf.write(to: otfURL)
        let woffURL = folder.appending(path: "Marlowe.woff2")
        try WOFF2Writer.woff2(otf).write(to: woffURL)
        let junk = folder.appending(path: "junk.ttf")
        try Data("junk".utf8).write(to: junk)
        #expect(FontImportController.read(Data("x".utf8), fileExtension: "woff2") == nil)
        #expect(FontImportController.contentTypes.count >= 3)
        // Into a new typeface document from the menu.
        let fixture = TypefaceWindowFixture()
        defer { fixture.close() }
        var created: [DocumentHandle] = []
        fixture.features.createDocument = { title in
            let handle = DocumentHandle.memory(title: title)
            created.append(handle)
            return handle
        }
        var alerts: [String] = []
        fixture.features.alert = { message, _, _ in alerts.append(message) }
        fixture.features.chooseFontFile = { _ in woffURL }
        let report = try #require(await fixture.features.openFontFile().value)
        let imported = try #require(created.first)
        #expect(DocumentKind(imported.state) == .typeface && GlyphIndex(imported.state).glyph(named: "A") != nil)
        #expect(alerts.isEmpty == report.isEmpty && imported.undoTitle.contains("Import"))
        // Into the front typeface; an unreadable file says so; cancelling does nothing.
        _ = await fixture.document.perform(NewTypeface(family: "Front", style: "Regular", set: nil)).value
        fixture.features.chooseFontFile = { _ in otfURL }
        _ = await fixture.features.openFontFile().value
        #expect(GlyphIndex(fixture.document.state).glyph(named: "V") != nil && created.count == 1)
        fixture.features.chooseFontFile = { _ in junk }
        #expect(await fixture.features.openFontFile().value == nil && alerts.last?.contains("could not be opened") == true)
        fixture.features.chooseFontFile = { _ in nil }
        #expect(await fixture.features.openFontFile().value == nil)
        // From a glyph tab, the import goes to the tab's document.
        let a = try #require(GlyphIndex(fixture.document.state).glyph(named: "A")).id
        fixture.front = fixture.features.openGlyph(a, from: fixture.window)
        fixture.features.chooseFontFile = { _ in otfURL }
        _ = await fixture.features.openFontFile().value
        #expect(created.count == 1)
        // No document can be made: nothing happens.
        fixture.front = nil
        fixture.features.createDocument = { _ in nil }
        #expect(await fixture.features.openFontFile().value == nil)
        #expect(FontImportController(document: fixture.document).importFile(folder.appending(path: "none.otf"), newDocument: false) == nil)
    }

    @Test func newTypefaceMakesTheDocument() async throws {
        let fixture = TypefaceWindowFixture()
        defer { fixture.close() }
        var created: [DocumentHandle] = []
        fixture.features.createDocument = { title in
            let handle = DocumentHandle.memory(title: title)
            created.append(handle)
            return handle
        }
        let sheet = fixture.features.presentNewTypeface()
        #expect(sheet.identifier?.rawValue == "sheet.newTypeface")
        fixture.window.window?.endSheet(sheet)
        let document = try #require(await fixture.features.createTypeface(.init(family: "Marlowe", style: "Bold", set: .basicLatin, upm: 1_000)).value)
        #expect(document.title == "Marlowe Bold" && GlyphIndex(document.state).count == 96 && WTModel.FontInfo(document.state).names.style == "Bold")
        // From a font file: the file is asked for and imported into the new document.
        let source = try await drawnTypeface()
        defer { source.close() }
        let url = FileManager.default.temporaryDirectory.appending(path: "WireTunerNew-\(UUID().uuidString).otf")
        try await FontGeneration.generate(source.document.state, format: .otf).data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        fixture.features.chooseFontFile = { _ in url }
        let fromFile = try #require(await fixture.features.createTypeface(.init(family: "", style: "", set: .fromFile, upm: 1_000)).value)
        #expect(fromFile.title == "Untitled Typeface" && GlyphIndex(fromFile.state).glyph(named: "A") != nil)
        fixture.features.createDocument = { _ in nil }
        #expect(await fixture.features.createTypeface(.init(family: "X", style: "Y", set: .empty, upm: 1_000)).value == nil)
        // With no window the sheet stands alone.
        fixture.front = nil
        let alone = fixture.features.presentNewTypeface()
        alone.close()
        fixture.features.createTypefaceFromSheet(.init(family: "Sheet", style: "Regular", set: .empty, upm: 1_000))
    }

    @Test func theCommandsValidateAndAct() async throws {
        let fixture = try await drawnTypeface()
        defer { fixture.close() }
        let registry = fixture.environment.commands
        func validation(_ id: CommandID) -> CommandValidation { registry.command(id)!.validation() }
        let grid = try #require(fixture.mode.grid)
        #expect(validation(TypefaceFeatures.ID.fontInfo).isEnabled && !validation(TypefaceFeatures.ID.openGlyph).isEnabled)
        #expect(validation(TypefaceFeatures.ID.convertTypeface).isChecked && !validation(TypefaceFeatures.ID.nextGlyph).isEnabled)
        grid.model.select([fixture.glyph("A"), fixture.glyph("V")])
        #expect(validation(TypefaceFeatures.ID.openGlyph).isEnabled && validation(TypefaceFeatures.ID.removeGlyphs).isEnabled)
        for id in [TypefaceFeatures.ID.fontInfo, TypefaceFeatures.ID.generateFonts, TypefaceFeatures.ID.addGlyph, TypefaceFeatures.ID.convertMulti,
                   TypefaceFeatures.ID.convertPageToGlyph] {
            #expect(registry.perform(id))
            #expect(fixture.window.window?.attachedSheet != nil)
            if let sheet = fixture.window.window?.attachedSheet { fixture.window.window?.endSheet(sheet) }
        }
        #expect(registry.perform(TypefaceFeatures.ID.metricsWindow))
        let metrics = try #require(fixture.features.metrics[fixture.document.id])
        #expect(fixture.features.showMetrics() === metrics)
        metrics.window?.close()
        #expect(fixture.features.metrics.isEmpty)
        #expect(registry.perform(TypefaceFeatures.ID.copyGlyphToPage))
        await fixture.document.settle()
        #expect(PageList(fixture.document.state).pages.count == 3)
        #expect(registry.perform(TypefaceFeatures.ID.openGlyph))
        let tab = try #require(fixture.features.gridWindow(of: GlyphCanvas.tabID(document: fixture.document.id, glyph: fixture.glyph("A"))))
        fixture.front = tab
        #expect(validation(TypefaceFeatures.ID.nextGlyph).isEnabled && validation(TypefaceFeatures.ID.fitGlyph).isEnabled)
        #expect(registry.perform(TypefaceFeatures.ID.glyphParts) && tab.window?.attachedSheet?.identifier?.rawValue == "sheet.glyphParts")
        if let sheet = tab.window?.attachedSheet { tab.window?.endSheet(sheet) }
        #expect(registry.perform(TypefaceFeatures.ID.fitGlyph))
        #expect(registry.perform(TypefaceFeatures.ID.previousGlyph))
        // Install for Testing from the menu.
        fixture.front = fixture.window
        let installed = await fixture.features.installForTesting().value
        #expect(installed != nil && fixture.features.installed[fixture.document.id]?.count == 1)
        fixture.features.installer.remove(fixture.features.installed[fixture.document.id] ?? [])
        // Generate's hooks reach the features.
        let generate = try #require(fixture.features.presentGenerate())
        fixture.window.window?.endSheet(generate)
        #expect(registry.perform(TypefaceFeatures.ID.removeGlyphs))
        await fixture.document.settle()
        #expect(GlyphIndex(fixture.document.state).glyph(named: "V") == nil)
        // Nothing to act on without a window.
        fixture.front = nil
        #expect(!validation(TypefaceFeatures.ID.fontInfo).isEnabled && !validation(TypefaceFeatures.ID.openGlyph).isEnabled)
        #expect(!validation(TypefaceFeatures.ID.convertSingle).isEnabled)
        #expect(fixture.features.presentConvert(to: .typeface) == nil && fixture.features.presentFontInfo() == nil && fixture.features.presentGenerate() == nil)
        #expect(fixture.features.showMetrics() == nil && fixture.features.presentAddGlyph() == nil && fixture.features.removeSelectedGlyphs() == nil)
        #expect(fixture.features.stepGlyph(by: 1) == nil && fixture.features.presentGlyphParts() == nil && fixture.features.presentConvertPage() == nil)
        let noInstall = await fixture.features.installForTesting().value
        #expect(fixture.features.copySelectedGlyphsToPages().isEmpty && noInstall == nil)
        fixture.features.openSelectedGlyphs()
    }

    @Test func theCommandsNeedATypeface() async throws {
        let fixture = TypefaceWindowFixture()
        defer { fixture.close() }
        _ = await fixture.document.openedModel()
        let registry = fixture.environment.commands
        #expect(registry.command(TypefaceFeatures.ID.fontInfo)?.validation().reason == TypefaceFeatures.notTypeface)
        #expect(registry.command(TypefaceFeatures.ID.openGlyph)?.validation().reason == TypefaceFeatures.notTypeface)
        #expect(fixture.features.removeSelectedGlyphs() == nil)
        // Removing a drawn glyph asks first; declining keeps it.
        _ = await fixture.document.perform(NewTypeface(family: "M", style: "R")).value
        let a = GlyphIndex(fixture.document.state).glyph(named: "A")!.id
        _ = await fixture.box(0, -100, 100, 100, on: try #require(GlyphCanvas.handle(for: a, of: fixture.document)))
        fixture.mode.grid?.model.select([a])
        fixture.window.confirm = { _, _ in false }
        #expect(fixture.features.removeSelectedGlyphs() == nil)
        // In a glyph tab, removing its glyph closes the tab.
        fixture.window.confirm = { _, _ in true }
        let tab = try #require(fixture.features.openGlyph(a, from: fixture.window))
        tab.confirm = { _, _ in true }
        fixture.front = tab
        _ = await fixture.features.removeSelectedGlyphs()?.value
        #expect(GlyphIndex(fixture.document.state).glyph(named: "A") == nil)
    }

    @Test func glyphCanvasPlacesEveryKindItCanHold() throws {
        let glyph = OpID(counter: 9, replica: 1)
        var props = Wiretuner_Doc_V1_NodeProps()
        let cases: [(inout Wiretuner_Doc_V1_NodeProps) -> Void] = [
            { $0.path = .init() }, { $0.rect = .init() }, { $0.ellipse = .init() }, { $0.polygon = .init() }, { $0.group = .init() }, { $0.text = .init() },
        ]
        var kinds: [NodeKind] = []
        for build in cases {
            build(&props)
            kinds.append(try #require(GlyphCanvas.canvasValue(props, canvas: glyph)).kind)
        }
        #expect(kinds == [.path, .rect, .ellipse, .polygon, .group, .text])
        props.chart = .init()
        #expect(GlyphCanvas.canvasValue(props, canvas: glyph) == nil)
        // The Guides pane's colours reach the frame; unset ones keep the defaults.
        var guides = WTModel.FontInfo(EngineState()).guides
        var frame = GlyphCanvasFrame(advanceWidth: 500)
        GlyphCanvas.apply(guides, to: &frame)
        #expect(frame.baselineColor == GlyphCanvasFrame(advanceWidth: 0).baselineColor)
        guides.baselineColor = Color(red: 1, green: 0, blue: 0)
        guides.metricColor = Color(red: 0, green: 1, blue: 0)
        guides.bearingColor = Color(red: 0, green: 0, blue: 1)
        GlyphCanvas.apply(guides, to: &frame)
        #expect(frame.baselineColor == Color(red: 1, green: 0, blue: 0) && frame.bearingColor == Color(red: 0, green: 0, blue: 1))
        #expect(GlyphCanvas.documentID(ofTab: "plain") == "plain")
        #expect(GlyphCanvas.background(of: glyph, in: EngineState()).isEmpty && GlyphCanvas.frame(for: glyph, in: EngineState()) == nil)
        let placed = GlyphCanvas.placing(RemoveAllKerning(), on: glyph)
        #expect(GlyphCanvas.placing(placed, on: glyph) is CanvasPlacedCommand && GlyphCanvas.placing(placed, on: nil) is CanvasPlacedCommand)
        #expect(placed.label == "Remove all kerning" && placed.recordsUndo && placed.coalescing == .none)
    }

    @Test func theGlyphFrameFollowsTheFontsGuides() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        _ = await fixture.document.perform(SetMetricGuides([.show(.xHeight, false), .addLine(name: "overshoot", y: 510)])).value
        let frame = try #require(GlyphCanvas.frame(for: fixture.glyph("A"), in: fixture.document.state))
        #expect(!frame.showXHeight && frame.extraLines.map(\.label) == ["overshoot"])
        #expect(GlyphCanvas.emBox(frame) == Rect(x: 0, y: -800, width: 500, height: 1_000))
        #expect(GlyphCanvas.scrollBounds(frame).minY == -1_500 && GlyphCanvas.scrollBounds(frame).maxY == 700)
    }
}
