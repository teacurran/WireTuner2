import AppKit
import PDFKit
import Testing
import WTGeometry
import WTInterchange
import WTModel
@testable import WireTuner

/// What the Quick Look extensions read of a package (IO-034), through `PackagePeek`.
@Suite(.serialized) @MainActor struct QuickLookTests {
    /// A zip of `entries` as the package writer writes them.
    static func zip(_ entries: [(String, Data, ZipMethod)]) throws -> Data {
        var data = Data()
        let writer = ZipWriter(date: Date(timeIntervalSince1970: 1_790_000_000)) { data.append($0) }
        for (name, bytes, method) in entries { try writer.add(name, data: bytes, method: method) }
        try writer.finish()
        return data
    }

    static func png() -> Data {
        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    static func manifest(unsynced: Int) -> Data {
        Data("{\"format\":\"wiretuner-package\",\"title\":\"Poster\",\"exportedByName\":\"Priya\",\"exportedAtMs\":\"1790000000000\",\"unsyncedChanges\":\(unsynced)}".utf8)
    }

    @Test func aPackageFromTheExportReadsItsManifestThumbnailAndPreview() async throws {
        let directory = TestEnvironment.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = DocumentHandle.memory(title: "Exported")
        await document.addRectangles([Rect(x: 0, y: 0, width: 50, height: 50)])
        let url = directory.appending(path: "Exported.wiretuner")
        _ = try await PackageController().export(document, to: url)
        let peek = try PackagePeek(url: url)
        #expect(peek.manifest?.title == "Exported" && peek.manifest?.unsyncedChanges == 0)
        #expect(peek.thumbnail != nil && peek.preview.flatMap(PDFDocument.init(data:))?.pageCount == 1)
        let image = try #require(peek.thumbnailImage(fitting: CGSize(width: 128, height: 128), scale: 2))
        #expect(max(image.width, image.height) == 256)
        let view = peek.previewView()
        #expect(view.subviews.contains { $0 is PDFView })
    }

    @Test func theUnsyncedBadgeTheHeaderAndTheThumbnailFallback() throws {
        let png = Self.png()
        let clean = try PackagePeek(data: Self.zip([("manifest.json", Self.manifest(unsynced: 0), .deflate), ("thumbnail.png", png, .stored)]))
        let dirty = try PackagePeek(data: Self.zip([("manifest.json", Self.manifest(unsynced: 3), .deflate), ("thumbnail.png", png, .stored)]))
        let manifest = try #require(dirty.manifest)
        #expect(manifest == PackagePeek.Manifest(title: "Poster", exportedByName: "Priya", exportedAt: Date(timeIntervalSince1970: 1_790_000_000), unsyncedChanges: 3))
        let header = PackagePeek.header(manifest, locale: Locale(identifier: "en_US_POSIX"))
        #expect(header.hasPrefix("Poster\nExported by Priya, ") && header.hasSuffix(PackagePeek.unsyncedNote))
        #expect(PackagePeek.header(PackagePeek.Manifest(title: "", exportedByName: "", unsyncedChanges: 0)) == "Untitled")
        // The badge paints the corner orange.
        let plain = try #require(clean.thumbnailImage(fitting: CGSize(width: 40, height: 20)))
        let badged = try #require(dirty.thumbnailImage(fitting: CGSize(width: 40, height: 20)))
        #expect(Self.pixel(badged, x: 36, y: 16) != Self.pixel(plain, x: 36, y: 16))
        #expect(clean.thumbnailImage(fitting: .zero) == nil)
        // No preview.pdf: the thumbnail stands in.
        #expect(clean.preview == nil && dirty.previewView().subviews.contains { $0 is NSImageView })
        // No manifest: an untitled header.
        let bare = try PackagePeek(data: Self.zip([("thumbnail.png", png, .deflate)]))
        #expect(bare.manifest == nil && bare.thumbnail == png)
        #expect((bare.previewView().subviews.first as? NSTextField)?.stringValue == "Untitled")
        let empty = try PackagePeek(data: Self.zip([("manifest.json", Data("{}".utf8), .stored)]))
        #expect(empty.manifest == PackagePeek.Manifest(title: "", exportedByName: "", unsyncedChanges: 0))
        #expect(bare.thumbnailImage(fitting: CGSize(width: 10, height: 10)) != nil, "no manifest, no badge")
        let junk = try PackagePeek(data: Self.zip([("manifest.json", Data("[1]".utf8), .stored)]))
        #expect(junk.manifest == nil && junk.thumbnailImage(fitting: CGSize(width: 10, height: 10)) == nil)
    }

    @Test func damagedArchivesAreRefused() throws {
        #expect(throws: PackagePeek.Failure.notAZip) { try PackagePeek(data: Data("tiny".utf8)) }
        #expect(throws: PackagePeek.Failure.notAZip) { try PackagePeek(data: Data(repeating: 1, count: 100)) }
        let text = Data(repeating: 0x61, count: 500)
        let good = try Self.zip([("a", text, .deflate), ("empty", Data(), .deflate)])
        let peek = try PackagePeek(data: good)
        #expect(try peek.contents(of: "a") == text && peek.contents(of: "empty").isEmpty)
        #expect(throws: PackagePeek.Failure.missing("b")) { try peek.contents(of: "b") }
        // A method other than stored and deflate, a local header that is not one, a truncated entry,
        // damaged deflate data, a directory entry pointing past its end.
        var method = good
        let central = try #require(Self.find(method, [0x50, 0x4B, 0x01, 0x02]))
        method[central + 10] = 99
        #expect(throws: PackagePeek.Failure.unsupported("compression method 99")) { try PackagePeek(data: method).contents(of: "a") }
        var header = good
        header[0] = 0
        #expect(throws: PackagePeek.Failure.notAZip) { try PackagePeek(data: header).contents(of: "a") }
        var size = good
        size[central + 20] = 0xFF
        size[central + 21] = 0xFF
        #expect(throws: PackagePeek.Failure.notAZip) { try PackagePeek(data: size).contents(of: "a") }
        var inflate = good
        for offset in 31..<36 { inflate[offset] = 0xFF }
        #expect(throws: (any Error).self) { try PackagePeek(data: inflate).contents(of: "a") }
        var directory = good
        directory[central + 28] = 0xFF
        #expect(throws: PackagePeek.Failure.notAZip) { try PackagePeek(data: directory) }
        // An empty entry marked deflated reads as empty.
        var deflatedEmpty = good
        let second = try #require(Self.find(Data(good[(central + 4)...]), [0x50, 0x4B, 0x01, 0x02])).advanced(by: central + 4)
        deflatedEmpty[second + 10] = 8
        #expect(try PackagePeek(data: deflatedEmpty).contents(of: "empty").isEmpty)
        var entry = good
        entry[central] = 0
        #expect(throws: PackagePeek.Failure.notAZip) { try PackagePeek(data: entry) }
    }

    static func find(_ data: Data, _ signature: [UInt8]) -> Int? {
        let bytes = [UInt8](data)
        return (0...(bytes.count - signature.count)).first { Array(bytes[$0..<($0 + signature.count)]) == signature }
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return pixel
    }
}
