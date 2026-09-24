import Foundation
import Testing
@testable import WTModel

/// FONT-008: glyph naming -- the AGLFN table, `uni`/`u` forms, ligature decomposition, suffixes and
/// invalid names (glyph-grid.adoc, "Client").
@Suite struct GlyphNamingTests {
    @Test func aglfnSamplesRoundTrip() {
        #expect(GlyphNaming.aglfn.count == 586)
        // 200 samples spread over the table: every name maps to its scalar and back.
        let step = GlyphNaming.aglfn.count / 200
        var checked = 0
        for index in stride(from: 0, to: GlyphNaming.aglfn.count, by: step).prefix(200) {
            let entry = GlyphNaming.aglfn[index]
            #expect(GlyphNaming.name(for: entry.scalar) == entry.name)
            #expect(GlyphNaming.codepoint(of: entry.name) == entry.scalar)
            #expect(GlyphNaming.isValid(entry.name))
            checked += 1
        }
        #expect(checked == 200)
        #expect(GlyphNaming.name(for: 0x41) == "A" && GlyphNaming.name(for: 0xE9) == "eacute" && GlyphNaming.name(for: 0x20) == "space")
        #expect(GlyphNaming.name(for: 0x2026) == "ellipsis" && GlyphNaming.name(for: 0x20AC) == "Euro")
    }

    @Test func uniAndUForms() {
        #expect(GlyphNaming.name(for: 0x0302) == "uni0302")
        #expect(GlyphNaming.name(for: 0x1F600) == "u1F600")
        #expect(GlyphNaming.scalars(of: "uni0041") == [0x41])
        #expect(GlyphNaming.scalars(of: "uni00410042") == [0x41, 0x42])
        #expect(GlyphNaming.scalars(of: "u1F600") == [0x1F600])
        #expect(GlyphNaming.scalars(of: "u0041") == [0x41])
        #expect(GlyphNaming.scalars(of: "u10FFFF") == [0x10FFFF])
        // Lower-case hex, surrogates, out-of-range values and odd lengths map to nothing.
        for name in ["uni00e9", "uniD800", "u110000", "uDFFF", "uni004", "u12", "u1234567", "unizzzz", "u12G4"] {
            #expect(GlyphNaming.scalars(of: name).isEmpty, "\(name)")
        }
    }

    @Test func ligaturesAndSuffixes() {
        #expect(GlyphNaming.ligatureName(for: [0x66, 0x66, 0x69]) == "f_f_i")
        #expect(GlyphNaming.ligatureParts("f_i.alt") == ["f", "i"])
        #expect(GlyphNaming.scalars(of: "f_i") == [0x66, 0x69])
        #expect(GlyphNaming.scalars(of: "f_i.liga") == [0x66, 0x69])
        #expect(GlyphNaming.codepoint(of: "f_i") == nil)
        #expect(GlyphNaming.codepoint(of: "a.sc") == nil && GlyphNaming.scalars(of: "a.sc") == [0x61])
        #expect(GlyphNaming.split("a.alt").base == "a" && GlyphNaming.split("a.alt").suffix == "alt")
        #expect(GlyphNaming.split(".notdef").suffix == nil && GlyphNaming.split("a").suffix == nil)
        #expect(GlyphNaming.scalars(of: "f_unknownthing").isEmpty)
        #expect(GlyphNaming.name(forText: "é") == "eacute" && GlyphNaming.name(forText: "fi") == "f_i" && GlyphNaming.name(forText: "") == nil)
    }

    @Test func validityAndUniqueness() {
        for name in [".notdef", "A", "a.sc", "f_i", "uni0041", "_part", String(repeating: "a", count: 63)] {
            #expect(GlyphNaming.isValid(name), "\(name)")
        }
        for name in ["", "9a", "a b", "é", "a-b", String(repeating: "a", count: 64)] {
            #expect(!GlyphNaming.isValid(name), "\(name)")
        }
        #expect(GlyphNaming.unique("a", taken: []) == "a")
        #expect(GlyphNaming.unique("a", taken: ["a", "a.1"]) == "a.2")
        #expect(GlyphNaming.characterName(0xE9) == "LATIN SMALL LETTER E WITH ACUTE")
        #expect(GlyphNaming.characterName(0xD800) == nil)
    }
}
