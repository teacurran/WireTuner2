import CryptoKit
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import SwiftProtobuf
import WTProto

/// The calls of `PublishService` (publish-html.adoc, "Publishing to a web link"; WEB-011 and
/// WEB-012 built the server).  `GRPCPublishTransport` is the network one; tests and the simulator
/// supply their own.
public protocol PublishTransport: Sendable {
    func createPublish(_ request: Wiretuner_Publish_V1_CreatePublishRequest, token: String) async throws
        -> Wiretuner_Publish_V1_CreatePublishResponse
    func getPublish(_ request: Wiretuner_Publish_V1_GetPublishRequest, token: String) async throws
        -> Wiretuner_Publish_V1_GetPublishResponse
    func listPublishes(_ request: Wiretuner_Publish_V1_ListPublishesRequest, token: String) async throws
        -> Wiretuner_Publish_V1_ListPublishesResponse
    func setPublishAccess(_ request: Wiretuner_Publish_V1_SetPublishAccessRequest, token: String) async throws
        -> Wiretuner_Publish_V1_SetPublishAccessResponse
    func deletePublish(_ request: Wiretuner_Publish_V1_DeletePublishRequest, token: String) async throws
        -> Wiretuner_Publish_V1_DeletePublishResponse
}

/// `PublishTransport` over grpc-swift 2, with the metadata of api-conventions.adoc; rejections
/// arrive as `SyncCallError`s as they do from `GRPCSyncTransport`.
public final class GRPCPublishTransport<Transport: ClientTransport>: PublishTransport {
    private let client: GRPCClient<Transport>
    private let service: Wiretuner_Publish_V1_PublishService.Client<Transport>
    private let identity: GRPCSyncTransport<Transport>.Identity
    private let connections: Task<Void, Never>

    /// A transport over `transport`; its connections run until `close()`.
    public init(transport: Transport, identity: GRPCSyncTransport<Transport>.Identity) {
        let client = GRPCClient(transport: transport)
        self.client = client
        service = Wiretuner_Publish_V1_PublishService.Client(wrapping: client)
        self.identity = identity
        connections = Task { try? await client.runConnections() }
    }

    /// Closes the connection once in-flight calls have finished.
    public func close() async {
        client.beginGracefulShutdown()
        await connections.value
    }

    private func metadata(_ token: String) -> Metadata {
        var metadata = Metadata()
        metadata.addString("Bearer \(token)", forKey: "authorization")
        metadata.addString("macos/\(identity.clientVersion)", forKey: "wt-client")
        metadata.addString(identity.deviceID, forKey: "wt-device")
        metadata.addString(UUID().uuidString, forKey: "wt-request-id")
        return metadata
    }

    private func unary<Output: Sendable>(_ body: () async throws -> Output) async throws -> Output {
        do {
            return try await body()
        } catch {
            throw GRPCSyncTransport<Transport>.mapped(error)
        }
    }

    public func createPublish(_ request: Wiretuner_Publish_V1_CreatePublishRequest, token: String) async throws
        -> Wiretuner_Publish_V1_CreatePublishResponse {
        try await unary { try await service.createPublish(request, metadata: metadata(token)) }
    }

    public func getPublish(_ request: Wiretuner_Publish_V1_GetPublishRequest, token: String) async throws
        -> Wiretuner_Publish_V1_GetPublishResponse {
        try await unary { try await service.getPublish(request, metadata: metadata(token)) }
    }

    public func listPublishes(_ request: Wiretuner_Publish_V1_ListPublishesRequest, token: String) async throws
        -> Wiretuner_Publish_V1_ListPublishesResponse {
        try await unary { try await service.listPublishes(request, metadata: metadata(token)) }
    }

    public func setPublishAccess(_ request: Wiretuner_Publish_V1_SetPublishAccessRequest, token: String) async throws
        -> Wiretuner_Publish_V1_SetPublishAccessResponse {
        try await unary { try await service.setPublishAccess(request, metadata: metadata(token)) }
    }

    public func deletePublish(_ request: Wiretuner_Publish_V1_DeletePublishRequest, token: String) async throws
        -> Wiretuner_Publish_V1_DeletePublishResponse {
        try await unary { try await service.deletePublish(request, metadata: metadata(token)) }
    }
}

