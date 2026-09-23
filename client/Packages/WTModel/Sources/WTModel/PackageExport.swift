import Foundation
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender

/// The document half of the `.wiretuner` package (saving.adoc, "Packages: a document as a file";
/// IO-005, IO-006): what `PackageWriter` is given for a document -- the zstd snapshot, its state
/// hash, every referenced blob and page 1 -- and the state an opened package holds.
public enum DocumentPackage {
    /// The feature level this client writes and reads (saving.adoc, `feature_level`).
    public static let featureLevel: UInt32 = 1
    /// The merge table version written into manifests.  The generated table identifies itself by a
    /// content hash (`WTMergeTable.version`), not a number; packages carry 1 until it gains one.
    public static let mergeTableVersion: UInt32 = 1

    /// The reader for this client's feature level and merge table.
    public static var reader: PackageReader { PackageReader(featureLevel: featureLevel, mergeTableVersion: mergeTableVersion) }

    /// The manifest's document fields at export.
    public struct Info: Hashable, Sendable {
        public var documentID: String
        public var title: String
        public var exportedBy: String
        public var exportedByName: String
        public var appVersion: String
        /// The last server sequence applied on this replica.
        public var headServerSeq: UInt64
        /// The outbox: local changes not yet acknowledged.
        public var unsyncedChanges: UInt32
        public var exportedAt: Date

        public init(documentID: String, title: String, exportedBy: String = "", exportedByName: String = "", appVersion: String = "",
                    headServerSeq: UInt64 = 0, unsyncedChanges: UInt32 = 0, exportedAt: Date = Date()) {
            self.documentID = documentID
            self.title = title
            self.exportedBy = exportedBy
            self.exportedByName = exportedByName
            self.appVersion = appVersion
            self.headServerSeq = headServerSeq
            self.unsyncedChanges = unsyncedChanges
            self.exportedAt = exportedAt
        }
    }

    /// One blob the document references: its hash, media type and a display name.
    public struct Reference: Hashable, Sendable {
        public var sha256: Data
        public var mediaType: String
        public var name: String
    }

    /// Every blob the live nodes reference (images' pixels, placed files and their previews,
    /// assets), once each, in tree order.
    public static func referencedBlobs(in state: EngineState) -> [Reference] {
        var seen = Set<Data>()
        var out: [Reference] = []
        func add(_ hash: Data, _ mediaType: String, _ name: String) {
            guard hash.count == 32, seen.insert(hash).inserted else { return }
            out.append(Reference(sha256: hash, mediaType: mediaType, name: name))
        }
        for node in liveNodes(in: state) {
            switch state.props(node).kind {
            case .image(let image)?:
                add(image.pixels.blobSha256, mediaType(uti: image.pixels.format), image.sourceName)
            case .placedFile(let placed)?:
                add(placed.content.blobSha256, "application/postscript", placed.content.sourceName)
                add(placed.content.previewSha256, "image/png", placed.content.sourceName)
            case .asset(let asset)?:
                add(asset.sha256, asset.mediaType.isEmpty ? "application/octet-stream" : asset.mediaType, asset.common.name)
            default:
                continue
            }
        }
        return out
    }

    /// The MIME type of a UTI (`public.png` → `image/png`).
    static func mediaType(uti: String) -> String {
        UTType(uti)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Every live node under the document root, parents before children, siblings in order.
    static func liveNodes(in state: EngineState) -> [OpID] {
        var out: [OpID] = []
        func visit(_ node: OpID) {
            for child in state.liveChildren(node) {
                out.append(child)
                visit(child)
            }
        }
        visit(WellKnown.document)
        return out
    }

    /// What `PackageWriter` writes for `state`: the snapshot compressed with zstd and its state
    /// hash, the referenced blobs (`cached` answers a blob's bytes, nil when it is not on this
    /// Mac), and `page` (pasteboard space) drawn from the document for the thumbnail and preview.
    public static func contents(of state: EngineState, info: Info, page: Rect, cached: (Data) -> Data?) -> PackageContents {
        let snapshot = Snapshot.encode(state, serverSeq: info.headServerSeq)
        var manifest = PackageManifest()
        manifest.originDocumentID = info.documentID
        manifest.title = info.title
        manifest.exportedBy = info.exportedBy
        manifest.exportedByName = info.exportedByName
        manifest.exportedAtMs = Int64((info.exportedAt.timeIntervalSince1970 * 1000).rounded(.down))
        manifest.appVersion = info.appVersion
        manifest.featureLevel = featureLevel
        manifest.mergeTableVersion = mergeTableVersion
        manifest.headServerSeq = info.headServerSeq
        manifest.unsyncedChanges = info.unsyncedChanges
        manifest.stateHash = Data(StateHash.of(state.store))
        let blobs = referencedBlobs(in: state).map { reference in
            PackageBlobSource(sha256: reference.sha256, mediaType: reference.mediaType, name: reference.name, data: cached(reference.sha256))
        }
        var builder = DocumentDisplayListBuilder(canvas: CanvasID("package"))
        let displayList = builder.rebuild(state).displayList
        let scene = ExportScene(name: info.title, pages: [ExportPage(bounds: page, displayList: displayList)])
        return PackageContents(manifest: manifest, snapshot: Data(Zstd.compress(snapshot)), blobs: blobs, firstPage: scene)
    }

    /// Why an opened package's document could not be read.
    public enum ReadError: Error, Hashable, Sendable, CustomStringConvertible {
        case snapshot(String)

        public var description: String {
            switch self {
            case .snapshot(let reason): "The document in the package is damaged: \(reason)."
            }
        }
    }

    /// The state `package`'s snapshot holds, checked against the manifest's state hash.
    public static func state(of package: OpenedPackage, schema: Schema = .generated) throws -> EngineState {
        let compressed = Array(package.snapshot)
        guard let size = ZstdFrame.contentSize(compressed) else { throw ReadError.snapshot("it is not a zstd frame with its size") }
        let snapshot: [UInt8]
        do {
            snapshot = try Zstd.decompress(compressed, size: size)
        } catch {
            throw ReadError.snapshot(error.description)
        }
        guard let hash = Snapshot.stateHash(snapshot), package.manifest.stateHash.isEmpty || Data(hash) == package.manifest.stateHash else {
            throw ReadError.snapshot("its state hash does not match the manifest")
        }
        do {
            return try Snapshot.decode(snapshot, schema: schema)
        } catch {
            throw ReadError.snapshot(error.description)
        }
    }
}

/// The content size a zstd frame header declares (RFC 8878, 3.1.1.1), which `Zstd.decompress`
/// needs; nil when the bytes are not a frame or the size is not recorded.
enum ZstdFrame {
    static func contentSize(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 6, bytes[0] == 0x28, bytes[1] == 0xB5, bytes[2] == 0x2F, bytes[3] == 0xFD else { return nil }
        let descriptor = bytes[4]
        let sizeFlag = Int(descriptor >> 6)
        let singleSegment = descriptor & 0x20 != 0
        let dictionaryBytes = [0, 1, 2, 4][Int(descriptor & 0x03)]
        let sizeBytes = [singleSegment ? 1 : 0, 2, 4, 8][sizeFlag]
        guard sizeBytes > 0 else { return nil }
        let start = 5 + (singleSegment ? 0 : 1) + dictionaryBytes
        guard bytes.count >= start + sizeBytes else { return nil }
        var value: UInt64 = 0
        for index in (0..<sizeBytes).reversed() {
            value = value << 8 | UInt64(bytes[start + index])
        }
        if sizeBytes == 2 { value += 256 }
        return value <= UInt64(Int.max) ? Int(value) : nil
    }
}
