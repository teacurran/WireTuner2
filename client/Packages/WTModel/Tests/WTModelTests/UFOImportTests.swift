import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto

/// FONT-024 (model half): a UFO written into a typeface document -- what `FontImport` writes plus
/// anchors, mark kinds, mark colors and the feature file (font-export.adoc, "UFO packages").
@Suite struct UFOImportTests {
    static func ufo() -> UFOFont {
        let box = Contour(polygon: [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 700), Point(x: 0, y: 700)])
        let names = FontSource.Names(family: "Marlowe", style: "Regular", postscript: "Marlowe-Regular", full: "Marlowe Regular")
        let font = ImportedFont(names: names, metrics: FontSource.Metrics(), os2: FontSource.OS2(), glyphs: [
            .init(name: ".notdef", codepoints: [], advanceWidth: 500, contours: [], components: []),
            .init(name: "A", codepoints: [0x41], advanceWidth: 600, contours: [box], components: []),
            .init(name: "acutecomb", codepoints: [0x301], advanceWidth: 0, contours: [box], components: []),
            .init(name: "B", codepoints: [0x42], advanceWidth: 600, contours: [box], components: []),
        ], kerning: FontSource.Kerning(pairs: [.init(left: 1, right: 3, value: -40)]), report: ["The layer x was not imported."])
        return UFOFont(font: font, formatVersion: 3,
                       anchors: [[], [.init(name: "top", x: 300, y: 700), .init(name: "bad name", x: 0, y: 0)], [.init(name: "_top", x: 0, y: 500)], []],
                       markColors: [0, 3, 0, 0], features: "feature ss01 { sub A by B; } ss01;\n", lib: Data([1]))
    }

    static func perform(_ plan: FontImport.Plan, on replica: inout Replica) throws {
        let recording = DocumentCore.Recording(group: 7, limit: 100, now: Replica.now)
        for command in plan.commands { _ = try replica.core.perform(command, recording: recording) }
    }

    @Test func openingAUFOMakesATypefaceWithAnchorsColorsAndFeatures() throws {
        var a = Replica(0xA)
        let plan = UFOImport.plan(Self.ufo(), fileName: "Marlowe.ufo", into: a.state, newDocument: true, batchSize: 2)
        #expect(plan.commands.map(\.label) == (1...6).map { "Import Marlowe.ufo [\($0)/6]" })
        #expect(plan.report == ["The layer x was not imported."])
        try Self.perform(plan, on: &a)
        #expect(DocumentKind(a.state) == .typeface && FontInfo(a.state).names.family == "Marlowe")
        let index = GlyphIndex(a.state)
        let glyphA = try #require(index.glyph(named: "A"))
        #expect(glyphA.anchors.map(\.name) == ["top"] && glyphA.anchors[0].position == Point(x: 300, y: -700) && glyphA.markColor == 3)
        let mark = try #require(index.glyph(named: "acutecomb"))
        #expect(mark.kind == .mark && mark.anchors.first?.name == "_top")
        #expect(index.glyph(named: "B")?.kind == .base && index.glyph(named: "B")?.markColor == 0)
        #expect(FontInfo(a.state).features == "feature ss01 { sub A by B; } ss01;\n")
        // The unread lib keys are kept on the settings for a UFO export.
        #expect(a.state.props(WellKnown.settings).settings.font.ufoLibPassthrough == Data([1]))
        #expect(Kerning(a.state, index: index).value(glyphA.id, index.glyph(named: "B")!.id) == -40)
    }

    @Test func importingIntoAnExistingTypefaceFollowsTheGridsRules() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41)]))
        let plan = UFOImport.plan(Self.ufo(), fileName: "Other.ufo", into: a.state, newDocument: false)
        #expect(plan.names.contains("A.1") && plan.report.contains { $0.contains("feature file was not added") })
        #expect(plan.report.contains { $0.contains("lib.plist keys were not kept; this typeface keeps its own") })
        try Self.perform(plan, on: &a)
        let index = GlyphIndex(a.state)
        #expect(index.glyph(named: "A.1")?.anchors.first?.name == "top" && index.glyph(named: "A")?.anchors.isEmpty == true)
        #expect(FontInfo(a.state).features.isEmpty && a.state.props(WellKnown.settings).settings.font.ufoLibPassthrough.isEmpty)
        // A lib over the field's limit is reported, not written.
        var large = Self.ufo()
        large.lib = Data(count: ImportUFOLib.limit + 1)
        let refused = UFOImport.plan(large, fileName: "L.ufo", into: Replica(0xC).state, newDocument: true)
        #expect(refused.report.contains { $0.contains("larger than 1 MB") } && !refused.commands.contains { $0 is ImportUFOLib })
        // A UFO with nothing beyond outlines adds no extra changes.
        var plain = Self.ufo()
        plain.anchors = plain.anchors.map { _ in [] }
        plain.markColors = plain.markColors.map { _ in 0 }
        plain.features = ""
        plain.lib = nil
        var b = Replica(0xB)
        #expect(UFOImport.plan(plain, fileName: "P.ufo", into: b.state, newDocument: true).commands.count == 2)
        try Self.perform(UFOImport.plan(plain, fileName: "P.ufo", into: b.state, newDocument: true), on: &b)
        #expect(GlyphIndex(b.state).glyphs.count == 4)
    }

    @Test func anImportConcurrentWithARenameConverges() throws {
        var pair = Pair()
        try TypefaceFixture.typeface(&pair.a, set: nil)
        try pair.a.perform(AddGlyphs([NewGlyph(scalar: 0x43)]))
        pair.sync()
        let c = TypefaceFixture.glyph("C", in: pair.b)
        try pair.b.perform(RenameGlyph(c, to: "A"))
        for command in UFOImport.plan(Self.ufo(), fileName: "M.ufo", into: pair.a.state, newDocument: false).commands {
            try pair.a.perform(command)
        }
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        // Two glyphs claim the name A: the grid's collision rule keeps one of them as A.
        #expect(GlyphIndex(pair.a.state).glyphs.filter { $0.name == "A" }.count == 1)
    }
}
