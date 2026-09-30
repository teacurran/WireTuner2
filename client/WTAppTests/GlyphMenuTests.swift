import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
@testable import WireTuner

/// The Glyph menu over the grid's selection (FONT-008, FONT-010, FONT-012 rests): the metric sheet,
/// Center / Thirds, Set Kind, Set Mark Color, Export Glyph, the component and outline commands,
/// the Select submenu; FONT-003's single-page Document panel.
@Suite @MainActor struct GlyphMenuTests {
    typealias ID = TypefaceFeatures.GlyphMenuID

    /// Basic Latin with A and B drawn, both selected in the grid.
    static func selected() async throws -> (TypefaceWindowFixture, a: OpID, b: OpID) {
        let fixture = await TypefaceWindowFixture.typeface()
        let a = fixture.glyph("A"), b = fixture.glyph("B")
        for glyph in [a, b] {
            let handle = GlyphCanvas.handle(for: fixture.index[glyph]!, of: fixture.document)
            _ = await fixture.box(100, -700, 300, 700, on: handle)
            handle.close()
        }
        try #require(fixture.mode.grid).model.select([a, b])
        return (fixture, a, b)
    }

    func run(_ id: CommandID, _ fixture: TypefaceWindowFixture) async {
        #expect(fixture.environment.commands.perform(id), "\(id)")
        await fixture.document.settle()
        for _ in 0..<20 { await Task.yield() }
        await fixture.document.settle()
    }

    @Test func spacingCommandsActOnTheSelection() async throws {
        let (fixture, a, b) = try await Self.selected()
        defer { fixture.close() }
        let commands = fixture.environment.commands
        #expect(commands.validate(ID.setWidth)?.isEnabled == true && commands.validate(ID.thirds)?.isEnabled == true)
        await run(ID.thirds, fixture)
        let metrics = try #require(GlyphOutlines.metrics(of: a, in: fixture.document.state))
        #expect(abs(metrics.rightSideBearing - 2 * metrics.leftSideBearing) < 1e-6 && fixture.document.undoTitle == "Undo Thirds in width of 2 glyphs")
        await run(ID.center, fixture)
        #expect(GlyphOutlines.metrics(of: b, in: fixture.document.state)?.leftSideBearing == 100)
        // The sheet: Add 20 to both widths in one change; a bad number is refused.
        let window = try #require(fixture.features.presentMetricSheet(.width))
        window.close()
        let model = GlyphMetricSheetModel(metric: .width, glyphs: [a, b], state: fixture.document.state) { fixture.document.perform($0) }
        #expect(model.title == "Set Advance Width" && model.subtitle == "2 glyphs" && model.value.isEmpty)
        model.mode = .add
        model.value = "x"
        #expect(!model.commit() && model.problem == GlyphMetricSheetModel.invalid)
        model.value = "20"
        #expect(model.commit())
        await fixture.document.settle()
        #expect(fixture.index[a]?.advanceWidth == 520 && fixture.index[b]?.advanceWidth == 520)
        model.mode = .scale
        model.value = "50"
        #expect(model.adjustment == .scale(0.5))
        model.mode = .set
        #expect(model.adjustment == .set(50))
        // One glyph: the sheet starts from its value.
        for metric in GlyphMetric.allCases {
            let single = GlyphMetricSheetModel(metric: metric, glyphs: [a], state: fixture.document.state) { _ in nil }
            #expect(!single.value.isEmpty && single.subtitle == "1 glyph")
        }
        #expect(GlyphMetricSheetModel(metric: .left, glyphs: [a], state: fixture.document.state) { _ in nil }.title == "Set Left Side Bearing")
        #expect(GlyphMetricSheetModel(metric: .right, glyphs: [a], state: fixture.document.state) { _ in nil }.title == "Set Right Side Bearing")
        PanelRendering.host(GlyphMetricSheet(model: model, close: {}))
        #expect(GlyphMetricSheetModel.Mode.allCases.map(\.title) == ["Set to", "Add", "Scale by %"])
    }

