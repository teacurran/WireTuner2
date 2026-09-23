// IMG-009 and IMG-010: malformed and unusual input -- missing operands and entries, odd colour
// spaces, broken streams, fonts without names or glyphs -- is read without a crash and with the
// documented defaults.

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct PDFImportRobustnessTests {
    @Test func missingOperandsAndEntriesReadAsDefaults() throws {
        var f = PDFImportFixture()
        let broken = f.stream("/Filter /FlateDecode", Data([1, 2, 3, 4]))
        let noSize = f.stream("/Subtype /Image /ColorSpace /DeviceGray", Data([0]))
        let maskNoEntries = f.stream("/Subtype /Image", Data([0xFF]))
        let smallMask = f.stream("/Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /Decode [1]", Data([0]))
        let masked = f.stream("/Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /SMask \(smallMask) 0 R", Data([9]))
        let noEntriesMasked = f.stream("/Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /SMask \(maskNoEntries) 0 R", Data([9]))
        let patternImage = f.stream("/Subtype /Image /Width 1 /Height 1 /ColorSpace /Pattern /BitsPerComponent 8", Data([0]))
        let brokenImage = f.stream("/Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", Data([9, 9]))
        let form = f.stream("/Subtype /Form /Matrix [1 0]", "0 0 1 1 re f")
        let proc = f.stream("", "BT /H 1000 Tf (x) Tj ET")
        let fonts = """
        /T3 << /Subtype /Type3 /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /A \(proc) 0 R >> /Encoding << /BaseEncoding /WinAnsiEncoding >> /FirstChar 65 /Widths [500] /Resources << /Font << /H << /Subtype /Type1 /BaseFont /Helvetica >> >> >> >> \
        /Anon << /Subtype /TrueType /Encoding << /BaseEncoding /WinAnsiEncoding >> >> /Bare << /BaseFont /Helvetica >> \
        /Plain << /Subtype /TrueType /BaseFont /AndaleMono /FontDescriptor << /FontFile2 \(try f.fontProgram()) 0 R >> >>
        """
        let resources = """
        << /XObject << /N \(noSize) 0 R /M \(masked) 0 R /E \(noEntriesMasked) 0 R /P \(patternImage) 0 R /B \(brokenImage) 0 R /F \(form) 0 R >> \
        /ExtGState << /D << /D [[1]] >> /Font << /Font [\(f.objects.count + 1) 0 R] >> >> /Font << \(fonts) >> \
        /Pattern << /Tile << /PaintType 1 >> >> >>
        """
        _ = broken
        let content = """
        BT (orphan) Tj ET
        d [1] (x) d 10 10 20 20 v f 1 1 m
        BT /Bare 10 Tf Tj TJ ' " [(a) true (b)] TJ 3 Tw (a b) Tj ET
        BT /T3 10 Tf (AB) Tj ET
        BT /Anon 10 Tf (anon) Tj ET
        BT /Plain 10 Tf 3 Tr (A) Tj 0 Tr ET
        /D gs /Font gs
        /Pattern cs /Tile scn q 10 0 0 10 0 0 cm BI /W 8 /H 1 /IM true ID \u{0F} EI Q 0 0 5 5 re f
        /N Do /M Do /E Do /P Do /B Do /F Do
        BI ID EI
        BI /W 1 /H 1 /CS [/Indexed /RGB () <00FF00>] /D [1 0] ID \u{00} EI
        BI /W 1 /H 1 /CS [/I /Nope 1 <00>] ID \u{00} EI
        BI /W 1 /H 1 /CS 5 ID \u{00} EI
        """
        let data = f.document([.init(content, resources: resources)])
        let scene = try PDFImportFixture.importPDF(data)
        let outlined = try PDFImportFixture.importPDF(data, PDFImportOptions(text: .outlines))
        #expect(scene.texts.contains("anon"))
        #expect(PDFImportFixture.texts(scene.nodes).first { $0.string == "anon" }?.runs.first?.fontName == "Helvetica")
        #expect(scene.texts.contains("aba b"))
        #expect(!scene.texts.contains("orphan"))
        #expect(scene.images.count >= 4)
        #expect(!PDFImportFixture.paths(outlined.nodes).isEmpty)
        // Broken streams read as empty content rather than failing the import.
        var g = PDFImportFixture()
        var page = PDFImportFixture.Page("")
        page.contents = [g.stream("/Filter /FlateDecode", Data([1, 2, 3]))]
        #expect(try PDFImportFixture.importPDF(g.document([page])).nodes.isEmpty)
        var h = PDFImportFixture()
        var none = PDFImportFixture.Page("")
        none.contents = [0]
        #expect(try PDFImportFixture.importPDF(h.document([none])).nodes.isEmpty)
    }

    @Test func unusualFontsDecodeOrOutline() throws {
        var f = PDFImportFixture()
        let program = try f.fontProgram()
        let map = f.stream("", Data([0, 0, 0, 36]))
        let fonts = """
        /Plain << /Subtype /TrueType /BaseFont /AndaleMono /FontDescriptor << /FontFile2 \(program) 0 R >> >> \
        /Sym << /Subtype /TrueType /BaseFont /AndaleMono /FontDescriptor << /Flags 4 /FontFile2 \(program) 0 R >> >> \
        /Short << /Subtype /Type0 /Encoding /Identity-H /DescendantFonts [<< /Subtype /CIDFontType2 /CIDToGIDMap \(map) 0 R /FontDescriptor << /FontFile2 \(program) 0 R >> >>] >> \
        /NoType << /BaseFont /Helvetica /Encoding << /BaseEncoding /WinAnsiEncoding >> >>
        """
        let content = "BT /Plain 10 Tf (A) Tj /Sym 10 Tf <01> Tj /Short 10 Tf <00010005> Tj /NoType 10 Tf (z) Tj ET"
        let scene = try PDFImportFixture.importPDF(f.document([.init(content, resources: "<< /Font << \(fonts) >> >>")]), PDFImportOptions(text: .outlines))
        #expect(!PDFImportFixture.paths(scene.nodes).isEmpty)
        #expect(PDFImportFont.unicode(glyphName: ".") == nil)
        var path = CGMutablePath()
        path.move(to: .zero)
        path.addCurve(to: CGPoint(x: 3, y: 0), control1: CGPoint(x: 1, y: 1), control2: CGPoint(x: 2, y: 1))
        path.addQuadCurve(to: CGPoint(x: 4, y: 4), control: CGPoint(x: 4, y: 0))
        path.closeSubpath()
        let contours = PDFImportPaths.contours(of: path)
        #expect(contours.count == 1 && contours[0].segments.count == 2 && contours[0].closed)
    }

    @Test func unusualColourSpacesAndShadings() throws {
        var f = PDFImportFixture()
        let noN = f.stream("", Data([0]))
        let spaces = """
        /ColorSpace << /A [/ICCBased \(noN) 0 R] /B [/Lab << >>] /C [/Lab << /Range [1 2] >>] /D [/Indexed /Nope 1 <00>] /E [/Indexed /DeviceRGB] \
        /F [/Indexed /DeviceRGB 1 5] /G [/Separation /S /Nope] /H [/Separation 5 /DeviceGray] /I [/DeviceN [/A] /Nope] /J [/DeviceN 5 /DeviceGray] >>
        """
        let labShading = "<< /ShadingType 2 /ColorSpace [/Lab << >>] /Coords [0 0 10 0] /Domain [0] /Function << /FunctionType 2 /C0 [0 -50 0] /C1 [100 50 0] >> >>"
        let patternShading = "<< /ShadingType 2 /ColorSpace /Pattern /Coords [0 0 10 0] /Function << /C0 [0] >> >>"
        let untyped = "<< /ColorSpace /DeviceGray >>"
        let patternFunction = "<< /ShadingType 2 /ColorSpace /Pattern /Coords [0 0 10 0] /Function << /FunctionType 2 /C0 [0] /C1 [1] >> >>"
        let resources = "<< \(spaces) /Shading << /L \(labShading) /P \(patternShading) /U \(untyped) /Q \(patternFunction) >> >>"
        let content = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J"].map { "/\($0) cs 0.5 sc 0 0 1 1 re f" }.joined(separator: " ") + " /L sh /P sh /U sh /Q sh"
        let scene = try PDFImportFixture.importPDF(f.document([.init(content, resources: resources)]))
        let paths = scene.scenePaths
        #expect(paths.count == 14)
        guard case .gradient(let lab) = paths[10].fill else {
            Issue.record("lab gradient")
            return
        }
        #expect(lab.stops.first?.color.space == .lab && lab.stops.count >= 2)
        if case .gradient(let black) = paths[13].fill {
            #expect(black.stops.allSatisfy { $0.color == .black })
        } else {
            Issue.record("pattern-space shading")
        }
    }

    @Test func softMasksOfEveryShape() throws {
        var f = PDFImportFixture()
        func group(_ shading: String, content: String = "/Sh sh", extra: String = "") -> Int {
            f.stream("/Subtype /Form /BBox [0 0 10 10] \(extra) /Resources << /Shading << /Sh \(shading) >> >>", content)
        }
        let ramp = "<< /FunctionType 2 /C0 [0] /C1 [1] >>"
        let matrix = group("<< /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 10 0] /Domain [0] /Function \(ramp) >>", extra: "/Matrix [2 0 0 2 0 0]")
        let noFunction = group("<< /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 10 0] >>")
        let typeOne = group("<< /ShadingType 1 /ColorSpace /DeviceGray /Function \(ramp) >>")
        let pattern = group("<< /ShadingType 2 /ColorSpace /Pattern /Coords [0 0 10 0] /Function \(ramp) >>")
        let two = group("<< /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 10 0] /Function \(ramp) >>", content: "/Sh sh /Sh sh")
        let states = [matrix, noFunction, typeOne, pattern, two].enumerated().map { "/M\($0) << /SMask << /S /Luminosity /G \($1) 0 R >> >>" }.joined(separator: " ")
        let axial = "<< /PatternType 2 /Shading << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 10 0] /Function << /FunctionType 2 /C0 [1 0 0] /C1 [0 0 1] >> >> >>"
        let content = (0..<5).map { "q /M\($0) gs 1 0 0 rg 0 0 5 5 re f /Pattern cs /P scn 0 0 5 5 re f Q" }.joined(separator: " ")
        let scene = try PDFImportFixture.importPDF(f.document([.init(content, resources: "<< /ExtGState << \(states) >> /Pattern << /P \(axial) >> >>")]))
        let fills = scene.scenePaths.map(\.fill)
        #expect(fills.count == 10)
        guard case .gradient(let masked) = fills[0] else {
            Issue.record("masked flat fill")
            return
        }
        #expect(masked.axis?.end == Point(x: 20, y: 150))
        // A mesh mask keeps the flat fill; a pattern-space mask reads black, so fully clear.
        #expect(fills[4] == .solid(Color(red: 1, green: 0, blue: 0)))
        if case .gradient(let clear) = fills[7] {
            #expect(clear.stops.allSatisfy { $0.color.alpha == 0 })
        } else {
            Issue.record("pattern mask")
        }
        #expect(scene.notes.contains("Soft masks were left out; the objects they mask are imported without them."))
    }

    @Test func calculatorAndFunctionEdges() {
        #expect(PDFImportFunction.interpolate(5, 1, 1, 7, 9) == 7)
        #expect(PDFImportFunction.array([.exponential(domain: [0, 1], c0: [], c1: [], exponent: 1)]).evaluate([0]) == [0])
        #expect(PDFImportFunction.stitching(domain: [0, 1], functions: [.exponential(domain: [0, 1], c0: [0], c1: [1], exponent: 1)], bounds: [], encode: []).evaluate([]) == [0])
        let calculator = PDFImportFunction.calculator(domain: [0, 1], range: [0, 1], program: [.keyword("pop"), .bool(true)])
        #expect(calculator.evaluate([0.5, 0.5]) == [0])
        let cases: [(String, [PDFImportOperand])] = [
            ("1 { 2 } if", []), ("true { 1 } { 2 } ifelse", [.number(1)]), ("eq", [.bool(true)]), ("and", [.number(0)]),
            ("not", [.number(-1)]), ("/a 1 and", [.number(0)]), ("/a not", [.number(-1)]), ("false true and", [.bool(false)]),
            ("false true or", [.bool(true)]), ("true false xor", [.bool(true)]),
        ]
        for (program, expected) in cases {
            #expect(PDFImportParsingTests.run(program) == expected, "\(program)")
        }
        var parser = PDFImportParser(Data("% c\n1 m".utf8), keepComments: true)
        var ops: [String] = []
        parser.forEachOperator { op, _ in ops.append(op) }
        #expect(ops == ["m"])
        let value = PDFImportValue.string(Data([1]))
        #expect(value.string == Data([1]))
        #expect(PDFImportValue.name("x").operand == .name("x"))
    }

    @Test func legacyIllustratorEdges() throws {
        let file = """
        %!PS-Adobe-3.0
        %%BoundingBox: 0 0 100 100
        10 10 20 20 v f m
        0 d /_Helvetica Tf Tl (loose) Tx
        1 XR *u 0 0 m 1 1 l S *U
        0 0 XI
        %AI5_BeginRaster
        %AI5_EndRaster
        [1 0 0 1 0 100] 0 0 1 1 1 1 8 3 0 0 0 0 XI
        %AI5_BeginRaster
        %FF0000
        %AI5_EndRaster
        [1 0 0 1 0 100] 0 0 1 1 1 1 8 4 0 0 0 0 XI
        %AI5_BeginRaster
        %00FF0000
        %AI5_EndRaster
        0 To /_Helvetica 0 Tf (zero) Tx TO
        """
        let scene = try IllustratorImportTests.convert(Data(file.utf8), PDFImportOptions(text: .outlines))
        let paths = scene.scenePaths
        #expect(paths.contains { $0.fillRule == .evenOdd && $0.stroke != nil && $0.fill == .none })
        #expect(scene.images.map(\.pixels.mode) == [.rgb, .cmyk])
        let editable = try IllustratorImportTests.convert(Data(file.utf8))
        #expect(editable.texts.contains("loose"))
    }
}

extension PDFImportFixture {
    /// Adds the Andale Mono program as a `FontFile2` stream.
    mutating func fontProgram() throws -> Int {
        let program = try Data(contentsOf: URL(fileURLWithPath: PDFImportTextTests.fontFile))
        return stream("/Length1 \(program.count)", program)
    }
}
