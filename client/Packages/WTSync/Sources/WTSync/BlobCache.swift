import CryptoKit
import Foundation
import Synchronization
import WTProto

/// The content-addressed local blob cache (docs/spec/sync-protocol.adoc, "Blobs"; SYNC-008):
/// images, embedded fonts and thumbnails by their sha256, under
/// `~/Library/Application Support/WireTuner/Blobs/<first two hex digits>/<hex sha256>`, shared by
/// every document.  A blob is written to a temporary file and moved into place once its hash is
/// known, so a path in the cache always holds exactly the bytes its name says.
public struct BlobCache: Sendable {
    /// Why a blob could not be stored.
    public enum Failure: Error, Equatable {
        /// Downloaded bytes whose sha256 is not the one asked for.
        case hashMismatch(expected: String, actual: String)
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/WireTuner/Blobs`.
    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(components: "WireTuner", "Blobs")
    }

    /// Where the blob `hash` (lower-case hex sha256) lives, whether or not it is there.
    public func url(for hash: String) -> URL {
        directory.appending(components: String(hash.prefix(2)), hash)
    }

    /// Whether the blob `hash` is cached.
    public func contains(_ hash: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: hash).path)
    }

    /// Stores `data` and returns its hash.
    @discardableResult
    public func insert(_ data: Data) throws -> String {
        let hash = Self.hex(SHA256.hash(data: data))
        let temporary = try temporaryURL()
        try data.write(to: temporary)
        try adopt(temporary, as: hash)
        return hash
    }

    /// Copies the file at `file` into the cache, hashing it as it is read `chunkSize` bytes at a
    /// time (a 100 MiB image is never held in memory), and returns its hash and size.
    public func insert(contentsOf file: URL, chunkSize: Int = 1 << 20) throws -> (hash: String, size: Int64) {
        let temporary = try temporaryURL()
        // Gone once adopted; left behind only by a failed copy.
        defer { try? FileManager.default.removeItem(at: temporary) }
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        let reader = BlobChunks.Reader(file)
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try reader.next(chunkSize) {
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
            size += Int64(chunk.count)
        }
        let hash = Self.hex(hasher.finalize())
        try adopt(temporary, as: hash)
        return (hash, size)
    }

    /// A fresh file name in the cache's scratch directory (same volume, so moving is atomic).
    func temporaryURL() throws -> URL {
        let scratch = directory.appending(path: "incoming")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch.appending(path: UUID().uuidString)
    }

    /// Moves `temporary` into place as the blob `hash` (dropping it when that blob is cached).
    @discardableResult
    func adopt(_ temporary: URL, as hash: String) throws -> URL {
        let target = url(for: hash)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
        return target
    }

    /// Lower-case hex of a digest.
    static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The 32 raw bytes a hex sha256 names (what travels on the wire).
    static func bytes(hex: String) -> Data {
        let digits = Array(hex.utf8)
        return Data(stride(from: 0, to: digits.count - 1, by: 2).map { UInt8(Self.nibble(digits[$0]) << 4 | Self.nibble(digits[$0 + 1])) })
    }

    private static func nibble(_ digit: UInt8) -> UInt8 {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        default: 0
        }
    }
}

/// The blob service as the client calls it (`wiretuner.blob.v1.BlobService`, PROTO-008):
/// `GRPCSyncTransport` implements it on the document's connection.
public protocol BlobTransport: Sendable {
    func stat(_ request: Wiretuner_Blob_V1_StatRequest, token: String) async throws -> Wiretuner_Blob_V1_StatResponse
    /// A client-streaming upload: `header`, then the chunks as `chunks` yields them.
    func upload(_ header: Wiretuner_Blob_V1_UploadHeader, chunks: AsyncThrowingStream<Data, any Error>, token: String) async throws
        -> Wiretuner_Blob_V1_UploadResponse
    func download(_ request: Wiretuner_Blob_V1_DownloadRequest, token: String)
        -> AsyncThrowingStream<Wiretuner_Blob_V1_DownloadResponse, any Error>
}

/// A file read lazily in chunks, for an upload that must not load it whole: the next chunk is read
/// only when the upload asks for it.
enum BlobChunks {
    static func read(_ url: URL, chunkSize: Int) -> AsyncThrowingStream<Data, any Error> {
        let reader = Reader(url)
        return AsyncThrowingStream(unfolding: { try reader.next(chunkSize) })
    }

    final class Reader: Sendable {
        private let url: URL
        private let handle = Mutex<FileHandle?>(nil)

        init(_ url: URL) {
            self.url = url
        }

        /// The next chunk, nil at the end (the file is closed then).
        func next(_ size: Int) throws -> Data? {
            try handle.withLock { handle in
                if handle == nil {
                    handle = try FileHandle(forReadingFrom: url)
                }
                guard let chunk = try handle!.read(upToCount: size), !chunk.isEmpty else {
                    try handle?.close()
                    return nil
                }
                return chunk
            }
        }
    }
}
