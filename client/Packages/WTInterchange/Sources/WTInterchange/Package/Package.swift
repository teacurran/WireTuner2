// The `.wiretuner` package (saving.adoc, "Data model" and "Client"; D-038; IO-005, IO-006): a zip
// of `manifest.json`, `snapshot.pb.zst`, `blobs/<sha256>`, `thumbnail.png` and `preview.pdf`, in
// that order so a reader can stream the manifest first.  WTInterchange knows nothing of the
// snapshot's contents: `WTModel` supplies the zstd-compressed `DocumentSnapshot` bytes and their
// state hash when exporting, and decodes them and re-issues the state as fresh ops when opening
// (saving.adoc, "Client").  The writer collects blobs (listing the ones not in the cache as
// missing), renders the thumbnail and the page-1 preview PDF from an export scene of page 1; the
// reader validates the archive and the manifest before anything is created.

import Foundation
import CoreGraphics
import UniformTypeIdentifiers
import WTGeometry
import WTRender

/// Why a package could not be written or opened.
public enum PackageError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The zip is damaged.
    case archive(ZipError)
    /// `manifest.json` is missing or not a manifest.
    case malformedManifest(String)
    /// Not a {product} package (`format` differs).
    case notAPackage(String)
    /// A package format version this client does not read.
    case unsupportedFormatVersion(UInt32)
    /// The document needs a newer {product}: its feature level is above this client's.
    case needsUpdate(featureLevel: UInt32, supported: UInt32)
    /// The snapshot was written with a merge table this client does not have.
    case unsupportedMergeTable(version: UInt32, supported: UInt32)
    /// `snapshot.pb.zst` is missing or empty.
    case missingSnapshot
    /// A blob's bytes do not hash to its name.
    case corruptBlob(String)
    /// There is no page to render the thumbnail from.
    case nothingToExport
    /// The file could not be written.
    case writeFailed(String)

    public var description: String {
        switch self {
        case .archive(let error): return "The package is damaged. \(error.description)"
        case .malformedManifest(let reason): return "The package's manifest is damaged: \(reason)."
        case .notAPackage(let format): return "This is not a WireTuner package (its format is “\(format)”)."
        case .unsupportedFormatVersion(let version): return "This package uses format version \(version), which this version of WireTuner cannot open.  Update WireTuner to open it."
        case .needsUpdate(let level, let supported): return "This document needs a newer version of WireTuner (feature level \(level); this version supports \(supported)).  Update WireTuner to open it."
        case .unsupportedMergeTable(let version, let supported): return "This document was saved with merge table \(version); this version of WireTuner has \(supported).  Update WireTuner to open it."
        case .missingSnapshot: return "The package has no document in it."
        case .corruptBlob(let name): return "The image or font “\(name)” in the package is damaged."
        case .nothingToExport: return "There is no page to put in the package."
        case .writeFailed(let reason): return "The package could not be written: \(reason)"
        }
    }
}

/// The entry names of a package.
public enum PackageEntry {
    public static let manifest = "manifest.json"
    public static let snapshot = "snapshot.pb.zst"
    public static let blobPrefix = "blobs/"
    public static let thumbnail = "thumbnail.png"
    public static let preview = "preview.pdf"
}

/// A blob the snapshot references: its bytes when they are in the local cache, else nil (listed
/// in `missing_blobs`).
public struct PackageBlobSource: Hashable, Sendable {
    public var sha256: Data
    public var mediaType: String
    public var name: String
    public var data: Data?

    public init(sha256: Data, mediaType: String, name: String = "", data: Data?) {
        self.sha256 = sha256
        self.mediaType = mediaType
        self.name = name
        self.data = data
    }

    /// A cached blob, its hash computed from `data`.
    public init(data: Data, mediaType: String, name: String = "") {
        self.init(sha256: ImportedBlob.hash(data), mediaType: mediaType, name: name, data: data)
    }
}

/// What a package holds, as the exporting `WTModel` supplies it.
public struct PackageContents: Sendable {
    /// The manifest's document fields; `format`, `format_version`, `blobs` and `missing_blobs`
    /// are filled by the writer.
    public var manifest: PackageManifest
    /// `DocumentSnapshot`, zstd, exactly the format of `FetchSnapshot` chunks concatenated.
    public var snapshot: Data
    /// Every blob referenced from the snapshot's assets node.
    public var blobs: [PackageBlobSource]
    /// Page 1 as an export scene: the thumbnail and `preview.pdf` are rendered from its first
    /// page.
    public var firstPage: ExportScene
    /// A thumbnail already rendered (the library's), used instead of rendering one.
    public var thumbnail: Data?

    public init(manifest: PackageManifest, snapshot: Data, blobs: [PackageBlobSource] = [], firstPage: ExportScene, thumbnail: Data? = nil) {
        self.manifest = manifest
        self.snapshot = snapshot
        self.blobs = blobs
        self.firstPage = firstPage
        self.thumbnail = thumbnail
    }
}

