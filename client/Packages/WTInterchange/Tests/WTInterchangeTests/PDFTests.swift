// IO-025: the PDF writer.  Every file opens in PDFKit; its pages rasterized by Core Graphics'
// PDF renderer are held to the Core Graphics reference renderer's pixels of the same display
// list; structure (objects, fonts, masks, annotations) is read back with CGPDFDocument.

import CoreGraphics
import Foundation
import PDFKit
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct PDFTests {
    static func export(_ pages: [ExportPage], options: PDFOptions = PDFOptions(), nodes: [NodeID: ExportNodeInfo] = [:], assets: [String: ExportAsset] = [:], info: ExportDocumentInfo = ExportDocumentInfo()) throws -> (data: Data, notes: [String], document: PDFDocument) {
        let scene = Corpus.scene(pages, nodes: nodes, assets: assets, info: info)
        let result = try PDFExporter().data(scene: scene, options: options)
        let document = try #require(PDFDocument(data: result.data), "PDFKit cannot open the file")
        return (result.data, result.notes, document)
    }

    /// Page `index` of `data` rasterized by Core Graphics at `scale` over white.
    static func rasterize(_ data: Data, page index: Int = 1, scale: Double) -> CGImage {
        let document = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        let page = document.page(at: index)!
        let box = page.getBoxRect(.mediaBox)
        let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.drawPDFPage(page)
        return context.makeImage()!
    }

    /// The raw text of the file with every Flate stream inflated (for structural assertions).
    static func text(of data: Data) -> String {
        var result = String(decoding: data, as: UTF8.self)
        var search = data.startIndex
        while let start = data.range(of: Data("stream\n".utf8), in: search..<data.endIndex), let end = data.range(of: Data("\nendstream".utf8), in: start.upperBound..<data.endIndex) {
            let body = data[start.upperBound..<end.lowerBound]
            if body.count > 6, body.first == 0x78, let inflated = try? (Data(body.dropFirst(2).dropLast(4)) as NSData).decompressed(using: .zlib) as Data {
                result += "\n" + String(decoding: inflated, as: UTF8.self)
            }
            search = end.upperBound
        }
        return result
    }

    @Test(arguments: Corpus.fixtures)
    func pagesRenderLikeTheLivePage(_ name: String) throws {
        let page = Corpus.fixture(name)
        let result = try Self.export([page])
        #expect(result.document.pageCount == 1)
        let rendered = Self.rasterize(result.data, scale: 2)
        let reference = Corpus.reference(page, scale: 2)
        let failing = Corpus.difference(reference, rendered, tolerance: 40)
        if failing > 0.02 {
            Corpus.dump(rendered, "pdf-\(name)")
            Corpus.dump(reference, "pdf-\(name)-reference")
        }
        #expect(failing <= 0.02, "\(name): \(failing)")
    }

    @Test func textIsSearchableForEveryFontKind() throws {
        let items = [
            Corpus.text("TrueType text"),
            Corpus.text("Kohinoor", font: "KohinoorDevanagari-Regular", origin: Point(x: 10, y: 70)),
            Corpus.text("Variable", origin: Point(x: 10, y: 100), variations: [0x7767_6874: 700]),
            Corpus.text("Restricted", font: "LucidaGrande", origin: Point(x: 10, y: 130)),
        ]
        let result = try Self.export([Corpus.page(items)])
        let string = result.document.string ?? ""
        #expect(string.contains("TrueType"))
        #expect(string.contains("Kohinoor"))
        #expect(string.contains("Variable"))
        #expect(!string.contains("Restricted"))
        #expect(result.notes.contains("font LucidaGrande does not allow embedding; its text is outlined"))
        let raw = Self.text(of: result.data)
        #expect(raw.contains("/CIDFontType2"))
        #expect(raw.contains("/FontFile2"))
        #expect(raw.contains("/Type3"))
        #expect(raw.contains("/ToUnicode"))
        #expect(raw.range(of: "/[A-Z]{6}\\+Helvetica", options: .regularExpression) != nil)
        let full = try Self.export([Corpus.page([Corpus.text("Full")])], options: PDFOptions(fonts: .embedFull))
        #expect(Self.text(of: full.data).contains("/BaseFont /Helvetica"))
        let outlined = try Self.export([Corpus.page([Corpus.text("Outlined")])], options: PDFOptions(fonts: .outlines))
        #expect((outlined.document.string ?? "").isEmpty)
        #expect(!Self.text(of: outlined.data).contains("/Font"))
    }

    @Test func scaledAndPlacedGlyphs() throws {
        var run = Corpus.run("Wide", horizontalScale: 1.5)
        run.glyphs[1].transform = AffineTransform.rotation(radians: 0.3).concatenating(.translation(x: run.glyphs[1].position.x, y: 40))
        run.glyphs[2].position.y += 3
        let item = DisplayItem.text(TextRunItem(text: "Wide", glyphRun: run, origin: Point(x: 10, y: 40)))
        let result = try Self.export([Corpus.page([item])])
        let raw = Self.text(of: result.data)
        #expect(raw.contains("150 Tz"))
        #expect(raw.components(separatedBy: " Tm").count - 1 == 4)
        let rendered = Self.rasterize(result.data, scale: 2)
        #expect(Corpus.difference(Corpus.reference(Corpus.page([item]), scale: 2), rendered, tolerance: 40) <= 0.01)
    }

    @Test func manyGlyphsSplitType3Fonts() throws {
        let font = GlyphFont(postScriptName: "KohinoorDevanagari-Regular", size: 10, variations: [:])
        let glyphs = (1...300).map { PositionedGlyph(glyph: CGGlyph($0), position: Point(x: Double($0 % 30) * 6, y: Double($0 / 30) * 12 + 12)) }
        let item = DisplayItem.text(TextRunItem(text: "glyphs", glyphRun: GlyphRun(font: font, glyphs: glyphs), origin: .zero))
        let result = try Self.export([Corpus.page([item])])
        let raw = Self.text(of: result.data)
        #expect(raw.components(separatedBy: "/Subtype /Type3").count - 1 == 2)
    }

    @Test func gradientMaskIsAVectorSoftMask() throws {
        let mask = Gradient(.radial, from: .black, to: .white)
        let item = Corpus.path(Corpus.rect(10, 10, 100, 80), [Corpus.fill(.solid(Corpus.red))], effects: [EffectElement(.transparency(LiveEffect.Transparency(style: .gradientMask, mask: mask)))])
        let result = try Self.export([Corpus.page([item])])
        let raw = Self.text(of: result.data)
        #expect(raw.contains("/S /Luminosity"))
        #expect(raw.contains("/ShadingType 3"))
        #expect(!raw.contains("/Subtype /Image"))
        let rendered = Self.rasterize(result.data, scale: 2)
        let reference = Corpus.reference(Corpus.page([item]), scale: 2)
        #expect(Corpus.difference(reference, rendered, tolerance: 12) <= 0.01)
    }

    @Test func imagesAreCompressedAndMasked() throws {
        let alpha = Corpus.image(alpha: true)
        let photo = Corpus.image(width: 64, height: 48)
        let jpeg = Corpus.jpeg(photo)
        let assets = ["alpha": ExportAsset(image: alpha), "photo": ExportAsset(image: photo, jpegData: jpeg)]
        let items: [DisplayItem] = [
            .image(ImageItem(assetID: "alpha", rect: Rect(x: 0, y: 0, width: 32, height: 24))),
            .image(ImageItem(assetID: "alpha", rect: Rect(x: 40, y: 0, width: 32, height: 24))),
            .image(ImageItem(assetID: "photo", rect: Rect(x: 0, y: 40, width: 64, height: 48))),
        ]
        let auto = try Self.export([Corpus.page(items)], assets: assets)
        let raw = Self.text(of: auto.data)
        #expect(raw.components(separatedBy: "/Subtype /Image").count - 1 == 3)
        #expect(raw.contains("/DCTDecode"))
        #expect(raw.contains("/SMask"))
        #expect(auto.data.range(of: jpeg) != nil)
        let lossless = try Self.export([Corpus.page(items)], options: PDFOptions(colorImages: .lossless), assets: assets)
        #expect(!Self.text(of: lossless.data).contains("/DCTDecode"))
        let jpegged = try Self.export([Corpus.page(items)], options: PDFOptions(colorImages: .jpeg, jpegQuality: 50), assets: assets)
        #expect(Self.text(of: jpegged.data).components(separatedBy: "/DCTDecode").count - 1 == 2)
        let uncompressed = try Self.export([Corpus.page(items)], options: PDFOptions(colorImages: .none, compressContent: false, embedProfiles: false), assets: assets)
        #expect(!Self.text(of: uncompressed.data).contains("/FlateDecode"))
        #expect(Self.text(of: uncompressed.data).contains("/DeviceRGB"))
        // Downsampling: a 64-pixel image over 8 points is 576 ppi, above 450.
        let small = [DisplayItem.image(ImageItem(assetID: "photo", rect: Rect(x: 0, y: 0, width: 8, height: 6)))]
        let downsampled = try Self.export([Corpus.page(small)], options: PDFOptions(downsample: true, downsampleAbovePPI: 450, downsampleToPPI: 300), assets: assets)
        #expect(Self.text(of: downsampled.data).contains("/Width 33"))
        #expect(!Self.text(of: downsampled.data).contains("/DCTDecode"))
        // Grey and CMYK JPEGs keep their colour model; unreadable JPEG bytes are re-encoded.
        let grayJPEG = ImageEncoding.encode(Self.grayImage(), type: .jpeg)!
        let grayAssets = ["g": ExportAsset(image: Self.grayImage(), jpegData: grayJPEG), "bad": ExportAsset(image: photo, jpegData: Data([0, 1, 2]))]
        let grey = try Self.export([Corpus.page([.image(ImageItem(assetID: "g", rect: Rect(x: 0, y: 0, width: 10, height: 10))), .image(ImageItem(assetID: "bad", rect: Rect(x: 20, y: 0, width: 10, height: 10)))])], assets: grayAssets)
        #expect(Self.text(of: grey.data).contains("/DeviceGray /Filter /DCTDecode"))
        #expect(PDFDocumentBuild.jpegComponents(Data([0, 1])) == nil)
        let cmykJPEG = ImageEncoding.encode(Self.cmykImage(), type: .jpeg)!
        #expect(PDFDocumentBuild.jpegComponents(cmykJPEG) == 4)
    }

    static func grayImage() -> CGImage {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }

    static func cmykImage() -> CGImage {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceCMYK(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(cyan: 0.5, magenta: 0, yellow: 0, black: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }

    @Test func wideColorsUseDisplayP3AtVersion17() throws {
        let wide = Color(red: 1.1, green: 0.1, blue: -0.1)
        let items = [Corpus.path(Corpus.rect(0, 0, 50, 50), [Corpus.fill(.solid(wide)), Corpus.stroke(.solid(wide), width: 2)])]
        let modern = try Self.export([Corpus.page(items)])
        let raw = Self.text(of: modern.data)
        #expect(raw.contains("/OutputIntents"))
        #expect(raw.contains("Display P3"))
        #expect(modern.notes.contains("2 Display P3 colors written with the Display P3 profile"))
        let legacy = try Self.export([Corpus.page(items)], options: PDFOptions(version: .v1_4))
        #expect(!Self.text(of: legacy.data).contains("/OutputIntents"))
        #expect(legacy.notes.contains { $0.hasPrefix("2 wide-gamut colors gamut-mapped into sRGB") })
        #expect(legacy.data.starts(with: Data("%PDF-1.4".utf8)))
        let one = try Self.export([Corpus.page([Corpus.path(Corpus.rect(0, 0, 5, 5), [Corpus.fill(.solid(wide))])])], options: PDFOptions(version: .v2_0))
        #expect(one.notes.contains("1 Display P3 color written with the Display P3 profile"))
        let clippedOne = try Self.export([Corpus.page([Corpus.path(Corpus.rect(0, 0, 5, 5), [Corpus.fill(.solid(wide))])])], options: PDFOptions(embedProfiles: false))
        #expect(clippedOne.notes.contains { $0.hasPrefix("1 wide-gamut color gamut-mapped") })
    }

    @Test func documentInfoLinksAndBoxes() throws {
        let linked = Corpus.node(1)
        let info = ExportDocumentInfo(title: "Poster ✓", author: "Tea", description: "A (test) poster", keywords: ["a", "b"], language: "en-US")
        var page = Corpus.page([Corpus.path(Corpus.rect(10, 10, 50, 30), [Corpus.fill(.solid(Corpus.red))])], nodes: [linked])
        page.bleed = 9
        let result = try Self.export([page, Corpus.page([])], options: PDFOptions(pageSize: .pagePlusBleed), nodes: [linked: ExportNodeInfo(url: "https://example.com")], info: info)
        #expect(result.document.pageCount == 2)
        #expect(result.document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Poster ✓")
        #expect(result.document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String == "Tea")
        let first = result.document.page(at: 0)!
        #expect(first.bounds(for: .mediaBox).width == 218)
        #expect(first.bounds(for: .trimBox).minX == 9)
        #expect(first.bounds(for: .bleedBox).width == 218)
        #expect(first.bounds(for: .artBox).minX == 19)
        #expect(first.annotations.first?.url?.absoluteString == "https://example.com")
        let raw = Self.text(of: result.data)
        #expect(raw.contains("<dc:title>"))
        #expect(raw.contains("/Lang (en-US)"))
        #expect(raw.contains("/Keywords (a, b)"))
        let bare = try Self.export([page], options: PDFOptions(includeDocumentInfo: false, linksFromURLs: false), nodes: [linked: ExportNodeInfo(url: "https://example.com")])
        #expect(!Self.text(of: bare.data).contains("/Metadata"))
        #expect(bare.document.page(at: 0)!.annotations.isEmpty)
        #expect(bare.document.page(at: 0)!.bounds(for: .mediaBox).width == 200)
    }

    @Test func linksInsideTransparencyGroups() throws {
        let id = Corpus.node(7)
        var page = Corpus.page([.group(GroupItem(children: [Corpus.path(Corpus.rect(0, 0, 20, 20), [Corpus.fill(.solid(.black))])], opacity: 0.5))])
        page.nestedNodeIDs = [[0, 0]: id]
        let result = try Self.export([page], nodes: [id: ExportNodeInfo(url: "https://example.org")])
        #expect(result.document.page(at: 0)!.annotations.count == 1)
    }

    @Test func overprintAndGradientAlpha() throws {
        let items = [
            Corpus.path(Corpus.rect(0, 0, 50, 50), [Corpus.fill(.solid(Corpus.blue), overprint: true)]),
            Corpus.path(Corpus.rect(60, 0, 50, 50), [Corpus.fill(Corpus.gradient(.radial, stops: [Gradient.Stop(offset: 0, color: .black), Gradient.Stop(offset: 1, color: Color.white.withAlpha(multipliedBy: 0))]))]),
            Corpus.path(Corpus.wave(0, 60, 100, 30), [Corpus.stroke(Corpus.gradient(.linear, stops: [Gradient.Stop(offset: 0, color: .black), Gradient.Stop(offset: 1, color: Corpus.red.withAlpha(multipliedBy: 0.3))]), width: 4)]),
        ]
        let result = try Self.export([Corpus.page(items)])
        let raw = Self.text(of: result.data)
        #expect(raw.contains("/OP true"))
        #expect(raw.contains("/PatternType 2"))
        #expect(raw.contains("SCN"))
        let off = try Self.export([Corpus.page(items)], options: PDFOptions(embedProfiles: false, preserveOverprint: false))
        #expect(!Self.text(of: off.data).contains("/OP true"))
        let rendered = Self.rasterize(result.data, scale: 2)
        #expect(Corpus.difference(Corpus.reference(Corpus.page(items), scale: 2), rendered, tolerance: 40) <= 0.02)
    }

    @Test func optionsAreValidatedAndReported() throws {
        let page = Corpus.fixture("basics")
        let invalid = [
            PDFOptions(bleedPoints: -1), PDFOptions(bleedPoints: 100),
            PDFOptions(jpegQuality: 0), PDFOptions(downsample: true, downsampleAbovePPI: 100, downsampleToPPI: 300), PDFOptions(rasterPPI: -1),
        ]
        for options in invalid {
            #expect(throws: ExportError.self) { try PDFExporter().data(scene: Corpus.scene([page]), options: options) }
        }
        #expect(throws: ExportError.nothingToExport) { try PDFExporter().data(scene: Corpus.scene([]), options: PDFOptions()) }
        let reported = try Self.export([page], options: PDFOptions(version: .v1_4, layers: true, embedPackage: true, linearize: true, colors: .convertToRGB, rasterPPI: 72))
        #expect(reported.notes.contains { $0.contains("linearization") })
        #expect(reported.notes.contains { $0.contains("layers") })
        #expect(reported.notes.contains("no document package was supplied; the PDF does not embed the document"))
        #expect(PDFOptions.Version.allCases.map(\.rawValue) == ["1.4", "1.5", "1.6", "1.7", "2.0"])
        #expect(PDFOptions.defaults == PDFOptions())
        let directory = Corpus.directory()
        let summary = try PDFExporter().export(scene: Corpus.scene([page, page]), options: PDFOptions(), to: ExportDestination(url: directory.appendingPathComponent("doc.pdf")))
        #expect(summary.files.map(\.lastPathComponent) == ["doc.pdf"])
        #expect(PDFDocument(url: summary.files[0])?.pageCount == 2)
        #expect(throws: ExportError.wrongOptions(format: .pdf)) { try PDFExporter().export(scene: Corpus.scene([page]), options: SVGOptions(), to: ExportDestination(url: directory.appendingPathComponent("x.pdf"))) }
        #expect(throws: ExportError.self) { try PDFExporter().export(scene: Corpus.scene([page]), options: PDFOptions(), to: ExportDestination(url: URL(fileURLWithPath: "/nonexistent-folder/x.pdf"))) }
        #expect(PDFExporter().optionsType is PDFOptions.Type)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/gs")))
    func ghostscriptReadsTheCorpusWithoutErrors() throws {
        let directory = Corpus.directory()
        let url = directory.appendingPathComponent("corpus.pdf")
        let scene = Corpus.scene(Corpus.fixtures.map(Corpus.fixture))
        try PDFExporter().data(scene: scene, options: PDFOptions()).data.write(to: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/gs")
        process.arguments = ["-q", "-dNOPAUSE", "-dBATCH", "-dPDFSTOPONERROR", "-sDEVICE=nullpage", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(output)")
        #expect(!output.lowercased().contains("error"), "\(output)")
    }

    @Test func valuesSerialize() {
        #expect(PDFValue.null.text == "null")
        #expect(PDFValue.bool(false).text == "false")
        #expect(PDFValue.name("A B/#").text == "/A#20B#2F#23")
        #expect(PDFValue.string("a(b)\\").text == "(a\\(b\\)\\\\)")
        #expect(PDFValue.string("é").text == "<FEFF00E9>")
        #expect(PDFValue.real(-0.000001).text == "0")
        #expect(PDFFontRegistry.unicodeMapping(glyphs: [1, 2], text: "ffi") == ["ffi", nil])
        #expect(PDFFontRegistry.subsetTag([3, 1, 2]) == PDFFontRegistry.subsetTag([1, 2, 3]))
        let cmap = String(decoding: PDFFontRegistry.cmap((0..<150).map { ($0, $0 == 5 ? nil : "x") }, codeBytes: 1), as: UTF8.self)
        #expect(cmap.contains("100 beginbfchar") && cmap.contains("49 beginbfchar"))
    }
}
