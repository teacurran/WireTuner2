// IO-028: the package embedded in PDF, Illustrator and EPS exports and found again on open; and
// the IO-018 follow-up: a placed EPS file's PostScript passed through verbatim into EPS exports.

import CoreGraphics
import Foundation
import PDFKit
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct EmbeddedPackageTests {
    static let reader = PackageReader(featureLevel: 3, mergeTableVersion: 7)

    static var page: ExportPage {
        Corpus.page(Corpus.basics + [Corpus.text("Embedded", origin: Point(x: 20, y: 140))], width: 200, height: 160, name: "Poster")
    }

    /// A package of the page as the app writes it (the real thumbnail and preview).
    static func package() throws -> Data {
        let manifest = PackageManifest(originDocumentID: "01926a3c-0000-7000-8000-00000000abcd", title: "Poster", featureLevel: 3, mergeTableVersion: 7, stateHash: Data(repeating: 7, count: 32))
        let contents = PackageContents(manifest: manifest, snapshot: Data((0..<6000).map { UInt8(truncatingIfNeeded: $0 &* 13) }), firstPage: Corpus.scene([page]))
        return try PackageWriter().data(contents).data
    }

    static func scene(package: Data?) -> ExportScene {
        var scene = Corpus.scene([page])
        scene.name = "Poster"
        scene.package = package
        return scene
    }

    // MARK: PDF

    @Test func pdfCarriesThePackageAndReopensIt() throws {
        let package = try Self.package()
        let with = try PDFExporter().data(scene: Self.scene(package: package), options: PDFOptions(embedPackage: true))
        let without = try PDFExporter().data(scene: Self.scene(package: package), options: PDFOptions())
        #expect(EmbeddedPackage.find(in: with.data) == EmbeddedPackage.slimmed(package))
        #expect(EmbeddedPackage.find(in: without.data) == nil, "a PDF without the attachment falls through to the importer")
        // Reopened, the document is the original: manifest, snapshot and blobs.
        let opened = try #require(try EmbeddedPackage.open(with.data, reader: Self.reader))
        let original = try Self.reader.open(package)
        #expect(opened.manifest == original.manifest && opened.snapshot == original.snapshot && opened.blobs == original.blobs)
        #expect(opened.thumbnail == nil && opened.preview == nil && original.preview != nil)
        #expect(try EmbeddedPackage.open(without.data, reader: Self.reader) == nil)
        let text = PDFTests.text(of: with.data)
        #expect(text.contains("/AFRelationship /Source") && text.contains("/EmbeddedFiles") && text.contains("(Poster.wiretuner)"))
        #expect(text.contains("/Subtype /application#2Fvnd.wiretuner.package+zip"))
        #expect(PDFDocument(data: with.data)?.pageCount == 1)
        #expect(Double(with.data.count) < 2.2 * Double(without.data.count), "\(with.data.count) vs \(without.data.count)")
        if Ghostscript.isAvailable {
            let url = Corpus.directory().appendingPathComponent("embedded.pdf")
            try with.data.write(to: url)
            #expect(try Ghostscript.check(url, pdf: true).status == 0)
        }
    }

    @Test func packagesSurviveEncryptionAndIllustratorButNotPDFX() throws {
        let package = try Self.package()
        let restricted = try PDFExporter().data(scene: Self.scene(package: package), options: PDFOptions(embedPackage: true, permissionsPassword: "owner", allowCopying: false))
        #expect(EmbeddedPackage.find(in: restricted.data) == EmbeddedPackage.slimmed(package))
        let ai = try IllustratorExporter().data(scene: Self.scene(package: package), options: IllustratorOptions(embedPackage: true))
        #expect(EmbeddedPackage.find(in: ai.data) == EmbeddedPackage.slimmed(package))
        var x4 = PDFOptions.printPDFX4
        x4.embedPackage = true
        let pdfx = try PDFExporter().data(scene: Self.scene(package: package), options: x4)
        #expect(EmbeddedPackage.find(in: pdfx.data) == nil && pdfx.notes.contains { $0.contains("embedded document package left out") })
        let missing = try PDFExporter().data(scene: Self.scene(package: nil), options: PDFOptions(embedPackage: true))
        #expect(missing.notes.contains("no document package was supplied; the PDF does not embed the document"))
    }

    /// A hand-made PDF whose embedded files sit in a name tree's kids, under a file name only.
    static func nameTreePDF(package: Data, name: String) -> Data {
        let objects = PDFObjects(compress: false)
        let pages = objects.reserve()
        let page = objects.add(.dictionary([("Type", .name("Page")), ("Parent", .reference(pages)), ("MediaBox", .rect(0, 0, 10, 10))]))
        objects.set(pages, .dictionary([("Type", .name("Pages")), ("Kids", .array([.reference(page)])), ("Count", .int(1))]))
        let stream = objects.addStream([("Type", .name("EmbeddedFile"))], data: package)
        let other = objects.addStream([("Type", .name("EmbeddedFile"))], data: Data("notes".utf8))
        let otherSpec = objects.add(.dictionary([("Type", .name("Filespec")), ("F", .string("notes.txt")), ("EF", .dictionary([("F", .reference(other))]))]))
        let spec = objects.add(.dictionary([("Type", .name("Filespec")), ("F", .string(name)), ("EF", .dictionary([("UF", .reference(stream))]))]))
        let noFile = objects.add(.dictionary([("Type", .name("Filespec")), ("F", .string("empty.wiretuner"))]))
        let leaf = objects.add(.dictionary([("Names", .array([.string("a"), .reference(noFile), .string("b"), .reference(otherSpec), .string("c"), .reference(spec)]))]))
        let root = objects.add(.dictionary([("Kids", .array([.reference(leaf)]))]))
        let catalog = objects.add(.dictionary([("Type", .name("Catalog")), ("Pages", .reference(pages)), ("Names", .dictionary([("EmbeddedFiles", .reference(root))]))]))
        return objects.file(version: "1.7", root: catalog, info: nil)
    }

    @Test func nameTreeKidsAndFileNamesAreSearched() throws {
        let package = try Self.package()
        #expect(EmbeddedPackage.find(in: Self.nameTreePDF(package: package, name: "Poster.wiretuner")) == package)
        #expect(EmbeddedPackage.find(in: Self.nameTreePDF(package: package, name: "poster.zip")) == nil)
        #expect(EmbeddedPackage.find(in: Self.nameTreePDF(package: Data("not a zip".utf8), name: "Broken.wiretuner")) == nil, "a damaged package falls through")
        #expect(EmbeddedPackage.find(in: Data("%PDF-1.7 garbage".utf8)) == nil)
        let noNames = PDFObjects(compress: false)
        let pages = noNames.add(.dictionary([("Type", .name("Pages")), ("Kids", .array([])), ("Count", .int(0))]))
        let catalog = noNames.add(.dictionary([("Type", .name("Catalog")), ("Pages", .reference(pages))]))
        #expect(EmbeddedPackage.find(in: noNames.file(version: "1.7", root: catalog, info: nil)) == nil)
        #expect(EmbeddedPackage.fileName("") == "Untitled.wiretuner")
        #expect(EmbeddedPackage.slimmed(Data("not a zip".utf8)) == Data("not a zip".utf8))
    }

    // MARK: EPS

    @Test func epsCarriesThePackageAsCommentsAndReopensIt() throws {
        let package = try Self.package()
        for preview in [EPSOptions.Preview.none, .tiff72] {
            let options = EPSOptions(preview: preview, embedPackage: true)
            let eps = try EPSExporter().data(scene: Self.scene(package: package), page: 0, options: options)
            #expect(EmbeddedPackage.find(in: eps.data) == EmbeddedPackage.slimmed(package))
            #expect(try EmbeddedPackage.open(eps.data, reader: Self.reader)?.manifest.title == "Poster")
            let without = try EPSExporter().data(scene: Self.scene(package: package), page: 0, options: EPSOptions(preview: preview))
            #expect(EmbeddedPackage.find(in: without.data) == nil)
            let text = String(decoding: EPSBuild.postScriptSection(eps.data), as: UTF8.self)
            let block = try #require(text.range(of: "%%BeginData:"))
            #expect(text[block.lowerBound...].split(separator: "\n").dropFirst().prefix { $0 != "%%EndData" }.allSatisfy { $0.hasPrefix("%") })
            #expect(text.hasSuffix("%%EndData\n%%EOF\n"))
            if Ghostscript.isAvailable {
                let url = Corpus.directory().appendingPathComponent("embedded-\(preview.ppi ?? 0).eps")
                try eps.data.write(to: url)
                #expect(try Ghostscript.check(url).status == 0)
            }
        }
        let missing = try EPSExporter().data(scene: Self.scene(package: nil), page: 0, options: EPSOptions(embedPackage: true))
        #expect(missing.notes.contains("no document package was supplied; the EPS does not embed the document"))
        #expect(EmbeddedPackage.find(in: Data("%!PS-Adobe-3.0\n%WireTunerPackage 3\n%AAAA\n".utf8)) == nil, "no end of data")
    }

    // MARK: Placed EPS pass-through

    static let placedNode = Corpus.node(40)

    /// A placed EPS drawing a red box over its 100 × 50 bounding box, with a comment byte past
    /// 7-bit ASCII when `binary`.
    static func placedProgram(binary: Bool = false) -> Data {
        var text = "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 10 20 110 70\n%%EndComments\n/box { 10 20 100 50 rectfill } def\n1 0 0 setrgbcolor box showpage\n%%EOF"
        if binary {
            text = text.replacingOccurrences(of: "%%EndComments", with: "%%EndComments\n% caf\u{00E9}")
        }
        return Data(text.utf8)
    }

    static func placedScene(_ data: Data) -> ExportScene {
        let bounds = Rect(x: 0, y: 0, width: 100, height: 50)
        let item = PlacedFileDrawing.item(PlacedFile(bounds: bounds, name: "placed.eps", transform: .translation(x: 40, y: 30)))
        var scene = Corpus.scene([Corpus.page([item, Corpus.path(Corpus.rect(0, 0, 20, 20), [Corpus.fill(.solid(Corpus.blue))])], nodes: [placedNode, nil])], nodes: [placedNode: ExportNodeInfo(name: "Logo")])
        scene.placedPostScript = [placedNode: ExportPostScript(data: data, boundingBox: Rect(x: 10, y: 20, width: 100, height: 50), bounds: bounds, transform: .translation(x: 40, y: 30))]
        return scene
    }

    @Test func placedPostScriptIsWrittenVerbatim() throws {
        let program = Self.placedProgram()
        let eps = try EPSExporter().data(scene: Self.placedScene(program), page: 0, options: EPSOptions())
        let text = String(decoding: eps.data, as: UTF8.self)
        #expect(text.contains("%%BeginDocument: Logo\n" + String(decoding: program, as: UTF8.self) + "\n%%EndDocument"))
        #expect(text.contains("/showpage {} def") && text.contains("%%DocumentData: Clean7Bit"))
        #expect(eps.notes.contains("1 placed EPS file written as its own PostScript"))
        // The preview's gray box is not written in its place.
        #expect(!text.contains("0.85 0.85 0.85 rg"))
        // PDF has no PostScript: it draws the preview (here the gray box).
        let pdf = try PDFExporter().data(scene: Self.placedScene(program), options: PDFOptions())
        #expect(!pdf.notes.contains { $0.contains("PostScript") })
        if Ghostscript.isAvailable {
            let url = Corpus.directory().appendingPathComponent("passthrough.eps")
            try eps.data.write(to: url)
            let rendered = try #require(try Ghostscript.render(url, ppi: 72).image)
            #expect(AnimationExportTests.close(AnimationExportTests.pixel(rendered, 90, 55), [255, 0, 0, 255], 30), "the placed program's red box at the placed bounds")
            #expect(AnimationExportTests.close(AnimationExportTests.pixel(rendered, 10, 10), [26, 77, 230, 255], 30), "the export's own artwork around it")
            #expect(AnimationExportTests.close(AnimationExportTests.pixel(rendered, 150, 100), [255, 255, 255, 255], 30))
        }
    }

    @Test func dosHeadersAreStrippedAndBinaryIsDeclared() throws {
        let program = Self.placedProgram(binary: true)
        let tiff = Data(repeating: 0x49, count: 64)
        let dos = EPSWriter.binaryHeader(postscript: program, tiff: tiff)
        #expect(EPSBuild.postScriptSection(dos) == program)
        #expect(EPSBuild.postScriptSection(Data([0xC5, 0xD0, 0xD3, 0xC6, 0xFF, 0xFF, 0, 0, 1, 0, 0, 0])) == Data([0xC5, 0xD0, 0xD3, 0xC6, 0xFF, 0xFF, 0, 0, 1, 0, 0, 0]), "a header pointing past the file is left alone")
        let eps = try EPSExporter().data(scene: Self.placedScene(dos), page: 0, options: EPSOptions())
        #expect(eps.data.range(of: program) != nil && eps.data.range(of: tiff) == nil)
        #expect(String(decoding: eps.data, as: UTF8.self).contains("%%DocumentData: Binary"))
        // A placed file with a degenerate bounding box maps at scale 1.
        var scene = Self.placedScene(Self.placedProgram())
        scene.placedPostScript[Self.placedNode]?.boundingBox = Rect(x: 0, y: 0, width: 0, height: 0)
        let flat = try EPSExporter().data(scene: scene, page: 0, options: EPSOptions())
        #expect(String(decoding: flat.data, as: UTF8.self).contains("1 0 0 -1 40 80 cm"))
        let unnamed = Self.placedScene(Self.placedProgram())
        var anonymous = unnamed
        anonymous.nodes = [:]
        #expect(String(decoding: try EPSExporter().data(scene: anonymous, page: 0, options: EPSOptions()).data, as: UTF8.self).contains("%%BeginDocument: placed.eps"))
    }
}