/// What an export wrote.
public struct PackageSummary: Hashable, Sendable {
    /// The manifest as written.
    public var manifest: PackageManifest
    /// Whether `preview.pdf` was written (false only when the PDF writer failed).
    public var wrotePreview: Bool
    /// For the export sheet: missing blobs by name, a skipped preview.
    public var notes: [String]
}

/// Writes packages (IO-005).
public struct PackageWriter: Sendable {
    /// The long edge of `thumbnail.png`, in pixels.
    public static let thumbnailSize = 1024

    /// The PDF options of `preview.pdf`: the *Screen* preset (export-pdf.adoc: images above
    /// 150 ppi downsampled to 100 ppi, RGB) with fonts embedded, no tags and no package
    /// attachment.
    public static let previewOptions = PDFOptions(colorImages: .jpeg, downsample: true, downsampleAbovePPI: 150, downsampleToPPI: 100, fonts: .embedSubset, colors: .convertToRGB, embedProfiles: false, pageSize: .page)

    /// Renders the preview; replaceable so tests can make the PDF writer fail.
    public var renderPreview: @Sendable (ExportScene) throws -> Data

    public init(renderPreview: @escaping @Sendable (ExportScene) throws -> Data = PackageWriter.preview) {
        self.renderPreview = renderPreview
    }

    /// Page 1 of `scene` as a one-page PDF with the preview options.
    @Sendable public static func preview(_ scene: ExportScene) throws -> Data {
        var page = scene
        page.pages = Array(scene.pages.prefix(1))
        return try PDFExporter().data(scene: page, options: previewOptions).data
    }

    /// Writes `contents` to `url` (streamed entry by entry).
    @discardableResult
    public func write(_ contents: PackageContents, to url: URL) throws -> PackageSummary {
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) else {
            throw PackageError.writeFailed("“\(url.lastPathComponent)” could not be created.")
        }
        defer { try? handle.close() }
        return try write(contents) { try handle.write(contentsOf: $0) }
    }

    /// The package as bytes.
    public func data(_ contents: PackageContents) throws -> (data: Data, summary: PackageSummary) {
        var data = Data()
        let summary = try write(contents) { data.append($0) }
        return (data, summary)
    }

    func write(_ contents: PackageContents, sink: @escaping (Data) throws -> Void) throws -> PackageSummary {
        guard !contents.firstPage.pages.isEmpty else {
            throw PackageError.nothingToExport
        }
        var manifest = contents.manifest
        manifest.format = PackageManifest.formatName
        manifest.formatVersion = PackageManifest.currentFormatVersion
        manifest.blobs = []
        manifest.missingBlobs = []
        var notes: [String] = []
        var present: [(PackageBlob, Data)] = []
        var seen = Set<Data>()
        for source in contents.blobs where seen.insert(source.sha256).inserted {
            if let data = source.data, ImportedBlob.hash(data) == source.sha256 {
                let blob = PackageBlob(sha256: source.sha256, size: UInt64(data.count), mediaType: source.mediaType, name: source.name)
                manifest.blobs.append(blob)
                present.append((blob, data))
            } else {
                manifest.missingBlobs.append(PackageBlob(sha256: source.sha256, size: 0, mediaType: source.mediaType, name: source.name))
                let label = source.name.isEmpty ? ImportedBlob.hex(source.sha256) : source.name
                notes.append("“\(label)” is not on this Mac and was left out of the package.")
            }
        }
        let thumbnail = try contents.thumbnail ?? PackageWriter.thumbnail(contents.firstPage)
        var preview: Data?
        do {
            preview = try renderPreview(contents.firstPage)
        } catch {
            notes.append("The Quick Look preview could not be written (\(error)); the package uses its thumbnail instead.")
        }
        do {
            let zip = ZipWriter(date: manifest.exportedAtMs > 0 ? Date(timeIntervalSince1970: Double(manifest.exportedAtMs) / 1000) : Date(), sink: sink)
            try zip.add(PackageEntry.manifest, data: manifest.jsonData())
            try zip.add(PackageEntry.snapshot, data: contents.snapshot, method: .stored)
            for (blob, data) in present {
                try zip.add(PackageEntry.blobPrefix + blob.hex, data: data)
            }
            try zip.add(PackageEntry.thumbnail, data: thumbnail)
            if let preview {
                try zip.add(PackageEntry.preview, data: preview)
            }
            try zip.finish()
        } catch let error as ZipError {
            throw PackageError.archive(error)
        } catch {
            throw PackageError.writeFailed(error.localizedDescription)
        }
        return PackageSummary(manifest: manifest, wrotePreview: preview != nil, notes: notes)
    }

    /// The first page rendered at `thumbnailSize` pixels on the long edge, sRGB with alpha, PNG.
    /// Drawn straight through the reference renderer with Core Graphics anti-aliasing: a
    /// thumbnail needs no supersampling, and skipping it keeps a package export fast.
    static func thumbnail(_ scene: ExportScene) throws -> Data {
        let page = scene.pages[0]
        let longEdge = max(page.bounds.width, page.bounds.height, 1)
        let scale = Double(PackageWriter.thumbnailSize) / longEdge
        let width = max(Int((page.bounds.width * scale).rounded()), 1)
        let height = max(Int((page.bounds.height * scale).rounded()), 1)
        // An sRGB 8-bit premultiplied context of at most 1024 × 1024 always exists.
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        let viewport = Viewport(scrollOrigin: Point(x: page.bounds.minX, y: page.bounds.minY), zoom: 1, size: Size(width: page.bounds.width, height: page.bounds.height))
        var renderer = CoreGraphicsRenderer(background: nil)
        renderer.rasterPreview = .document
        renderer.render(page.displayList, viewport: viewport, into: context)
        return ImageEncoding.encode(context.makeImage()!, type: .png)!
    }
}

