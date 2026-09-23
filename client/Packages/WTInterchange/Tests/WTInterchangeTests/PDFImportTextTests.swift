// IMG-009: text import -- the text state operators, font encodings and ToUnicode maps, widths,
// editable runs joined per baseline, and outlines from embedded programs, Type 3 procedures and
// installed fonts.

import CoreGraphics
import CoreText
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct PDFImportTextTests {
    static let fontFile = "/System/Library/Fonts/Supplemental/Andale Mono.ttf"

    /// The glyph ids of `text` in the Andale Mono file.
    static func glyphs(_ text: String) throws -> [CGGlyph] {
        let data = try Data(contentsOf: URL(fileURLWithPath: fontFile))
        let font = CTFontCreateWithGraphicsFont(CGFont(CGDataProvider(data: data as CFData)!)!, 1, nil, nil)
        let characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        return glyphs
    }

    static func document() throws -> Data {
        var f = PDFImportFixture()
        let program = try Data(contentsOf: URL(fileURLWithPath: fontFile))
        let file = f.stream("/Length1 \(program.count)", program)
        let cmap = """
        /CIDInit /ProcSet findresource begin 12 dict begin begincmap
        1 begincodespacerange <0000> <FFFF> endcodespacerange
        2 beginbfchar <0001> <0048> <0002> <D83DDE00> endbfchar
        2 beginbfrange <0010> <0012> <0061> <0020> <0021> [<0058> <0059>] <0030> <0031> [<0058>] endbfrange
        endcmap end end
        """
        let toUnicode = f.stream("", cmap)
        let glyphs = try Self.glyphs("AB")
        let map = f.stream("", Data([0, 0, UInt8(glyphs[0] >> 8), UInt8(glyphs[0] & 0xFF), UInt8(glyphs[1] >> 8), UInt8(glyphs[1] & 0xFF)]))
        let proc = f.stream("", "500 0 d0 0 0 500 500 re f 1 0 0 rg 600 0 100 100 re S")
        let fonts = [
            "/F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "/F2 << /Subtype /Type1 /BaseFont /Times-Roman /Encoding << /BaseEncoding /MacRomanEncoding /Differences [65 /Euro /uni00E9 /u1F600 /g12 /eacute.alt] >> /FirstChar 65 /Widths [500 600 700 800 900] >>",
            "/F3 << /Subtype /Type1 /BaseFont /Helvetica /Encoding /StandardEncoding /FirstChar 32 /Widths [278] /FontDescriptor << /MissingWidth 250 >> >>",
            "/F4 << /Subtype /Type1 /BaseFont /ZapfDingbats /FontDescriptor << /Flags 4 >> >>",
            "/F5 << /Subtype /Type0 /BaseFont /ABCDEF+Helvetica /Encoding /Identity-H /ToUnicode \(toUnicode) 0 R /DescendantFonts [<< /Subtype /CIDFontType2 /DW 500 /W [1 [600 700] 16 18 400 3] >>] >>",
            "/F6 << /Subtype /Type0 /BaseFont /AndaleMono /Encoding /Identity-H /DescendantFonts [<< /Subtype /CIDFontType2 /CIDToGIDMap \(map) 0 R /FontDescriptor << /FontFile2 \(file) 0 R >> >>] >>",
            "/F7 << /Subtype /Type3 /FontMatrix [0.001 0 0 0.001 0 0] /FontBBox [0 0 1000 1000] /CharProcs << /square \(proc) 0 R >> /Encoding << /Differences [65 /square] >> /FirstChar 65 /Widths [700] >>",
            "/F8 << /Subtype /TrueType /BaseFont /NoSuchFont-Regular /FirstChar 32 /Widths [250] >>",
            "/F9 << /Subtype /TrueType /BaseFont /AndaleMono /FontDescriptor << /Flags 4 /FontFile2 \(file) 0 R >> >>",
            "/F10 << /Subtype /TrueType /BaseFont /AndaleMono /Encoding << /Differences [65 /B /nosuchglyph] >> /FontDescriptor << /FontFile2 \(file) 0 R >> >>",
            "/F11 << /Subtype /Type0 /BaseFont /AndaleMono /Encoding /Identity-H /DescendantFonts [<< /Subtype /CIDFontType2 /FontDescriptor << /FontFile2 \(file) 0 R >> >>] >>",
        ]
        let content = """
        BT /F1 12 Tf 10 20 Td (Hello) Tj ET
        BT /F1 10 Tf 0 100 Td (A) Tj [(B) -300 (C) 400 (D)] TJ ET
        BT /F1 10 Tf 2 Tc 3 Tw 120 Tz 14 TL 1 Ts 0 60 Td (Scaled) Tj T* (Next) Tj 0 -14 TD (Third) ' 1 1 (Fourth) " ET
        BT /F1 10 Tf 0 Tc 0 Tw 100 Tz 0 Ts 1 0 0 1 150 50 Tm (M) Tj 3 Tr (hidden) Tj 1 Tr 1 0 0 RG (S) Tj 2 Tr (T) Tj 0 Tr ET
        BT /F2 10 Tf 0 0 1 0 0 1 20 120 Tm (ABCDE) Tj ET
        BT /F3 10 Tf 20 130 Td (`x') Tj ET
        BT /F4 10 Tf 20 140 Td (a) Tj ET
        BT /F5 20 Tf 30 10 Td <0001001000110012002000210002> Tj <0030> Tj ET
        BT /F6 20 Tf 60 10 Td <00010002> Tj ET
        BT /F7 20 Tf 90 10 Td (AA) Tj ET
        BT /F8 10 Tf 120 10 Td (Missing) Tj ET
        BT /F9 10 Tf 150 10 Td (A) Tj ET
        BT /F10 10 Tf 150 20 Td (AB) Tj ET
        BT /F11 10 Tf 150 30 Td <0024> Tj ET
        BT /Missing 10 Tf (none) Tj ET
        BT (no font) Tj ET
        BT /F1 10 Tf 2 0 0 2 10 140 Tm (Two) Tj (Three) Tj 0.5 0 0 0.5 10 10 cm (Four) Tj ET
        """
        return f.document([.init(content, resources: "<< /Font << \(fonts.joined(separator: " ")) >> >>")])
    }

    static func scene(_ text: ImportTextHandling = .editable) throws -> ImportedScene {
        try PDFImportFixture.importPDF(document(), PDFImportOptions(text: text))
    }

    @Test func editableTextKeepsItsStringsFontsAndPlaces() throws {
        let scene = try Self.scene()
        let texts = PDFImportFixture.texts(scene.nodes)
        let strings = texts.map(\.string)
        #expect(strings.first == "Hello")
        let hello = texts[0].runs[0]
        #expect(hello.fontName == "Helvetica" && hello.fontSize == 12)
        #expect(hello.origin == Point(x: 10, y: 130))
        // A TJ gap of more than a fifth of an em splits the run; a wide one stands for a space.
        let line = try #require(texts.first { $0.string.hasPrefix("AB") })
        #expect(line.runs.map(\.text) == ["A", "B ", "C", "D"])
        #expect(line.runs[2].origin.x > line.runs[1].origin.x + 6)
        #expect(strings.contains("‘x’"))
        #expect(strings.contains("HabcXY\u{1F600}X"))
        #expect(strings.contains { $0.hasPrefix("HabcXY") })
        #expect(strings.contains("Missing"))
        #expect(!strings.contains("hidden"))
        #expect(scene.notes.contains { $0.contains("NoSuchFont-Regular") })
        let f5 = try #require(texts.first { $0.string.hasPrefix("Habc") }?.runs.first)
        #expect(f5.fontName == "Helvetica" && f5.fontSize == 20)
        // Horizontal scaling keeps a transform; a uniform text matrix scales the size.
        let scaled = try #require(texts.first { $0.string == "Scaled" })
        #expect(!scaled.transform.isIdentity)
        let two = try #require(texts.first { $0.string == "TwoThree" })
        #expect(two.runs[0].fontSize == 20 && two.transform.isIdentity)
        #expect(strings.contains("Four"))
        let next = try #require(texts.first { $0.string == "Next" })
        #expect(!next.transform.isIdentity)
    }

    @Test func textWithoutUnicodeOrAsPathsBecomesOutlines() throws {
        let scene = try Self.scene()
        let paths = PDFImportFixture.paths(scene.nodes)
        // Render modes 1 and 2 outline with strokes; Type 3, CID fonts without ToUnicode and
        // the font whose glyph `g12` has no Unicode are outlined too.
        #expect(paths.contains { $0.stroke != nil && $0.fill == .none })
        #expect(paths.contains { $0.stroke != nil && $0.fill != .none })
        let type3 = try #require(paths.first { path in path.contours.count == 4 && Rect(boundingPoints: path.contours.flatMap(\.allPoints)).width > 20 })
        #expect(type3.fill != .none)
        #expect(paths.count >= 7)
        let outlined = try Self.scene(.outlines)
        #expect(outlined.texts.isEmpty)
        #expect(PDFImportFixture.paths(outlined.nodes).count > paths.count)
    }

    @Test func fontTablesDecodeCodes() throws {
        #expect(PDFImportFont.stripSubset("ABCDEF+Helvetica") == "Helvetica")
        #expect(PDFImportFont.stripSubset("abcdef+Helvetica") == "abcdef+Helvetica")
        #expect(PDFImportFont.stripSubset("Helvetica") == "Helvetica")
        #expect(PDFImportFont.decode(0xE9, encoding: "WinAnsiEncoding") == "é")
        #expect(PDFImportFont.decode(0x8E, encoding: "MacRomanEncoding") == "é")
        #expect(PDFImportFont.decode(0x60, encoding: "StandardEncoding") == "\u{2018}")
        #expect(PDFImportFont.decode(0x41, encoding: "StandardEncoding") == "A")
        #expect(PDFImportFont.decode(0x05, encoding: "StandardEncoding") == nil)
        #expect(PDFImportFont.unicode(glyphName: "space") == " ")
        #expect(PDFImportFont.unicode(glyphName: "A.sc") == "A")
        #expect(PDFImportFont.unicode(glyphName: "uni20AC") == "€")
        #expect(PDFImportFont.unicode(glyphName: "u1F600") == "\u{1F600}")
        #expect(PDFImportFont.unicode(glyphName: "g12") == nil)
        #expect(PDFImportFont.unicode(glyphName: "uniZZZZ") == nil)
        #expect(PDFImportFont.glyphName(unicode: "€") == "Euro")
        #expect(PDFImportFont.glyphName(unicode: "q") == "q")
        #expect(PDFImportFont.glyphName(unicode: "\u{263A}") == "uni263A")
        #expect(PDFImportFont.glyphName(unicode: "") == nil)
        #expect(PDFImportFont.isInstalled("Helvetica"))
        #expect(!PDFImportFont.isInstalled("NoSuchFont-Regular"))
        #expect(PDFImportFont.installedGlyph("", "") == nil)
        #expect(PDFImportFont.installedGlyph("", "A") != nil)
        let map = PDFImportFont.parseCMap(Data("1 beginbfrange <41> <43> <0061> endbfrange 1 beginbfchar <44> endbfchar 1 beginbfrange <50> <40> <0061> <60> endbfrange".utf8))
        #expect(map == [0x41: "a", 0x42: "b", 0x43: "c"])
    }

    @Test func cidWidthsReadBothForms() throws {
        var f = PDFImportFixture()
        let data = f.document([.init("", resources: "<< /W [1 [100 200] 5 7 300 9 /bad 10 [400] 20 21] >>")])
        let document = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        let resources = PDFImportDict(ref: document.page(at: 1)!.dictionary!).dict("Resources")!
        let widths = PDFImportFont.parseCIDWidths(resources.array("W"))
        #expect(widths == [1: 100, 2: 200, 5: 300, 6: 300, 7: 300, 10: 400])
        #expect(PDFImportFont.parseCIDWidths(nil).isEmpty)
    }
}
