import AppKit
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

/// The typeface UI's edges: every menu command through the registry, the features' hooks, the
/// sheets' messages and the models' fallbacks.
@Suite @MainActor struct TypefaceEdgeTests {
    func host<V: View>(_ view: V, size: NSSize = NSSize(width: 600, height: 700)) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        _ = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds).map { hosting.cacheDisplay(in: hosting.bounds, to: $0) }
    }

    func endSheet(_ window: DocumentWindowController) {
        if let sheet = window.window?.attachedSheet { window.window?.endSheet(sheet) }
    }

    @Test func everyMenuCommandActs() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let registry = fixture.environment.commands
        fixture.features.chooseFontFile = { _ in nil }
        #expect(registry.perform(TypefaceFeatures.ID.newTypeface))
        #expect(fixture.window.window?.attachedSheet?.identifier?.rawValue == "sheet.newTypeface")
        endSheet(fixture.window)
        for id in [TypefaceFeatures.ID.convertSingle, TypefaceFeatures.ID.convertTypeface] {
            #expect(registry.perform(id))
            endSheet(fixture.window)
        }
        #expect(registry.perform(TypefaceFeatures.ID.openFont))
        fixture.features.installer = TestFontInstaller(directory: URL(fileURLWithPath: "/dev/null/fonts"), scope: .process)
        var alerts: [String] = []
        fixture.features.alert = { message, _, _ in alerts.append(message) }
        _ = await fixture.features.installForTesting().value
        #expect(alerts == ["Install for Testing failed"])
        #expect(registry.perform(TypefaceFeatures.ID.installForTesting))
        let tab = try #require(fixture.features.openGlyph(fixture.glyph("A"), from: fixture.window))
        fixture.front = tab
        #expect(registry.perform(TypefaceFeatures.ID.nextGlyph))
        fixture.front = fixture.features.gridWindow(of: GlyphCanvas.tabID(document: fixture.document.id, glyph: fixture.glyph("B")))
        #expect(registry.perform(TypefaceFeatures.ID.previousGlyph))
    }

    @Test func theFeaturesHooksAndFallbacks() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let features = fixture.features
        #expect(features.attach(fixture.window) === fixture.mode)
        #expect(features.thumbnails(for: fixture.document) === features.thumbnails(for: fixture.document))
        #expect(TypefaceFeatures.testFontsDirectory().path.hasSuffix("WireTuner/TestFonts"))
        // A window the features do not know opens its glyph as its own parent.
        let stranger = DocumentWindowController(document: fixture.document, environment: fixture.environment.document)
        defer { stranger.close() }
        let tab = try #require(features.openGlyph(fixture.glyph("C"), from: stranger))
        let environment = features.glyphEnvironment(fixture.environment.document, parent: fixture.window)
        environment.documentDidClose(tab.documentHandle)
        TypefaceFeatures.keepOpen(tab.documentHandle)
        #expect(tab.documentHandle.model != nil)
        // Generate's hooks: a problem opens its glyph, installs are remembered and removed.
        let model = features.generateModel(for: fixture.window)
        model.openGlyph(fixture.glyph("D"))
        #expect(features.gridWindow(of: GlyphCanvas.tabID(document: fixture.document.id, glyph: fixture.glyph("D"))) != nil)
        model.didInstall([fixture.fonts.appending(path: "x.otf")])
        #expect(features.installed[fixture.document.id]?.count == 1)
        model.removeInstalled()
        #expect(features.installed[fixture.document.id] == nil)
        // Convert Page to Glyph opens the glyph it made.
        _ = await fixture.document.perform(ReplacePageRects([Pasteboard.letterPage])).value
        let command = ConvertPageToGlyph(fixture.document.activePage.id, name: "sketch", move: true)
        let opened = await features.convertPage(command, in: fixture.window).value
        #expect(opened && features.gridWindow(of: GlyphCanvas.tabID(document: fixture.document.id, glyph: fixture.glyph("sketch"))) != nil)
        // A glyph tab whose grid window is gone answers for its own document.
        features.detach(fixture.window)
        #expect(features.gridDocument(of: tab) === tab.documentHandle)
        features.attach(fixture.window)
        // The grid's own open and remove.
        let grid = try #require(fixture.mode.grid)
        var removed = false
        grid.onRemove = { removed = true }
        grid.gridView.onRemove?()
        grid.gridView.onOpen?(fixture.glyph("E"))
        #expect(removed && features.gridWindow(of: GlyphCanvas.tabID(document: fixture.document.id, glyph: fixture.glyph("E"))) != nil)
        // A view alone lays out to its rows.
        let alone = GlyphGridView(model: grid.model)
        alone.relayout(width: 100)
        #expect(abs(alone.frame.height - Double(alone.rows) * alone.cellSize.height) < 1)
        // Closing the window forgets its layout.
        let closing = try #require(features.openGlyph(fixture.glyph("F"), from: fixture.window))
        closing.window?.close()
        #expect(features.mode(of: closing) == nil)
    }

    @Test func sheetsShowTheirMessages() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let document = fixture.document
        let perform: TypefacePerform = { document.perform($0) }
        let bar = GlyphBarModel(document: document, glyph: fixture.glyph("A"), perform: perform)
        bar.widthText = "?"
        bar.submitWidth()
        host(GlyphBar(model: bar), size: NSSize(width: 900, height: 40))
        let parts = GlyphPartsModel(document: document, glyph: fixture.glyph("A"), perform: perform)
        parts.componentName = "none"
        parts.addComponent()
        host(GlyphPartsSheet(model: parts, close: {}))
        #expect(parts.toggleRole(OpID(counter: 1, replica: 1)) != nil)
        #expect(GlyphPartsModel.label(of: .resolved).isEmpty && GlyphPartsModel.label(of: .dangling) == "removed" && GlyphPartsModel.label(of: .loop) == "loop")
        let row = GlyphPartsModel.AnchorRow(id: OpID(counter: 1, replica: 1), name: "top.dup1", x: 0, y: 0, isMark: false, isDuplicate: true)
        #expect(row.color == .red && GlyphPartsModel.AnchorRow(id: row.id, name: "top", x: 0, y: 0, isMark: true, isDuplicate: false).color == .primary)
        let info = FontInfoModel(document: document)
        info.upmText = "0"
        _ = info.ok()
        host(FontInfoSheet(model: info, close: {}))
        let page = ConvertPageModel(document: document, page: document.activePage.id) { _ in }
        page.text = "!!"
        _ = page.commit()
        host(ConvertPageSheet(model: page, close: {}))
        page.text = "sketch"
        #expect(page.command()?.scaling == .pageHeightIsEm)
        let metrics = MetricsModel(document: document)
        metrics.nudgeUp()
        host(MetricsView(model: metrics))
        let generate = GenerateFontsModel(document: document, installer: fixture.features.installer)
        generate.removeTestFonts()
        host(GenerateFontsSheet(model: generate, close: {}))
        generate.otf = false
        #expect(generate.formats.isEmpty)
        // The glyph bar keeps its fields when its glyph is gone.
        _ = await document.perform(RemoveGlyphs([fixture.glyph("A")])).value
        bar.reload()
        #expect(bar.name == "A")
    }

    @Test func fontInfoWritesEveryOS2AndFeatureSwitch() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let model = FontInfoModel(document: fixture.document)
        model.widthText = "7"
        model.italic = true
        model.embedding = .restricted
        model.generateKern = false
        model.generateMark = false
        model.extraLineName = "top"
        model.extraLineY = "?"
        #expect(model.commit() == nil)
        model.extraLineY = "900"
        await model.commit()?.value
        let info = WTModel.FontInfo(fixture.document.state)
        #expect(info.os2.widthClass == 7 && info.os2.italic && info.os2.embedding == .restricted && info.omitGeneratedKern && info.omitGeneratedMark)
    }

    @Test func modelsReadEdgeCases() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        #expect(MetricsSetting(items: []).width == 0)
        let metrics = MetricsModel(document: fixture.document)
        metrics.text = "AVA"
        #expect(metrics.setting.items[0].outline == metrics.setting.items[2].outline)
        metrics.select(1)
        metrics.text = "A"
        #expect(metrics.selected == nil)
        // A name collision (an older client's rename) badges the glyph.
        let b = fixture.glyph("B")
        _ = await fixture.document.perform(OpsCommand("Rename", ops: [Ops.set(b, [GlyphFields.name], values: GlyphFields.values { $0.name = "A" })])).value
        let grid = GlyphGridModel()
        grid.reload(fixture.document.state)
        #expect(grid.cells.contains { $0.badges.contains(.collision) })
        // The switch goes to Sketches through its action and back.
        fixture.mode.switcher.selectedSegment = 1
        NSApp.sendAction(try #require(fixture.mode.switcher.action), to: fixture.mode.switcher.target, from: fixture.mode.switcher)
        #expect(fixture.mode.view == .sketches)
        fixture.mode.switcher.selectedSegment = 0
        NSApp.sendAction(try #require(fixture.mode.switcher.action), to: fixture.mode.switcher.target, from: fixture.mode.switcher)
        #expect(fixture.mode.view == .glyphs && fixture.mode.open(fixture.glyph("C")) != nil)
        fixture.mode.fitGlyph()
    }
}
