import CoreGraphics
import CoreText
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange

/// FONT-025: reading OTF and TTF files -- the compiler's own output back, and system fonts checked
/// against Core Text.
@Suite struct OpenTypeReaderTests {
    static let arial = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")
    static let stix = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/STIXGeneral.otf")

    /// The tight bounds of contours.
    static func bounds(_ contours: [Contour]) -> CGRect? {
        guard let first = contours.first else { return nil }
        let rect = contours.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    /// Contours placed by a component chain, flattened (for comparing composites).
    static func outline(_ font: ImportedFont, _ glyph: Int, depth: Int = 0) -> [Contour] {
        guard depth < 8 else { return [] }
        return font.glyphs[glyph].contours + font.glyphs[glyph].components.flatMap { component in
            outline(font, component.glyph, depth: depth + 1).map { $0.applying(component.transform) }
        }
    }

    @Test(arguments: FontCompiler.Format.allCases)
    func compiledFontsReadBack(format: FontCompiler.Format) throws {
        var source = FontFixture.source()
        source.names.designerURL = "https://example.com/designer"
        source.metrics.italicAngle = -8
        source.os2.italic = true
        source.os2.weightClass = 700
        let data = try FontCompiler.compile(source, options: .init(format: format)).data
        let font = try OpenTypeReader.read(data)
        #expect(font.names.family == "Marlowe" && font.names.style == "Regular" && font.names.postscript == "Marlowe-Regular")
        #expect(font.names.version == "1.000" && font.names.copyright == source.names.copyright && font.names.designerURL == "https://example.com/designer")
        #expect(font.names.trademark == source.names.trademark && font.names.license == "OFL" && font.names.sampleText == "AVO")
        #expect(font.metrics.unitsPerEm == 1_000 && font.metrics.ascender == 800 && font.metrics.descender == -200)
        #expect(font.metrics.xHeight == 500 && font.metrics.capHeight == 700 && font.metrics.italicAngle == -8)
        #expect(font.os2.italic && font.os2.weightClass == 700 && font.os2.vendorID == "WTNR")
        #expect(font.glyphs.map(\.name) == source.glyphs.map(\.name))
        #expect(font.glyphs.map(\.codepoints) == source.glyphs.map(\.codepoints))
        #expect(font.glyphs.map(\.advanceWidth) == source.glyphs.map(\.advanceWidth))
        for (read, original) in zip(font.glyphs, source.glyphs) {
            let a = Self.bounds(read.contours), b = Self.bounds(original.contours)
            #expect((a == nil) == (b == nil), "\(read.name)")
            if let a, let b {
                #expect(abs(a.minX - b.minX) <= 0.5 && abs(a.maxX - b.maxX) <= 0.5 && abs(a.minY - b.minY) <= 0.5 && abs(a.maxY - b.maxY) <= 0.5, "\(read.name)")
            }
            #expect(read.contours.count == original.contours.count)
        }
        // Kerning reads back to the same lookup values.
        for left in font.glyphs.indices {
            for right in font.glyphs.indices {
                #expect(font.kerning.value(left, right) == source.kerning.value(left, right), "\(left) \(right)")
            }
        }
        #expect(font.report.isEmpty)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: arial.path)))
    func trueTypeSystemFontMatchesCoreText() throws {
        try Self.compareWithCoreText(Self.arial, expectComposites: true)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: stix.path)))
    func cffSystemFontMatchesCoreText() throws {
        try Self.compareWithCoreText(Self.stix, expectComposites: false)
    }

