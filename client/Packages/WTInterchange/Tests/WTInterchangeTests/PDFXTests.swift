// IO-026 and IO-029: PDF/X-1a and PDF/X-4 output (forced options and the fix report, output
// intents, identification, page boxes, CMYK conversion, flattening for X-1a), layers as optional
// content, and the Illustrator profile.  Ghostscript interprets every file when installed;
// veraPDF validates PDF/A and PDF/UA only (not PDF/X) and is not installed on the build Mac.

import CoreGraphics
import Foundation
import PDFKit
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct PDFXTests {
    static func corpus(bleed: Double = 9) -> [ExportPage] {
        Corpus.fixtures.map { name in
            var page = Corpus.fixture(name)
            page.bleed = bleed
            return page
        }
    }

    static func ghostscript(_ data: Data, _ name: String) throws {
        guard Ghostscript.isAvailable else { return }
        let url = Corpus.directory().appendingPathComponent(name + ".pdf")
        try data.write(to: url)
        let result = try Ghostscript.check(url, pdf: true)
        #expect(result.status == 0, "\(result.output)")
        #expect(!result.output.lowercased().contains("error"), "\(result.output)")
    }

    @Test func pressPDFX1aIsFlatCMYKAndIdentified() throws {
        let photo = Corpus.image(width: 32, height: 24)
        let assets = ["photo": ExportAsset(image: photo, jpegData: Corpus.jpeg(photo)), "alpha": ExportAsset(image: Corpus.image(alpha: true))]
        var pages = Self.corpus()
        pages.append(Corpus.page([.image(ImageItem(assetID: "photo", rect: Rect(x: 10, y: 10, width: 64, height: 48))), .image(ImageItem(assetID: "alpha", rect: Rect(x: 90, y: 10, width: 64, height: 48)))]))
        let linked = Corpus.node(9)
        pages[0] = Corpus.page(Corpus.basics, nodes: [linked])
        let scene = Corpus.scene(pages, nodes: [linked: ExportNodeInfo(url: "https://example.com")], assets: assets, info: ExportDocumentInfo(author: "Tea"))
        let result = try PDFExporter().data(scene: scene, options: .pressPDFX1a)
        let raw = PDFTests.text(of: result.data)
        #expect(result.data.starts(with: Data("%PDF-1.3".utf8)))
        #expect(raw.contains("/GTS_PDFXConformance (PDF/X-1a:2001)"))
        #expect(raw.contains("/GTS_PDFXVersion (PDF/X-1:2001)"))
        #expect(raw.contains("/Trapped /False"))
        #expect(raw.contains("/Title (Corpus)"))
        #expect(raw.contains("/S /GTS_PDFX"))
        #expect(raw.contains("/OutputConditionIdentifier (\(ProfileCMYKConverter().outputConditionIdentifier))"))
        #expect(raw.contains("/DestOutputProfile"))
        for forbidden in ["/SMask", "/CA ", "/ca ", "/DeviceRGB", "/ICCBased", "/Annots", "/S /Transparency", "/ArtBox"] {
            #expect(!raw.contains(forbidden), "\(forbidden)")
        }
        #expect(raw.contains("/DeviceCMYK"))
        #expect(!result.notes.contains { $0.hasPrefix("PDF/X check") })
        #expect(result.notes.contains { $0.contains("links left out") })
        #expect(result.notes.contains { $0.contains("images converted to CMYK with the \(ProfileCMYKConverter().name) profile") })
        #expect(result.notes.contains { $0.contains("flattened into opaque pieces") || $0.contains("transparency rendered") })
        let document = try #require(PDFDocument(data: result.data))
        #expect(document.pageCount == pages.count)
        try Self.ghostscript(result.data, "x1a")
    }

    @Test func printPDFX4KeepsTransparencyAndTaggedColor() throws {
        let scene = Corpus.scene(Self.corpus(), info: ExportDocumentInfo(title: "Poster"))
        let result = try PDFExporter().data(scene: scene, options: .printPDFX4)
        let raw = PDFTests.text(of: result.data)
        #expect(result.data.starts(with: Data("%PDF-1.6".utf8)))
        #expect(raw.contains("/GTS_PDFXVersion (PDF/X-4)"))
        #expect(raw.contains("<pdfxid:GTS_PDFXVersion>PDF/X-4</pdfxid:GTS_PDFXVersion>"))
        #expect(raw.contains("<xmpMM:RenditionClass>default</xmpMM:RenditionClass>"))
        #expect(raw.contains("/S /Transparency"))
        #expect(raw.contains("/ICCBased"))
        #expect(!raw.replacingOccurrences(of: "/Alternate /DeviceRGB", with: "").contains("/DeviceRGB"))
        #expect(!result.notes.contains { $0.hasPrefix("PDF/X check") })
        // Transparency stays live: the pages render like the live pages.
        for (index, page) in scene.pages.enumerated().prefix(3) {
            let rendered = PDFTests.rasterize(result.data, page: index + 1, scale: 2)
            let cropped = try #require(rendered.cropping(to: CGRect(x: 18, y: 18, width: 400, height: 300)))
            #expect(Corpus.difference(Corpus.reference(page, scale: 2), cropped, tolerance: 40) <= 0.03)
        }
        let cmyk = try PDFExporter().data(scene: scene, options: PDFOptions(standard: .pdfX4_2010, colors: .convertToCMYK))
        #expect(PDFTests.text(of: cmyk.data).contains("/DeviceCMYK"))
        #expect(!cmyk.notes.contains { $0.hasPrefix("PDF/X check") })
        try Self.ghostscript(result.data, "x4")
        try Self.ghostscript(cmyk.data, "x4-cmyk")
    }

    @Test func bleedAndTrimBoxesMatchTheDocument() throws {
        let scene = Corpus.scene(Self.corpus(bleed: 9).prefix(1).map { $0 })
        let result = try PDFExporter().data(scene: scene, options: .pressPDFX1a)
        let page = try #require(PDFDocument(data: result.data)?.page(at: 0))
        let media = page.bounds(for: .mediaBox), trim = page.bounds(for: .trimBox), bleed = page.bounds(for: .bleedBox)
        #expect(abs(media.width - 218) < 0.01 && abs(media.height - 168) < 0.01)
        #expect(abs(trim.minX - 9) < 0.01 && abs(trim.minY - 9) < 0.01 && abs(trim.width - 200) < 0.01 && abs(trim.height - 150) < 0.01)
        #expect(bleed == media)
        let custom = try PDFExporter().data(scene: scene, options: PDFOptions(standard: .pdfX4_2010, useDocumentBleed: false, bleedPoints: 18))
        let customPage = try #require(PDFDocument(data: custom.data)?.page(at: 0))
        #expect(abs(customPage.bounds(for: .trimBox).minX - 18) < 0.01)
        #expect(abs(customPage.bounds(for: .mediaBox).width - 236) < 0.01)
        // Without bleed a PDF/X page still has a bleed box, equal to the trim.
        let none = try PDFExporter().data(scene: Corpus.scene([Corpus.fixture("basics")]), options: .pressPDFX1a)
        let nonePage = try #require(PDFDocument(data: none.data)?.page(at: 0))
        #expect(nonePage.bounds(for: .bleedBox) == nonePage.bounds(for: .trimBox))
    }

    @Test func fixReportListsWhatTheStandardForced() {
        let (x1a, fixes) = PDFOptions(standard: .pdfX1a2001, layers: true, embedPackage: true, includeDocumentInfo: false, preserveOverprint: false).conforming()
        #expect(x1a.colors == .convertToCMYK && !x1a.embedProfiles && !x1a.layers && x1a.includeDocumentInfo && x1a.preserveOverprint && !x1a.embedPackage && !x1a.linksFromURLs)
        // Bookmarks are on by default and PDF/X turns them off (IO-027).
        #expect(fixes.count == 9 && !x1a.bookmarksFromPageNames)
        let (x4, x4Fixes) = PDFOptions(standard: .pdfX4_2010, embedProfiles: false).conforming()
        #expect(x4.embedProfiles && x4.colors == .keep)
        #expect(x4Fixes.first == "profiles embedded (PDF/X-4 requires tagged color)")
        #expect(PDFOptions.pressPDFX1a.conforming().fixes.count == 2)
        #expect(PDFOptions().conforming().fixes.isEmpty)
        #expect(PDFOptions(standard: .pdfX4_2010).headerVersion == "1.6")
        #expect(PDFXCheck.violations(["<</SMask 3 0 R>>", "<</ColorSpace /DeviceRGB>>"], standard: .pdfX1a2001) == ["soft mask (transparency) is not allowed", "RGB color is not allowed"])
        #expect(PDFXCheck.violations(["<</Annots []>>"], standard: .pdfX4_2010) == ["annotations is not allowed"])
        #expect(PDFXCheck.violations(["<</Annots []>>"], standard: .none).isEmpty)
        #expect(PDFXCheck.violations(["<</N 3 /Alternate /DeviceRGB>>"], standard: .pdfX4_2010).isEmpty)
    }

    @Test func taggedColorsKeepTheirSpace() throws {
        let items = [
            Corpus.path(Corpus.rect(0, 0, 40, 40), [Corpus.fill(.solid(Color(cyan: 0.1, magenta: 0.9, yellow: 0.2, black: 0)))]),
            Corpus.path(Corpus.rect(50, 0, 40, 40), [Corpus.fill(.solid(Color(labL: 60, a: 70, b: -20)))]),
            Corpus.path(Corpus.rect(100, 0, 40, 40), [Corpus.fill(.solid(Color(displayP3Red: 0, green: 0.9, blue: 0.2)))]),
            Corpus.path(Corpus.rect(150, 0, 40, 40), [Corpus.fill(.solid(Color(oklabL: 0.7, a: -0.2, b: 0.1)))]),
        ]
        let page = Corpus.page(items)
        let kept = try PDFExporter().data(scene: Corpus.scene([page]), options: PDFOptions())
        let raw = PDFTests.text(of: kept.data)
        #expect(raw.contains("0.1 0.9 0.2 0 k"))
        #expect(raw.contains("[/Lab <</WhitePoint [0.9642 1 0.8249] /Range [-128 127 -128 127]>>]"))
        #expect(kept.notes.contains("2 Display P3 colors written with the Display P3 profile"))
        let rgb = try PDFExporter().data(scene: Corpus.scene([page]), options: PDFOptions(colors: .convertToRGB))
        let rgbRaw = PDFTests.text(of: rgb.data)
        #expect(!rgbRaw.contains("/Lab") && !rgbRaw.contains(" k\n"))
        #expect(rgb.notes.contains { $0.contains("gamut-mapped into sRGB") })
        let eps = try EPSExporter().data(scene: Corpus.scene([page]), page: 0, options: EPSOptions())
        #expect(String(decoding: eps.data, as: UTF8.self).contains("0.1 0.9 0.2 0 k"))
        // CMYK converts through the profile: paper white is no ink.
        #expect(ProfileCMYKConverter().cmyk(.white).allSatisfy { $0 < 0.001 })
    }

    @Test func layersBecomeOptionalContentGroups() throws {
        let base = Corpus.node(1), art = Corpus.node(2), unnamed = Corpus.node(3)
        let page = Corpus.page([
            .group(GroupItem(children: [Corpus.path(Corpus.rect(0, 0, 200, 150), [Corpus.fill(.solid(Corpus.yellow))])])),
            .group(GroupItem(children: [Corpus.path(Corpus.ellipse(50, 30, 100, 80), [Corpus.fill(.solid(Corpus.red))]), Corpus.text("Layered", origin: Point(x: 60, y: 80))])),
            .group(GroupItem(children: [Corpus.path(Corpus.rect(10, 10, 20, 20), [Corpus.fill(.solid(.black))])])),
            Corpus.path(Corpus.rect(170, 120, 20, 20), [Corpus.fill(.solid(.black))]),
        ], nodes: [base, art, unnamed, nil])
        let nodes = [base: ExportNodeInfo(name: "Background", isLayer: true), art: ExportNodeInfo(name: "Artwork ✓", isLayer: true), unnamed: ExportNodeInfo(isLayer: true)]
        let scene = Corpus.scene([page, page], nodes: nodes)
        let result = try PDFExporter().data(scene: scene, options: PDFOptions(layers: true))
        let raw = PDFTests.text(of: result.data)
        #expect(raw.contains("/OCProperties"))
        #expect(raw.components(separatedBy: "/Type /OCG").count - 1 == 3)
        #expect(raw.contains("/Name (Background)"))
        #expect(raw.contains("/Name (Layer 3)"))
        #expect(raw.contains("/OC /MC1 BDC"))
        #expect(raw.contains("/Subtype /Artwork"))
        #expect(!result.notes.contains { $0.contains("layers") })
        let rendered = PDFTests.rasterize(result.data, scale: 2)
        #expect(Corpus.difference(Corpus.reference(page, scale: 2), rendered, tolerance: 40) <= 0.02)
        let flat = try PDFExporter().data(scene: scene, options: PDFOptions(standard: .pdfX1a2001, layers: true))
        #expect(!PDFTests.text(of: flat.data).contains("/OCProperties"))
        let x4 = try PDFExporter().data(scene: scene, options: PDFOptions(standard: .pdfX4_2010, layers: true))
        #expect(PDFTests.text(of: x4.data).contains("/OCProperties"))
        try Self.ghostscript(result.data, "layers")
    }

    @Test func illustratorProfile() throws {
        let base = Corpus.node(1)
        let page = Corpus.page([.group(GroupItem(children: [Corpus.text("Editable"), Corpus.path(Corpus.rect(10, 60, 80, 40), [Corpus.fill(.solid(Corpus.blue))])]))], nodes: [base])
        let scene = Corpus.scene([page], nodes: [base: ExportNodeInfo(name: "Type", isLayer: true)], info: ExportDocumentInfo(title: "Art"))
        let directory = Corpus.directory()
        let exporter = IllustratorExporter()
        let summary = try exporter.export(scene: scene, options: IllustratorOptions(), to: ExportDestination(url: directory.appendingPathComponent("art.pdf")))
        #expect(summary.files.map(\.lastPathComponent) == ["art.ai"])
        let data = try Data(contentsOf: summary.files[0])
        #expect(data.starts(with: Data("%PDF-1.7".utf8)))
        let raw = PDFTests.text(of: data)
        #expect(raw.contains("/Name (Type)"))
        #expect(raw.contains("/BaseFont /Helvetica"))
        let document = try #require(PDFDocument(data: data))
        #expect(document.string?.contains("Editable") == true)
        #expect(exporter.optionsType is IllustratorOptions.Type)
        #expect(exporter.capabilities == ExportFormat.illustrator.capabilities)
        #expect(IllustratorOptions.defaults == IllustratorOptions())
        let cmyk = try exporter.data(scene: scene, options: IllustratorOptions(colors: .convertToCMYK, embedPackage: true, includeDocumentInfo: false))
        #expect(PDFTests.text(of: cmyk.data).contains(" k\n"))
        #expect(cmyk.notes.contains("no document package was supplied; the PDF does not embed the document"))
        #expect(throws: ExportError.wrongOptions(format: .illustrator)) { try exporter.export(scene: scene, options: PDFOptions(), to: ExportDestination(url: directory.appendingPathComponent("x.ai"))) }
        #expect(throws: ExportError.self) { try exporter.export(scene: scene, options: IllustratorOptions(), to: ExportDestination(url: URL(fileURLWithPath: "/nonexistent-folder/x.ai"))) }
        try Self.ghostscript(data, "illustrator")
    }
}
