// IMG-011: the EPS importer.  Every fixture is written here -- EPSI text files, DOS binary EPS
// files with a TIFF preview made by ImageIO, EPS files carrying a PDF, DCS and preview-less
// files -- and the EPS exporter (IO-018) is round-tripped: export, import, and the bounding box
// and preview come back.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WTGeometry
@testable import WTInterchange
import WTRender

enum EPSFixtures {
    /// An EPS text file: header comments, an optional EPSI preview, a body.
    static func text(header: [String], preview: String? = nil, body: String = "0 0 moveto 10 10 lineto stroke\n", trailer: [String] = [], newline: String = "\n") -> Data {
        var lines = ["%!PS-Adobe-3.0 EPSF-3.0"] + header + ["%%EndComments"]
        if let preview {
            lines.append(preview)
        }
        lines += ["%%BeginProlog", "%%EndProlog", body, "showpage", "%%Trailer"] + trailer + ["%%EOF"]
        return Data(lines.joined(separator: newline).utf8)
    }

    /// An EPSI preview section of `rows` (hex strings, top row first).
    static func epsi(width: Int, height: Int, depth: Int, rows: [String]) -> String {
        (["%%BeginPreview: \(width) \(height) \(depth) \(rows.count)"] + rows.map { "%" + $0 } + ["%%EndPreview"]).joined(separator: "\n")
    }

