import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

/// FONT-025 (model half): importing a read font into a new or an existing typeface document.
@Suite struct FontImportTests {
    /// Performs every command of `plan` in one undo group.
    static func perform(_ plan: FontImport.Plan, on replica: inout Replica) throws {
        let recording = DocumentCore.Recording(group: 42, limit: 100, now: Replica.now)
        for command in plan.commands { _ = try replica.core.perform(command, recording: recording) }
    }

    @Test(arguments: FontCompiler.Format.allCases)
    func generateThenOpenRoundTrips(format: FontCompiler.Format) async throws {
        var a = Replica(0xA)
        let g = try FontGenerationTests.drawn(&a)
        try a.perform(SetFontNames([.designer: "Tester", .copyright: "Copyright 2026"]))
        try a.perform(SetFontMetrics([.xHeight: 480]))
        let data = try await FontGeneration.generate(a.state, format: format).data
        let font = try OpenTypeReader.read(data)
        var b = Replica(0xB)
        let plan = FontImport.plan(font, fileName: "Marlowe-Regular.\(format.fileExtension)", into: b.state, newDocument: true, batchSize: 40)
        #expect(plan.commands.count == 4 && plan.commands[0].label == "Import Marlowe-Regular.\(format.fileExtension) [1/4]")
        #expect(plan.report.isEmpty)
        try Self.perform(plan, on: &b)
        #expect(DocumentKind(b.state) == .typeface)
        let info = FontInfo(b.state)
        #expect(info.names.family == "Marlowe" && info.names.designer == "Tester" && info.metrics.xHeight == 480 && info.metrics.upm == 1_000)
        let original = GlyphIndex(a.state), imported = GlyphIndex(b.state)
        #expect(imported.glyph(named: "A")?.codepoints == [0x41] && imported.glyph(named: "Agrave")?.advanceWidth == 600)
        for name in ["A", "O", "Agrave", "gravecomb"] {
            let before = try #require(GlyphOutlines.metrics(of: original.glyph(named: name)!.id, in: a.state)?.bounds)
            let after = try #require(GlyphOutlines.metrics(of: imported.glyph(named: name)!.id, in: b.state)?.bounds)
            #expect(abs(before.minX - after.minX) <= 0.5 && abs(before.maxY - after.maxY) <= 0.5 && abs(before.width - after.width) <= 1, "\(name)")
        }
        let kerning = Kerning(b.state)
        let id = { (name: String) in imported.glyph(named: name)!.id }
        #expect(kerning.value(id("A"), id("V")) == -80 && kerning.value(id("Agrave"), id("O")) == -30 && kerning.value(id("V"), id("A")) == 0)
        // The whole import is one undo step.
        b.undo()
        #expect(GlyphIndex(b.state).isEmpty && DocumentKind(b.state) == .multiPage)
    }

    @Test func importIntoAnExistingTypefaceFollowsTheCollisionRules() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(name: "B.alt", codepoints: [0x42])]))
        let box = Contour(polygon: [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 100), Point(x: 0, y: 100)])
        var names = FontSource.Names(family: "Other", style: "Bold", postscript: "Other-Bold", full: "Other Bold")
        names.copyright = String(repeating: "c", count: 5_000)   // out of range: left out, the rest kept
        let font = ImportedFont(
            names: names, metrics: FontSource.Metrics(unitsPerEm: 2_048), os2: FontSource.OS2(vendorID: "?"),
            glyphs: [
                .init(name: ".notdef", codepoints: [], advanceWidth: 500, contours: [], components: []),
                .init(name: "A", codepoints: [0x41], advanceWidth: 600, contours: [box], components: []),
                .init(name: "B", codepoints: [0x42], advanceWidth: 600, contours: [box], components: []),
                .init(name: "Aring", codepoints: [0xC5], advanceWidth: 600, contours: [],
                      components: [.init(glyph: 1, transform: .identity), .init(glyph: 2, transform: .translation(x: 10, y: 700)),
                                   .init(glyph: 99, transform: .identity)]),
                .init(name: "bad name", codepoints: [], advanceWidth: 0, contours: [], components: []),
            ],
            kerning: FontSource.Kerning(pairs: [.init(left: 1, right: 2, value: -20), .init(left: 1, right: 99, value: -5)],
                                        leftClasses: [[1, 3]], rightClasses: [[2], [99]],
                                        classValues: [.init(left: 0, right: 0, value: -15), .init(left: 0, right: 1, value: -1)]),
            report: ["Hinting instructions were not read."]
        )
        let plan = FontImport.plan(font, fileName: "Other.ttf", into: a.state, newDocument: false)
        #expect(plan.names == [".notdef", "A.1", "B", "Aring", "glyph4"])
        #expect(plan.report.contains("A was imported as A.1.") && plan.report.contains { $0.hasPrefix("U+0041 is already encoded") })
        #expect(plan.report.contains { $0.hasPrefix("U+0042") } && plan.report.first == "Hinting instructions were not read.")
        #expect(plan.commands.count == 2 && plan.commands.map(\.label) == ["Import Other.ttf [1/2]", "Import Other.ttf [2/2]"])
        try Self.perform(plan, on: &a)
        let index = GlyphIndex(a.state)
        #expect(index.glyph(named: "A.1")?.codepoints == [] && index.glyph(named: "B")?.codepoints == [])
        let aring = try #require(index.glyph(named: "Aring"))
        #expect(aring.components.count == 2 && aring.components[1].transform == .translation(x: 10, y: -700))
        #expect(GlyphOutlines.metrics(of: aring.id, in: a.state)?.bounds == Rect(x: 0, y: -800, width: 110, height: 800))
        // Font Info is untouched by an import into an existing document.
        #expect(FontInfo(a.state).names.family == "Marlowe" && FontInfo(a.state).metrics.upm == 1_000)
        let kerning = Kerning(a.state)
        #expect(kerning.value(index.glyph(named: "A.1")!.id, index.glyph(named: "B")!.id) == -20)
        #expect(kerning.value(aring.id, index.glyph(named: "B")!.id) == -15 && kerning.classes.map(\.name) == ["kern1.1", "kern2.1"])
        // Into a new document: names in range kept, the invalid vendor and copyright left out.
        var b = Replica(0xB)
        try Self.perform(FontImport.plan(font, fileName: "Other.ttf", into: b.state, newDocument: true), on: &b)
        let info = FontInfo(b.state)
        #expect(info.names.family == "Other" && info.names.style == "Bold" && info.names.copyright.isEmpty && info.os2.vendorID == "WTNR")
        #expect(info.metrics.upm == 2_048)
        #expect(FontImport.plan(ImportedFont(names: names, metrics: .init(), os2: .init(), glyphs: [], kerning: .init(), report: []),
                                fileName: "x", into: b.state, newDocument: false).commands.count == 2)
    }
}
