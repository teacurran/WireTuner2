import CoreGraphics
import CoreText
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

/// Fonts for the compiler, writer and reader tests.
enum FontFixture {
    /// A closed polygon (y up, counter-clockwise as given).
    static func polygon(_ points: [(Double, Double)]) -> Contour {
        Contour(polygon: points.map { Point(x: $0.0, y: $0.1) }, closed: true)
    }

    /// A circle of `radius` about (`cx`, `cy`), counter-clockwise (`clockwise` reverses it),
    /// four cubic arcs meeting at the extremes.
    static func circle(_ cx: Double, _ cy: Double, _ radius: Double, clockwise: Bool = false) -> Contour {
        let k = 0.5522847498 * radius
        let segments = [
            CubicBezier(Point(x: cx + radius, y: cy), Point(x: cx + radius, y: cy + k), Point(x: cx + k, y: cy + radius), Point(x: cx, y: cy + radius)),
            CubicBezier(Point(x: cx, y: cy + radius), Point(x: cx - k, y: cy + radius), Point(x: cx - radius, y: cy + k), Point(x: cx - radius, y: cy)),
            CubicBezier(Point(x: cx - radius, y: cy), Point(x: cx - radius, y: cy - k), Point(x: cx - k, y: cy - radius), Point(x: cx, y: cy - radius)),
            CubicBezier(Point(x: cx, y: cy - radius), Point(x: cx + k, y: cy - radius), Point(x: cx + radius, y: cy - k), Point(x: cx + radius, y: cy)),
        ]
        let contour = Contour(segments: segments, closed: true)
        return clockwise ? contour.reversed() : contour
    }

    /// A small font: .notdef (box with counter), space, A, V, O (ring), o (dot), and an emoji
    /// glyph above the BMP, with a pair kern A/V and a class kern (A | O,o).
    static func source(upm: Int = 1_000, style: String = "Regular") -> FontSource {
        let s = Double(upm) / 1_000
        func sc(_ points: [(Double, Double)]) -> Contour { polygon(points.map { ($0.0 * s, $0.1 * s) }) }
        var names = FontSource.Names(family: "Marlowe", style: style, postscript: "Marlowe-\(style.replacingOccurrences(of: " ", with: ""))",
                                     full: "Marlowe \(style)")
        names.copyright = "Copyright 2026 WireTuner"
        names.trademark = "Marlowe is a trademark"
        names.designer = "Test"
        names.license = "OFL"
        names.sampleText = "AVO"
        let glyphs: [FontSource.Glyph] = [
            .init(name: ".notdef", advanceWidth: 500 * s, contours: [sc([(50, 0), (450, 0), (450, 700), (50, 700)]),
                                                                     sc([(100, 50), (100, 650), (400, 650), (400, 50)])]),
            .init(name: "space", codepoints: [0x20], advanceWidth: 250 * s),
            .init(name: "A", codepoints: [0x41], advanceWidth: 600 * s, contours: [sc([(0, 0), (600, 0), (300, 700)])]),
            .init(name: "V", codepoints: [0x56], advanceWidth: 600 * s, contours: [sc([(300, 0), (600, 700), (0, 700)])]),
            .init(name: "O", codepoints: [0x4F], advanceWidth: 700 * s,
                  contours: [circle(350 * s, 350 * s, 300 * s), circle(350 * s, 350 * s, 200 * s, clockwise: true)]),
            .init(name: "o", codepoints: [0x6F], advanceWidth: 500 * s, contours: [circle(250 * s, 250 * s, 200 * s)]),
            .init(name: "u1F600", codepoints: [0x1F600], advanceWidth: 1_000 * s, contours: [sc([(100, 0), (900, 0), (900, 800), (100, 800)])]),
        ]
        let kerning = FontSource.Kerning(pairs: [.init(left: 2, right: 3, value: -80)], leftClasses: [[2]], rightClasses: [[4, 5]],
                                         classValues: [.init(left: 0, right: 0, value: -30)])
        return FontSource(names: names, metrics: FontSource.Metrics(unitsPerEm: upm, ascender: 800 * s, descender: -200 * s),
                          glyphs: glyphs, kerning: kerning)
    }

    /// Core Text's font of `data` at one point per font unit.
    static func coreText(_ data: Data, upm: Int = 1_000) -> CTFont? {
        guard let provider = CGDataProvider(data: data as CFData), let graphics = CGFont(provider) else { return nil }
        return CTFontCreateWithGraphicsFont(graphics, CGFloat(upm), nil, nil)
    }

    static func glyph(_ font: CTFont, _ character: Character) -> CGGlyph {
        var units = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
        return glyphs[0]
    }