    @Test func kindColorAndExport() async throws {
        let (fixture, a, b) = try await Self.selected()
        defer { fixture.close() }
        let commands = fixture.environment.commands
        #expect(commands.validate(ID.kind(.base))?.isChecked == true)
        await run(ID.kind(.mark), fixture)
        #expect(fixture.index[a]?.kind == .mark && fixture.index[b]?.kind == .mark)
        #expect(commands.validate(ID.kind(.mark))?.isChecked == true && commands.validate(ID.kind(.base))?.isChecked == false)
        await run(ID.markColor(3), fixture)
        #expect(fixture.index[a]?.markColor == 3 && commands.validate(ID.markColor(3))?.isChecked == true)
        #expect(TypefaceFeatures.markColorTitles.count == 13 && GlyphKind.allCases.map(TypefaceFeatures.title(of:)) == ["Base", "Mark", "Ligature", "Component"])
        // Export: one glyph off makes the item mixed; choosing it exports both.
        _ = await fixture.document.perform(SetGlyphAttributes([a], export: false)).value
        #expect(commands.validate(ID.export)?.isMixed == true)
        await run(ID.export, fixture)
        #expect(fixture.index[a]?.skipExport == false)
        await run(ID.export, fixture)
        #expect(fixture.index[a]?.skipExport == true && fixture.index[b]?.skipExport == true)
    }

    @Test func componentAndOutlineCommands() async throws {
        let (fixture, a, _) = try await Self.selected()
        defer { fixture.close() }
        _ = await fixture.document.perform(AddGlyphs([NewGlyph(scalar: 0x300), NewGlyph(scalar: 0xC0)])).value
        let grave = fixture.glyph("gravecomb"), agrave = fixture.glyph("Agrave")
        let graveCanvas = GlyphCanvas.handle(for: fixture.index[grave]!, of: fixture.document)
        _ = await fixture.box(0, -100, 100, 100, on: graveCanvas)
        graveCanvas.close()
        _ = await fixture.document.perform(AddAnchor("top", at: Point(x: 250, y: -700), to: a)).value
        _ = await fixture.document.perform(AddAnchor("_top", at: Point(x: 50, y: 0), to: grave)).value
        fixture.mode.grid?.model.select([agrave])
        await run(ID.buildAccented, fixture)
        #expect(fixture.index[agrave]?.components.map(\.source) == [a, grave])
        _ = await fixture.document.perform(SetComponentTransform(fixture.index[agrave]!.components[1].id, of: agrave, to: .identity)).value
        await run(ID.snapComponents, fixture)
        #expect(fixture.index[agrave]?.components[1].transform == .translation(x: 200, y: -700))
        await run(ID.decompose, fixture)
        #expect(fixture.index[agrave]?.components.isEmpty == true && GlyphArtwork.objectIDs(on: agrave, in: fixture.document.state).count == 2)
        // The mark sits apart from the letter: merged, they are one path of two contours.
        await run(ID.rewrite(.removeOverlaps), fixture)
        #expect(GlyphArtwork.objectIDs(on: agrave, in: fixture.document.state).count == 1 && fixture.document.undoTitle == "Undo Remove Overlaps")
        for operation in [RewriteGlyphOutlines.Operation.correctDirections, .addExtrema] {
            #expect(fixture.environment.commands.validate(ID.rewrite(operation))?.isEnabled == true)
        }
        await run(ID.roundToUnits, fixture)
        // Nothing selected: the commands are disabled and do nothing.
        fixture.mode.grid?.model.select([])
        #expect(fixture.environment.commands.validate(ID.buildAccented)?.isEnabled == false)
        #expect(fixture.features.performOnTargets { SnapComponentsToAnchors($0) } == nil)
    }