extension GRPCPublishTransport where Transport == HTTP2ClientTransport.Posix {
    /// A transport to the API at `api` (`https` uses TLS).
    public static func http2(api: URL, identity: GRPCSyncTransport<Transport>.Identity) throws -> GRPCPublishTransport {
        let tls = api.scheme == "https"
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: api.host ?? "localhost", port: api.port ?? (tls ? 443 : 80)),
            transportSecurity: tls ? .tls : .plaintext
        )
        return GRPCPublishTransport(transport: transport, identity: identity)
    }
}

/// One file of a rendered HTML bundle (`HTMLBundle` in WTInterchange hands them over).
public struct PublishBundleFile: Sendable, Hashable {
    public var path: String
    public var data: Data
    public var mediaType: String

    public init(path: String, data: Data, mediaType: String) {
        self.path = path
        self.data = data
        self.mediaType = mediaType
    }

    /// The lower-case hex sha256 of `data`.
    public var hash: String { BlobCache.hex(SHA256.hash(data: data)) }

    /// The Content-Type a bundle path is served with, by its extension.
    public static func mediaType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js": "text/javascript; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "avif": "image/avif"
        case "woff2": "font/woff2"
        case "json": "application/json"
        case "txt": "text/plain; charset=utf-8"
        default: "application/octet-stream"
        }
    }
}

/// Where a publish stands (the Publish sheet's progress bar and its caption).
public struct PublishProgress: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        /// Asking the server which files it already has (`Stat`).
        case checking
        /// Uploading the files it does not have.
        case uploading
        /// Registering the bundle (`CreatePublish`).
        case registering
        /// Done: the publish the link serves now.
        case published(Wiretuner_Publish_V1_Publish)
    }

    public var phase: Phase
    /// Bytes of the files to upload, sent so far and in all (files the server had count as neither).
    public var sentBytes: Int64
    public var totalBytes: Int64
    /// Distinct blobs confirmed on the server, of all the bundle needs.
    public var blobsDone: Int
    public var blobCount: Int

    /// 0...1 for the bar.
    public var fraction: Double {
        switch phase {
        case .published: 1
        default: totalBytes == 0 ? Double(blobsDone) / Double(max(blobCount, 1)) : Double(sentBytes) / Double(totalBytes)
        }
    }
}

