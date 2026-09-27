import CoreText
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel

/// The Metrics window's *Features* pop-up (FONT-020): which features it lists, the warning for a
/// file that does not check clean, and the Core Text font shaping with the chosen ones.
@Suite struct PreviewFeaturesTests {
    /// A typeface with f, i, f_i (a ligature), a and a.sc drawn, and `features` as its feature file.
    static func typeface(features: String) throws -> Replica {
        var a = Replica(0xF20)
        try TypefaceFixture.typeface(&a)
        try a.perform(AddGlyphs([NewGlyph(name: "f_i", kind: .ligature), NewGlyph(name: "a.sc")]))
        let g = Dictionary(uniqueKeysWithValues: GlyphIndex(a.state).glyphs.map { ($0.name, $0.id) })
        try TypefaceFixture.box(0, -700, 500, 700, on: g["f"]!, in: &a)
        try TypefaceFixture.box(0, -700, 200, 700, on: g["i"]!, in: &a)
        try TypefaceFixture.box(0, -700, 650, 700, on: g["f_i"]!, in: &a)
        try TypefaceFixture.box(0, -500, 450, 500, on: g["a"]!, in: &a)
        try TypefaceFixture.box(0, -400, 400, 400, on: g["a.sc"]!, in: &a)
        try a.perform(SetGlyphWidth([g["f_i"]!], to: 650))
        if !features.isEmpty {
            try a.perform(OpsCommand("Edit features", ops: [Ops.textInsert(WellKnown.settings, FontFields.features, features, left: .zero)]))
        }
        return a
    }

    @Test func listsTheAutomaticFeaturesThenTheFilesOnce() throws {
        let a = try Self.typeface(features: "feature smcp {\n  sub a by a.sc;\n} smcp;\nfeature liga {\n  sub f i by f_i;\n} liga;\nfeature ss01 {\n  sub a by a.sc;\n} ss01;\n")
        let features = PreviewFeatures.of(FontGeneration.snapshot(a.state).source)
        #expect(features.warning == nil)
        #expect(features.items.map(\.tag) == ["liga", "smcp", "ss01"])
        #expect(features.items.map(\.isAutomatic) == [true, false, false])
        #expect(features.defaultEnabled == ["liga"])
        let settings = features.settings(enabled: ["smcp"])
        #expect(settings.count == 3)
        #expect(settings[1][kCTFontOpenTypeFeatureTag as String] as? String == "smcp")
        #expect(settings[1][kCTFontOpenTypeFeatureValue as String] as? Int == 1)
        #expect(settings[0][kCTFontOpenTypeFeatureValue as String] as? Int == 0)
    }

    @Test func aFileWithErrorsLeavesOnlyTheAutomaticFeatures() throws {
        let a = try Self.typeface(features: "feature smcp {\n  sub a by nosuchglyph;\n} smcp;\n")
        let features = PreviewFeatures.of(FontGeneration.snapshot(a.state).source)
        #expect(features.warning == PreviewFeatures.uncheckedWarning)
        #expect(features.items.map(\.tag) == ["liga"])
    }

    @Test func anEmptyFileListsTheAutomaticFeatures() throws {
        let a = try Self.typeface(features: "")
        let features = PreviewFeatures.of(FontGeneration.snapshot(a.state).source)
        #expect(features == PreviewFeatures(items: [PreviewFeatures.Item(tag: "liga", isAutomatic: true, isOnByDefault: true)]))
        #expect(PreviewFeatures().items.isEmpty && PreviewFeatures().defaultEnabled.isEmpty)
        #expect(features.items[0].id == "liga")
    }

    /// The glyph names Core Text sets `text` with in `font`.
    static func shaped(_ text: String, _ font: CTFont, names: [String]) -> [String] {
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return (CTLineGetGlyphRuns(CTLineCreateWithAttributedString(attributed)) as! [CTRun]).flatMap { run -> [String] in
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            return glyphs.map { names.indices.contains(Int($0)) ? names[Int($0)] : "?" }
        }
    }

    /// The done-when case: `liga` on shows f_i for "fi", off shows f and i; a user feature (smcp)
    /// is off until chosen, then substitutes.
    @Test func theFontShapesWithTheChosenFeatures() async throws {
        let a = try Self.typeface(features: "feature smcp {\n  sub a by a.sc;\n} smcp;\n")
        let source = FontGeneration.snapshot(a.state).source
        let compiled = try await FontCompiler().quickCompile(source)
        let provider = try #require(CGDataProvider(data: compiled.data as CFData))
        let base = CTFontCreateWithGraphicsFont(try #require(CGFont(provider)), 100, nil, nil)
        let names = source.glyphs.map(\.name)
        let features = PreviewFeatures.of(source)
        #expect(features.items.map(\.tag) == ["liga", "smcp"])
        let standard = features.font(base, enabled: features.defaultEnabled)
        #expect(CTFontGetSize(standard) == 100)
        #expect(Self.shaped("fi", standard, names: names) == ["f_i"])
        #expect(Self.shaped("a", standard, names: names) == ["a"])
        let plain = features.font(base, enabled: [])
        #expect(Self.shaped("fi", plain, names: names) == ["f", "i"])
        let smallCaps = features.font(base, enabled: ["liga", "smcp"])
        #expect(Self.shaped("afi", smallCaps, names: names) == ["a.sc", "f_i"])
    }
}
