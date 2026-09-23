// IO-018: the EPS writer.  Every corpus page is interpreted by Ghostscript and held to the Core
// Graphics reference renderer's pixels; structure (DSC comments, fonts, shadings, the binary
// header) is checked on the text.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct EPSTests {
    static func export(_ page: ExportPage, options: EPSOptions = EPSOptions(), info: ExportDocumentInfo = ExportDocumentInfo(), assets: [String: ExportAsset] = [:]) throws -> (data: Data, notes: [String], text: String) {
        let result = try EPSExporter().data(scene: Corpus.scene([page], assets: assets, info: info), page: 0, options: options)
        return (result.data, result.notes, String(decoding: result.data, as: UTF8.self))
    }

    static func write(_ data: Data, _ name: String) -> URL {
        let url = Corpus.directory().appendingPathComponent(name + ".eps")
        try! data.write(to: url)
        return url
    }

    /// Ghostscript's rendering of `data` at 144 ppi against the reference at 2×.
    static func compare(_ data: Data, page: ExportPage, name: String, tolerance: Int = 40, limit: Double = 0.03, reference: CGImage? = nil) throws {
        let url = write(data, name)
        let rendered = try Ghostscript.render(url, ppi: 144)
        let image = try #require(rendered.image, "gs failed: \(rendered.output)")
        #expect(!rendered.output.contains("Error"), "\(rendered.output)")
        let reference = reference ?? Corpus.reference(page, scale: 2)
        let failing = Corpus.difference(reference, image, tolerance: tolerance)
        if failing > limit {
            Corpus.dump(image, "eps-\(name)")
            Corpus.dump(reference, "eps-\(name)-reference")
        }
        #expect(failing <= limit, "\(name): \(failing)")
    }

    @Test(.enabled(if: Ghostscript.isAvailable), arguments: Corpus.fixtures)
    func ghostscriptRendersTheCorpusLikeTheLivePage(_ name: String) throws {
        let page = Corpus.fixture(name)
        let result = try Self.export(page)
        try Self.compare(result.data, page: page, name: name)
    }

    @Test(.enabled(if: Ghostscript.isAvailable))
    func levelTwoBandsGradients() throws {
        let page = Corpus.fixture("gradients")
        let result = try Self.export(page, options: EPSOptions(level: .level2, gradientSteps: 128))
        #expect(!result.text.contains("shfill"))
        #expect(result.text.contains("%%LanguageLevel: 2"))
        #expect(result.notes.contains { $0.contains("stepped bands") })
        try Self.compare(result.data, page: page, name: "gradients-level2", limit: 0.05)
    }

    @Test(.enabled(if: Ghostscript.isAvailable))
    func imagesAndPlacedJPEGs() throws {
        let photo = Corpus.image(width: 64, height: 48)
        let assets = ["alpha": ExportAsset(image: Corpus.image(alpha: true)), "photo": ExportAsset(image: photo, jpegData: Corpus.jpeg(photo))]
        let page = Corpus.page([
            Corpus.path(Corpus.rect(0, 0, 200, 150), [Corpus.fill(.solid(Corpus.yellow))]),
            .image(ImageItem(assetID: "alpha", rect: Rect(x: 10, y: 10, width: 64, height: 48))),
            .image(ImageItem(assetID: "photo", rect: Rect(x: 90, y: 10, width: 96, height: 72))),
        ])
        let level3 = try Self.export(page, assets: assets)
        #expect(level3.text.contains("/DCTDecode"))
        #expect(level3.text.contains("/FlateDecode"))
        // The reference renderer draws placeholders; placed images are held to the flattened page.
        let flat = EPSExporter.flattener(options: EPSOptions(), scene: Corpus.scene([page], assets: assets)).flatten(page, scene: Corpus.scene([page], assets: assets)).page
        let reference = try #require(FlatRenderer().render(flat, scale: 2, background: .white))
        try Self.compare(level3.data, page: page, name: "images", limit: 0.05, reference: reference)
        let level2 = try Self.export(page, options: EPSOptions(level: .level2), assets: assets)
        #expect(level2.text.contains("/RunLengthDecode"))
        try Self.compare(level2.data, page: page, name: "images-level2", limit: 0.05, reference: reference)
        let cmyk = try Self.export(page, options: EPSOptions(colors: .convertToCMYK), assets: assets)
        #expect(!cmyk.text.contains("/DCTDecode"))
        #expect(cmyk.text.contains("/DeviceCMYK setcolorspace"))
        #expect(!cmyk.text.contains(" rg\n"))
        let url = Self.write(cmyk.data, "cmyk")
        #expect(try Ghostscript.check(url).status == 0)
    }

    @Test(.enabled(if: Ghostscript.isAvailable))
    func fontsEmbedAsType42OrAreOutlined() throws {
        let page = Corpus.page([
            Corpus.text("Type 42 text"),
            Corpus.text("Kohinoor", font: "KohinoorDevanagari-Regular", origin: Point(x: 10, y: 70)),
            Corpus.text("Restricted", font: "LucidaGrande", origin: Point(x: 10, y: 100)),
        ])
        let result = try Self.export(page)
        #expect(result.text.contains("/FontType 42 def"))
        #expect(result.text.contains("%%DocumentSuppliedResources: font WT+Helvetica"))
        #expect(result.text.contains("xshow"))
        #expect(result.notes.contains("font LucidaGrande does not allow embedding; its text is outlined"))
        #expect(result.notes.contains { $0.hasPrefix("font KohinoorDevanagari-Regular has no TrueType outlines") })
        try Self.compare(result.data, page: page, name: "fonts")
        let full = try Self.export(Corpus.page([Corpus.text("Full")]), options: EPSOptions(fonts: .embedFull))
        #expect(full.data.count > result.data.count)
        let outlined = try Self.export(Corpus.page([Corpus.text("Outlined")]), options: EPSOptions(fonts: .outlines))
        #expect(!outlined.text.contains("FontType"))
        #expect(outlined.notes.contains("1 text run converted to outlines"))
    }

    @Test(.enabled(if: Ghostscript.isAvailable))
    func referencedFontsAndPlacedGlyphs() throws {
        var run = Corpus.run("Wide", horizontalScale: 1.5)
        run.glyphs[1].transform = AffineTransform.rotation(radians: 0.3).concatenating(.translation(x: run.glyphs[1].position.x, y: 40))
        run.glyphs[2].position.y += 3
        let placed = DisplayItem.text(TextRunItem(text: "Wide", glyphRun: run, origin: Point(x: 10, y: 40)))
        let page = Corpus.page([placed, Corpus.text("Café", origin: Point(x: 10, y: 90)), Corpus.text("ﬁ ✓", origin: Point(x: 10, y: 130))])
        let result = try Self.export(page, options: EPSOptions(fonts: .reference))
        #expect(result.text.contains("%%DocumentNeededResources: font Helvetica"))
        #expect(result.text.contains("%%IncludeResource: font Helvetica"))
        #expect(result.text.contains("ISOLatin1Encoding"))
        #expect(result.notes.contains { $0.contains("outside ISO Latin-1") })
        let url = Self.write(result.data, "reference")
        #expect(try Ghostscript.check(url).status == 0)
        let embedded = try Self.export(Corpus.page([placed]))
        try Self.compare(embedded.data, page: Corpus.page([placed]), name: "placed-glyphs")
        // More than 256 glyphs of one font need a second Type 42 resource.
        let font = GlyphFont(postScriptName: "Helvetica", size: 10)
        let glyphs = (1...300).map { PositionedGlyph(glyph: CGGlyph($0), position: Point(x: Double($0 % 30) * 6, y: Double($0 / 30) * 12 + 12)) }
        let many = try Self.export(Corpus.page([.text(TextRunItem(text: "glyphs", glyphRun: GlyphRun(font: font, glyphs: glyphs), origin: .zero))]))
        #expect(many.text.contains("/FontName /WT+Helvetica-1 def"))
        #expect(try Ghostscript.check(Self.write(many.data, "many")).status == 0)
    }

    @Test func previewHeaderAndDocumentInfo() throws {
        let info = ExportDocumentInfo(title: "Poster ✓ (A)", author: "Tea", subject: "Subject", description: "Desc", keywords: ["a", "b"], language: "en")
        let result = try Self.export(Corpus.fixture("basics"), options: EPSOptions(preview: .tiff72, embedPackage: true), info: info)
        let data = result.data
        #expect(data.prefix(4) == Data([0xC5, 0xD0, 0xD3, 0xC6]))
        func word(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24 }
        #expect(word(4) == 30)
        let postscript = String(decoding: data[30..<(30 + word(8))], as: UTF8.self)
        #expect(postscript.hasPrefix("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 200 150\n"))
        #expect(postscript.contains("%%Title: (Poster \\342\\234\\223 \\(A\\))"))
        #expect(postscript.contains("%%For: Tea"))
        #expect(postscript.contains("%WTKeywords: a, b"))
        #expect(postscript.hasSuffix("%%EOF\n"))
        let tiff = data[word(20)..<(word(20) + word(24))]
        let source = try #require(CGImageSourceCreateWithData(Data(tiff) as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 200 && image.height == 150)
        #expect(result.notes.contains { $0.contains("IO-028") })
        let big = try Self.export(Corpus.fixture("basics"), options: EPSOptions(preview: .tiff144))
        #expect(big.data.count > data.count)
        let bare = try Self.export(Corpus.fixture("basics"), options: EPSOptions(includeDocumentInfo: false), info: info)
        #expect(!bare.text.contains("%%For"))
        #expect(bare.text.contains("%%Title: Corpus"))
        #expect(EPSBuild.dscText("plain") == "plain")
    }

    @Test(.enabled(if: Ghostscript.isAvailable))
    func overprintCMYKAndBackground() throws {
        var page = Corpus.page([
            Corpus.path(Corpus.rect(10, 10, 50, 50), [Corpus.fill(.solid(Corpus.blue), overprint: true)]),
            Corpus.path(Corpus.rect(70, 10, 50, 50), [Corpus.fill(.solid(Color(red: 1.2, green: 0, blue: 0)))]),
            Corpus.path(Corpus.wave(10, 70, 150, 40), [Corpus.stroke(Corpus.gradient(.linear), width: 6)]),
            Corpus.path(Corpus.ellipse(130, 70, 60, 60), [Corpus.fill(Corpus.gradient(.radial))]),
        ], background: Color(red: 0.9, green: 0.95, blue: 1))
        page.name = "Plate"
        // The reference shows the wide red as the EPS writes it: gamut-mapped into sRGB.
        var mapped = page.displayList.items
        mapped[1] = Corpus.path(Corpus.rect(70, 10, 50, 50), [Corpus.fill(.solid(ColorMath.sRGBFallback(Color(red: 1.2, green: 0, blue: 0))))])
        var renderer = CoreGraphicsRenderer(background: page.background)
        renderer.rasterPreview = .document
        let reference = try #require(renderer.renderBitmap(DisplayList(canvas: "page", items: mapped), viewport: Viewport(size: Size(width: 200, height: 150)), scale: 2))
        let result = try Self.export(page)
        #expect(result.text.contains("true setoverprint"))
        #expect(result.notes.contains("1 wide-gamut color gamut-mapped into sRGB (EPS has no Display P3)"))
        try Self.compare(result.data, page: page, name: "overprint", reference: reference)
        let off = try Self.export(page, options: EPSOptions(preserveOverprint: false))
        #expect(!off.text.contains("setoverprint"))
        let cmyk = try Self.export(page, options: EPSOptions(colors: .convertToCMYK))
        #expect(cmyk.text.contains("/DeviceCMYK"))
        #expect(cmyk.notes.contains("colors converted to CMYK with the \(ProfileCMYKConverter().name) profile"))
        #expect(try Ghostscript.check(Self.write(cmyk.data, "cmyk-vector")).status == 0)
        let banded = try Self.export(page, options: EPSOptions(level: .level2, gradientSteps: 64))
        try Self.compare(banded.data, page: page, name: "overprint-level2", limit: 0.05, reference: reference)
        let bandedCMYK = try Self.export(page, options: EPSOptions(level: .level2, colors: .convertToCMYK))
        #expect(try Ghostscript.check(Self.write(bandedCMYK.data, "cmyk-level2")).status == 0)
    }

    @Test func sfntsChunksRespectTableAndGlyphBoundaries() throws {
        let helvetica = GlyphFont(postScriptName: "Helvetica", size: 1000).ctFont
        let program = try #require(FontProgram.trueTypeSubset(of: helvetica, glyphs: Set((0..<200).map { CGGlyph($0) })))
        // Tables other than glyf are never cut, so the limit binds only where glyphs can split.
        let limit = 4096
        let chunks = PSFontRegistry.sfntsChunks(program, limit: limit)
        let glyfLength = Int(try #require(FontProgram.table("glyf", of: helvetica)).count)
        #expect(chunks.count > 2)
        #expect(chunks.reduce(0) { $0 + $1.count } == program.count)
        #expect(chunks.allSatisfy { $0.count % 2 == 0 })
        #expect(chunks.filter { $0.count <= limit }.count >= 3)
        #expect(glyfLength > limit)
        #expect(PSFontRegistry.sfntsChunks(program).count >= 1)
        #expect(PSFontRegistry.latin1Codes(glyphs: 2, text: "é") == nil)
        #expect(PSFontRegistry.latin1Codes(glyphs: 1, text: "é") == [0xE9])
    }

    @Test func optionsFilesAndErrors() throws {
        let page = Corpus.fixture("basics")
        for options in [EPSOptions(rasterPPI: -1), EPSOptions(gradientSteps: 1)] {
            #expect(throws: ExportError.self) { try EPSExporter().data(scene: Corpus.scene([page]), page: 0, options: options) }
        }
        #expect(throws: ExportError.nothingToExport) { try EPSExporter().data(scene: Corpus.scene([page]), page: 3, options: EPSOptions()) }
        let directory = Corpus.directory()
        let summary = try EPSExporter().export(scene: Corpus.scene([page, Corpus.fixture("text")]), options: EPSOptions(), to: ExportDestination(url: directory.appendingPathComponent("art.eps"), namePattern: .standard))
        #expect(summary.files.map(\.lastPathComponent) == ["art-1.eps", "art-2.eps"])
        #expect(throws: ExportError.nothingToExport) { try EPSExporter().export(scene: Corpus.scene([]), options: EPSOptions(), to: ExportDestination(url: directory.appendingPathComponent("x.eps"))) }
        #expect(throws: ExportError.wrongOptions(format: .eps)) { try EPSExporter().export(scene: Corpus.scene([page]), options: PDFOptions(), to: ExportDestination(url: directory.appendingPathComponent("x.eps"))) }
        #expect(throws: ExportError.self) { try EPSExporter().export(scene: Corpus.scene([page]), options: EPSOptions(), to: ExportDestination(url: URL(fileURLWithPath: "/nonexistent-folder/x.eps"))) }
        #expect(EPSExporter().optionsType is EPSOptions.Type)
        #expect(EPSExporter().capabilities == ExportFormat.eps.capabilities)
        #expect(EPSOptions.defaults == EPSOptions())
        #expect(EPSOptions.Level.allCases.map(\.rawValue) == [2, 3])
    }

    @Test func byteEncoders() {
        #expect(ASCII85.encode(Data()) == "~>")
        #expect(ASCII85.encode(Data([0, 0, 0, 0])) == "z\n~>")
        #expect(ASCII85.encode(Data("Man ".utf8)) == "9jqo^\n~>")
        #expect(ASCII85.encode(Data([0x0C, 0x80, 0x00, 0x00]), lineLength: 64).hasPrefix(" %"))
        #expect(HexLines.encode(Data([0xAB, 0x01, 0x02]), bytesPerLine: 2) == "AB01\n02")
        let sample: [UInt8] = [1, 1, 1, 2, 3, 4, 4] + [UInt8](repeating: 9, count: 200) + (0..<150).map { UInt8($0) }
        let packed = PackBits.encode(sample)
        #expect(PackBits.decode(packed) == sample)
        #expect(!packed.contains(128) || PackBits.decode(packed + [128, 5]) == sample)
        #expect(PackBits.decode([2, 1]) == [1])
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
        var data = Data()
        data.appendBigEndian(UInt64(0x0102_0304_0506_0708))
        #expect(data == Data([1, 2, 3, 4, 5, 6, 7, 8]))
        let converter = ProfileCMYKConverter()
        #expect(converter.cmyk(.white).allSatisfy { $0 < 0.01 })
        #expect(converter.cmyk(.black)[3] > 0.5)
        #expect(converter.iccProfile.count > 1000)
        #expect(converter.cmykPixels(Corpus.image(alpha: true)).count == 16 * 12 * 4)
        #expect(converter.outputConditionIdentifier == converter.name && converter.name.contains("CMYK"))
        #expect(converter.cmyk(Color(cyan: 0.2, magenta: 0.3, yellow: 0.4, black: 1.5)) == [0.2, 0.3, 0.4, 1])
        #expect(ProfileCMYKConverter(profile: WTColor.ProfileRegistry.shared.sRGB).profile == WTColor.ProfileRegistry.shared.defaultCMYK)
    }
}
