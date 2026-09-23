// TYPE-048: static instancing of variable TrueType fonts for PDF.  STIX Two Text (a glyf/gvar font
// with `avar` and `HVAR`, 2,221 glyphs, shipped with macOS) is instanced at three weights; each
// instance's outlines are loaded back through Core Graphics and held to Core Text's rendering of
// the same tuple within 0.01 em, its advances to Core Text's, and a PDF with the three weights
// carries three static TrueType font resources that search in PDFKit and pass `qpdf --check`
// (when installed).  The packed-data decoders, IUP, the tuple scalar and the glyph codecs are
// tested on hand-made bytes.

import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct VariableFontTests {
    static let family = "STIXTwoText"
    static let wght: UInt32 = 0x7767_6874
    static let text = "Hamburgefonstiv \u{00C5}\u{00E9}\u{0151}fi"

    static func font(_ weight: Double?, size: CGFloat = 1000) -> CTFont {
        GlyphFont(postScriptName: family, size: Double(size), variations: weight.map { [wght: $0] } ?? [:]).ctFont
    }

    static func glyphs(_ font: CTFont, _ string: String = text) -> [CGGlyph] {
        let characters = Array(string.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        return glyphs.filter { $0 != 0 }
    }

    /// Every point of a glyph path, in order.
    static func points(_ font: CTFont, _ glyph: CGGlyph) -> [CGPoint] {
        guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { return [] }
        var result: [CGPoint] = []
        path.applyWithBlock { element in
            let count: Int
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            default: count = 0
            }
            for index in 0..<count { result.append(element.pointee.points[index]) }
        }
        return result
    }

    static func loaded(_ program: Data, size: CGFloat = 1000) throws -> CTFont {
        let provider = try #require(CGDataProvider(data: program as CFData))
        let graphics = try #require(CGFont(provider))
        return CTFontCreateWithGraphicsFont(graphics, size, nil, nil)
    }

    @Test(arguments: [400.0, 550, 700])
    func instancedOutlinesMatchCoreText(_ weight: Double) throws {
        let variable = Self.font(weight)
        let glyphs = Self.glyphs(variable)
        let program = try VariableFontInstancer.instance(of: variable, variations: [Self.wght: weight], glyphs: Set(glyphs))
        let instance = try Self.loaded(program)
        #expect(FontProgram.table("gvar", of: instance) == nil && FontProgram.table("fvar", of: instance) == nil && FontProgram.table("HVAR", of: instance) == nil)
        var worst = 0.0
        for glyph in glyphs {
            let expected = Self.points(variable, glyph)
            let actual = Self.points(instance, glyph)
            #expect(expected.count == actual.count, "glyph \(glyph)")
            for (a, b) in zip(expected, actual) {
                worst = max(worst, abs(Double(a.x - b.x)), abs(Double(a.y - b.y)))
            }
        }
        // 0.01 em at 1000 units per em.
        #expect(worst <= 10, "worst \(worst) units")
        var expectedAdvances = [CGSize](repeating: .zero, count: glyphs.count), actualAdvances = expectedAdvances
        CTFontGetAdvancesForGlyphs(variable, .horizontal, glyphs, &expectedAdvances, glyphs.count)
        CTFontGetAdvancesForGlyphs(instance, .horizontal, glyphs, &actualAdvances, glyphs.count)
        for (a, b) in zip(expectedAdvances, actualAdvances) {
            #expect(abs(a.width - b.width) <= 1)
        }
        // Unused glyphs are empty.
        let unused = CGGlyph(CTFontGetGlyphCount(variable) - 1)
        if !glyphs.contains(unused) {
            #expect(Self.points(instance, unused).isEmpty)
        }
    }

    /// Skia (an older TrueType GX font: two axes, no `avar`, 2048 units per em) exercises
    /// embedded peaks and intermediate regions.
    @Test(arguments: [[0x7767_6874: 2.4, 0x7769_6474: 0.8], [0x7767_6874: 0.6, 0x7769_6474: 1.2], [0x7767_6874: 1.0, 0x7769_6474: 1.0]] as [[UInt32: Double]])
    func twoAxisFontMatchesCoreText(_ tuple: [UInt32: Double]) throws {
        let variable = GlyphFont(postScriptName: "Skia-Regular", size: 2048, variations: tuple).ctFont
        let glyphs = Self.glyphs(variable, "Skia &Qg@fi 0123")
        let instance = try Self.loaded(try VariableFontInstancer.instance(of: variable, variations: tuple, glyphs: Set(glyphs)), size: 2048)
        var worst = 0.0
        for glyph in glyphs {
            let expected = Self.points(variable, glyph), actual = Self.points(instance, glyph)
            #expect(expected.count == actual.count, "glyph \(glyph)")
            for (a, b) in zip(expected, actual) {
                worst = max(worst, abs(Double(a.x - b.x)), abs(Double(a.y - b.y)))
            }
        }
        #expect(worst <= 20.48, "worst \(worst) units")
        // The tuple moves the outlines (away from the default instance, except at 1, 1).
        let plain = GlyphFont(postScriptName: "Skia-Regular", size: 2048, variations: [:]).ctFont
        let moved = glyphs.contains { glyph in zip(Self.points(plain, glyph), Self.points(instance, glyph)).contains { abs($0.x - $1.x) > 30 } }
        #expect(moved == (tuple[0x7767_6874] != 1.0))
    }

    @Test func pdfEmbedsOneStaticInstancePerWeight() throws {
        let items = [400.0, 550, 700].enumerated().map { index, weight in
            Corpus.text("Weight \(Int(weight))", font: Self.family, size: 24, origin: Point(x: 10, y: 40 + Double(index) * 40), variations: [Self.wght: weight])
        }
        let page = Corpus.page(items, width: 300, height: 150)
        let result = try PDFExporter().data(scene: Corpus.scene([page]), options: PDFOptions())
        let raw = PDFTests.text(of: result.data)
        let names = Set(raw.components(separatedBy: "/BaseFont /").dropFirst().compactMap { $0.split(separator: " ").first.map(String.init) }.filter { $0.contains("-Instance-") })
        #expect(names.count == 3, "\(names)")
        #expect(names.allSatisfy { $0.range(of: "^[A-Z]{6}\\+STIXTwoText-Instance-[0-9A-F]{8}$", options: .regularExpression) != nil })
        #expect(raw.components(separatedBy: "/FontFile2").count - 1 == 3 && !raw.contains("/Type3"))
        let document = try #require(PDFDocument(data: result.data))
        let string = document.string ?? ""
        #expect(string.contains("Weight 400") && string.contains("Weight 550") && string.contains("Weight 700"))
        let rendered = PDFTests.rasterize(result.data, scale: 2)
        // Core Graphics draws embedded text a little heavier than the outlines the reference
        // renderer fills: the instances differ from the reference no more than the static font
        // (the default instance, embedded from the font's own tables) does.
        let failing = Corpus.difference(Corpus.reference(page, scale: 2), rendered, tolerance: 40)
        let statics = [400.0, 400, 400].enumerated().map { index, _ in
            Corpus.text("Weight 400", font: Self.family, size: 24, origin: Point(x: 10, y: 40 + Double(index) * 40))
        }
        let staticPage = Corpus.page(statics, width: 300, height: 150)
        let staticPDF = try PDFExporter().data(scene: Corpus.scene([staticPage]), options: PDFOptions())
        let baseline = Corpus.difference(Corpus.reference(staticPage, scale: 2), PDFTests.rasterize(staticPDF.data, scale: 2), tolerance: 40)
        #expect(failing <= max(baseline * 1.5, 0.005) && failing <= 0.03, "\(failing) against the static font's \(baseline)")
        let complete = try PDFExporter().data(scene: Corpus.scene([page]), options: PDFOptions(fonts: .embedFull))
        let completeRaw = PDFTests.text(of: complete.data)
        #expect(completeRaw.contains("/BaseFont /STIXTwoText-Instance-") && !completeRaw.contains("/Type3"))
        let directory = Corpus.directory()
        for (name, data) in [("instances.pdf", result.data), ("complete.pdf", complete.data)] {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            let qpdf = "/opt/homebrew/bin/qpdf"
            if FileManager.default.isExecutableFile(atPath: qpdf) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: qpdf)
                process.arguments = ["--check", url.path]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                try process.run()
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                #expect(process.terminationStatus == 0, "\(output)")
            }
            if Ghostscript.isAvailable {
                #expect(try Ghostscript.check(url, pdf: true).status == 0)
            }
        }
    }

    @Test func fontsThatCannotBeInstancedAreOutlinedAndReported() throws {
        // A static font given variations is embedded as the static font.
        let helvetica = try PDFExporter().data(scene: Corpus.scene([Corpus.page([Corpus.text("Static", variations: [Self.wght: 700])])]), options: PDFOptions())
        #expect(PDFTests.text(of: helvetica.data).contains("/FontFile2"))
        #expect(!VariableFontInstancer.canInstance(Self.font(nil).copy(size: 10, "Helvetica")))
        #expect(throws: VariableFontInstancer.Failure.malformed("required tables")) {
            try VariableFontInstancer.instance(of: CTFontCreateWithName("Helvetica" as CFString, 10, nil), variations: [:], glyphs: [])
        }
        #expect(throws: VariableFontInstancer.Failure.notTrueType) {
            try VariableFontInstancer.instance(of: CTFontCreateWithName("KohinoorDevanagari-Regular" as CFString, 10, nil), variations: [:], glyphs: [])
        }
        // A variable font the instancer refuses (as a CFF2 font is) draws as outlines, reported.
        let objects = PDFObjects(compress: true)
        let registry = PDFFontRegistry(objects: objects, embedAll: false)
        registry.instanceable = { _ in false }
        let refused = GlyphFont(postScriptName: Self.family, size: 12, variations: [Self.wght: 600])
        #expect(registry.font(for: refused) == nil && registry.font(for: refused) == nil)
        #expect(registry.uninstanceableNames == [Self.family])
        #expect(registry.font(for: GlyphFont(postScriptName: Self.family, size: 12, variations: [:]))?.kind == .trueType)
    }

    @Test func reportNamesTheRefusedVariableFont() throws {
        let build = PDFDocumentBuild(options: PDFOptions(), scene: Corpus.scene([]))
        build.fonts.instanceable = { _ in false }
        let page = Corpus.page([Corpus.text("Refused", font: Self.family, variations: [Self.wght: 600])])
        let flat = PDFExporter.flattener(options: PDFOptions(), scene: Corpus.scene([page])).flatten(page, scene: Corpus.scene([page]))
        let result = build.write([flat.page])
        #expect(result.notes.contains("font STIXTwoText converted to outlines: variable font (only TrueType variable fonts are instanced)"))
        #expect(!PDFTests.text(of: result.data).contains("/FontFile2"))
    }

    // MARK: Pieces

    @Test func coordinatesNormalizeAndMapThroughAvar() throws {
        let axis = VariableFontInstancer.Axis(tag: Self.wght, minimum: 100, defaultValue: 400, maximum: 900)
        #expect(VariableFontInstancer.normalize(100, axis: axis) == -1 && VariableFontInstancer.normalize(650, axis: axis) == 0.5 && VariableFontInstancer.normalize(2000, axis: axis) == 1)
        #expect(VariableFontInstancer.normalize(400, axis: axis) == 0)
        let flat = VariableFontInstancer.Axis(tag: 1, minimum: 5, defaultValue: 5, maximum: 5)
        #expect(VariableFontInstancer.normalize(1, axis: flat) == 0 && VariableFontInstancer.normalize(9, axis: flat) == 0)
        let segments = [(-1.0, -1.0), (0, 0), (0.5, 0.8), (1, 1)]
        #expect(abs(VariableFontInstancer.map(0.25, through: segments) - 0.4) < 1e-9)
        #expect(VariableFontInstancer.map(-2, through: segments) == -1 && VariableFontInstancer.map(2, through: segments) == 1)
        #expect(VariableFontInstancer.map(0.3, through: [(0, 0)]) == 0.3)
        #expect(VariableFontInstancer.map(0.5, through: [(0, 0), (0, 1), (1, 1)]) == 1)
        // STIX Two Text's own tables.
        let font = Self.font(nil)
        let axes = try VariableFontInstancer.axes(try #require(FontProgram.table("fvar", of: font)))
        #expect(axes == [axis.with(minimum: 400, maximum: 700)])
        let avar = FontProgram.table("avar", of: font)
        #expect(VariableFontInstancer.segmentMaps(avar, axisCount: 1).count == 1)
        #expect(VariableFontInstancer.segmentMaps(avar, axisCount: 2).isEmpty && VariableFontInstancer.segmentMaps(nil, axisCount: 1).isEmpty)
        #expect(VariableFontInstancer.segmentMaps(Data([0, 1, 0, 0, 0, 0, 0, 1, 0, 9]), axisCount: 1).isEmpty)
        #expect(VariableFontInstancer.segmentMaps(Data([0, 1, 0, 0, 0, 0, 0, 1]), axisCount: 1).isEmpty)
        #expect(VariableFontInstancer.coordinates([Self.wght: 700], axes: axes, avar: avar) == [1])
        #expect(throws: VariableFontInstancer.Failure.self) { try VariableFontInstancer.axes(Data(count: 8)) }
        #expect(throws: VariableFontInstancer.Failure.self) { try VariableFontInstancer.axes(Data([0, 1, 0, 0, 0, 16, 0, 2, 0, 9, 0, 20, 0, 0, 0, 0])) }
    }

    @Test func tupleScalars() {
        let s = VariableFontInstancer.scalar
        #expect(s([1], nil, nil, [0.5]) == 0.5)
        #expect(s([1], nil, nil, [-0.5]) == 0 && s([-1], nil, nil, [0.5]) == 0 && s([0.5], nil, nil, [0.8]) == 0)
        #expect(s([1], nil, nil, [0]) == 0)
        #expect(s([0, 1], nil, nil, [0.7, 1]) == 1)
        #expect(s([0.5], [0.25], [1], [0.375]) == 0.5 && s([0.5], [0.25], [1], [0.75]) == 0.5)
        #expect(s([0.5], [0.25], [1], [0.1]) == 0)
        #expect(s([0.5], [0.6], [1], [0.1]) == 1, "an invalid region ignores the axis")
        #expect(s([0.5], [-0.5], [1], [0.1]) == 1, "a region spanning zero ignores the axis")
    }

    @Test func packedPointsAndDeltasDecode() throws {
        var position = 0
        #expect(try VariableFontInstancer.points([0], &position) == nil && position == 1)
        position = 0
        // Three points in one byte run (1, +2, +3), then two word points (+300, +1).
        #expect(try VariableFontInstancer.points([5, 0x02, 1, 2, 3, 0x81, 0x01, 0x2C, 0x00, 0x01], &position) == [1, 3, 6, 306, 307])
        position = 0
        #expect(try VariableFontInstancer.points([0x80, 0x02, 0x01, 4, 5], &position) == [4, 9])
        for broken: [UInt8] in [[], [0x80], [2], [2, 0x81, 1], [2, 0x01, 1]] {
            position = 0
            #expect(throws: VariableFontInstancer.Failure.self) { _ = try VariableFontInstancer.points(broken, &position) }
        }
        position = 0
        // Two zero deltas, a word run (-2), a byte run (5, -1).
        #expect(try VariableFontInstancer.deltas([0x81, 0x40, 0xFF, 0xFE, 0x01, 0x05, 0xFF], &position, count: 5) == [0, 0, -2, 5, -1])
        for broken: [UInt8] in [[], [0x40, 1], [0x01, 1]] {
            position = 0
            #expect(throws: VariableFontInstancer.Failure.self) { _ = try VariableFontInstancer.deltas(broken, &position, count: 2) }
        }
    }

    @Test func untouchedPointsInterpolate() {
        // One contour of five points; 0 and 2 touched.
        var deltas = [10.0, 0, 20, 0, 0]
        VariableFontInstancer.interpolate(&deltas, touched: [true, false, true, false, false], coordinates: [0, 50, 100, 150, -10], ends: [4])
        #expect(deltas == [10, 15, 20, 20, 10])
        // A lone touched point moves its contour; an untouched contour stays.
        var lone = [0.0, 7, 0, 0, 0]
        VariableFontInstancer.interpolate(&lone, touched: [false, true, false, false, false], coordinates: [0, 1, 2, 3, 4], ends: [2, 4])
        #expect(lone == [7, 7, 7, 0, 0])
        // Equal reference coordinates.
        var equal = [4.0, 0, 4]
        VariableFontInstancer.interpolate(&equal, touched: [true, false, true], coordinates: [5, 5, 5], ends: [2])
        var unequal = [4.0, 0, 6]
        VariableFontInstancer.interpolate(&unequal, touched: [true, false, true], coordinates: [5, 9, 5], ends: [2])
        #expect(equal == [4, 4, 4] && unequal == [4, 0, 6])
        var reversed = [10.0, 0, 20]
        VariableFontInstancer.interpolate(&reversed, touched: [true, false, true], coordinates: [100, 300, 0], ends: [2, 9])
        #expect(reversed == [10, 10, 20])
    }

    @Test func glyphsParseAndEncode() throws {
        // A simple glyph: a triangle with a far point (word coordinates) and two instructions.
        let simple = VariableFontInstancer.encodeSimple(ends: [2], instructions: [0xB0, 0x01], flags: [1, 0, 1], x: [0, 400, 800], y: [0, -700, 0])
        guard case .simple(let ends, let instructions, let flags, let x, let y) = try VariableFontInstancer.parse(simple[...]) else {
            Issue.record("expected a simple glyph")
            return
        }
        #expect(ends == [2] && Array(instructions) == [0xB0, 0x01] && flags == [1, 0, 1] && x == [0, 400, 800] && y == [0, -700, 0])
        // Repeated flags read back.
        let repeated: [UInt8] = [0, 1, 0, 0, 0, 0, 0, 10, 0, 10, 0, 1, 0, 0, 0x3F, 1, 5, 5, 3, 3]
        guard case .simple(_, _, _, let rx, _) = try VariableFontInstancer.parse(repeated[...]) else {
            Issue.record("expected a simple glyph")
            return
        }
        #expect(rx == [5, 10])
        #expect(VariableFontInstancer.pointCount(.empty) == 0)
        if case .empty = try VariableFontInstancer.parse([]) {} else { Issue.record("expected empty") }
        for broken: [UInt8] in [[0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0], [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9], [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0],
                                [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0x08], [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x00], [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02]] {
            #expect(throws: VariableFontInstancer.Failure.self) { _ = try VariableFontInstancer.parse(broken[...]) }
        }
        // A composite: an offset component with a scale, a point-matched one, instructions.
        var composite: [UInt8] = [0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0]
        composite += [0x00, 0x2A, 0x00, 0x05, 0x10, 0xF0, 0x40, 0x00]  // XY bytes, scale, more
        composite += [0x01, 0x01, 0x00, 0x06, 0x00, 0x02, 0x00, 0x03]  // words, point numbers, instructions
        composite += [0x00, 0x01, 0xB0]
        guard case .composite(var components, let compositeInstructions) = try VariableFontInstancer.parse(composite[...]) else {
            Issue.record("expected a composite")
            return
        }
        #expect(components.count == 2 && components[0].dx == 16 && components[0].dy == -16 && Array(compositeInstructions) == [0xB0] && !components[1].hasOffset)
        components[0].dx = 300.4
        let encoded = VariableFontInstancer.encodeComposite(components, instructions: compositeInstructions, bounds: (0, 0, 10, 10))
        guard case .composite(let again, let againInstructions) = try VariableFontInstancer.parse(encoded[...]) else {
            Issue.record("expected a composite")
            return
        }
        #expect(again[0].dx == 300 && again[0].flags & 0x0001 != 0 && Array(again[0].transform) == [0x40, 0x00] && Array(again[1].arguments) == [0x00, 0x02, 0x00, 0x03])
        #expect(Array(againInstructions) == [0xB0] && VariableFontInstancer.pointCount(.composite(components: again, instructions: [])) == 2)
        for broken: [UInt8] in [[0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0], [0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0x00, 0x05], [0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x08, 0x00, 0x05, 1, 1]] {
            #expect(throws: VariableFontInstancer.Failure.self) { _ = try VariableFontInstancer.parse(broken[...]) }
        }
        #expect(throws: VariableFontInstancer.Failure.self) { _ = try VariableFontInstancer.gvarHeader([UInt8](repeating: 0, count: 10)) }
        #expect(throws: VariableFontInstancer.Failure.self) { _ = try VariableFontInstancer.gvarHeader([0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 20, 0, 9, 0, 0, 0, 0, 0, 0]) }
    }

    /// TYPE-048's budget: one tuple of a 2,000-glyph font in under 200 ms.
    @Test func instancingAWholeFontIsQuick() throws {
        let font = Self.font(620)
        #expect(CTFontGetGlyphCount(font) >= 2000)
        let start = ContinuousClock.now
        let program = try VariableFontInstancer.instance(of: font, variations: [Self.wght: 620], glyphs: nil)
        let elapsed = ContinuousClock.now - start
        let instance = try Self.loaded(program)
        #expect(CTFontGetGlyphCount(instance) == CTFontGetGlyphCount(font))
        PerfBudget.expect(elapsed, within: .milliseconds(200), "2,221 glyphs of STIX Two Text at wght 620")
    }
}

extension VariableFontInstancer.Axis {
    func with(minimum: Double, maximum: Double) -> Self {
        var copy = self
        copy.minimum = minimum
        copy.maximum = maximum
        return copy
    }
}

extension CTFont {
    /// A font of another family at `size` (the test's shorthand).
    func copy(size: CGFloat, _ name: String) -> CTFont {
        CTFontCreateWithName(name as CFString, size, nil)
    }
}