/// *Publish to web link* (`WTSync.PublishUploader`, publish-html.adoc "Client"; WEB-013): uploads
/// every distinct file of a bundle through `BlobService.Upload` -- reusing blobs the server
/// already has (`Stat`), smallest first so the largest go last -- then registers the bundle with
/// `CreatePublish` and its manifest.  A job keeps its `publish_id` and the blobs confirmed so far,
/// so after a dropped connection `resume` starts from the next blob rather than from the top, and
/// a retried `CreatePublish` is idempotent on the id.  Cancelling (the task's cancellation) stops
/// between chunks and deletes nothing on the server: uploaded blobs are harmless orphans until GC.
/// Offline the destination is disabled, never queued: a publish is not made from stale state later.
public actor PublishUploader {
    /// One publish in progress: what `resume` continues.
    public struct Job: Sendable, Hashable {
        public var publishID: String
        public var files: [PublishBundleFile]
        public var serverSeq: UInt64
        public var settingName: String
        public var access: Wiretuner_Publish_V1_PublishAccess
        /// Hashes known to be on the server.
        public var confirmed: Set<String> = []
        /// The publish, once registered.
        public var publish: Wiretuner_Publish_V1_Publish?
    }

    public nonisolated let documentID: String
    private let blobs: any BlobTransport
    private let publishes: any PublishTransport
    private let token: @Sendable () async throws -> String
    private let chunkSize: Int

    public init(documentID: String, blobs: any BlobTransport, publishes: any PublishTransport, chunkSize: Int = 1 << 20,
                token: @escaping @Sendable () async throws -> String) {
        self.documentID = documentID
        self.blobs = blobs
        self.publishes = publishes
        self.chunkSize = max(1, chunkSize)
        self.token = token
    }

    /// A job for `files` rendered from `serverSeq` with the HTML setting `settingName`.
    public func job(_ files: [PublishBundleFile], serverSeq: UInt64, settingName: String,
                    access: Wiretuner_Publish_V1_PublishAccess = .unspecified, publishID: String = DocumentIdentifier.make()) -> Job {
        Job(publishID: publishID, files: files, serverSeq: serverSeq, settingName: settingName, access: access)
    }

    /// Runs `job` to its end, reporting to `progress`; on a failure `job` holds what got through,
    /// for `run` again (the resume).  Returns the publish.
    @discardableResult
    public func run(_ job: inout Job, progress: @escaping @Sendable (PublishProgress) -> Void = { _ in }) async throws -> Wiretuner_Publish_V1_Publish {
        if let publish = job.publish { return publish }
        var unique: [String: PublishBundleFile] = [:]
        for file in job.files { unique[file.hash] = unique[file.hash] ?? file }
        let ordered = unique.sorted { ($0.value.data.count, $0.key) < ($1.value.data.count, $1.key) }
        var report = PublishProgress(phase: .checking, sentBytes: 0, totalBytes: 0, blobsDone: job.confirmed.count, blobCount: ordered.count)
        progress(report)
        let bearer = try await token()
        var missing: [(hash: String, file: PublishBundleFile)] = []
        for (hash, file) in ordered where !job.confirmed.contains(hash) {
            try Task.checkCancellation()
            let stat = try await blobs.stat(.with {
                $0.documentID = documentID
                $0.sha256 = BlobCache.bytes(hex: hash)
            }, token: bearer)
            if stat.exists {
                job.confirmed.insert(hash)
            } else {
                missing.append((hash, file))
            }
        }
        report.phase = .uploading
        report.blobsDone = job.confirmed.count
        report.totalBytes = missing.reduce(0) { $0 + Int64($1.file.data.count) }
        progress(report)
        for (hash, file) in missing {
            try Task.checkCancellation()
            let header = Wiretuner_Blob_V1_UploadHeader.with {
                $0.documentID = documentID
                $0.sha256 = BlobCache.bytes(hex: hash)
                $0.size = UInt64(file.data.count)
                $0.mediaType = file.mediaType
            }
            let base = report.sentBytes
            let sent = Sent()
            let before = report
            let chunks = Self.chunks(file.data, size: chunkSize) { count in
                let total = sent.add(count)
                var partial = before
                partial.sentBytes = base + total
                progress(partial)
            }
            _ = try await blobs.upload(header, chunks: chunks, token: bearer)
            job.confirmed.insert(hash)
            report.sentBytes = base + Int64(file.data.count)
            report.blobsDone = job.confirmed.count
            progress(report)
        }
        try Task.checkCancellation()
        report.phase = .registering
        progress(report)
        var request = Wiretuner_Publish_V1_CreatePublishRequest()
        request.publishID = job.publishID
        request.documentID = documentID
        request.serverSeq = job.serverSeq
        request.settingName = job.settingName
        request.access = job.access
        request.manifest.files = job.files.map { file in
            var entry = Wiretuner_Publish_V1_PublishFile()
            entry.path = file.path
            entry.sha256 = BlobCache.bytes(hex: file.hash)
            entry.mediaType = file.mediaType
            entry.size = UInt64(file.data.count)
            return entry
        }
        let publish = try await publishes.createPublish(request, token: bearer).publish
        job.publish = publish
        report.phase = .published(publish)
        progress(report)
        return publish
    }

    /// Bytes handed to the upload so far, counted from the chunk stream.
    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Int64 = 0

        func add(_ count: Int) -> Int64 {
            lock.withLock {
                bytes += Int64(count)
                return bytes
            }
        }
    }

    /// `data` in `size` chunks, telling `sent` as each is taken; stops at cancellation.
    static func chunks(_ data: Data, size: Int, sent: @escaping @Sendable (Int) -> Void) -> AsyncThrowingStream<Data, any Error> {
        let offset = Sent()
        return AsyncThrowingStream(unfolding: {
            try Task.checkCancellation()
            let start = Int(offset.add(0))
            guard start < data.count else { return nil }
            let end = min(start + size, data.count)
            _ = offset.add(end - start)
            sent(end - start)
            return data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))
        })
    }
}