    static func compareWithCoreText(_ url: URL, expectComposites: Bool) throws {
        let data = try Data(contentsOf: url)
        let font = try OpenTypeReader.read(data)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let graphics = try #require(CGFont(provider))
        let upm = CGFloat(font.metrics.unitsPerEm)
        let core = CTFontCreateWithGraphicsFont(graphics, upm, nil, nil)
        #expect(CTFontGetGlyphCount(core) == font.glyphs.count)
        #expect(font.glyphs.contains { !$0.components.isEmpty } == expectComposites)
        var mismatches = 0
        for index in font.glyphs.indices {
            var glyph = CGGlyph(index)
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(core, .horizontal, &glyph, &advance, 1)
            if abs(Double(advance.width) - font.glyphs[index].advanceWidth) > 0.01 { mismatches += 1 }
            let path = CTFontCreatePathForGlyph(core, glyph, nil)
            let expected = path.map { $0.boundingBoxOfPath }.flatMap { $0.isNull || $0.isEmpty ? nil : $0 }
            let read = bounds(outline(font, index))
            switch (expected, read) {
            case (nil, nil): break
            case (let e?, let r?):
                if abs(e.minX - r.minX) > 0.01 || abs(e.maxX - r.maxX) > 0.01 || abs(e.minY - r.minY) > 0.01 || abs(e.maxY - r.maxY) > 0.01 {
                    mismatches += 1
                }
            default:
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
        // The character map agrees with Core Text.
        for character in "AVTo0é" {
            var units = Array(String(character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            CTFontGetGlyphsForCharacters(core, &units, &glyphs, units.count)
            #expect(font.glyphs[Int(glyphs[0])].codepoints.contains(character.unicodeScalars.first!.value))
        }
        // Kerning agrees with Core Text's layout for sampled pairs.
        var checked = 0
        let pairs = font.kerning.pairs.prefix(200)
        for pair in pairs {
            guard let left = font.glyphs[pair.left].codepoints.first, let right = font.glyphs[pair.right].codepoints.first,
                  let l = Unicode.Scalar(left), let r = Unicode.Scalar(right) else { continue }
            let text = String(String.UnicodeScalarView([l, r]))
            let positions = FontFixture.positions(core, text)
            guard positions.count == 2 else { continue }
            #expect(abs(positions[1] - positions[0] - (font.glyphs[pair.left].advanceWidth + Double(font.kerning.value(pair.left, pair.right)))) < 0.01,
                    "\(text)")
            checked += 1
        }
        #expect(checked > 0 || pairs.isEmpty)
    }

    @Test func refusalsAndEdgeCases() throws {
        #expect(throws: FontReadError.unsupported("font collections")) { try OpenTypeReader.read(Data([0x74, 0x74, 0x63, 0x66, 0, 0])) }
        #expect(throws: FontReadError.unsupported("not an OpenType font")) { try OpenTypeReader.read(Data("wOF2xxxx".utf8)) }
        #expect(throws: FontReadError.truncated("sfnt")) { try OpenTypeReader.read(Data([0, 1, 0, 0])) }
        let missing = FontTables.assemble(["name": [0, 0, 0, 0, 0, 6]], signature: 0x0001_0000)
        #expect(throws: FontReadError.missingTable("head")) { try OpenTypeReader.read(missing) }
        // Restricted embedding is refused.
        var source = FontFixture.source()
        source.os2.fsType = 2
        #expect(throws: FontReadError.unsupported("embedding permission Restricted")) {
            try OpenTypeReader.read(try FontCompiler.compile(source).data)
        }
        #expect(OpenTypeReader.version("Version 2.5; ttfautohint") == "2.500" && OpenTypeReader.version("x") == "1.000")
        #expect(OpenTypeReader.version("Version 1.0123") == "1.012")
        // A quadratic contour of off-curve points only reads with implied on-curve midpoints.
        let circle = TrueTypeReader.cubic([(Point(x: 0, y: 10), false), (Point(x: 10, y: 0), false), (Point(x: 0, y: -10), false), (Point(x: -10, y: 0), false)])
        #expect(circle.segments.count == 4 && circle.bounds.width > 0)
        #expect(TrueTypeReader.cubic([]).isEmpty)
        #expect(GPOSReader.valueRecord(0x0005) == (4, 2) && GPOSReader.valueRecord(0x0001).xAdvance == nil)
        // An old-format kern table.
        var kern = FontWriter()
        kern.u16(0); kern.u16(1)
        kern.u16(0); kern.u16(6 + 8 + 6); kern.u16(0x0001)
        kern.u16(1); kern.u16(6); kern.u16(0); kern.u16(0)
        kern.u16(2); kern.u16(3); kern.i16(-50)
        #expect(try OpenTypeReader.readKernTable(FontReader(kern.bytes, context: "kern")).pairs == [.init(left: 2, right: 3, value: -50)])
        #expect(try OpenTypeReader.readKernTable(FontReader([0, 1, 0, 0], context: "kern")).isEmpty)
    }
}