    static func advance(_ font: CTFont, _ glyph: CGGlyph) -> Double {
        var glyph = glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return Double(advance.width)
    }

    /// The x of each glyph laid out by Core Text (kerning applied).
    static func positions(_ font: CTFont, _ text: String) -> [Double] {
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        let run = (CTLineGetGlyphRuns(line) as! [CTRun])[0]
        var positions = [CGPoint](repeating: .zero, count: CTRunGetGlyphCount(run))
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        return positions.map { Double($0.x) }
    }
}

/// FONT-018: compiling a `FontSource` to OTF and TTF, checked through Core Text and the tables.
@Suite struct FontCompilerTests {
    @Test(arguments: FontCompiler.Format.allCases)
    func compiledFontLoadsInCoreText(format: FontCompiler.Format) throws {
        let source = FontFixture.source()
        let result = try FontCompiler.compile(source, options: .init(format: format))
        #expect(result.diagnostics.isEmpty)
        let font = try #require(FontFixture.coreText(result.data))
        #expect(CTFontGetGlyphCount(font) == 7)
        #expect(CTFontCopyFamilyName(font) as String == "Marlowe" && CTFontCopyPostScriptName(font) as String == "Marlowe-Regular")
        let graphics = CTFontCopyGraphicsFont(font, nil)
        for (index, glyph) in source.glyphs.enumerated() {
            #expect(graphics.name(for: CGGlyph(index)) as String? == glyph.name)
        }
        let a = FontFixture.glyph(font, "A"), v = FontFixture.glyph(font, "V"), o = FontFixture.glyph(font, "O")
        #expect(a == 2 && v == 3 && o == 4)
        #expect(FontFixture.glyph(font, "😀") == 6)
        #expect(FontFixture.advance(font, a) == 600 && FontFixture.advance(font, 1) == 250)
        // Outlines: the ring's bounds within half a unit (TrueType curves are approximations).
        let ring = CTFontCreatePathForGlyph(font, o, nil)!.boundingBoxOfPath
        #expect(abs(ring.minX - 50) <= 0.5 && abs(ring.maxX - 650) <= 0.5 && abs(ring.minY - 50) <= 0.5 && abs(ring.maxY - 650) <= 0.5)
        let triangle = CTFontCreatePathForGlyph(font, a, nil)!.boundingBoxOfPath
        #expect(triangle == CGRect(x: 0, y: 0, width: 600, height: 700))
        // Kerning through Core Text's layout: the pair kern, then the class kern.
        let av = FontFixture.positions(font, "AV")
        #expect(av[1] - av[0] == 520)
        let ao = FontFixture.positions(font, "AOo")
        #expect(ao[1] - ao[0] == 570 && ao[2] - ao[1] == 700)
        let va = FontFixture.positions(font, "VA")
        #expect(va[1] - va[0] == 600)
        #expect(abs(CTFontGetAscent(font) - 800) < 0.01 && abs(CTFontGetDescent(font) - 200) < 0.01)
    }

    @Test func otherEmsAndStylesAndItalics() throws {
        var source = FontFixture.source(upm: 2_048, style: "Semibold Italic")
        source.metrics.italicAngle = -12
        source.os2.italic = true
        source.os2.bold = true
        for format in FontCompiler.Format.allCases {
            let data = try FontCompiler.compile(source, options: .init(format: format, date: Date(timeIntervalSince1970: 1_700_000_000))).data
            let font = try #require(FontFixture.coreText(data, upm: 2_048))
            #expect(CTFontGetUnitsPerEm(font) == 2_048)
            #expect(FontFixture.advance(font, FontFixture.glyph(font, "A")) == 1_228.8.rounded())
            #expect(CTFontCopyFamilyName(font) as String == "Marlowe")
            let traits = CTFontGetSymbolicTraits(font)
            #expect(traits.contains(.traitItalic))
            #expect(abs(CTFontGetSlantAngle(font) + 12) < 0.01)
            let triangle = CTFontCreatePathForGlyph(font, FontFixture.glyph(font, "A"), nil)!.boundingBoxOfPath
            #expect(abs(triangle.maxY - 1_433.6) <= 1)
        }
    }

    @Test func identicalSourcesGiveIdenticalBytes() throws {
        let one = try FontCompiler.compile(FontFixture.source()).data
        let two = try FontCompiler.compile(FontFixture.source()).data
        #expect(one == two)
        #expect(one.prefix(4) == Data("OTTO".utf8))
        #expect(try FontCompiler.compile(FontFixture.source(), options: .init(format: .ttf)).data.prefix(4) == Data([0, 1, 0, 0]))
        #expect(FontCompiler.Format.otf.fileExtension == "otf" && FontCompiler.Format.ttf.fileExtension == "ttf")
    }

