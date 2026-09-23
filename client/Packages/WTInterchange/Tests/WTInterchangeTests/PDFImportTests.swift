// IMG-009: PDF import.  Round trips through WireTuner's own PDF writer (export, import, compare
// geometry, colours, text, images, layers and links, and render both), pages, page boxes and
// rotation, annotations, probing and refusals.

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct PDFImportTests {
    static func export(_ page: ExportPage, nodes: [NodeID: ExportNodeInfo] = [:], assets: [String: ExportAsset] = [:], options: PDFOptions = PDFOptions()) throws -> Data {
        try PDFExporter().data(scene: Corpus.scene([page], nodes: nodes, assets: assets), options: options).data
    }

    /// The expected contours of a display-list path under `transform`.
    static func contours(_ path: DisplayPath, _ transform: AffineTransform) -> [ImportedContour] {
        var builder = ImportPathBuilder()
        for element in path.elements {
            switch element {
            case .move(let p): builder.move(to: transform.apply(p))
            case .line(let p): builder.line(to: transform.apply(p))
            case .quadCurve(let c, let e): builder.quad(transform.apply(c), transform.apply(e))
            case .cubicCurve(let c1, let c2, let e): builder.cubic(transform.apply(c1), transform.apply(c2), transform.apply(e))
            case .close: builder.close()
            }
        }
        return builder.build()
    }

    static func close(_ a: [ImportedContour], _ b: [ImportedContour], tolerance: Double = 1e-3) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            let p = x.allPoints
            let q = y.allPoints
            guard p.count == q.count, x.closed == y.closed else { return false }
            for (u, v) in zip(p, q) where u.distance(to: v) > tolerance {
                return false
            }
        }
        return true
    }

    // MARK: Round trips

    @Test(arguments: Corpus.fixtures)
    func roundTripRendersLikeTheSource(_ name: String) throws {
        let page = Corpus.fixture(name)
        let data = try Self.export(page)
        let scene = try PDFImportFixture.importPDF(data)
        #expect(scene.kind == .vector)
        #expect(scene.bounds == Rect(x: 0, y: 0, width: 200, height: 150))
        // The imported scene written again and rasterized against the source PDF.
        let again = try PDFExporter().data(scene: scene.exportScene(), options: PDFOptions()).data
        let source = PDFTests.rasterize(data, scale: 2)
        let reimported = PDFTests.rasterize(again, scale: 2)
        let failing = Corpus.difference(source, reimported, tolerance: 40)
        if failing > 0.02 {
            Corpus.dump(source, "pdfimport-\(name)-source")
            Corpus.dump(reimported, "pdfimport-\(name)-import")
        }
        #expect(failing <= 0.02, "\(name): \(failing)")
        if scene.images.isEmpty {
            // Without images the reference renderer draws the scene directly.
            let direct = Corpus.reference(scene.exportScene().pages[0], scale: 2)
            #expect(Corpus.difference(source, direct, tolerance: 40) <= 0.02)
        }
    }

    @Test func basicsKeepGeometryColoursAndStrokes() throws {
        let page = Corpus.fixture("basics")
        let scene = try PDFImportFixture.importPDF(try Self.export(page))
        var expected: [(contours: [ImportedContour], fill: Color?, stroke: (Color, Double)?)] = []
        for item in page.displayList.items {
            guard case .path(let path) = item else { continue }
            let contours = Self.contours(path.path, path.transform)
            for element in path.appearance.items {
                switch element {
                case .fill(let fill): expected.append((contours, fill.paint.color, nil))
                case .stroke(let stroke): expected.append((contours, nil, (stroke.paint.color!, stroke.style.width)))
                }
            }
        }
        let paths = scene.scenePaths
        #expect(paths.count == expected.count)
        for (path, want) in zip(paths, expected) {
            #expect(Self.close(path.contours, want.contours), "\(path.contours)")
            if let fill = want.fill {
                let got = try #require(path.fill.representativeColor)
                #expect(abs(got.red - fill.red) < 1e-3 && abs(got.green - fill.green) < 1e-3 && abs(got.blue - fill.blue) < 1e-3)
                #expect(path.stroke == nil)
            }
            if let (color, width) = want.stroke, width > 0 {
                let stroke = try #require(path.stroke)
                #expect(abs(stroke.style.width - width) < 1e-3)
                #expect(abs(stroke.paint.representativeColor!.blue - color.blue) < 1e-3)
                #expect(path.fill == .none)
            }
        }
        // The dashed stroke keeps its dash; the ring keeps even-odd.
        #expect(paths.contains { $0.stroke?.style.dash == [6, 3] && $0.stroke?.style.cap == .round })
        #expect(paths.contains { $0.fillRule == .evenOdd })
    }

    @Test func transparencyAndClipsBecomeGroups() throws {
        let scene = try PDFImportFixture.importPDF(try Self.export(Corpus.fixture("transparency")))
        let groups = PDFImportFixture.groups(scene.nodes)
        #expect(groups.contains { abs($0.opacity - 0.6) < 1e-6 })
        let clip = try #require(groups.first { $0.clip != nil })
        #expect(clip.children.count == 2)
        // The half-transparent red fill keeps its alpha in its colour.
        #expect(scene.scenePaths.contains { abs(($0.fill.representativeColor?.alpha ?? 1) - 0.5) < 1e-6 })
    }

    @Test func gradientsComeBackAsGradients() throws {
        let scene = try PDFImportFixture.importPDF(try Self.export(Corpus.fixture("gradients")))
        let gradients = scene.scenePaths.compactMap { path -> Gradient? in
            if case .gradient(let g) = path.fill { return g }
            if case .gradient(let g)? = path.stroke?.paint { return g }
            return nil
        }
        #expect(gradients.count == 7)
        #expect(gradients.contains { $0.kind == .radial && $0.axis?.end2 != nil })
        let linear = try #require(gradients.first)
        #expect(linear.kind == .linear)
        #expect(linear.stops.count >= 3 && linear.stops.count <= 33)
        #expect(abs(linear.axis!.start.x - 10) < 1e-3 && abs(linear.axis!.end.x - 90) < 1e-3)
        // The translucent ramp's alpha comes back from its soft mask.
        #expect(gradients.contains { abs(($0.sortedStops.last?.color.alpha ?? 1) - 0.2) < 0.02 })
    }

    @Test func textRoundTripsAsEditableTextAndAsOutlines() throws {
        let data = try Self.export(Corpus.fixture("text"))
        let scene = try PDFImportFixture.importPDF(data)
        let texts = PDFImportFixture.texts(scene.nodes)
        #expect(texts.map(\.string) == ["Export 123", "Scaled"])
        let first = texts[0].runs[0]
        #expect(first.fontName == "Helvetica")
        #expect(abs(first.fontSize - 18) < 1e-3)
        #expect(first.origin.distance(to: Point(x: 10, y: 40)) < 1e-3)
        #expect(texts[0].transform.isIdentity)
        let scaled = texts[1].runs[0]
        #expect(abs(scaled.fontSize - 18) < 1e-3)
        #expect(scaled.fill.representativeColor.map { abs($0.red - Corpus.red.red) < 1e-3 } == true)
        let outlined = try PDFImportFixture.importPDF(data, PDFImportOptions(text: .outlines))
        #expect(outlined.texts.isEmpty)
        #expect(outlined.scenePaths.count == 2)
        #expect(outlined.scenePaths[0].contours.count > 8)
    }

    @Test func imagesKeepPixelsAlphaAndJPEGBytes() throws {
        let image = Corpus.image(alpha: true)
        let jpegImage = Corpus.image(width: 20, height: 10)
        let page = Corpus.page([
            .image(ImageItem(assetID: "a", rect: Rect(x: 10, y: 10, width: 16, height: 12), hasAlpha: true)),
            .image(ImageItem(assetID: "j", rect: Rect(x: 50, y: 20, width: 40, height: 20))),
        ])
        let assets = ["a": ExportAsset(image: image), "j": ExportAsset(image: jpegImage, jpegData: Corpus.jpeg(jpegImage))]
        let scene = try PDFImportFixture.importPDF(try Self.export(page, assets: assets))
        let images = scene.images
        #expect(images.count == 2)
        #expect(images[0].pixels.width == 16 && images[0].pixels.height == 12)
        #expect(images[0].pixels.hasAlpha)
        #expect(images[0].transform.apply(Point(x: 0, y: 0)).distance(to: Point(x: 10, y: 10)) < 1e-3)
        let natural = images[0].naturalRect
        #expect(images[0].transform.apply(Point(x: natural.maxX, y: natural.maxY)).distance(to: Point(x: 26, y: 22)) < 1e-3)
        #expect(images[1].pixels.blob.uti == "public.jpeg")
        #expect(images[1].pixels.blob.data == Corpus.jpeg(jpegImage))
        #expect(scene.blobs.count == 2)
    }

    @Test func layersNamesAndLinksRoundTrip() throws {
        let background = NodeID(counter: 10, replica: 1)
        let art = NodeID(counter: 11, replica: 1)
        let linked = NodeID(counter: 12, replica: 1)
        let items: [DisplayItem] = [
            .group(GroupItem(children: [Corpus.path(Corpus.rect(0, 0, 200, 150), [Corpus.fill(.solid(Corpus.yellow))])])),
            .group(GroupItem(children: [Corpus.path(Corpus.rect(20, 20, 40, 40), [Corpus.fill(.solid(Corpus.red))])])),
            Corpus.path(Corpus.rect(100, 20, 40, 40), [Corpus.fill(.solid(Corpus.blue))]),
        ]
        let page = Corpus.page(items, nodes: [background, art, linked])
        let nodes = [
            background: ExportNodeInfo(name: "Background", isLayer: true),
            art: ExportNodeInfo(name: "Art", isLayer: true),
            linked: ExportNodeInfo(name: "Linked", url: "https://example.com/a"),
        ]
        let data = try Self.export(page, nodes: nodes, options: PDFOptions(version: .v1_7, layers: true))
        let scene = try PDFImportFixture.importPDF(data)
        let layers = PDFImportFixture.groups(scene.nodes).filter { $0.role == .layer }
        #expect(layers.map(\.name) == ["Background", "Art"])
        let urls = try #require(scene.layers.first { $0.name == "URLs" })
        let link = try #require(PDFImportFixture.paths(urls.nodes).first)
        #expect(link.url == "https://example.com/a")
        #expect(link.fill == .none && link.stroke == nil)
        let bounds = Rect(boundingPoints: link.contours.flatMap(\.allPoints))
        #expect(abs(bounds.minX - 100) < 1e-3 && abs(bounds.minY - 20) < 1e-3)
        let noLinks = try PDFImportFixture.importPDF(data, PDFImportOptions(importLinks: false))
        #expect(noLinks.layers.isEmpty)
    }

    // MARK: Pages

    static func threePages() -> Data {
        var fixture = PDFImportFixture()
        return fixture.document([
            .init("1 0 0 rg 0 0 10 10 re f"),
            .init("0 1 0 rg 0 0 20 20 re f", extra: "/MediaBox [0 0 100 80]"),
            .init("0 0 1 rg 0 0 30 30 re f"),
        ])
    }

    @Test func pagesAreGroupedInARow() throws {
        let data = Self.threePages()
        let all = try PDFImportFixture.importPDF(data, context: ImportContext(keepBothOffset: 10))
        #expect(all.nodes.count == 3)
        let groups = all.nodes.compactMap { node -> ImportedGroup? in
            if case .group(let g) = node { return g }
            return nil
        }
        #expect(groups.map(\.name) == ["Page 1", "Page 2", "Page 3"])
        #expect(groups.map(\.transform.tx) == [0, 210, 320])
        #expect(all.bounds == Rect(x: 0, y: 0, width: 520, height: 150))
        let second = try PDFImportFixture.importPDF(data, PDFImportOptions(pages: ImportPageRange(parsing: "2")!))
        #expect(second.nodes.count == 1)
        #expect(second.bounds == Rect(x: 0, y: 0, width: 100, height: 80))
        #expect(second.scenePaths[0].contours[0].start == Point(x: 0, y: 80))
        let range = try PDFImportFixture.importPDF(data, PDFImportOptions(pages: ImportPageRange(parsing: "1,3")!))
        #expect(range.nodes.compactMap(\.name) == ["Page 1", "Page 3"])
    }

    @Test func pageRangeErrorsNameTheFile() throws {
        let data = Self.threePages()
        #expect(throws: ImportError.invalidOption(name: "fixture.pdf", reason: "page 5 is beyond the last page (3).")) {
            try PDFImportFixture.importPDF(data, PDFImportOptions(pages: ImportPageRange(pages: [5])))
        }
        #expect(throws: ImportError.empty(name: "fixture.pdf")) {
            try PDFImporter().convert(PDFImporter.document(data, name: "fixture.pdf"), name: "fixture.pdf", options: PDFImportOptions(pages: ImportPageRange(pages: [])), context: ImportContext())
        }
        var values = PDFImportOptions().values
        values["pages"] = .string("x-y")
        #expect(throws: ImportError.self) {
            try PDFImporter().convert(data, name: "fixture.pdf", format: .pdf, options: values, context: ImportContext())
        }
    }

    @Test func keepPageClipWrapsEachPage() throws {
        let scene = try PDFImportFixture.importPDF(Self.threePages(), PDFImportOptions(pages: ImportPageRange(pages: [1]), keepPageClip: true))
        guard case .group(let group) = scene.nodes[0] else {
            Issue.record("expected a clip group")
            return
        }
        let clip = try #require(group.clip)
        #expect(Rect(boundingPoints: clip.contours[0].allPoints) == Rect(x: 0, y: 0, width: 200, height: 150))
    }

    @Test(arguments: [0, 90, 180, 270])
    func rotatedAndCroppedPagesDrawAsDisplayed(_ rotation: Int) throws {
        let content = "1 0 0 rg 10 10 60 20 re f 0 0 1 rg 20 40 m 80 40 l 20 90 l f"
        let data = PDFImportFixture.page(content, extra: "/MediaBox [0 0 200 150] /CropBox [5 5 105 125] /Rotate \(rotation)")
        let scene = try PDFImportFixture.importPDF(data)
        let size = rotation % 180 == 0 ? (100.0, 120.0) : (120.0, 100.0)
        #expect(scene.bounds == Rect(x: 0, y: 0, width: size.0, height: size.1))
        let document = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        let page = document.page(at: 1)!
        let context = CGContext(data: nil, width: Int(size.0) * 2, height: Int(size.1) * 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.0 * 2, height: size.1 * 2))
        context.scaleBy(x: 2, y: 2)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: size.0, height: size.1), rotate: 0, preserveAspectRatio: true))
        context.clip(to: page.getBoxRect(.cropBox))
        context.drawPDFPage(page)
        let source = context.makeImage()!
        let imported = Corpus.reference(scene.exportScene().pages[0], scale: 2)
        #expect(Corpus.difference(source, imported, tolerance: 40) <= 0.01)
    }

    @Test func severalContentStreamsAreConcatenated() throws {
        var fixture = PDFImportFixture()
        let a = fixture.stream("", "1 0 0 rg 0 0 10 10 re")
        let b = fixture.stream("", "f 0 0 1 rg 20 0 10 10 re f", flate: true)
        var page = PDFImportFixture.Page("")
        page.contents = [a, b]
        let scene = try PDFImportFixture.importPDF(fixture.document([page]))
        #expect(scene.scenePaths.count == 2)
        var empty = PDFImportFixture()
        var none = PDFImportFixture.Page("")
        none.contents = []
        #expect(try PDFImportFixture.importPDF(empty.document([none])).nodes.isEmpty)
    }

    // MARK: Annotations

    @Test func notesAndLinksGoToTheirLayers() throws {
        let annotations = """
        /Annots [<< /Type /Annot /Subtype /Link /Rect [10 10 50 30] /A << /S /URI /URI (https://example.com) >> >> \
        << /Subtype /Link /Rect [0 0 1 1] >> \
        << /Subtype /Text /Rect [20 100 40 120] /Contents (Line one\\nLine two) /T (Reviewer) >> \
        << /Subtype /FreeText /Rect [60 100 90 120] /Contents (Free) >> \
        << /Subtype /Text /Rect [0 0 1 1] >> \
        << /Subtype /Square /Rect [0 0 1 1] >> \
        << /Subtype /Link >>]
        """
        let data = PDFImportFixture.page("", extra: "/MediaBox [0 0 200 150] \(annotations)")
        let scene = try PDFImportFixture.importPDF(data)
        #expect(scene.layers.map(\.name) == ["Notes", "URLs"])
        let notes = PDFImportFixture.texts(scene.layers[0].nodes)
        #expect(notes.map(\.string) == ["Line oneLine two", "Free"])
        #expect(notes[0].name == "Reviewer")
        #expect(notes[0].runs.map(\.origin) == [Point(x: 20, y: 42), Point(x: 20, y: 56.4)])
        #expect(PDFImportFixture.paths(scene.layers[1].nodes).map(\.url) == ["https://example.com"])
        let none = try PDFImportFixture.importPDF(data, PDFImportOptions(importNotes: false, importLinks: false))
        #expect(none.layers.isEmpty)
    }

    // MARK: Probe and refusals

    @Test func probeDescribesTheFirstPage() throws {
        let descriptor = try PDFImporter().probe(Self.threePages(), name: "three.pdf", format: .pdf)
        #expect(descriptor.pageCount == 3)
        #expect(descriptor.naturalSize == Rect(x: 0, y: 0, width: 200, height: 150))
        #expect(descriptor.preview?.width == 256)
        #expect(PDFImporter().formats == [.pdf])
        #expect(PDFImporter().optionsSchema(for: .pdf) == PDFImportOptions.schema)
    }

    @Test func damagedAndProtectedFilesAreRefused() throws {
        #expect(throws: ImportError.unreadable(name: "junk.pdf", reason: "it is damaged or is not a PDF.")) {
            try PDFImporter().convert(Data("not a pdf".utf8), name: "junk.pdf", format: .pdf, options: PDFImportOptions().values, context: ImportContext())
        }
        func encrypted(user: String) -> Data {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 100, height: 100)
            let info = [kCGPDFContextUserPassword: user, kCGPDFContextOwnerPassword: "owner"] as CFDictionary
            let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, info)!
            context.beginPDFPage(nil)
            context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
            context.endPDFPage()
            context.closePDF()
            return data as Data
        }
        #expect(throws: ImportError.unreadable(name: "locked.pdf", reason: "it is protected by a password.")) {
            try PDFImporter().convert(encrypted(user: "secret"), name: "locked.pdf", format: .pdf, options: PDFImportOptions().values, context: ImportContext())
        }
        let open = try PDFImporter().convert(encrypted(user: ""), name: "open.pdf", format: .pdf, options: PDFImportOptions().values, context: ImportContext())
        #expect(open.scenePaths.count == 1)
    }
}
