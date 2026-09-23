// IO-027: note comments, bookmarks from page names, open and permissions passwords with AES
// (revision 4 below PDF 2.0, revision 6 at 2.0), PDF/X stripping all of them; and FX-012's spot
// colours as `/Separation` spaces.  Files are opened with PDFKit (which unlocks and enforces the
// permissions as Preview does) and, when installed, Ghostscript with the password.

import CoreGraphics
import Foundation
import PDFKit
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct PDFInteractiveTests {
    static let square = Corpus.node(1)
    static let circle = Corpus.node(2)

    static var page: ExportPage {
        Corpus.page([
            Corpus.path(Corpus.rect(20, 30, 60, 40), [Corpus.fill(.solid(Corpus.red))]),
            Corpus.path(Corpus.ellipse(110, 40, 50, 50), [Corpus.fill(.solid(Corpus.blue))]),
            Corpus.text("Secret words", origin: Point(x: 10, y: 130)),
        ], nodes: [square, circle, nil], name: "Cover")
    }

    static let nodes: [NodeID: ExportNodeInfo] = [
        square: ExportNodeInfo(name: "Square", url: "https://example.com/square", note: "Check the red"),
        circle: ExportNodeInfo(note: "Rounder?"),
    ]

    static func export(_ options: PDFOptions, pages: [ExportPage] = [page]) throws -> (data: Data, notes: [String]) {
        try PDFExporter().data(scene: Corpus.scene(pages, nodes: nodes), options: options)
    }

    // MARK: Annotations and bookmarks

    @Test func notesBecomeCommentsAtTheObjectsTopLeft() throws {
        let result = try Self.export(PDFOptions(notesAsComments: true))
        let document = try #require(PDFDocument(data: result.data))
        let annotations = try #require(document.page(at: 0)).annotations
        let comments = annotations.filter { $0.type == "Text" }
        #expect(comments.count == 2)
        let square = try #require(comments.first { $0.contents == "Check the red" })
        // The square's top-left (20, 30) on a 150 pt page is (20, 120) in PDF space.
        #expect(abs(square.bounds.minX - 20) < 0.01 && abs(square.bounds.maxY - 120) < 0.01)
        #expect(square.userName == "Square")
        #expect(comments.contains { $0.contents == "Rounder?" })
        #expect(annotations.contains { $0.type == "Link" && $0.url?.absoluteString == "https://example.com/square" })
        // Off by default.
        let plain = try #require(PDFDocument(data: Self.export(PDFOptions()).data))
        #expect(plain.page(at: 0)!.annotations.allSatisfy { $0.type == "Link" })
        let bare = try #require(PDFDocument(data: Self.export(PDFOptions(linksFromURLs: false)).data))
        #expect(bare.page(at: 0)!.annotations.isEmpty)
    }

    @Test func namedPagesBecomeBookmarks() throws {
        var second = Self.page
        second.name = "Back \u{2014} final"
        var unnamed = Self.page
        unnamed.name = nil
        let result = try Self.export(PDFOptions(), pages: [Self.page, unnamed, second])
        let document = try #require(PDFDocument(data: result.data))
        let root = try #require(document.outlineRoot)
        #expect(root.numberOfChildren == 2)
        #expect(root.child(at: 0)?.label == "Cover" && root.child(at: 1)?.label == "Back \u{2014} final")
        #expect(root.child(at: 1)?.destination?.page == document.page(at: 2))
        #expect(PDFTests.text(of: result.data).contains("/PageMode /UseOutlines"))
        #expect(PDFDocument(data: try Self.export(PDFOptions(bookmarksFromPageNames: false)).data)?.outlineRoot == nil)
        #expect(PDFDocument(data: try Self.export(PDFOptions(), pages: [unnamed]).data)?.outlineRoot == nil)
    }

    @Test func pdfXStripsInteractiveFeatures() throws {
        var options = PDFOptions.printPDFX4
        options.notesAsComments = true
        options.openPassword = "open"
        options.permissionsPassword = "owner"
        let result = try Self.export(options)
        for fix in ["comments left out", "bookmarks left out", "the open password removed", "the permissions password removed", "links left out"] {
            #expect(result.notes.contains { $0.contains(fix) }, "\(fix)")
        }
        let text = PDFTests.text(of: result.data)
        #expect(!text.contains("/Encrypt") && !text.contains("/Annots") && !text.contains("/Outlines"))
        #expect(!result.notes.contains { $0.hasPrefix("PDF/X check") })
        let document = try #require(PDFDocument(data: result.data))
        #expect(!document.isEncrypted)
    }

    // MARK: Passwords

    @Test(arguments: [PDFOptions.Version.v1_7, .v2_0])
    func openPasswordLocksTheFile(_ version: PDFOptions.Version) throws {
        let result = try Self.export(PDFOptions(version: version, notesAsComments: true, openPassword: "s3cret"))
        #expect(result.notes.contains(version == .v2_0 ? "encrypted with AES-256" : "encrypted with AES-128"))
        let text = String(decoding: result.data, as: UTF8.self)
        #expect(text.contains(version == .v2_0 ? "/V 5 /R 6" : "/V 4 /R 4"))
        #expect(!text.contains("Check the red"), "strings are encrypted")
        let document = try #require(PDFDocument(data: result.data))
        #expect(document.isEncrypted && document.isLocked)
        #expect(!document.unlock(withPassword: "wrong"))
        #expect(document.unlock(withPassword: "s3cret"))
        #expect(document.page(at: 0)?.string?.contains("Secret words") == true)
        #expect(document.page(at: 0)?.annotations.contains { $0.contents == "Check the red" } == true)
        #expect(document.outlineRoot?.child(at: 0)?.label == "Cover")
        // The unlocked pages draw like the unencrypted file's.
        let plain = try Self.export(PDFOptions(version: version, notesAsComments: true))
        let reference = PDFTests.rasterize(plain.data, scale: 1)
        let cg = try #require(CGPDFDocument(CGDataProvider(data: result.data as CFData)!))
        #expect(cg.isEncrypted && !cg.isUnlocked && cg.unlockWithPassword("s3cret"))
        let rendered = Self.rasterize(cg, scale: 1)
        #expect(Corpus.difference(reference, rendered, tolerance: 8) < 0.001)
        if Ghostscript.isAvailable {
            let url = Corpus.directory().appendingPathComponent("locked-\(version.rawValue).pdf")
            try result.data.write(to: url)
            let checked = try Ghostscript.run(["-dPDFSTOPONERROR", "-sPDFPassword=s3cret", "-sDEVICE=nullpage", url.path])
            #expect(checked.status == 0, "\(checked.output)")
        }
    }

    static func rasterize(_ document: CGPDFDocument, scale: Double) -> CGImage {
        let page = document.page(at: 1)!
        let box = page.getBoxRect(.mediaBox)
        let context = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale))
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(page)
        return context.makeImage()!
    }

    @Test(arguments: [PDFOptions.Version.v1_4, .v2_0])
    func permissionsPasswordRestrictsWithoutLocking(_ version: PDFOptions.Version) throws {
        let result = try Self.export(PDFOptions(version: version, permissionsPassword: "owner", allowPrinting: true, allowCopying: false, allowEditing: false))
        if version == .v1_4 {
            #expect(String(decoding: result.data.prefix(8), as: UTF8.self) == "%PDF-1.6")
            #expect(result.notes.contains("passwords need AES, so the file is PDF 1.6 rather than 1.4"))
        }
        let document = try #require(PDFDocument(data: result.data))
        #expect(document.isEncrypted && !document.isLocked)
        #expect(!document.allowsCopying && document.allowsPrinting && !document.allowsCommenting)
        let cg = try #require(CGPDFDocument(CGDataProvider(data: result.data as CFData)!))
        #expect(cg.isUnlocked && !cg.allowsCopying && cg.allowsPrinting)
        #expect(document.page(at: 0)?.string?.contains("Secret words") == true)
        let open = try #require(PDFDocument(data: Self.export(PDFOptions(version: version, permissionsPassword: "owner", allowPrinting: false)).data))
        #expect(!open.allowsPrinting && open.allowsCopying)
    }

    @Test func permissionBitsAndPasswordsEncodeAsTheStandardSays() {
        #expect(PDFEncryption.permissions(printing: false, copying: false, editing: false) == Int32(bitPattern: 0xFFFF_F2C0))
        #expect(PDFEncryption.permissions(printing: true, copying: true, editing: true) == Int32(bitPattern: 0xFFFF_FFFC))
        #expect(PDFEncryption.padded("") == Data(PDFEncryption.padding))
        #expect(PDFEncryption.padded("ab\u{4E2D}c").prefix(3) == Data("abc".utf8))
        #expect(PDFEncryption.saslPassword(String(repeating: "x", count: 200)).count == 127)
        // A deterministic file: the same random bytes give the same encryption dictionary.
        var counter: UInt8 = 0
        let random: (Int) -> Data = { count in
            Data((0..<count).map { _ in counter &+= 1; return counter })
        }
        let first = PDFEncryption(revision: .r6, userPassword: "u", ownerPassword: "", permissions: -4, random: random)
        counter = 0
        let second = PDFEncryption(revision: .r6, userPassword: "u", ownerPassword: "", permissions: -4, random: random)
        #expect(first.dictionary.text == second.dictionary.text && first.key == second.key)
        #expect(first.encrypt(Data("abc".utf8), object: 3).count == 32)
    }

    // MARK: Spot colours (FX-012)

    static func spot(_ name: String, tint: Double = 1) -> Color {
        let ink = SpotInk(swatch: Corpus.node(99), name: name, tint: tint)
        return Color(cyan: 1 * tint, magenta: 0.44 * tint, yellow: 0, black: 0).asSpot(ink)
    }

    @Test func spotColorsAreSeparations() throws {
        let page = Corpus.page([
            Corpus.path(Corpus.rect(10, 10, 80, 40), [Corpus.fill(.solid(Self.spot("PANTONE 300 C", tint: 0.5))), Corpus.stroke(.solid(Self.spot("PANTONE 300 C")), width: 2)]),
            Corpus.path(Corpus.rect(100, 10, 20, 20), [Corpus.fill(.solid(Color.black.asSpot(.registration)))]),
        ])
        let text = PDFTests.text(of: try PDFExporter().data(scene: Corpus.scene([page]), options: PDFOptions()).data)
        #expect(text.contains("[/Separation /PANTONE#20300#20C /DeviceCMYK <</FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [1 0.44 0 0] /N 1>>]"))
        #expect(text.contains("0.5 scn") && text.contains("1 SCN"))
        #expect(text.contains("[/Separation /All /DeviceCMYK <</FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [1 1 1 1] /N 1>>]"))
        // An sRGB alternate converts to CMYK through the converter.
        let rgb = Color(red: 1, green: 0.5, blue: 0.5).asSpot(SpotInk(swatch: Corpus.node(98), name: "Salmon", tint: 0.5))
        let rgbText = PDFTests.text(of: try PDFExporter().data(scene: Corpus.scene([Corpus.page([Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(.solid(rgb))])])]), options: PDFOptions()).data)
        #expect(rgbText.contains("/Separation /Salmon /DeviceCMYK"))
        for options in [PDFOptions(preserveSpot: false), PDFOptions(colors: .convertToRGB)] {
            #expect(!PDFTests.text(of: try PDFExporter().data(scene: Corpus.scene([page]), options: options).data).contains("/Separation"))
        }
        // PDF/X-1a keeps spot inks.
        let x1a = try PDFExporter().data(scene: Corpus.scene([page]), options: .pressPDFX1a)
        #expect(PDFTests.text(of: x1a.data).contains("/Separation /PANTONE#20300#20C"))
        #expect(!x1a.notes.contains { $0.hasPrefix("PDF/X check") })
    }
}

extension PDFInteractiveTests {
    /// Revision 6 hashes the UTF-8 password (Core Graphics unlocks it); revision 4 writes the
    /// PDFDocEncoding bytes the standard asks for, which Core Graphics does not read, so the
    /// summary warns about any password outside ASCII.
    @Test func nonASCIIPasswordsAreWrittenByTheStandardAndReported() throws {
        let r6 = try Self.export(PDFOptions(version: .v2_0, openPassword: "\u{00E9}t\u{00E9}"))
        let cg = try #require(CGPDFDocument(CGDataProvider(data: r6.data as CFData)!))
        #expect(cg.unlockWithPassword("\u{00E9}t\u{00E9}"))
        let r4 = try Self.export(PDFOptions(version: .v1_7, permissionsPassword: "\u{00FC}ber"))
        for result in [r6, r4] {
            #expect(result.notes.contains { $0.contains("outside ASCII") })
        }
        #expect(!(try Self.export(PDFOptions(openPassword: "plain"))).notes.contains { $0.contains("outside ASCII") })
    }
}