    @Test func invalidSourcesAreRefusedWithDiagnostics() throws {
        var source = FontFixture.source()
        source.glyphs[0].name = "notdef"
        source.glyphs[3].name = "A"
        source.glyphs[3].codepoints = [0x41]
        source.metrics.unitsPerEm = 8
        source.metrics.ascender = -300
        source.names.family = ""
        source.names.postscript = "Bad Name"
        source.features = "feature liga { sub f i by f_i; } liga;"
        do {
            _ = try FontCompiler.compile(source)
            Issue.record("compiled")
        } catch FontCompiler.Failure.invalidSource(let diagnostics) {
            let errors = diagnostics.filter { $0.severity == .error }.map(\.message)
            #expect(errors.contains("The first glyph must be .notdef."))
            #expect(errors.contains("Units per em must be between 16 and 16384."))
            #expect(errors.contains("The ascender must be above the descender."))
            #expect(errors.contains("The family and style names must not be empty."))
            #expect(errors.contains("Invalid PostScript name."))
            #expect(errors.contains("Two glyphs are named A.") && errors.contains("Two glyphs encode U+0041."))
            // The feature file names glyphs the font lacks: errors at their line and column.
            #expect(diagnostics.contains { $0.severity == .error && $0.line == 1 && $0.column == 20 && $0.glyph == "f" })
        }
        var many = FontFixture.source()
        many.glyphs += Array(repeating: FontSource.Glyph(name: "x", advanceWidth: 0), count: FontCompiler.maximumGlyphs)
        #expect(FontCompiler.check(many).contains { $0.message == "More than 65535 glyphs." })
        #expect(FontCompiler.check(FontSource(names: FontFixture.source().names, glyphs: [])).contains { $0.message == "The first glyph must be .notdef." })
        // A feature file that checks clean compiles without diagnostics; a warning (a feature
        // defined twice) does not stop it.
        var featured = FontFixture.source()
        featured.features = "languagesystem DFLT dflt;"
        #expect(try FontCompiler.compile(featured).diagnostics.isEmpty)
        featured.features = "feature ss01 { sub A by V; } ss01;\nfeature ss01 { sub O by o; } ss01;"
        #expect(try FontCompiler.compile(featured).diagnostics.map(\.severity) == [.warning])
    }

