// IMG-009: the content-stream interpreter on hand-built PDFs -- colour spaces, patterns and
// shadings, graphics states, clipping, marked content, forms, images and inline images.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct PDFImportContentTests {
    static func fills(_ scene: ImportedScene) -> [Color?] {
        scene.scenePaths.map(\.fill.representativeColor)
    }

    static func near(_ a: Color?, _ b: Color, _ tolerance: Double = 2e-3) -> Bool {
        guard let a, a.space == b.space else { return false }
        let d = a.components - b.components
        return max(abs(d.x), abs(d.y), abs(d.z), abs(d.w)) <= tolerance && abs(a.alpha - b.alpha) <= tolerance
    }

    // MARK: Colour

    @Test func everyColourSpaceBecomesATaggedColour() throws {
        var f = PDFImportFixture()
        let gray = f.stream("/N 1", Data([1, 2, 3]))
        let rgb = f.stream("/N 3", Data([1, 2, 3]))
        let cmyk = f.stream("/N 4", Data([1, 2, 3]))
        let p3 = f.stream("/N 3", PDFImportColorSpace.displayP3Profile)
        let lookup = f.stream("", Data([0, 128, 128, 100, 128, 128]))
        let tint = f.add("<< /FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [0 1 0 0] /N 1 >>")
        let calculator = f.stream("/FunctionType 4 /Domain [0 1 0 1] /Range [0 1 0 1 0 1]", "{ pop dup dup }")
        let spaces = """
        << /ColorSpace << /G1 [/ICCBased \(gray) 0 R] /RGB1 [/ICCBased \(rgb) 0 R] /K1 [/ICCBased \(cmyk) 0 R] /P3 [/ICCBased \(p3) 0 R] \
        /Cal [/CalRGB << /WhitePoint [0.95 1 1.09] >>] /CalG [/CalGray << /WhitePoint [0.95 1 1.09] >>] /Lab [/Lab << /WhitePoint [0.96 1 0.82] /Range [-50 50 -60 60] >>] \
        /Idx [/Indexed /DeviceRGB 1 <FF000000FF00>] /IdxLab [/Indexed [/Lab << /WhitePoint [0.96 1 0.82] >>] 1 \(lookup) 0 R] \
        /Sep [/Separation /Spot /DeviceCMYK \(tint) 0 R] /All [/Separation /All /DeviceGray \(tint) 0 R] /None [/Separation /None /DeviceGray \(tint) 0 R] \
        /DN [/DeviceN [/A /B] /DeviceRGB \(calculator) 0 R] /DNplain [/DeviceN [/A /B /C] /DeviceRGB null] /Bad [/Unknown] /Short [/ICCBased] >> >>
        """
        let rects = [
            "0.5 g", "1 0 0 rg", "0 1 0 0 k", "/G1 cs 0.25 sc", "/RGB1 cs 0 0 1 sc", "/K1 cs 0 0 1 0 sc", "/P3 cs 1 0 0 sc",
            "/Cal cs 0 1 1 sc", "/CalG cs 0.75 sc", "/Lab cs 50 20 -70 sc", "/Idx cs 1 sc", "/IdxLab cs 1 sc", "/Sep cs 0.5 scn",
            "/All cs 1 scn", "/None cs 1 scn", "/DN cs 0.2 0.4 scn", "/DNplain cs 0.1 0.2 0.3 scn", "/Bad cs", "/Short cs", "/DeviceCMYK cs",
        ]
        let content = rects.enumerated().map { "\($1) \($0 * 5) 0 5 5 re f" }.joined(separator: "\n") + "\n0 0 1 RG 2 w 0 0 m 10 10 l S"
        let scene = try PDFImportFixture.importPDF(f.document([.init(content, resources: spaces)]))
        let colors = Self.fills(scene)
        let expected: [Color] = [
            Color(white: 0.5), Color(red: 1, green: 0, blue: 0), Color(cyan: 0, magenta: 1, yellow: 0, black: 0), Color(white: 0.25),
            Color(red: 0, green: 0, blue: 1), Color(cyan: 0, magenta: 0, yellow: 1, black: 0), Color(displayP3Red: 1, green: 0, blue: 0),
            Color(red: 0, green: 1, blue: 1), Color(white: 0.75), Color(labL: 50, a: 20, b: -60), Color(red: 0, green: 1, blue: 0),
            Color(labL: 100 * 100 / 255, a: -100 + 128 / 255 * 200, b: -100 + 128 / 255 * 200), Color(cyan: 0, magenta: 0.5, yellow: 0, black: 0),
            Color(white: 0), Color(white: 0, alpha: 0), Color(red: 0.2, green: 0.2, blue: 0.2), Color(red: 0.1, green: 0.2, blue: 0.3),
            Color(white: 0), Color(white: 0), Color(cyan: 0, magenta: 0, yellow: 0, black: 1),
        ]
        #expect(colors.count == expected.count + 1)
        for (index, (got, want)) in zip(colors, expected).enumerated() {
            #expect(Self.near(got, want), "\(index): \(String(describing: got)) != \(want)")
        }
        let stroke = try #require(scene.scenePaths.last?.stroke)
        #expect(Self.near(stroke.paint.representativeColor, Color(red: 0, green: 0, blue: 1)))
        #expect(stroke.style.width == 2)
    }

    // MARK: Patterns and shadings

    @Test func patternsAndShadingsBecomeGradientsOrFlatFills() throws {
        var f = PDFImportFixture()
        let axial = "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 100 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> >>"
        let stitch = "<< /FunctionType 3 /Domain [0 1] /Functions [<< /FunctionType 2 /C0 [1] /C1 [0] /N 1 >> << /FunctionType 2 /C0 [0] /C1 [1] /N 1 >>] /Bounds [0.5] /Encode [0 1 0 1] >>"
        let radial = "<< /ShadingType 3 /ColorSpace /DeviceGray /Coords [50 50 10 50 50 40] /Function \(stitch) >>"
        let shrinking = "<< /ShadingType 3 /ColorSpace /DeviceGray /Coords [50 50 40 60 50 0] /Function << /FunctionType 2 /C0 [0] /C1 [1] /N 1 >> >>"
        let mesh = "<< /ShadingType 4 /ColorSpace /DeviceGray >>"
        let broken = "<< /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0] /Function << /FunctionType 2 /C0 [0] /C1 [1] >> >>"
        let brokenRadial = "<< /ShadingType 3 /ColorSpace /DeviceGray /Coords [0 0 1] /Function << /FunctionType 2 /C0 [0] /C1 [1] >> >>"
        let resources = """
        << /Pattern << /P1 << /PatternType 2 /Shading \(axial) /Matrix [1 0 0 1 10 0] >> /P2 << /PatternType 2 /Shading \(radial) >> \
        /P3 << /PatternType 1 /PaintType 1 >> /P4 << /PatternType 2 /Shading \(axial) /Matrix [1 0] >> >> \
        /Shading << /S1 \(axial) /S2 \(mesh) /S3 \(shrinking) /S4 \(broken) /S5 \(brokenRadial) /S6 5 >> >>
        """
        let content = """
        /Pattern cs /P1 scn 0 0 50 50 re f
        /P2 scn 0 0 50 50 re f
        /P3 scn 0 0 50 50 re f
        /Missing scn 0 0 50 50 re f
        /P4 scn 0 0 50 50 re f
        /Pattern CS /P1 SCN 0 0 m 50 50 l S
        /S1 sh
        q 10 10 40 40 re W n /S2 sh Q
        /S3 sh /S4 sh /S5 sh /S6 sh /Nope sh
        """
        let scene = try PDFImportFixture.importPDF(f.document([.init(content, resources: resources)]))
        let paths = scene.scenePaths
        #expect(paths.count == 12)
        guard case .gradient(let linear) = paths[0].fill, case .gradient(let circle) = paths[1].fill else {
            Issue.record("expected gradients")
            return
        }
        #expect(linear.kind == .linear && linear.stops.count == 2)
        #expect(linear.axis == Gradient.Axis(start: Point(x: 10, y: 150), end: Point(x: 110, y: 150)))
        #expect(circle.kind == .radial)
        #expect(abs(circle.stops[0].offset - 0.25) < 1e-9)
        #expect(circle.stops.count == 3)
        #expect(circle.axis?.end2 == Point(x: 50, y: 60))
        let mesh10 = Color(cyan: 0, magenta: 0, yellow: 0, black: 0.1)
        #expect(paths[2].fill == .solid(mesh10))
        #expect(paths[3].fill == .solid(.black))
        if case .gradient(let identity) = paths[4].fill {
            #expect(identity.axis?.start == Point(x: 0, y: 150))
        } else {
            Issue.record("P4 is a gradient")
        }
        if case .gradient? = paths[5].stroke?.paint {} else { Issue.record("stroke pattern") }
        // `sh` fills the page, or the clip.
        #expect(Rect(boundingPoints: paths[6].contours[0].allPoints) == Rect(x: 0, y: 0, width: 200, height: 150))
        #expect(Rect(boundingPoints: paths[7].contours[0].allPoints) == Rect(x: 10, y: 100, width: 40, height: 40))
        #expect(paths[7].fill == .solid(mesh10))
        guard case .gradient(let reversed) = paths[8].fill else {
            Issue.record("S3")
            return
        }
        #expect(reversed.stops.first?.color.red == 1)
        #expect(paths[9].fill == .solid(mesh10) && paths[10].fill == .solid(mesh10) && paths[11].fill == .solid(mesh10))
        #expect(scene.notes.contains("Tiling patterns were imported as flat fills."))
        #expect(scene.notes.contains("Shadings other than linear and radial were imported as flat fills."))
        #expect(scene.notes.contains("Radial shadings with a focal point were imported with it at the centre."))
    }

    // MARK: Graphics state and clipping

    @Test func graphicsStatesStrokesAndClipsAreRead() throws {
        var f = PDFImportFixture()
        let maskGroup = f.stream("/Subtype /Form /BBox [0 0 10 10]", "0 0 5 5 re f")
        let lumGroup = f.stream("/Subtype /Form /BBox [0 0 10 10] /Resources << /Shading << /Sh1 << /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 10 0] /Function << /FunctionType 2 /C0 [0] /C1 [1] /N 1 >> >> >> >>", "2 0 0 2 0 0 cm /Sh1 sh")
        let font = f.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let resources = """
        << /ExtGState << /GS1 << /LW 3 /LC 1 /LJ 2 /ML 4 /D [[2 1] 0.5] /CA 0.5 /ca 0.25 /BM /Multiply >> \
        /GS2 << /SMask << /S /Alpha /G \(maskGroup) 0 R >> >> /GS3 << /SMask /None >> /GS4 << /Font [\(font) 0 R 24] >> \
        /GS5 << /SMask << /S /Luminosity /G \(lumGroup) 0 R >> >> /GS6 << /BM /Normal >> >> >>
        """
        let content = """
        q /GS1 gs 1 0 0 RG 0 0 m 10 0 l 10 10 v 20 20 y h S Q
        q 2 J 1 j 7 M [4 2] 1 d 0.5 0 0 2 0 0 cm 0 0 10 10 re s Q
        q 1 w 0 0 m 5 5 l 0 10 l b Q
        q 0 0 m 5 5 l 0 10 l b* B* Q
        0 0 10 10 re B
        0 0 10 10 re f*
        0 0 10 10 re F
        0 0 10 10 re n
        q /GS2 gs /GS6 gs /Missing gs 0 0 10 10 re f /GS3 gs Q
        q 0 0 100 100 re W* n 10 10 50 50 re W n 1 0 0 rg 0 0 10 10 re f 20 20 10 10 re f Q 30 30 5 5 re f
        q /GS4 gs BT (x) Tj ET Q
        q /GS5 gs 0 0 20 20 re f Q
        W n
        q Q Q
        1 2 3 cm
        """
        let scene = try PDFImportFixture.importPDF(f.document([.init(content, resources: resources)]))
        let paths = PDFImportFixture.paths(scene.nodes)
        let first = try #require(paths.first?.stroke)
        #expect(first.style.width == 3 && first.style.cap == .round && first.style.join == .bevel && first.style.miterLimit == 4)
        #expect(first.style.dash == [2, 1] && first.style.dashPhase == 0.5)
        #expect(first.paint.representativeColor?.alpha == 0.5)
        #expect(paths[0].contours[0].closed && paths[0].contours[0].segments.count == 3)
        let second = try #require(paths[1].stroke)
        #expect(second.style.cap == .square && second.style.join == .round && second.style.miterLimit == 7)
        #expect(second.style.dash == [4, 2] && second.style.dashPhase == 1)
        #expect(second.style.width == 1)
        #expect(paths[2].fillRule == .nonZero && paths[2].stroke != nil && paths[2].fill != .none)
        #expect(paths[3].fillRule == .evenOdd)
        #expect(paths.map(\.fillRule).contains(.evenOdd))
        let groups = PDFImportFixture.groups(scene.nodes)
        let outer = try #require(groups.first { $0.clip?.fillRule == .evenOdd })
        guard case .group(let inner)? = outer.children.first else {
            Issue.record("nested clip")
            return
        }
        #expect(inner.clip?.fillRule == .nonZero)
        #expect(inner.children.count == 2)
        #expect(scene.notes.contains("Soft masks were left out; the objects they mask are imported without them."))
        #expect(scene.notes.contains("Blend modes were imported as Normal."))
        #expect(scene.texts == ["x"])
        #expect(PDFImportFixture.texts(scene.nodes).first?.runs.first?.fontSize == 24)
        // A luminosity mask over a flat fill turns it into a gradient of its colour.
        #expect(paths.contains { if case .gradient = $0.fill { return true } else { return false } })
    }

    // MARK: Marked content

    @Test func optionalContentBecomesLayers() throws {
        var f = PDFImportFixture()
        let ocg = f.add("<< /Type /OCG /Name (Layer Two) >>")
        let resources = "<< /Properties << /L1 << /Type /OCG /Name (Layer One) >> /M1 << /Type /OCMD /OCGs \(ocg) 0 R >> /M2 << /Type /OCMD /OCGs [\(ocg) 0 R] >> /X << /Type /OCG >> >> >>"
        let content = """
        /OC /L1 BDC 0 0 10 10 re f EMC
        /OC /M1 BDC 0 0 10 10 re f EMC
        /OC /M2 BDC 0 0 10 10 re f EMC
        /OC << /Name (Inline) >> BDC 0 0 10 10 re f EMC
        /OC /X BDC /OC [1] BDC /OC BDC /Span << /ActualText (x) >> BDC /Tag BMC 0 0 10 10 re f EMC EMC EMC EMC EMC EMC
        /OC /L1 BDC q 0 0 50 50 re W n 0 0 10 10 re f Q EMC
        """
        let scene = try PDFImportFixture.importPDF(f.document([.init(content, resources: resources)]))
        let layers = PDFImportFixture.groups(scene.nodes).filter { $0.role == .layer }
        #expect(layers.map(\.name) == ["Layer One", "Layer Two", "Layer Two", "Inline", "Layer One"])
        guard case .group(let clip)? = layers.last?.children.first else {
            Issue.record("clip inside the layer")
            return
        }
        #expect(clip.clip != nil)
        #expect(scene.nodes.count == 6)
    }

    // MARK: Forms

    @Test func formsNestClipAndCarryGroupOpacity() throws {
        var f = PDFImportFixture()
        let plain = f.stream("/Type /XObject /Subtype /Form /BBox [0 0 50 50] /Matrix [1 0 0 1 10 10]", "0 0 100 100 re f")
        let group = f.stream("/Subtype /Form /BBox [0 0 50 50] /Group << /S /Transparency >> /Resources << /ExtGState << /G << /ca 0.5 >> >> >>", "0 0 10 10 re f /G gs 0 0 5 5 re f")
        let selfNumber = f.objects.count + 1
        f.stream("/Subtype /Form /BBox [0 0 5 5] /Resources << /XObject << /Loop \(selfNumber) 0 R >> >>", "0 0 1 1 re f /Loop Do")
        let postscript = f.stream("/Subtype /PS", "")
        let noBox = f.stream("/Subtype /Form", "0 0 3 3 re f")
        let resources = "<< /XObject << /F1 \(plain) 0 R /F2 \(group) 0 R /F3 \(selfNumber) 0 R /F4 \(postscript) 0 R /F5 \(noBox) 0 R >> /ExtGState << /Half << /ca 0.5 >> >> >>"
        let content = "/F1 Do q /Half gs /F2 Do Q /F3 Do /F4 Do /F5 Do /Nothing Do"
        let scene = try PDFImportFixture.importPDF(f.document([.init(content, resources: resources)]))
        let groups = PDFImportFixture.groups(scene.nodes)
        let clipped = try #require(groups.first)
        #expect(Rect(boundingPoints: clipped.clip!.contours[0].allPoints) == Rect(x: 10, y: 90, width: 50, height: 50))
        let transparent = try #require(groups.first { $0.opacity == 0.5 })
        let inner = PDFImportFixture.paths(transparent.children)
        #expect(inner.map { $0.fill.representativeColor?.alpha } == [1, 0.5])
        #expect(scene.notes.contains("Forms nested more than 16 deep were left out."))
        #expect(PDFImportFixture.paths(scene.nodes).count == 2 + 1 + 16 + 1)
    }

    // MARK: Images

    static func jpeg(width: Int = 4, height: Int = 2) -> Data {
        ImageEncoding.encode(Corpus.image(width: width, height: height), type: .jpeg)!
    }

    @Test func imageXObjectsOfEveryKind() throws {
        var f = PDFImportFixture()
        let smask = f.stream("/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8", Data([128]))
        let rgb = f.stream("/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask \(smask) 0 R", Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]))
        let bilevel = f.stream("/Subtype /Image /Width 8 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 1", Data([0b1010_1010]))
        let mask = f.stream("/Subtype /Image /Width 8 /Height 1 /ImageMask true /Decode [1 0]", Data([0b1111_0000]))
        let indexed = f.stream("/Subtype /Image /Width 2 /Height 1 /ColorSpace [/Indexed /DeviceRGB 1 <FF000000FF00>] /BitsPerComponent 4", Data([0x01]))
        let cmyk = f.stream("/Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceCMYK /BitsPerComponent 8", Data([0, 255, 0, 0]))
        let keyed = f.stream("/Subtype /Image /Width 2 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Mask [0 0 0 0 0 0] /Decode [1 0 1 0 1 0]", Data([0, 0, 0, 255, 255, 255]))
        let stencil = f.stream("/Subtype /Image /Width 8 /Height 1 /BitsPerComponent 1", Data([0b0000_1111]))
        let stenciled = f.stream("/Subtype /Image /Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 16 /Mask \(stencil) 0 R", Data([0, 0, 255, 255]))
        let jpeg = f.stream("/Subtype /Image /Width 4 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", Self.jpeg())
        let jpegMask = f.stream("/Subtype /Image /Width 4 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", Data(repeating: 200, count: 8))
        let jpegAlpha = f.stream("/Subtype /Image /Width 4 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /SMask \(jpegMask) 0 R", Self.jpeg())
        let odd = f.stream("/Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 3", Data([0]))
        let lab = f.stream("/Subtype /Image /Width 1 /Height 1 /ColorSpace [/Lab << /WhitePoint [0.96 1 0.82] >>] /BitsPerComponent 8", Data([255, 128, 128]))
        let brokenJPEG = f.stream("/Subtype /Image /Width 1 /Height 1 /Filter /DCTDecode /SMask \(smask) 0 R", Data([1, 2, 3]))
        let names = [rgb, bilevel, mask, indexed, cmyk, keyed, stenciled, jpeg, jpegAlpha, odd, lab, brokenJPEG]
        let resources = "<< /XObject << \(names.enumerated().map { "/Im\($0) \($1) 0 R" }.joined(separator: " ")) >> >>"
        let content = "0 0 1 rg " + names.indices.map { "q 20 0 0 10 \($0 * 10) 0 cm /Im\($0) Do Q" }.joined(separator: " ")
        let scene = try PDFImportFixture.importPDF(f.document([.init(content, resources: resources)]))
        let images = scene.images
        #expect(images.count == 10)
        let first = images[0]
        #expect(first.pixels.width == 2 && first.pixels.hasAlpha && first.pixels.mode == .rgb)
        #expect(first.transform.apply(Point(x: 0, y: 0)).distance(to: Point(x: 0, y: 140)) < 1e-9)
        #expect(first.transform.apply(Point(x: first.naturalRect.maxX, y: first.naturalRect.maxY)).distance(to: Point(x: 20, y: 150)) < 1e-9)
        #expect(images[1].pixels.mode == .grayscale && !images[1].pixels.hasAlpha)
        #expect(images[2].pixels.hasAlpha)
        #expect(images[3].pixels.width == 2)
        #expect(images[4].pixels.mode == .cmyk)
        #expect(images[4].pixels.blob.uti == "public.tiff")
        #expect(images[5].pixels.hasAlpha)
        #expect(images[6].pixels.hasAlpha)
        #expect(images[7].pixels.blob.uti == "public.jpeg")
        #expect(images[8].pixels.hasAlpha && images[8].pixels.blob.uti == "public.png")
        #expect(images[9].pixels.width == 1)
        // The pixels decode as the file says.
        let decoded = RGBAPixels(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(images[0].pixels.blob.data as CFData, nil)!, 0, nil)!)
        #expect(Array(decoded.bytes.prefix(4)) == [255, 0, 0, 128])
        let masked = RGBAPixels(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(images[2].pixels.blob.data as CFData, nil)!, 0, nil)!)
        #expect(masked.bytes[3] == 255 && masked.bytes[7 * 4 + 3] == 0 && masked.bytes[2] == 255)
        let key = RGBAPixels(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(images[5].pixels.blob.data as CFData, nil)!, 0, nil)!)
        #expect(key.bytes[3] == 0 && key.bytes[7] == 255)
    }

    @Test func inlineImagesWithTheirFilters() throws {
        var content = Data()
        func add(_ text: String) { content.append(Data(text.utf8)) }
        add("q 10 0 0 10 0 0 cm BI /W 2 /H 1 /CS /RGB /BPC 8 /F /AHx ID FF000000FF00> EI Q\n")
        add("q 10 0 0 10 10 0 cm BI /W 1 /H 1 /CS /G /BPC 8 /F [/A85] ID J,~> EI Q\n")
        add("q 10 0 0 10 20 0 cm BI /W 1 /H 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /Fl ID ")
        content.append(Zlib.compress(Data([77])))
        add(" EI Q\n")
        add("q 10 0 0 10 30 0 cm BI /W 3 /H 1 /CS /G /BPC 8 /F /RL ID ")
        content.append(Data([1, 10, 20, 254, 30, 128]))
        add(" EI Q\n")
        add("q 10 0 0 10 40 0 cm BI /W 2 /H 1 /CS [/I /RGB 1 <FF00000000FF>] /BPC 8 ID ")
        content.append(Data([0, 1]))
        add(" EI Q\n")
        add("q 10 0 0 10 50 0 cm BI /W 4 /H 2 /CS /RGB /BPC 8 /F /DCT ID ")
        content.append(Self.jpeg())
        add(" EI Q\n")
        add("q 10 0 0 10 60 0 cm BI /W 8 /H 1 /IM true ID ")
        content.append(Data([0x0F]))
        add(" EI Q\n")
        add("q 10 0 0 10 70 0 cm BI /W 1 /H 1 /CS /I /BPC 8 ID ")
        content.append(Data([0]))
        add(" EI Q\n")
        add("q BI /W 1 /H 1 /F /LZW ID xx EI Q\n")
        add("q BI /W 1 /H 1 /CS /G /BPC 8 /F [/AHx /A85 /Fl] ID <EI Q")
        var f = PDFImportFixture()
        let scene = try PDFImportFixture.importPDF(f.document([.init(data: content)]))
        let images = scene.images
        #expect(images.count == 9)
        #expect(images.map(\.pixels.width) == [2, 1, 1, 3, 2, 4, 8, 1, 1])
        let flate = RGBAPixels(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(images[2].pixels.blob.data as CFData, nil)!, 0, nil)!)
        #expect(flate.bytes[0] == 77)
        let a85 = RGBAPixels(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(images[1].pixels.blob.data as CFData, nil)!, 0, nil)!)
        #expect(a85.bytes[0] == 0x80)
        let runs = RGBAPixels(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(images[3].pixels.blob.data as CFData, nil)!, 0, nil)!)
        #expect([runs.bytes[0], runs.bytes[4], runs.bytes[8]] == [10, 20, 30])
        #expect(scene.notes.contains("Inline images with LZW compression were left out."))
    }

    @Test func filtersDecodeEdgeCases() {
        #expect(PDFImportImage.asciiHex(Data("4 1 4>zz".utf8)) == Data([0x41, 0x40]))
        #expect(PDFImportImage.ascii85(Data("z<~".utf8)) == Data([0, 0, 0, 0]))
        let hello = Data("Hello World".utf8)
        #expect(PDFImportImage.ascii85(Data(ASCII85.encode(hello).utf8)) == hello)
        #expect(PDFImportImage.inflate(Data([1])) == Data())
        #expect(PDFImportImage.runLength(Data([255])) == Data())
        #expect(PDFImportImage.runLength(Data([2, 1])) == Data([1]))
    }
}
