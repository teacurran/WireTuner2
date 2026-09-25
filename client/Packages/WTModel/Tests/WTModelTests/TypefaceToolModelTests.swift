import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Auto Kern, Guess Classes (FONT-021) and the Find Problems fixes (FONT-014), model halves.
@Suite struct TypefaceToolModelTests {
    /// A Basic Latin typeface with A, V, T, o, L and n drawn so that AV, To and LT want negative
    /// kerning and nn none at the n-n separation.
    static func drawn(_ a: inout Replica) throws -> (String) -> OpID {
        _ = try TypefaceFixture.typeface(&a)
        let state = a.state
        func glyph(_ name: String) -> OpID { GlyphIndex(state).glyph(named: name)!.id }
        _ = try TypefaceFixture.draw([(20, 0), (480, 0), (250, -700)], on: glyph("A"), in: &a)
        _ = try TypefaceFixture.draw([(20, -700), (480, -700), (250, 0)], on: glyph("V"), in: &a)
        _ = try TypefaceFixture.draw([(0, -700), (500, -700), (500, -640), (280, -640), (280, 0), (220, 0), (220, -640), (0, -640)], on: glyph("T"), in: &a)
        _ = try TypefaceFixture.draw([(50, 0), (450, 0), (450, -450), (50, -450)], on: glyph("o"), in: &a)
        _ = try TypefaceFixture.draw([(50, 0), (450, 0), (450, -60), (110, -60), (110, -700), (50, -700)], on: glyph("L"), in: &a)
        _ = try TypefaceFixture.draw([(50, 0), (450, 0), (450, -500), (50, -500)], on: glyph("n"), in: &a)
        for name in ["A", "V", "T", "o", "L", "n"] { try a.perform(SetGlyphWidth([glyph(name)], to: 500)) }
        return glyph
    }

    @Test func autoKernKernsTheRoundAndDiagonalPairsAndLeavesNN() throws {
        var a = Replica(0xA)
        let glyph = try Self.drawn(&a)
        let separation = try #require(AutoKern.suggestedSeparation(in: a.state))
        #expect(abs(separation - 100) < 1)
        let values = AutoKern(separation: separation).values([(glyph("A"), glyph("V")), (glyph("T"), glyph("o")), (glyph("L"), glyph("T")),
                                                              (glyph("n"), glyph("n"))], in: a.state)
        #expect(values.count == 3 && values.allSatisfy { $0.value < 0 }, "\(values.map(\.value))")
        #expect(!values.contains { $0.left == glyph("n") })
        // A glyph without artwork, and pairs that never share a height.
        #expect(AutoKern(separation: 100).values([(glyph("B"), glyph("n")), (OpID(counter: 999, replica: 9), glyph("n"))], in: a.state).isEmpty)
        #expect(KerningProfiles.heights(ascender: 800, descender: -200, count: 1) == [-800])
        #expect(KerningProfiles.gap(left: .empty, advance: 500, right: .empty, heights: [0]) == nil)
        try a.perform(ApplyAutoKern(values))
        #expect(Kerning(a.state).value(glyph("A"), glyph("V")) < 0)
        // No n: no suggestion.
        var empty = Replica(0xB)
        _ = try TypefaceFixture.typeface(&empty, set: nil)
        #expect(AutoKern.suggestedSeparation(in: empty.state) == nil)
    }

    @Test func guessClassesGroupsAccentedVariantsWithTheirBase() throws {
        var a = Replica(0xA)
        _ = try TypefaceFixture.typeface(&a)
        try a.perform(AddGlyphs([NewGlyph(name: "agrave", codepoints: [0xE0]), NewGlyph(name: "aacute", codepoints: [0xE1]), NewGlyph(name: "Eacute", codepoints: [0xC9])]))
        let index = GlyphIndex(a.state)
        let classes = KerningGuesses.classes(in: index)
        let a_ = try #require(classes.first { $0.name == "a" })
        #expect(Set(a_.members.compactMap { index[$0]?.name }) == ["a", "agrave", "aacute"])
        #expect(classes.contains { $0.name == "E" })
        #expect(KerningGuesses.base(of: 0x61) == nil && KerningGuesses.base(of: 0xE0) == 0x61 && KerningGuesses.base(of: 0xD800) == nil)
    }

    @Test func roundToUnitsAndRemoveBrokenComponents() throws {
        var a = Replica(0xA)
        _ = try TypefaceFixture.typeface(&a)
        let glyph = TypefaceFixture.glyph("B", in: a)
        let path = try TypefaceFixture.draw([(10.4, 0), (300.6, 0.2), (300, -700.5)], on: glyph, in: &a)
        let group = try a.perform(GroupObjects([path]))!.createdObjects[0]
        try TypefaceFixture.place(group, on: glyph, in: &a)
        _ = try TypefaceFixture.draw([(0, 0), (1, 0), (1, 1)], on: glyph, in: &a)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        try TypefaceFixture.place(rect, on: glyph, in: &a)
        let change = try #require(try a.perform(RoundGlyphPoints(glyph)))
        #expect(change.label == "Round to Units")
        let rounded = VectorPath(a.state.props(path).path, node: path, state: a.state).contours[0].drawn.map(\.anchor)
        #expect(rounded.allSatisfy { $0.x == $0.x.rounded() && $0.y == $0.y.rounded() }, "\(rounded)")
        #expect(try a.perform(RoundGlyphPoints(glyph)) == nil, "nothing left to round")
        // A component whose source is removed.
        let source = TypefaceFixture.glyph("C", in: a)
        try a.perform(AddComponent(source, to: glyph))
        #expect(GlyphComponentFixes.removal(glyph, in: a.state) == nil)
        try a.perform(RemoveGlyphs([source]))
        let removal = try #require(GlyphComponentFixes.removal(glyph, in: a.state))
        try a.perform(removal)
        #expect(GlyphIndex(a.state)[glyph]?.components.isEmpty == true)
        #expect(GlyphComponentFixes.broken(OpID(counter: 999, replica: 9), in: a.state).isEmpty)
    }
}