    @Test func selectSubmenuSelectsInTheGrid() async throws {
        let (fixture, a, b) = try await Self.selected()
        defer { fixture.close() }
        let grid = try #require(fixture.mode.grid)
        #expect(fixture.features.selectGlyphs(.withOutlines) == [a, b] && grid.model.selection == [a, b])
        _ = await fixture.document.perform(SetGlyphAttributes([a], markColor: 5)).value
        grid.model.select([a])
        #expect(fixture.features.selectGlyphs(.sameMarkColor) == [a])
        #expect(fixture.features.selectGlyphs(.unencoded).isEmpty == false)
        await run(ID.select(.encoded), fixture)
        #expect(grid.model.selection.count == 96 - 1)
        // From a glyph tab: the grid window's selection changes.
        let tab = try #require(fixture.features.openGlyph(a, from: fixture.window))
        fixture.front = tab
        #expect(fixture.features.selectGlyphs(.usingSelectedAsComponent).isEmpty && grid.model.selection.isEmpty)
        fixture.front = nil
        #expect(fixture.features.selectGlyphs(.empty).isEmpty)
        #expect(fixture.features.presentMetricSheet(.width) == nil && fixture.features.toggleExport() == nil)
    }

    @Test func aSinglePageDocumentPanelOffersNoNewPages() async throws {
        let fixture = TypefaceWindowFixture()
        defer { fixture.close() }
        _ = await fixture.document.openedModel()
        _ = await fixture.document.perform(ConvertDocumentKind(to: .singlePage)).value
        let panel = DocumentPanelModel(window: fixture.window)
        let items = panel.optionsMenu()
        #expect(items.first { $0.title == "Add Pages…" }?.isEnabled == false && items.first { $0.title == "Duplicate" }?.isEnabled == false)
        _ = await fixture.document.perform(ConvertDocumentKind(to: .multiPage)).value
        #expect(panel.optionsMenu().first { $0.title == "Add Pages…" }?.isEnabled == true)
    }

    @Test func fontInfoFillsTheOpenFontLicenseAndEditsExtraLines() async throws {
        let fixture = await TypefaceWindowFixture.typeface(nil)
        defer { fixture.close() }
        _ = await fixture.document.perform(SetMetricGuides([.addLine(name: "Overshoot", y: 510), .addLine(name: "Small caps", y: 480)])).value
        let model = FontInfoModel(document: fixture.document)
        #expect(Set(model.lines.map(\.name)) == ["Overshoot", "Small caps"])
        model.lines.sort { $0.name < $1.name }
        #expect(model.lines[0].y == "510")
        // The licence preset puts the copyright line first.
        model.names[.copyright] = "Copyright 2026 Marlowe Type"
        model.useOpenFontLicense()
        #expect(model.names[.license]?.hasPrefix("Copyright 2026 Marlowe Type\n\nThis Font Software is licensed under the SIL Open Font License") == true)
        #expect(model.names[.licenseURL] == "https://openfontlicense.org")
        // Rename one line, remove the other (and a remove taken back is kept).
        model.lines[0].name = "Overshoot top"
        model.lines[0].y = "515"
        model.toggleRemoved(model.lines[1].id)
        model.toggleRemoved(OpID(counter: 999, replica: 1))
        #expect(model.lines[1].removed)
        _ = await model.commit()?.value
        var lines = WTModel.FontInfo(fixture.document.state).guides.extraLines
        #expect(lines.map(\.name) == ["Overshoot top"] && lines[0].y == 515)
        #expect(WTModel.FontInfo(fixture.document.state).names.licenseURL == "https://openfontlicense.org")
        // A line without a name is refused; an unchanged line writes nothing.
        let again = FontInfoModel(document: fixture.document)
        again.lines[0].name = " "
        #expect(again.commit() == nil && again.problem == "Each extra line needs a name and a height")
        again.lines[0].name = "Overshoot top"
        again.lines[0].y = "515"
        #expect(again.commands()?.isEmpty == true)
        again.toggleRemoved(again.lines[0].id)
        again.toggleRemoved(again.lines[0].id)
        #expect(!again.lines[0].removed)
        // Without a copyright the notice stands alone.
        again.names[.copyright] = ""
        again.useOpenFontLicense()
        #expect(again.names[.license]?.hasPrefix("This Font Software") == true)
        PanelRendering.host(FontInfoSheet(model: again, close: {}))
        again.pane = .guides
        PanelRendering.host(FontInfoSheet(model: again, close: {}))
        lines = []
        _ = lines
    }
}