    @Test func asyncCompileAndCancellation() async throws {
        let compiler = FontCompiler()
        let result = try await compiler.compile(FontFixture.source(), options: .init(format: .ttf))
        #expect(FontFixture.coreText(result.data) != nil)
        #expect(try await compiler.quickCompile(FontFixture.source()).data.prefix(4) == Data("OTTO".utf8))
        #expect(throws: FontCompiler.Failure.cancelled) { try FontCompiler.compile(FontFixture.source(), isCancelled: { true }) }
        var calls = 0
        #expect(throws: FontCompiler.Failure.cancelled) {
            try FontCompiler.compile(FontFixture.source()) {
                calls += 1
                return calls > 1
            }
        }
    }

    @Test func tablesAtTheirEdges() throws {
        // cmap: a run across U+FFFF is cut before the format 4 terminator.
        let edge = FontTables.cmapFormat4([0xFFFE: 1, 0xFFFF: 2])
        #expect(try FontReader(edge, context: "cmap").u16(6) == 4)
        #expect(FontTables.cmapFormat4([0xFFFF: 2]).count == 24)
        // CFF numbers in every encoding and reals with exponents.
        #expect(CFFWriter.number(0) == [139] && CFFWriter.number(200) == [247, 92] && CFFWriter.number(-200) == [251, 92])
        #expect(CFFWriter.number(5_000) == [28, 0x13, 0x88] && CFFWriter.number(0.5) == [255, 0, 0, 0x80, 0])
        #expect(CFFWriter.dictInteger(40_000) == [29, 0, 0, 0x9C, 0x40] && CFFWriter.dictInteger(-5_000) == [28, 0xEC, 0x78])
        #expect(CFFWriter.dictReal(-12.5) == [30, 0xE1, 0x2A, 0x5F])
        #expect(CFFWriter.dictReal(1e-20) == [30, 0x1C, 0x20, 0xFF])
        #expect(CFFWriter.dictReal(1e20) == [30, 0x1B, 0x20, 0xFF])
        #expect(CFFWriter.index([]) == [0, 0])
        // An empty font of just .notdef without outlines.
        let bare = FontSource(names: FontSource.Names(family: "Bare", style: "Regular", postscript: "Bare-Regular", full: "Bare"),
                              glyphs: [FontSource.Glyph(name: ".notdef", advanceWidth: 0)])
        for format in FontCompiler.Format.allCases {
            #expect(FontFixture.coreText(try FontCompiler.compile(bare, options: .init(format: format)).data) != nil)
        }
        #expect(FontTables.unicodeRanges([0x41, 0x1F600])[1] & (1 << 25) != 0)
        #expect(FeatureTables.layoutTable(.gpos, lookups: [], features: [], systems: []) == nil)
        #expect(FontSource.Kerning(pairs: [.init(left: 1, right: 2, value: -5)], leftClasses: [[3]], rightClasses: [[4]],
                                   classValues: [.init(left: 0, right: 0, value: -9)]).value(3, 4) == -9)
        #expect(FontSource.Kerning().value(1, 2) == 0 && FontSource.Kerning().isEmpty)
        #expect(FontSource.Names(family: "a", style: "b", postscript: "c", full: "d", version: "x").revision == 1)
        #expect(FontSource.Glyph(name: "x", advanceWidth: 0).bounds == nil)
        #expect(FontFixture.source().glyphs[0].bounds == Rect(x: 50, y: 0, width: 400, height: 700))
    }

    @Test func typedWindowsMetricsLegacyStylesAndLongLoca() throws {
        var source = FontFixture.source(style: "Heavy")
        source.metrics.winAscent = 1_100
        source.metrics.winDescent = 400
        source.os2.bold = true
        // Enough glyph data for 32-bit loca offsets.
        var points: [(Double, Double)] = []
        for index in 0..<40 {
            points.append((Double(index * 20), index % 2 == 0 ? 0 : 500))
        }
        points += [(800, 800), (0, 800)]
        let zigzag = FontFixture.polygon(points)
        source.glyphs += (0..<1_500).map { FontSource.Glyph(name: "z\($0)", advanceWidth: 800, contours: [zigzag]) }
        let data = try FontCompiler.compile(source, options: .init(format: .ttf)).data
        let font = try OpenTypeReader.read(data)
        #expect(font.metrics.winAscent == 1_100 && font.metrics.winDescent == 400)
        #expect(font.names.family == "Marlowe" && font.names.style == "Heavy" && font.os2.bold)
        let core = try #require(FontFixture.coreText(data))
        let nameTable = try #require(CTFontCopyTable(core, CTFontTableTag(kCTFontTableName), []) as Data?)
        let names = try OpenTypeReader.readNames(FontReader(nameTable, context: "name"))
        #expect(names[1] == "Marlowe Heavy" && names[2] == "Bold")
        #expect(font.glyphs.count == 1_507 && font.glyphs.last?.contours.first?.segments.count == 42)
        let head = try #require(CTFontCopyTable(core, CTFontTableTag(kCTFontTableHead), []) as Data?)
        #expect(try FontReader(head, context: "head").i16(50) == 1)
    }

    @Test func largeKerningSplitsSubtables() throws {
        var source = FontFixture.source()
        let base = source.glyphs.count
        for index in 0..<600 {
            source.glyphs.append(FontSource.Glyph(name: "g\(index)", advanceWidth: 500))
        }
        var pairs: [FontSource.Kerning.Pair] = []
        for left in 0..<120 {
            for right in 0..<120 { pairs.append(.init(left: base + left, right: base + 200 + right, value: -(left + right) % 50 - 1)) }
        }
        let lefts = (0..<300).map { [base + $0] }
        let rights = (0..<300).map { [base + 300 + $0] }
        let cells = (0..<300).flatMap { l in (0..<300).compactMap { r in (l + r) % 7 == 0 ? FontSource.Kerning.ClassValue(left: l, right: r, value: -10) : nil } }
        source.kerning = FontSource.Kerning(pairs: pairs, leftClasses: lefts, rightClasses: rights, classValues: cells)
        let data = try FontCompiler.compile(source).data
        let font = try #require(FontFixture.coreText(data))
        #expect(CTFontGetGlyphCount(font) == CFIndex(base + 600))
        let gpos = try #require(CTFontCopyTable(font, CTFontTableTag(kCTFontTableGPOS), []) as Data?)
        let reader = FontReader(gpos, context: "GPOS")
        let lookupList = try reader.u16(8)
        let lookup = lookupList + (try reader.u16(lookupList + 2))
        #expect(try reader.u16(lookup) == 9 && (try reader.u16(lookup + 4)) > 2)
    }
}
