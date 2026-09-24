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

/// The typeface sheets' models and views: New Typeface, Add Glyph, Convert Document To, Convert
/// Page to Glyph, Font Info, the glyph bar and Components and Anchors.
@Suite @MainActor struct TypefaceSheetTests {
    func host<V: View>(_ view: V, size: NSSize = NSSize(width: 560, height: 700)) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        _ = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds).map { hosting.cacheDisplay(in: hosting.bounds, to: $0) }
    }

    /// A perform that runs on `document`.
    func perform(_ document: DocumentHandle) -> TypefacePerform {
        { document.perform($0) }
    }

    @Test func newTypefaceValidatesAndCreates() {
        var created: [NewTypefaceModel.Choice] = []
        let model = NewTypefaceModel { created.append($0) }
        host(NewTypefaceSheet(model: model, close: {}))
        model.upmText = "12"
        #expect(!model.commit() && model.problem == NewTypefaceModel.invalidUPM)
        host(NewTypefaceSheet(model: model, close: {}))
        model.upmText = "2048"
        model.family = " Marlowe "
        model.set = .latin1
        #expect(model.commit())
        #expect(created == [NewTypefaceModel.Choice(family: "Marlowe", style: "Regular", set: .latin1, upm: 2_048)])
        #expect(NewTypefaceModel.StartingSet.allCases.map(\.title) == ["Empty", "Basic Latin", "Latin-1", "From a font file…"])
        #expect(NewTypefaceModel.StartingSet.allCases.map(\.glyphSet) == [nil, .basicLatin, .latin1, nil])
        #expect(NewTypefaceModel.StartingSet.empty.id == "empty")
    }

    @Test func addGlyphParsesCharactersCodepointsRangesAndNames() async throws {
        #expect(AddGlyphModel.glyphs(for: "é")?.map(\.name) == ["eacute"])
        #expect(AddGlyphModel.glyphs(for: "U+00E9")?.map(\.codepoints) == [[0xE9]])
        #expect(AddGlyphModel.glyphs(for: "U+00C0-U+00C2")?.count == 3)
        #expect(AddGlyphModel.glyphs(for: "u+d7ff-e000")?.count == 2)
        #expect(AddGlyphModel.glyphs(for: "f_i")?.first?.kind == .ligature)
        #expect(AddGlyphModel.glyphs(for: "ab")?.map(\.name) == ["ab"])
        #expect(AddGlyphModel.glyphs(for: "a b")?.map(\.name) == ["a", "b"])
        for bad in ["", "  ", "U+ZZ", "U+00C2-U+00C0", "U+0-U+1-U+2", "U+0-U+2000"] { #expect(AddGlyphModel.glyphs(for: bad) == nil) }
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let model = AddGlyphModel(document: fixture.document, after: fixture.glyph("A"), perform: perform(fixture.document))
        host(AddGlyphSheet(model: model, close: {}))
        #expect(!model.commit() && model.problem == AddGlyphModel.nothing)
        model.text = "A"
        #expect(!model.commit() && model.problem == AddGlyphModel.exists)
        model.text = "Aé"
        #expect(model.commit())
        await fixture.document.settle()
        #expect(fixture.index.glyph(named: "eacute")?.order == 36)
        #expect(model.addLatin1())
        await fixture.document.settle()
        #expect(fixture.index.glyph(named: "Aacute") != nil)
        #expect(model.addBasicLatin())
        host(AddGlyphSheet(model: model, close: {}))
    }

    @Test func convertDocumentExplainsAndConverts() async throws {
        let fixture = TypefaceWindowFixture()
        defer { fixture.close() }
        let document = fixture.document
        _ = await document.openedModel()
        let toTypeface = ConvertDocumentModel(document: document, kind: .typeface, perform: perform(document))
        #expect(toTypeface.hasOption && toTypeface.explanation.contains("Sketches"))
        host(ConvertDocumentSheet(model: toTypeface, close: {}))
        toTypeface.addBasicLatin = true
        #expect(toTypeface.commit())
        await document.settle()
        #expect(DocumentKind(document.state) == .typeface && GlyphIndex(document.state).count == 96)
        #expect(toTypeface.explanation.contains("already") && toTypeface.commit() && !toTypeface.hasOption)
        let back = ConvertDocumentModel(document: document, kind: .multiPage, perform: perform(document))
        #expect(back.explanation.contains("hidden") && back.hasOption)
        back.copyGlyphsToPages = true
        host(ConvertDocumentSheet(model: back, close: {}))
        #expect(back.commit())
        await document.settle()
        #expect(PageList(document.state).pages.count > 1)
        let single = ConvertDocumentModel(document: document, kind: .singlePage, perform: perform(document))
        #expect(single.explanation.contains("exactly one page"))
        #expect(!single.commit() && single.problem?.contains("pages") == true)
        host(ConvertDocumentSheet(model: single, close: {}))
        let multi = ConvertDocumentModel(document: fixture.document, kind: .multiPage, perform: perform(document))
        _ = await document.perform(ReplacePageRects([Pasteboard.letterPage])).value
        _ = await document.perform(ConvertDocumentKind(to: .singlePage)).value
        #expect(multi.explanation == "Pages can be added again." && multi.commit())
    }

    @Test func convertPageNamesTheGlyph() async throws {
        let fixture = await TypefaceWindowFixture.typeface(nil)
        defer { fixture.close() }
        let document = fixture.document
        var performed: [ConvertPageToGlyph] = []
        let model = ConvertPageModel(document: document, page: document.activePage.id) { performed.append($0) }
        host(ConvertPageSheet(model: model, close: {}))
        model.text = "not a name!"
        #expect(!model.commit() && model.problem == ConvertPageModel.invalid)
        model.text = "é"
        model.pageHeightIsEm = false
        model.move = false
        #expect(model.commit())
        #expect(performed.first?.name == "eacute" && performed.first?.codepoints == [0xE9] && performed.first?.move == false)
        #expect(performed.first?.scaling == .onePointPerUnit)
        model.text = "sketch.one"
        #expect(model.command()?.name == "sketch.one" && model.command()?.codepoints == nil)
        _ = await document.perform(AddGlyphs([NewGlyph(name: "sketch.one")])).value
        #expect(model.command() == nil && model.problem?.contains("exists") == true)
    }

    @Test func fontInfoWritesOnlyEditedFieldsPerPane() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let document = fixture.document
        let model = FontInfoModel(document: document)
        for pane in FontInfoModel.Pane.allCases {
            model.pane = pane
            host(FontInfoSheet(model: model, close: {}))
        }
        #expect(FontInfoModel.Pane.names.id == "Names")
        #expect(try #require(model.commands()).isEmpty)
        // Invalid fields keep the sheet open with a reason.
        model.binding(.postscript).wrappedValue = "Bad Name"
        #expect(model.commands() == nil && model.problem?.contains("PostScript") == true)
        model.names[.postscript] = ""
        model.names[.version] = "1.0"
        #expect(model.commands() == nil && model.problem?.contains("version") == true)
        model.names[.version] = "2.000"
        model.names[.designerURL] = "example"
        #expect(model.commands() == nil && model.problem?.contains("Designer URL") == true)
        model.names[.designerURL] = "https://example.com"
        model.binding(.xHeight).wrappedValue = "x"
        #expect(model.commands() == nil && model.problem?.contains("x-height") == true)
        model.metrics[.xHeight] = "520"
        model.metrics[.italicAngle] = "-100"
        #expect(model.commands() == nil)
        model.metrics[.italicAngle] = "-12"
        model.weightText = "0"
        #expect(model.commands() == nil && model.problem?.contains("Weight") == true)
        model.weightText = "700"
        model.vendor = "TOOLONG"
        #expect(model.commands() == nil && model.problem?.contains("vendor") == true)
        model.vendor = "MRLW"
        model.bold = true
        model.binding(.emBox).wrappedValue = false
        model.extraLineName = "overshoot"
        model.extraLineY = ""
        #expect(model.commands() == nil)
        model.extraLineY = "510"
        model.generateLiga = false
        #expect(model.binding(.version).wrappedValue == "2.000" && model.binding(.xHeight).wrappedValue == "520" && !model.binding(.emBox).wrappedValue)
        let commands = try #require(model.commands())
        #expect(commands.map(\.label) == ["Font Info: Names", "Font Info: Metrics", "Font Info: OS/2", "Font Info: Guides", "Font Info: Guides",
                                          "Font Info: Features"])
        model.upmText = "8"
        #expect(model.commit() == nil && model.problem == FontInfoModel.invalidUPM)
        model.upmText = "2048"
        await model.commit()?.value
        let info = WTModel.FontInfo(document.state)
        #expect(info.names.version == "2.000" && abs(info.metrics.xHeight - 1_064.96) < 1 && info.metrics.upm == 2_048 && info.os2.bold)
        #expect(!info.guides.showEmBox && info.guides.extraLines.count == 1 && info.omitGeneratedLiga)
        // The whole OK is undone pane by pane; the scale is one step.
        #expect(document.undoTitle.contains("2048"))
        let unchanged = FontInfoModel(document: document)
        #expect(unchanged.ok() && FontInfoModel.title(of: FontNameField.license) == "License")
        #expect(FontMetricField.allCases.map(FontInfoModel.title(of:)).count == 11 && SetMetricGuides.Line.allCases.map(FontInfoModel.title(of:)).last == "Labels")
    }

    @Test func theGlyphBarEditsWidthAndBearings() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let a = fixture.glyph("A")
        let handle = try #require(GlyphCanvas.handle(for: a, of: fixture.document))
        let model = GlyphBarModel(document: handle, glyph: a, perform: perform(handle))
        #expect(!model.hasOutline && model.leftText == "0" && model.rightText == "500" && model.unicode == "U+0041")
        _ = await fixture.box(100, -700, 300, 700, on: handle)
        model.reload()
        host(GlyphBar(model: model), size: NSSize(width: 900, height: 40))
        model.leftText = "50"
        _ = await model.commitLeft()?.value
        model.reload()
        #expect(model.leftText == "50" && model.rightText == "150")
        model.leftText = "60"
        _ = await model.commitLeft(keepRSB: true)?.value
        model.reload()
        #expect(model.widthText == "510")
        model.rightText = "40"
        model.submitRight()
        await handle.settle()
        model.submitCenter()
        await handle.settle()
        model.reload()
        #expect(model.leftText == model.rightText)
        model.widthText = "wide"
        #expect(model.commitWidth() == nil && model.problem == GlyphBarModel.invalidNumber)
        model.leftText = "?"
        model.submitLeft()
        model.rightText = "?"
        model.submitRight()
        model.widthText = "520"
        model.submitWidth()
        await handle.settle()
        #expect(model.problem == nil && GlyphIndex(handle.state)[a]?.advanceWidth == 520)
        #expect(FontUnits.format(1.5) == "1.5" && FontUnits.format(2.126) == "2.13" && FontUnits.format(-3) == "-3" && FontUnits.parse("inf") == nil)
    }

    @Test func componentsAndAnchorsAreEditedInTheSheet() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        _ = await fixture.document.perform(AddGlyphs([NewGlyph(name: "Aring"), NewGlyph(scalar: 0x030A)])).value
        let glyph = fixture.glyph("Aring")
        let handle = try #require(GlyphCanvas.handle(for: fixture.glyph("A"), of: fixture.document))
        _ = await fixture.box(100, -700, 300, 700, on: handle)
        let model = GlyphPartsModel(document: fixture.document, glyph: glyph, perform: perform(fixture.document))
        model.componentName = "nothing"
        #expect(model.addComponent() == nil && model.problem == GlyphPartsModel.unknownGlyph)
        model.componentName = "A"
        _ = await model.addComponent()?.value
        model.componentName = "uni030A"
        model.action(.addComponent)()
        await fixture.document.settle()
        model.reload()
        #expect(model.components.map(\.source) == ["A", "uni030A"] && model.components[0].status.isEmpty)
        model.anchorName = "bad name"
        #expect(model.addAnchor() == nil && model.problem == GlyphPartsModel.invalidAnchor)
        model.anchorName = "top"
        model.anchorX = "250"
        model.anchorY = "720"
        model.action(.addAnchor)()
        await fixture.document.settle()
        model.reload()
        let anchor = try #require(model.anchors.first)
        #expect(anchor.name == "top" && anchor.x == 250 && anchor.y == 720 && !anchor.isMark)
        host(GlyphPartsSheet(model: model, close: {}))
        _ = await model.moveAnchor(anchor.id, x: 260, y: 730)?.value
        model.action(.toggleRole, anchor.id)()
        await fixture.document.settle()
        model.reload()
        #expect(model.anchors.first?.isMark == true && model.anchors.first?.x == 260)
        model.action(.removeAnchor, anchor.id)()
        model.action(.removeComponent, model.components[1].id)()
        model.action(.removeComponent)()
        model.action(.toggleRole)()
        model.action(.removeAnchor)()
        await fixture.document.settle()
        model.reload()
        #expect(model.anchors.isEmpty && model.components.count == 1)
        model.action(.decompose, model.components[0].id)()
        await fixture.document.settle()
        model.reload()
        #expect(model.components.isEmpty && !GlyphArtwork.objectIDs(on: glyph, in: fixture.document.state).isEmpty)
        model.action(.decompose)()
        // A component whose source glyph is removed reads as removed.
        _ = await fixture.document.perform(AddComponent(fixture.glyph("B"), to: glyph)).value
        _ = await fixture.document.perform(RemoveGlyphs([fixture.glyph("B")])).value
        model.reload()
        #expect(model.components.first?.status == "removed" && model.components.first?.source == "—")
        host(GlyphPartsSheet(model: model, close: {}))
        // A glyph that is gone leaves the rows as they were.
        _ = await fixture.document.perform(RemoveGlyphs([glyph])).value
        model.reload()
        #expect(model.components.count == 1)
    }

    @Test func sheetsPresentOnAWindowOrAlone() {
        let window = TestWindow.make()
        defer { window.close() }
        let box = CloseBox()
        let sheet = TypefaceSheets.present("sheet.test", on: window) { close in CloseCapture(close: close, box: box) }
        #expect(window.attachedSheet === sheet && sheet.identifier?.rawValue == "sheet.test")
        box.close?()
        #expect(window.attachedSheet == nil)
        let aloneBox = CloseBox()
        let alone = TypefaceSheets.present("sheet.alone", on: nil) { close in CloseCapture(close: close, box: aloneBox) }
        #expect(alone.isVisible)
        aloneBox.close?()
        #expect(!alone.isVisible)
    }
}

/// Keeps the close action a sheet was given.
@MainActor
final class CloseBox {
    var close: (@MainActor () -> Void)?
}

struct CloseCapture: View {
    init(close: @escaping @MainActor () -> Void, box: CloseBox) {
        MainActor.assumeIsolated { box.close = close }
    }

    var body: some View { EmptyView() }
}
