// IO-040: foreign files opened as documents -- the registry's document formats, `ImportedDocument`
// and the importers that keep a file's pages (PDF pages, Illustrator artboards) and layers.

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct ImportedDocumentTests {
    /// A two-page PDF: page 1 (200 × 150) with the layers "Back" and "Front" and a note, page 2
    /// (300 × 100) with loose artwork.
    static func twoPages() -> Data {
        var fixture = PDFImportFixture()
        let resources = "<< /Properties << /L1 << /Type /OCG /Name (Back) >> /L2 << /Type /OCG /Name (Front) >> >> >>"
        let first = PDFImportFixture.Page("/OC /L1 BDC 0 0 10 10 re f EMC /OC /L2 BDC 20 20 10 10 re f EMC", resources: resources,
                                          extra: "/MediaBox [0 0 200 150] /Annots [<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (Check) >>]")
        let second = PDFImportFixture.Page("0 0 50 50 re f", extra: "/MediaBox [0 0 300 100]")
        return fixture.document([first, second])
    }

    /// The swatches opening a file writes: every named colour its pages use, on loose artwork and
    /// on named layers alike, once each, in first-use order.
    @Test func swatchesComeFromLooseArtworkAndLayersOnce() {
        let box = [ImportedContour(start: .zero, segments: [.line(to: Point(x: 10, y: 0)), .line(to: Point(x: 10, y: 10))], closed: true)]
        let ink = ImportedSwatch(name: "Ink", color: Color(red: 0.1, green: 0.1, blue: 0.4))
        let leaf = ImportedSwatch(name: "Leaf", color: Color(red: 0.2, green: 0.6, blue: 0.2))
        func painted(_ swatch: ImportedSwatch) -> ImportedNode { .path(ImportedPath(contours: box, fill: .swatch(swatch))) }
        let first = ImportedPage(size: Size(width: 100, height: 100), nodes: [painted(ink)],
                                 layers: [ImportedLayer(name: "Back", nodes: [painted(leaf)]), ImportedLayer(name: "Front", nodes: [painted(ink)])])
        let second = ImportedPage(size: Size(width: 100, height: 100), nodes: [], layers: [ImportedLayer(name: "Only", nodes: [painted(leaf)])])
        #expect(ImportedDocument(format: .freehand, name: "Swatches", pages: [first, second]).swatches == [ink, leaf])
    }

    @Test func theVectorFormatsOpenAsDocumentsAndBitmapsDoNot() {
        let registry = ImportRegistry.standard
        #expect(registry.documentFormats == [.pdf, .illustrator, .svg, .dxf, .eps, .freehand])
        #expect(registry.documentUTIs.contains("com.adobe.illustrator.ai-image") && !registry.documentUTIs.contains("public.png"))
        #expect(registry.documentExtensions.isSuperset(of: ["ai", "pdf", "svg", "svgz", "eps", "dxf", "fh10", "fh11"]))
        #expect(registry.opensAsDocument(named: "Poster.AI") && registry.opensAsDocument(named: "a.svgz") && registry.opensAsDocument(named: "Logo.FH10"))
        #expect(!registry.opensAsDocument(named: "photo.png") && !registry.opensAsDocument(named: "notes"))
        #expect(throws: ImportError.unsupportedFormat(name: "photo.png")) {
            try registry.document(Data([0x89, 0x50, 0x4E, 0x47, 0, 0]), name: "photo.png")
        }
        #expect(throws: ImportError.tooLarge(name: "a.pdf", bytes: 20, limit: 10)) {
            try registry.document(Data(count: 20), name: "a.pdf", context: ImportContext(maximumFileSize: 10))
        }
    }

    @Test func aPDFOpensWithAPageForEachPageAndItsLayers() throws {
        let document = try ImportRegistry.standard.document(Self.twoPages(), name: "Brochure.pdf")
        #expect(document.format == .pdf && document.title == "Brochure" && document.pages.count == 2)
        #expect(document.pages.map(\.size) == [Size(width: 200, height: 150), Size(width: 300, height: 100)])
        // Page 1's artwork is its layers, in page space (y down from the page's top).
        let layers = document.pages[0].nodes.compactMap { node -> ImportedGroup? in
            if case .group(let group) = node, group.role == .layer { return group }
            return nil
        }
        #expect(layers.map(\.name) == ["Back", "Front"])
        let back = PDFImportFixture.paths(layers[0].children)[0]
        let bounds = back.contours[0].allPoints.map { back.transform.apply($0) }
        #expect(bounds.map(\.y).max() == 150 && bounds.map(\.y).min() == 140)
        // The note is on page 1's Notes layer, in page 1's space; page 2 has only loose artwork.
        #expect(document.pages[0].layers.map(\.name) == ["Notes"])
        #expect(document.pages[1].layers.isEmpty && PDFImportFixture.paths(document.pages[1].nodes).count == 1)
        #expect(document.layerNames == ["Back", "Front", "Notes"])
        #expect(document.objectCount == 4)
        // A page range still applies.
        var options = PDFImportOptions().values
        options["pages"] = .string("2")
        #expect(try ImportRegistry.standard.document(Self.twoPages(), name: "Brochure.pdf", options: options).pages.map(\.size) == [Size(width: 300, height: 100)])
        options["pages"] = .string("9")
        #expect(throws: ImportError.self) { try ImportRegistry.standard.document(Self.twoPages(), name: "Brochure.pdf", options: options) }
    }

    @Test func anIllustratorFileOpensWithItsArtboardsAsPages() throws {
        // A PDF-compatible file: each artboard a page.
        let document = try ImportRegistry.standard.document(Self.twoPages(), name: "Poster.ai")
        #expect(document.format == .illustrator && document.pages.count == 2)
        // A PostScript file: one page, its layers as layer groups.
        let legacy = try ImportRegistry.standard.document(Data(IllustratorImportTests.legacy.utf8), name: "Old.ai")
        #expect(legacy.pages.count == 1 && legacy.pages[0].size == Size(width: 200, height: 150))
        #expect(legacy.layerNames.contains("Background"))
        #expect(throws: ImportError.self) { try IllustratorImporter().document(Data("plain".utf8), name: "x.ai", format: .illustrator, options: ImportOptionValues(), context: ImportContext()) }
    }

    @Test func anEPSOpensAsEditableArtworkOrPlaced() throws {
        var data = EPSFixtures.text(header: ["%%BoundingBox: 0 0 100 50", "%%Creator: Adobe Illustrator(R) 24.0"], body: "%AI9_PrivateDataBegin")
        data += EPSFixtures.pdf(width: 100, height: 50) + Data("\n%%EOF\n".utf8)
        let editable = try ImportRegistry.standard.document(data, name: "Logo.eps")
        #expect(editable.pages.count == 1 && editable.pages[0].size == Size(width: 100, height: 50))
        #expect(PDFImportFixture.paths(editable.pages[0].nodes).count == 1 && editable.notes.isEmpty)
        let plain = EPSFixtures.text(header: ["%%BoundingBox: 10 20 110 70"])
        let placed = try ImportRegistry.standard.document(plain, name: "Plain.eps")
        #expect(placed.pages[0].size == Size(width: 100, height: 50))
        guard case .placed(let file)? = placed.pages[0].nodes.first else {
            Issue.record("a PostScript-only EPS is placed")
            return
        }
        #expect(file.name == "Plain.eps" && placed.blobs.first?.data == plain)
        #expect(placed.notes.contains { $0.contains("placed EPS") })
        // An embedded PDF with nothing on its page is not artwork: the file is placed.
        let empty = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 50, height: 50)
        let context = CGContext(consumer: CGDataConsumer(data: empty as CFMutableData)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        var blank = EPSFixtures.text(header: ["%%BoundingBox: 0 0 50 50", "%%Creator: Adobe Illustrator(R) 24.0"], body: "%AI9_PrivateDataBegin")
        blank += (empty as Data) + Data("\n%%EOF\n".utf8)
        let blankDocument = try ImportRegistry.standard.document(blank, name: "Blank.eps")
        guard case .placed? = blankDocument.pages[0].nodes.first else {
            Issue.record("an EPS whose PDF is empty is placed")
            return
        }
    }

    @Test func anSVGOpensAsOnePageTheSizeOfItsViewBox() throws {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="10 20 120 80"><rect x="10" y="20" width="10" height="10"/></svg>"#.utf8)
        let document = try ImportRegistry.standard.document(svg, name: "Icon.svg")
        #expect(document.format == .svg && document.pages.count == 1 && document.pages[0].size == Size(width: 90, height: 60), "96 px to the inch")
        // No group named after the file: the document is the file.
        #expect(document.pages[0].nodes.allSatisfy { $0.name != "Icon.svg" })
        let rect = try #require(PDFImportFixture.paths(document.pages[0].nodes).first)
        let points = rect.contours[0].allPoints.map { rect.transform.apply($0) }
        #expect(points.map(\.x).min().map { abs($0) < 1e-9 } == true, "the view box's corner is the page's")
    }

    @Test func aSceneBecomesOnePageMovedToItsCorner() throws {
        let path = ImportedPath(contours: [ImportedContour(start: Point(x: 5, y: 5), segments: [.line(to: Point(x: 6, y: 6))])])
        let pixels = ImportedPixels(blob: ImportedBlob(data: Data([1]), uti: "public.png"), width: 1, height: 1, mode: .rgb, bitsPerChannel: 8, hasAlpha: false)
        let blob = ImportedBlob(data: Data([2]), uti: "public.svg-image")
        let nodes: [ImportedNode] = [.path(path), .text(ImportedText(runs: [])), .image(ImportedImage(pixels: pixels)),
                                     .placed(ImportedPlacedFile(kind: .eps, blob: blob, bounds: Rect(x: 0, y: 0, width: 1, height: 1))),
                                     .group(ImportedGroup(children: [.path(path)]))]
        let scene = ImportedScene(kind: .vector, name: "noext", bounds: Rect(x: 5, y: 5, width: 0, height: 10), nodes: nodes,
                                  layers: [ImportedLayer(name: "URLs", nodes: [.path(path)])], notes: ["n"])
        let document = ImportedDocument(scene: scene, format: .svg)
        #expect(document.title == "noext" && document.notes == ["n"])
        #expect(document.pages[0].size == Size(width: 1, height: 10))
        #expect(document.pages[0].nodes.allSatisfy { $0.transform == .translation(x: -5, y: -5) })
        #expect(document.pages[0].layers[0].nodes[0].transform == .translation(x: -5, y: -5))
        #expect(document.blobs.map(\.data) == [Data([1]), Data([2])])
        #expect(document.objectCount == 7 && document.layerNames == ["URLs"])
        // A bitmap scene's node is named after the file.
        let bitmap = ImportedScene(kind: .bitmap, name: "p.png", bounds: Rect(x: 0, y: 0, width: 1, height: 1), nodes: [.image(ImportedImage(pixels: pixels))])
        #expect(ImportedDocument(scene: bitmap, format: .png).pages[0].nodes[0].name == "p.png")
        // The default document of an importer is the converted scene on one page.
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="30"/>"#.utf8)
        #expect(try SVGImporter().document(svg, name: "e.svg", format: .svg, options: ImportOptionValues(), context: ImportContext()).pages[0].size == Size(width: 30, height: 22.5))
        #expect(ImageImporter().opensAsDocument(.png) == false && SVGImporter().opensAsDocument(.svg))
    }

    /// A JPEG drawn through an inverting `/Decode` (Photoshop's CMYK JPEGs in PDFs) comes in as
    /// Quartz draws it, not as a negative.
    @Test func aJPEGWithAnInvertedDecodeIsNotANegative() throws {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let jpeg = ImageEncoding.encode(context.makeImage()!, type: .jpeg)!
        func centre(_ decode: String) throws -> UInt8 {
            var f = PDFImportFixture()
            let image = f.stream("/Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode \(decode)", jpeg)
            let data = f.document([.init("q 10 0 0 10 0 0 cm /Im0 Do Q", resources: "<< /XObject << /Im0 \(image) 0 R >> >>")])
            let pixels = try #require(PDFImportFixture.images(try PDFImportFixture.importPDF(data).nodes).first?.pixels)
            let decoded = try #require(EPSFixtures.image(pixels))
            let canvas = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            canvas.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return canvas.data!.assumingMemoryBound(to: UInt8.self)[0]
        }
        #expect(try centre("") > 200)
        #expect(try centre("/Decode [1 0 1 0 1 0]") < 55)
        #expect(try centre("/Decode [0 1 0 1 0 1]") > 200, "a decode that does not invert changes nothing")
        // An Adobe CMYK JPEG is inverted; with an inverting decode as well, it is not.
        let cmyk = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceCMYK(),
                             bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        cmyk.setFillColor(CGColor(genericCMYKCyan: 0, magenta: 0, yellow: 0, black: 0, alpha: 1))
        cmyk.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let adobe = ImageEncoding.encode(cmyk.makeImage()!, type: .jpeg)!
        #expect(PDFImportImage.isAdobeJPEG(adobe) == true && !PDFImportImage.isAdobeJPEG(jpeg) && !PDFImportImage.isAdobeJPEG(Data([0xFF, 0xD8, 0xFF, 0xDA, 0, 2])))
        let plain = PDFImportImageSpec(width: 4, height: 4, bitsPerComponent: 8, space: .cmyk, decode: nil, imageMask: false, data: adobe, encoded: true)
        #expect(PDFImportImage.invertedDecode(plain) != nil)
        var both = plain
        both.decode = [1, 0, 1, 0, 1, 0, 1, 0]
        #expect(PDFImportImage.invertedDecode(both) == nil)
    }
}