    /// A DOS EPS binary file: header, then the PostScript, then the TIFF (or a metafile).
    static func binary(postscript: Data, tiff: Data? = nil, metafile: Data? = nil) -> Data {
        var file = Data([0xC5, 0xD0, 0xD3, 0xC6])
        func word(_ value: Int) {
            file.append(contentsOf: (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) })
        }
        let extra = tiff ?? metafile ?? Data()
        word(30)
        word(postscript.count)
        word(metafile == nil ? 0 : 30 + postscript.count)
        word(metafile?.count ?? 0)
        word(tiff == nil ? 0 : 30 + postscript.count)
        word(tiff?.count ?? 0)
        file.append(contentsOf: [0xFF, 0xFF])
        return file + postscript + extra
    }

    /// A `width` × `height` TIFF of one colour, through ImageIO.
    static func tiff(width: Int, height: Int, red: Double, green: Double, blue: Double) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ImageEncoding.encode(context.makeImage()!, type: .tiff)!
    }

    /// A one-page PDF of `width` × `height` points, blue on the left half.
    static func pdf(width: Double, height: Double) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    static func convert(_ data: Data, name: String = "art.eps") throws -> ImportedScene {
        try ImportRegistry.standard.convert(data, name: name)
    }

    static func placed(_ scene: ImportedScene) -> ImportedPlacedFile? {
        if case .placed(let placed)? = scene.nodes.first {
            return placed
        }
        return nil
    }

    static func image(_ pixels: ImportedPixels) -> CGImage? {
        CGImageSourceCreateWithData(pixels.blob.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
}

@Suite struct EPSImportTests {
    // MARK: EPSI

    @Test func epsiPreviewsPlaceAtTheBoundingBox() throws {
        // 16 × 4 at one bit: a black left half on the top two rows (0 is white, 1 black).
        let rows = ["FF00", "FF00", "0000", "0000"]
        let data = EPSFixtures.text(header: ["%%BoundingBox: 10 20 26 25", "%%HiResBoundingBox: 10 20 26 24", "%%Title: (Logo \\(v2\\) \\342\\234\\223)", "%%Creator: Tester", "%%DocumentProcessColors: Cyan Magenta", "%%+ Yellow", "%%DocumentCustomColors: (PANTONE 185 C)", "%%+ (Spot Two) Gold"],
                                    preview: EPSFixtures.epsi(width: 16, height: 4, depth: 1, rows: rows))
        let scene = try EPSFixtures.convert(data)
        #expect(scene.kind == .placed)
        #expect(scene.bounds == Rect(x: 0, y: 0, width: 16, height: 4))
        #expect(scene.notes.isEmpty)
        let placed = try #require(EPSFixtures.placed(scene))
        #expect(placed.kind == .eps)
        #expect(placed.bounds == scene.bounds)
        #expect(placed.blob.data == data)
        #expect(placed.blob.uti == EPSImporter.uti)
        let preview = try #require(placed.preview)
        #expect(preview.width == 16 && preview.height == 4)
        #expect(preview.blob.uti == UTType.png.identifier)
        #expect(preview.mode == .grayscale)
        #expect(scene.blobs.map(\.sha256) == [placed.blob.sha256, preview.blob.sha256])
        let image = try #require(EPSFixtures.image(preview))
        #expect(ImageFixtures.pixel(image, x: 2, y: 0).red < 0.1)
        #expect(ImageFixtures.pixel(image, x: 12, y: 0).red > 0.9)
        #expect(ImageFixtures.pixel(image, x: 2, y: 3).red > 0.9)
        let file = try EPSFile(data, name: "art.eps")
        #expect(file.title == "Logo (v2) ✓")
        #expect(file.creator == "Tester")
        #expect(file.processColors == ["Cyan", "Magenta", "Yellow"])
        #expect(file.customColors == ["PANTONE 185 C", "Spot Two", "Gold"])
        #expect(!file.isDCS)
        #expect(file.boundingBox == Rect(x: 10, y: 20, width: 16, height: 4))
        #expect(file.preview()?.source == .epsi)
        let descriptor = try ImportRegistry.standard.probe(data, name: "art.eps")
        #expect(descriptor.format == .eps && descriptor.placed)
        #expect(descriptor.naturalSize == scene.bounds)
        #expect(descriptor.preview?.width == 16)
    }

    @Test(arguments: [(2, "FF00"), (4, "F0F0"), (8, "FF00FF00")])
    func epsiDepthsReadAsGray(_ depth: Int, _ row: String) throws {
        // Two samples per test: black then white, or 4 samples black, white, black, white.
        let width = depth == 2 ? 8 : 4
        let data = EPSFixtures.text(header: ["%%BoundingBox: 0 0 8 1"], preview: EPSFixtures.epsi(width: width, height: 1, depth: depth, rows: [row]), newline: "\r\n")
        let placed = try #require(EPSFixtures.placed(try EPSFixtures.convert(data)))
        let preview = try #require(placed.preview)
        let image = try #require(EPSFixtures.image(preview))
        #expect(image.width == width)
        #expect(ImageFixtures.pixel(image, x: 0, y: 0).red < 0.1)
        #expect(ImageFixtures.pixel(image, x: width - 1, y: 0).red > 0.9)
    }

    @Test func midGraysKeepTheirLevel() throws {
        // Two-bit samples 1 and 2 of 3: two-thirds and one-third white.
        let data = EPSFixtures.text(header: ["%%BoundingBox: 0 0 2 1"], preview: EPSFixtures.epsi(width: 2, height: 1, depth: 2, rows: ["60"]))
        let file = try EPSFile(data, name: "g.eps")
        let image = try #require(file.epsiPreview())
        #expect(abs(ImageFixtures.pixel(image, x: 0, y: 0).red - 170.0 / 255) < 0.02)
        #expect(abs(ImageFixtures.pixel(image, x: 1, y: 0).red - 85.0 / 255) < 0.02)
    }

    @Test func unusableEPSIPreviewsAreIgnored() throws {
        let cases = [
            "%%BeginPreview: 8 1\n%FF\n%%EndPreview",           // too few numbers
            "%%BeginPreview: 8 1 3 1\n%FF\n%%EndPreview",       // depth 3
            "%%BeginPreview: 0 1 1 1\n%FF\n%%EndPreview",       // no width
            "%%BeginPreview: 16 2 1 1\n%FFFF\n%%EndPreview",    // short data
        ]
        for preview in cases {
            let scene = try EPSFixtures.convert(EPSFixtures.text(header: ["%%BoundingBox: 0 0 8 1"], preview: preview))
            #expect(EPSFixtures.placed(scene)?.preview == nil, "\(preview)")
            #expect(scene.notes == ["“art.eps” has no preview; it shows as a gray box of its bounding-box size."])
        }
        // A preview must follow the header: one after the prolog is not the file's.
        let late = Data("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 8 1\n%%EndComments\n%%BeginProlog\n%%EndProlog\n%%BeginPreview: 8 1 1 1\n%FF\n%%EndPreview\n".utf8)
        #expect(try EPSFile(late, name: "l.eps").preview() == nil)
    }

    @Test func aHeaderWithoutEndCommentsEndsAtThePreviewOrTheCode() throws {
        let direct = Data("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 8 2\n\n%%BeginPreview: 8 2 1 2\n%FF\n%00\n%%EndPreview\n0 0 moveto\n".utf8)
        let file = try EPSFile(direct, name: "d.eps")
        #expect(file.boundingBox == Rect(x: 0, y: 0, width: 8, height: 2))
        #expect(file.epsiPreview()?.height == 2)
        // Code ends the header; a comment after it is not a header comment.
        let code = Data("%!PS-Adobe-2.0 EPSF-1.2\r%%BoundingBox: 0 0 5 5\r%comment\rnewpath\r%%Title: late\r%%BoundingBox: 0 0 9 9\r".utf8)
        let early = try EPSFile(code, name: "c.eps")
        #expect(early.boundingBox == Rect(x: 0, y: 0, width: 5, height: 5))
        #expect(early.title == nil)
    }

    // MARK: DOS binary header

    @Test func binaryHeadersCarryATIFFPreview() throws {
        let postscript = EPSFixtures.text(header: ["%%BoundingBox: 0 0 40 20", "%%Creator: (Layout)"])
        let data = EPSFixtures.binary(postscript: postscript, tiff: EPSFixtures.tiff(width: 80, height: 40, red: 1, green: 0, blue: 0))
        #expect(ImportFormat.sniff(data) == .eps)
        let scene = try EPSFixtures.convert(data, name: "photo.eps")
        #expect(scene.bounds == Rect(x: 0, y: 0, width: 40, height: 20))
        #expect(scene.notes.isEmpty)
        let placed = try #require(EPSFixtures.placed(scene))
        #expect(placed.blob.data == data)
        let preview = try #require(placed.preview)
        #expect(preview.width == 80 && preview.height == 40)
        #expect(preview.mode == .rgb && !preview.hasAlpha)
        let decoded = try #require(EPSFixtures.image(preview))
        let pixel = ImageFixtures.pixel(decoded, x: 10, y: 10)
        #expect(pixel.red > 0.9 && pixel.green < 0.1)
        let file = try EPSFile(data, name: "photo.eps")
        #expect(file.postscript == postscript)
        #expect(file.creator == "Layout")
        #expect(file.preview()?.source == .tiff)
    }

    @Test func aMetafileOrUnreadableTIFFShowsAsAGrayBox() throws {
        let postscript = EPSFixtures.text(header: ["%%BoundingBox: 0 0 40 20"])
        let wmf = try EPSFixtures.convert(EPSFixtures.binary(postscript: postscript, metafile: Data([1, 2, 3, 4])))
        #expect(EPSFixtures.placed(wmf)?.preview == nil)
        #expect(wmf.notes == ["“art.eps” has a Windows Metafile preview, which WireTuner does not read; it shows as a gray box."])
        let damaged = try EPSFixtures.convert(EPSFixtures.binary(postscript: postscript, tiff: Data("not a tiff".utf8)))
        #expect(EPSFixtures.placed(damaged)?.preview == nil)
    }

    @Test func damagedFilesAreRefused() {
        let postscript = EPSFixtures.text(header: ["%%BoundingBox: 0 0 40 20"])
        var outside = EPSFixtures.binary(postscript: postscript)
        outside[11] = 0x7F                                          // PostScript length past the end
        #expect(throws: ImportError.unreadable(name: "a.eps", reason: "its EPS binary header points outside the file.")) {
            try EPSFixtures.convert(outside, name: "a.eps")
        }
        #expect(throws: ImportError.unreadable(name: "a.eps", reason: "its EPS binary header is truncated.")) {
            try EPSFixtures.convert(Data([0xC5, 0xD0, 0xD3, 0xC6, 0, 0]), name: "a.eps")
        }
        #expect(throws: ImportError.unreadable(name: "a.eps", reason: "it is not an Encapsulated PostScript file.")) {
            try EPSFixtures.convert(EPSFixtures.binary(postscript: Data("hello".utf8)), name: "a.eps")
        }
        #expect(throws: ImportError.unreadable(name: "a.eps", reason: "it is not an Encapsulated PostScript file.")) {
            try EPSImporter().probe(Data("hello".utf8), name: "a.eps", format: .eps)
        }
        // A binary header that is a slice of a larger buffer reads the same.
        let padded = Data([0, 0]) + EPSFixtures.binary(postscript: postscript)
        #expect((try? EPSFile(padded.dropFirst(2), name: "s.eps"))?.boundingBox == Rect(x: 0, y: 0, width: 40, height: 20))
    }

    // MARK: Embedded PDF

    @Test func anEmbeddedPDFIsRenderedAsThePreview() throws {
        // An Illustrator EPS with its PDF-compatible stream: placed, not read as legacy AI.
        var data = EPSFixtures.text(header: ["%%BoundingBox: 0 0 100 50", "%%Creator: Adobe Illustrator(R) 24.0"], body: "%AI9_PrivateDataBegin")
        data += EPSFixtures.pdf(width: 100, height: 50) + Data("\n%%EOF\n".utf8)
        let scene = try EPSFixtures.convert(data)
        #expect(scene.kind == .placed)
        #expect(scene.bounds == Rect(x: 0, y: 0, width: 100, height: 50))
        let preview = try #require(EPSFixtures.placed(scene)?.preview)
        #expect(preview.width == 200 && preview.height == 100)
        #expect(preview.hasAlpha)
        let image = try #require(EPSFixtures.image(preview))
        let left = ImageFixtures.pixel(image, x: 20, y: 50)
        #expect(left.blue > 0.9 && left.red < 0.1 && left.alpha > 0.9)
        #expect(ImageFixtures.pixel(image, x: 180, y: 50).alpha < 0.1)
        #expect(try EPSFile(data, name: "a.eps").preview()?.source == .pdf)
        // A very wide page is held to the largest preview side.
        var wide = EPSFixtures.text(header: ["%%BoundingBox: 0 0 5000 10"])
        wide += EPSFixtures.pdf(width: 5000, height: 10)
        let big = try #require(EPSFixtures.placed(try EPSFixtures.convert(wide))?.preview)
        #expect(big.width == EPSFile.maximumPreviewSide)
        #expect(big.height == 8)
        // A damaged PDF falls through to the other previews.
        let broken = EPSFixtures.text(header: ["%%BoundingBox: 0 0 8 1"], preview: EPSFixtures.epsi(width: 8, height: 1, depth: 1, rows: ["F0"]), body: "%PDF-1.4 garbage %%EOF")
        #expect(try EPSFile(broken, name: "b.eps").preview()?.source == .epsi)
    }

    // MARK: Convert to Editable (IMG-060)

    @Test func aPlacedEPSWithAPDFStreamConvertsToEditableObjects() throws {
        var data = EPSFixtures.text(header: ["%%BoundingBox: 0 0 100 50", "%%Creator: Adobe Illustrator(R) 24.0"], body: "%AI9_PrivateDataBegin")
        data += EPSFixtures.pdf(width: 100, height: 50) + Data("\n%%EOF\n".utf8)
        #expect(try EPSFile(data, name: "a.eps").embeddedPDF?.starts(with: Data("%PDF-".utf8)) == true)
        let scene = try EPSImporter.editable(data, name: "a.eps")
        #expect(scene.kind == .vector && scene.layers.isEmpty)
        #expect(scene.bounds == Rect(x: 0, y: 0, width: 100, height: 50))
        guard case .path(let path)? = scene.nodes.first else {
            Issue.record("the blue half arrives as a path")
            return
        }
        #expect(path.fill != .none)
    }

    @Test func plainPostScriptIsNotEditable() throws {
        let plain = EPSFixtures.text(header: ["%%BoundingBox: 0 0 10 10"])
        #expect(try EPSFile(plain, name: "p.eps").embeddedPDF == nil)
        #expect(throws: ImportError.unreadable(name: "p.eps", reason: EPSImporter.notEditable)) {
            try EPSImporter.editable(plain, name: "p.eps")
        }
        // A PostScript Illustrator file the legacy reader reads converts; one it cannot is refused.
        let readable = Data("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 100 100\n%%Creator: Adobe Illustrator(R) 8.0\n%%EndComments\n%%BeginSetup\n%%EndSetup\n0 0 m\n50 0 l\n50 50 l\nf\n%%EOF\n".utf8)
        #expect(try EPSImporter.editable(readable, name: "r.eps").kind == .vector)
        let unreadable = Data("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 10 10\n%%Creator: Adobe Illustrator(R) 8.0\n%%EndComments\n/x { } def x 12 dup exch\n%%EOF\n".utf8)
        #expect(throws: ImportError.self) { try EPSImporter.editable(unreadable, name: "u.eps") }
    }

    // MARK: Illustrator EPS
    // MARK: Illustrator EPS

    @Test func illustratorEPSIsConvertedWhenTheReaderCan() throws {
        let readable = Data("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 100 100\n%%Creator: Adobe Illustrator(R) 8.0\n%%EndComments\n%%BeginSetup\n%%EndSetup\n0 0 m\n50 0 l\n50 50 l\nf\n%%EOF\n".utf8)
        let scene = try EPSFixtures.convert(readable)
        #expect(scene.kind == .vector)
        #expect(scene.scenePaths.count == 1)
        let descriptor = try ImportRegistry.standard.probe(readable, name: "art.eps")
        #expect(!descriptor.placed)
        #expect(descriptor.naturalSize == Rect(x: 0, y: 0, width: 100, height: 100))
        // Outside the operator set it is placed by the EPS importer, as any EPS.
        let other = EPSFixtures.text(header: ["%%BoundingBox: 0 0 100 100", "%%Creator: Adobe Illustrator(R) 8.0"], body: "%%BeginSetup\n%%EndSetup\n1 2 moveto gsave\n")
        let placed = try EPSFixtures.convert(other)
        #expect(placed.kind == .placed)
        #expect(placed.notes == ["“art.eps” has no preview; it shows as a gray box of its bounding-box size."])
    }

    // MARK: DSC

    @Test func boundingBoxesAtTheEndAndFallbacks() throws {
        let atend = EPSFixtures.text(header: ["%%BoundingBox: (atend)", "%%Title: (atend)"], trailer: ["%%BoundingBox: 0 0 30 40", "%%Title: Late", "%%Pages: 1", "%comment"])
        let file = try EPSFile(atend, name: "e.eps")
        #expect(file.boundingBox == Rect(x: 0, y: 0, width: 30, height: 40))
        #expect(file.title == "Late")
        // No box and no preview: US Letter.
        let none = try EPSFixtures.convert(EPSFixtures.text(header: ["%%BoundingBox: 0 0 0 0"]))
        #expect(none.bounds == Rect(x: 0, y: 0, width: 612, height: 792))
        #expect(none.notes.first == "“art.eps” has no bounding box; it is placed at 612 × 792 pt.")
        // No box but a preview: the preview's pixels at 72 ppi.
        let sized = try EPSFixtures.convert(EPSFixtures.text(header: ["%%BoundingBox: (atend)"], preview: EPSFixtures.epsi(width: 8, height: 2, depth: 1, rows: ["FF", "00"])))
        #expect(sized.bounds == Rect(x: 0, y: 0, width: 8, height: 2))
        #expect(sized.notes == ["“art.eps” has no bounding box; it is placed at its preview’s size."])
        // A box that is not four numbers is no box.
        #expect(EPSFile.box("0 0 10") == nil)
        #expect(EPSFile.box(nil) == nil)
        #expect(EPSFile.box("10 10 0 0") == Rect(x: 0, y: 0, width: 10, height: 10))
    }

    @Test func dscTextAndColourLists() {
        #expect(EPSFile.text("plain") == "plain")
        #expect(EPSFile.text("(") == "(")
        #expect(EPSFile.text("(a\\nb\\rc\\td\\\\e\\7f\\101)") == "a\nb\rc\td\\e\u{7}fA")
        #expect(EPSFile.text("(caf\\351)") == "café")                   // Latin-1 when not UTF-8
        #expect(EPSFile.text("(end\\)") == "end\\")
        #expect(EPSFile.decode(Array("x\\".utf8)) == "x\\")
        #expect(EPSFile.names("  Cyan (Spot A)  Black (atend) (unclosed") == ["Cyan", "Spot A", "Black", "(unclosed"])
        #expect(EPSFile.names("") == [])
    }

    @Test func continuationsAndRepeatedKeys() throws {
        let data = EPSFixtures.text(header: ["%%+ orphan", "%%Creator: One", "%%Creator: Two", "%%+ ignored", "%%DocumentCustomColors: (A)", "%%+ (B)", "%%BoundingBox: 0 0 1 1"])
        let file = try EPSFile(data, name: "c.eps")
        #expect(file.creator == "One")
        #expect(file.customColors == ["A", "B"])
    }

    @Test(arguments: ["%%PlateFile: (Cyan) EPS Local 1000 200", "%%CyanPlate: file.C", "%%BlackPlate: file.K"])
    func dcsFilesArePlacedWithTheirCompositePreview(_ plate: String) throws {
        let data = EPSFixtures.binary(postscript: EPSFixtures.text(header: ["%%BoundingBox: 0 0 20 10", plate]), tiff: EPSFixtures.tiff(width: 20, height: 10, red: 0, green: 1, blue: 0))
        let scene = try EPSFixtures.convert(data, name: "sep.eps")
        #expect(try EPSFile(data, name: "sep.eps").isDCS)
        #expect(scene.bounds == Rect(x: 0, y: 0, width: 20, height: 10))
        #expect(EPSFixtures.placed(scene)?.preview != nil)
        #expect(scene.notes == ["“sep.eps” is a DCS file: it is placed with its composite preview and its plates are not separated."])
    }

    // MARK: Rendering

    @Test func placedFilesRenderTheirPreviewOrAGrayBox() throws {
        let data = EPSFixtures.binary(postscript: EPSFixtures.text(header: ["%%BoundingBox: 0 0 40 20"]), tiff: EPSFixtures.tiff(width: 40, height: 20, red: 1, green: 0, blue: 0))
        let scene = try EPSFixtures.convert(data, name: "red.eps")
        let export = scene.exportScene()
        let preview = try #require(EPSFixtures.placed(scene)?.preview)
        #expect(export.assets[preview.blob.hex] != nil)
        guard case .image(let item)? = export.pages[0].displayList.items.first else {
            Issue.record("a preview draws as an image")
            return
        }
        #expect(item.rect == Rect(x: 0, y: 0, width: 40, height: 20))
        #expect(item.name == "red.eps")
        #expect(item.hasAlpha == false && item.mode == .rgb)
        // Without a preview: a gray box with the file's name.
        let bare = try EPSFixtures.convert(EPSFixtures.text(header: ["%%BoundingBox: 0 0 100 40"]), name: "bare.eps")
        guard case .group(let box)? = bare.exportScene().pages[0].displayList.items.first else {
            Issue.record("a gray box and a name")
            return
        }
        #expect(box.children.count == 2)
        let unnamed = ImportedNode.placed(ImportedPlacedFile(kind: .eps, blob: ImportedBlob(data: Data([1]), uti: EPSImporter.uti), bounds: Rect(x: 0, y: 0, width: 10, height: 10)))
        guard case .group(let plain)? = ImportedScene.displayItems(unnamed, .identity).first else {
            Issue.record("a gray box")
            return
        }
        #expect(plain.children.count == 1)
        let previewed = ImportedNode.placed(ImportedPlacedFile(kind: .eps, blob: ImportedBlob(data: Data([1]), uti: EPSImporter.uti), bounds: Rect(x: 0, y: 0, width: 10, height: 10), preview: preview))
        guard case .image(let anonymous)? = ImportedScene.displayItems(previewed, .identity).first else {
            Issue.record("a preview")
            return
        }
        #expect(anonymous.name == "")
    }

    // MARK: Round trip through the EPS exporter

    @Test(arguments: [EPSOptions.Preview.tiff72, .tiff144])
    func exportedEPSReimportsAtItsSizeWithItsPreview(_ option: EPSOptions.Preview) throws {
        let page = Corpus.fixture("basics")
        let info = ExportDocumentInfo(title: "Poster ✓ (A)")
        let exported = try EPSExporter().data(scene: Corpus.scene([page], info: info), page: 0, options: EPSOptions(preview: option))
        let scene = try EPSFixtures.convert(exported.data, name: "basics.eps")
        #expect(scene.kind == .placed)
        #expect(scene.bounds == Rect(x: 0, y: 0, width: 200, height: 150))
        #expect(scene.notes.isEmpty)
        let placed = try #require(EPSFixtures.placed(scene))
        #expect(placed.blob.data == exported.data)
        let preview = try #require(placed.preview)
        let scale = option == .tiff72 ? 1 : 2
        #expect(preview.width == 200 * scale && preview.height == 150 * scale)
        let image = try #require(EPSFixtures.image(preview))
        let difference = Corpus.difference(image, Corpus.reference(page, scale: Double(scale)), tolerance: 40)
        #expect(difference < 0.03, "\(difference)")
        let file = try EPSFile(exported.data, name: "basics.eps")
        #expect(file.title == "Poster ✓ (A)")
        #expect(file.creator == "WireTuner")
    }

    @Test func exportedEPSWithoutAPreviewIsAGrayBoxOfItsSize() throws {
        let page = Corpus.fixture("basics")
        let exported = try EPSExporter().data(scene: Corpus.scene([page]), page: 0, options: EPSOptions(preview: .none))
        let scene = try EPSFixtures.convert(exported.data, name: "basics.eps")
        #expect(scene.bounds == Rect(x: 0, y: 0, width: 200, height: 150))
        #expect(EPSFixtures.placed(scene)?.preview == nil)
        #expect(scene.notes == ["“basics.eps” has no preview; it shows as a gray box of its bounding-box size."])
        #expect(scene.blobs.count == 1)
    }
}
