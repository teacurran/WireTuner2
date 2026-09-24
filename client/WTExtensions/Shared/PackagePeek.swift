import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// What Quick Look reads of a `.wiretuner` package (saving.adoc, "Client"; IO-034): the thumbnail,
/// the page-1 preview and the manifest's display fields, found through the zip's central directory
/// with only those entries inflated -- the file is memory-mapped, so a 500 MiB package costs a few
/// pages -- with no WTModel, no protobuf runtime and no network.  Compiled into the Quick Look
/// extensions and into the app (whose tests read packages `PackageWriter` wrote).
struct PackagePeek {
    /// The manifest fields Quick Look shows (`PackageManifest`, protobuf JSON, lowerCamelCase).
    struct Manifest: Equatable {
        var title: String
        var exportedByName: String
        var exportedAt: Date?
        var unsyncedChanges: Int
    }

    enum Failure: Error, Equatable {
        case notAZip
        case missing(String)
        case unsupported(String)
    }

    struct Entry: Equatable {
        var method: UInt16
        var compressedSize: Int
        var size: Int
        var headerOffset: Int
    }

    static let manifestName = "manifest.json"
    static let thumbnailName = "thumbnail.png"
    static let previewName = "preview.pdf"

    let data: Data
    let entries: [String: Entry]

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    init(data: Data) throws {
        self.data = data
        entries = try Self.directory(of: data)
    }

    /// The central directory: from the end record (the last 22 bytes plus a comment).
    static func directory(of data: Data) throws -> [String: Entry] {
        guard data.count >= 22 else { throw Failure.notAZip }
        var end = data.count - 22
        let lowest = max(0, end - 65_535)
        while end >= lowest, read32(data, end) != 0x0605_4B50 { end -= 1 }
        guard end >= lowest else { throw Failure.notAZip }
        let count = Int(read16(data, end + 10))
        var cursor = Int(read32(data, end + 16))
        var entries: [String: Entry] = [:]
        for _ in 0..<count {
            guard cursor + 46 <= end, read32(data, cursor) == 0x0201_4B50 else { throw Failure.notAZip }
            let nameLength = Int(read16(data, cursor + 28))
            let start = data.startIndex + cursor + 46
            guard cursor + 46 + nameLength <= end else { throw Failure.notAZip }
            let name = String(decoding: data[start..<(start + nameLength)], as: UTF8.self)
            entries[name] = Entry(method: read16(data, cursor + 10), compressedSize: Int(read32(data, cursor + 20)),
                                  size: Int(read32(data, cursor + 24)), headerOffset: Int(read32(data, cursor + 42)))
            cursor += 46 + nameLength + Int(read16(data, cursor + 30)) + Int(read16(data, cursor + 32))
        }
        return entries
    }

    /// The bytes of entry `name`: stored, or deflated (inflated here).
    func contents(of name: String) throws -> Data {
        guard let entry = entries[name] else { throw Failure.missing(name) }
        let header = entry.headerOffset
        guard header + 30 <= data.count, Self.read32(data, header) == 0x0403_4B50 else { throw Failure.notAZip }
        let start = header + 30 + Int(Self.read16(data, header + 26)) + Int(Self.read16(data, header + 28))
        guard start + entry.compressedSize <= data.count else { throw Failure.notAZip }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        switch entry.method {
        case 0: return raw
        case 8:
            guard entry.size > 0 else { return Data() }
            guard let inflated = try? (raw as NSData).decompressed(using: .zlib) as Data, inflated.count == entry.size else {
                throw Failure.unsupported("damaged \(name)")
            }
            return inflated
        default: throw Failure.unsupported("compression method \(entry.method)")
        }
    }

    /// The manifest's display fields; nil when it is missing or not JSON.
    var manifest: Manifest? {
        guard let bytes = try? contents(of: Self.manifestName),
              let json = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? {
            if let value = json[key] as? NSNumber { return value.doubleValue }
            return (json[key] as? String).flatMap(Double.init)
        }
        return Manifest(title: json["title"] as? String ?? "", exportedByName: json["exportedByName"] as? String ?? "",
                        exportedAt: number("exportedAtMs").map { Date(timeIntervalSince1970: $0 / 1000) },
                        unsyncedChanges: Int(number("unsyncedChanges") ?? 0))
    }

    var thumbnail: Data? { try? contents(of: Self.thumbnailName) }
    var preview: Data? { try? contents(of: Self.previewName) }

    /// The notice for a package exported with changes that had not reached the cloud.
    static let unsyncedNote = "Contains changes that had not been synced when it was exported."

    /// The preview's header: the title, who exported it and when, and the unsynced note.
    static func header(_ manifest: Manifest, locale: Locale = .current) -> String {
        var lines = [manifest.title.isEmpty ? "Untitled" : manifest.title]
        var byline: [String] = []
        if !manifest.exportedByName.isEmpty { byline.append("Exported by \(manifest.exportedByName)") }
        if let date = manifest.exportedAt {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            byline.append(formatter.string(from: date))
        }
        if !byline.isEmpty { lines.append(byline.joined(separator: ", ")) }
        if manifest.unsyncedChanges > 0 { lines.append(unsyncedNote) }
        return lines.joined(separator: "\n")
    }

    /// The thumbnail fitted into `size` (points at `scale`), with the *Offline changes* badge in
    /// the corner when the package holds unsynced changes; nil without a readable thumbnail.
    func thumbnailImage(fitting size: CGSize, scale: CGFloat = 1) -> CGImage? {
        guard let png = thumbnail, let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), size.width > 0, size.height > 0 else { return nil }
        let fit = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height)) * scale
        let width = max(1, Int(CGFloat(image.width) * fit)), height = max(1, Int(CGFloat(image.height) * fit))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        if (manifest?.unsyncedChanges ?? 0) > 0 {
            let diameter = max(6, CGFloat(min(width, height)) / 5)
            let badge = CGRect(x: CGFloat(width) - diameter * 1.15, y: diameter * 0.15, width: diameter, height: diameter)
            context.setFillColor(CGColor(red: 1, green: 0.58, blue: 0, alpha: 1))
            context.fillEllipse(in: badge)
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.setLineWidth(max(1, diameter / 10))
            context.strokeEllipse(in: badge.insetBy(dx: diameter / 20, dy: diameter / 20))
        }
        return context.makeImage()
    }

    /// The Quick Look preview: the header over page 1 in a `PDFView`, or over the thumbnail when the
    /// package has no `preview.pdf` (written before it existed).
    @MainActor
    func previewView(frame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 600)) -> NSView {
        let container = NSStackView(frame: frame)
        container.orientation = .vertical
        container.alignment = .leading
        container.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let header = NSTextField(wrappingLabelWithString: Self.header(manifest ?? Manifest(title: "", exportedByName: "", unsyncedChanges: 0)))
        header.setAccessibilityIdentifier("package.header")
        container.addArrangedSubview(header)
        if let pdf = preview.flatMap(PDFDocument.init(data:)) {
            let view = PDFView()
            view.document = pdf
            view.autoScales = true
            view.setAccessibilityIdentifier("package.preview")
            container.addArrangedSubview(view)
        } else {
            let view = NSImageView()
            view.image = thumbnail.flatMap(NSImage.init(data:))
            view.imageScaling = .scaleProportionallyUpOrDown
            view.setAccessibilityIdentifier("package.thumbnail")
            container.addArrangedSubview(view)
        }
        return container
    }

    static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(read16(data, offset)) | UInt32(read16(data, offset + 2)) << 16
    }
}