/// An opened package, validated.
public struct OpenedPackage: Sendable {
    public var manifest: PackageManifest
    /// The zstd-compressed snapshot, for `WTModel` to decode and re-issue.
    public var snapshot: Data
    /// Every blob present, by SHA-256; each verified against its hash.
    public var blobs: [Data: Data]
    public var thumbnail: Data?
    /// Nil when the package has none (packages made before previews were written).
    public var preview: Data?

    /// The blob of `blob`, if present.
    public func data(for blob: PackageBlob) -> Data? {
        blobs[blob.sha256]
    }
}

/// Reads packages (IO-006).
public struct PackageReader: Sendable {
    /// The feature level this client implements.
    public var featureLevel: UInt32
    /// The merge table version this client has; packages written with a newer one are refused.
    public var mergeTableVersion: UInt32

    public init(featureLevel: UInt32, mergeTableVersion: UInt32) {
        self.featureLevel = featureLevel
        self.mergeTableVersion = mergeTableVersion
    }

    /// The manifest alone, reading nothing else (Quick Look, Spotlight).
    public static func manifest(of data: Data) throws -> PackageManifest {
        let zip = try archive(data)
        return try manifest(in: zip)
    }

    /// The thumbnail alone.
    public static func thumbnail(of data: Data) throws -> Data {
        try entry(PackageEntry.thumbnail, in: archive(data))
    }

    /// The package at `url`, opened and validated.
    public func open(contentsOf url: URL) throws -> OpenedPackage {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw PackageError.archive(.malformed(error.localizedDescription))
        }
        return try open(data)
    }

    /// `data` opened: the zip and every entry's CRC, the manifest's format, version, feature
    /// level and merge table, the snapshot's presence and every blob's hash.  Nothing is
    /// created until this succeeds, so a damaged package never makes a document.
    public func open(_ data: Data) throws -> OpenedPackage {
        let zip = try PackageReader.archive(data)
        let manifest = try PackageReader.manifest(in: zip)
        guard manifest.format == PackageManifest.formatName else {
            throw PackageError.notAPackage(manifest.format)
        }
        guard manifest.formatVersion == PackageManifest.currentFormatVersion else {
            throw PackageError.unsupportedFormatVersion(manifest.formatVersion)
        }
        guard manifest.featureLevel <= featureLevel else {
            throw PackageError.needsUpdate(featureLevel: manifest.featureLevel, supported: featureLevel)
        }
        guard manifest.mergeTableVersion <= mergeTableVersion else {
            throw PackageError.unsupportedMergeTable(version: manifest.mergeTableVersion, supported: mergeTableVersion)
        }
        guard zip.entry(PackageEntry.snapshot) != nil, let snapshot = try? PackageReader.entry(PackageEntry.snapshot, in: zip), !snapshot.isEmpty else {
            throw PackageError.missingSnapshot
        }
        var blobs: [Data: Data] = [:]
        for blob in manifest.blobs {
            let name = PackageEntry.blobPrefix + blob.hex
            guard zip.entry(name) != nil else {
                continue
            }
            let bytes = try PackageReader.entry(name, in: zip)
            guard ImportedBlob.hash(bytes) == blob.sha256 else {
                throw PackageError.corruptBlob(blob.name.isEmpty ? blob.hex : blob.name)
            }
            blobs[blob.sha256] = bytes
        }
        let thumbnail = zip.entry(PackageEntry.thumbnail) == nil ? nil : try PackageReader.entry(PackageEntry.thumbnail, in: zip)
        let preview = zip.entry(PackageEntry.preview) == nil ? nil : try PackageReader.entry(PackageEntry.preview, in: zip)
        return OpenedPackage(manifest: manifest, snapshot: snapshot, blobs: blobs, thumbnail: thumbnail, preview: preview)
    }

    static func archive(_ data: Data) throws -> ZipReader {
        do {
            return try ZipReader(data: data)
        } catch let error as ZipError {
            throw PackageError.archive(error)
        }
    }

    static func entry(_ name: String, in zip: ZipReader) throws -> Data {
        do {
            return try zip.contents(of: name)
        } catch let error as ZipError {
            throw PackageError.archive(error)
        }
    }

    static func manifest(in zip: ZipReader) throws -> PackageManifest {
        guard zip.entry(PackageEntry.manifest) != nil else {
            throw PackageError.malformedManifest("the package has no manifest.json")
        }
        return try PackageManifest(jsonData: entry(PackageEntry.manifest, in: zip))
    }
}