/// The *Published links* sheet's model (publish-html.adoc, "Published links"; WEB-013): the
/// document's publishes as the last successful `ListPublishes` returned them, kept for offline
/// display (read-only then), refreshed when the document's `PublishesChanged` event arrives, and
/// the sheet's actions -- change access, unpublish, and the files of one publish for
/// *Download as folder*.
public actor PublishedLinks {
    /// What the sheet shows.
    public struct Listing: Sendable, Hashable {
        public var publishes: [Wiretuner_Publish_V1_Publish]
        /// False when the list is the cached one (offline): the sheet is read-only.
        public var isCurrent: Bool
    }

    public nonisolated let documentID: String
    private let transport: any PublishTransport
    private let token: @Sendable () async throws -> String
    private var cached: [Wiretuner_Publish_V1_Publish] = []
    private var continuations: [UUID: AsyncStream<Listing>.Continuation] = [:]
    /// Lists made, for tests and the log.
    public private(set) var refreshes = 0

    public init(documentID: String, transport: any PublishTransport, token: @escaping @Sendable () async throws -> String) {
        self.documentID = documentID
        self.transport = transport
        self.token = token
    }

    /// Every listing from now on (the sheet observes it).
    public func listings() -> AsyncStream<Listing> {
        let (stream, continuation) = AsyncStream<Listing>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { _ in Task { await self.removeContinuation(id) } }
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    /// Lists every page of the document's publishes; on failure answers the cached list, read-only.
    @discardableResult
    public func refresh() async -> Listing {
        let listing: Listing
        do {
            let bearer = try await token()
            var all: [Wiretuner_Publish_V1_Publish] = []
            var cursor = ""
            repeat {
                var request = Wiretuner_Publish_V1_ListPublishesRequest()
                request.documentID = documentID
                request.cursor = cursor
                let page = try await transport.listPublishes(request, token: bearer)
                all += page.publishes
                cursor = page.nextCursor
            } while !cursor.isEmpty
            refreshes += 1
            cached = all
            listing = Listing(publishes: all, isCurrent: true)
        } catch {
            listing = Listing(publishes: cached, isCurrent: false)
        }
        for continuation in continuations.values {
            continuation.yield(listing)
        }
        return listing
    }

    /// Refreshes when `event` is this document's `PublishesChanged` (`SyncEvent.document`).
    public func handle(_ event: SyncEvent) async {
        guard case .document(let frame) = event, case .publishesChanged? = frame.event else { return }
        await refresh()
    }

    /// *Change access*.
    public func setAccess(_ access: Wiretuner_Publish_V1_PublishAccess, of publishID: String) async throws {
        var request = Wiretuner_Publish_V1_SetPublishAccessRequest()
        request.publishID = publishID
        request.access = access
        _ = try await transport.setPublishAccess(request, token: try await token())
        await refresh()
    }

    /// *Unpublish*.
    public func unpublish(_ publishID: String) async throws {
        var request = Wiretuner_Publish_V1_DeletePublishRequest()
        request.publishID = publishID
        _ = try await transport.deletePublish(request, token: try await token())
        await refresh()
    }

    /// *Download as folder*: each file of the publish with its blob fetched through `blobs`.
    public func files(of publishID: String, blobs: any BlobTransport) async throws -> [PublishBundleFile] {
        let bearer = try await token()
        var request = Wiretuner_Publish_V1_GetPublishRequest()
        request.publishID = publishID
        let manifest = try await transport.getPublish(request, token: bearer).manifest
        var out: [PublishBundleFile] = []
        for file in manifest.files {
            var data = Data()
            for try await part in blobs.download(.with {
                $0.documentID = documentID
                $0.sha256 = file.sha256
            }, token: bearer) {
                data.append(part.chunk)
            }
            out.append(PublishBundleFile(path: file.path, data: data, mediaType: file.mediaType))
        }
        return out
    }

    /// The URL of the current publish, for *Copy Link*; nil when nothing is published.
    public var currentURL: String? { cached.first(where: \.current)?.url }
}
