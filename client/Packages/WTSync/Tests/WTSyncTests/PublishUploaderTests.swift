import CryptoKit
import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import Testing
import WTProto
@testable import WTSync

/// A blob and publish server in memory with a simulated link: `bitsPerSecond` turns bytes into
/// simulated seconds, and `dropAfter` cuts the connection once that many bytes have been sent.
final class FakePublishServer: BlobTransport, PublishTransport, @unchecked Sendable {
    struct Dropped: Error {}

    private let lock = NSLock()
    private(set) var blobs: [Data: Data] = [:]
    private(set) var uploadedBytes: Int64 = 0
    private(set) var uploads: [String] = []
    private(set) var publishes: [Wiretuner_Publish_V1_Publish] = []
    private(set) var manifests: [String: Wiretuner_Publish_V1_PublishManifest] = [:]
    private(set) var creates = 0
    var bitsPerSecond: Double = 10_000_000
    var dropAfter: Int64?
    var offline = false
    var pageSize = 2

    /// Simulated seconds the link spent sending.
    var seconds: Double { lock.withLock { Double(uploadedBytes) * 8 / bitsPerSecond } }

    private func online() throws {
        if lock.withLock({ offline }) { throw SyncCallError(code: 14, message: "offline") }
    }

    func stat(_ request: Wiretuner_Blob_V1_StatRequest, token: String) async throws -> Wiretuner_Blob_V1_StatResponse {
        try online()
        return lock.withLock { .with { $0.exists = blobs[request.sha256] != nil } }
    }

    func upload(_ header: Wiretuner_Blob_V1_UploadHeader, chunks: AsyncThrowingStream<Data, any Error>, token: String) async throws
        -> Wiretuner_Blob_V1_UploadResponse {
        try online()
        var data = Data()
        for try await chunk in chunks {
            let cut = lock.withLock { () -> Bool in
                uploadedBytes += Int64(chunk.count)
                if let limit = dropAfter, uploadedBytes > limit {
                    dropAfter = nil
                    return true
                }
                return false
            }
            if cut { throw Dropped() }
            data.append(chunk)
        }
        lock.withLock {
            blobs[Data(SHA256.hash(data: data))] = data
            uploads.append(header.mediaType)
        }
        return .with { $0.blob.sha256 = header.sha256 }
    }

    func download(_ request: Wiretuner_Blob_V1_DownloadRequest, token: String) -> AsyncThrowingStream<Wiretuner_Blob_V1_DownloadResponse, any Error> {
        let data = lock.withLock { blobs[request.sha256] ?? Data() }
        return AsyncThrowingStream { continuation in
            continuation.yield(.with { $0.info.size = UInt64(data.count) })
            continuation.yield(.with { $0.chunk = data })
            continuation.finish()
        }
    }

    func createPublish(_ request: Wiretuner_Publish_V1_CreatePublishRequest, token: String) async throws -> Wiretuner_Publish_V1_CreatePublishResponse {
        try online()
        return try lock.withLock {
            creates += 1
            if let existing = publishes.first(where: { $0.publishID == request.publishID }) {
                return .with { $0.publish = existing }
            }
            for file in request.manifest.files where blobs[file.sha256] == nil {
                throw SyncCallError(code: 5, message: "blob not found")
            }
            for index in publishes.indices { publishes[index].current = false }
            let publish = Wiretuner_Publish_V1_Publish.with {
                $0.publishID = request.publishID
                $0.documentID = request.documentID
                $0.serverSeq = request.serverSeq
                $0.settingName = request.settingName
                $0.access = request.access == .unspecified ? .members : request.access
                $0.url = "https://pub.example/d/\(request.documentID)/"
                $0.current = true
                $0.fileCount = UInt32(request.manifest.files.count)
                $0.totalSize = request.manifest.files.reduce(0) { $0 + $1.size }
            }
            publishes.insert(publish, at: 0)
            manifests[request.publishID] = request.manifest
            return .with { $0.publish = publish }
        }
    }

    func getPublish(_ request: Wiretuner_Publish_V1_GetPublishRequest, token: String) async throws -> Wiretuner_Publish_V1_GetPublishResponse {
        try online()
        return lock.withLock {
            .with {
                $0.publish = publishes.first { $0.publishID == request.publishID } ?? .init()
                $0.manifest = manifests[request.publishID] ?? .init()
            }
        }
    }

    func listPublishes(_ request: Wiretuner_Publish_V1_ListPublishesRequest, token: String) async throws -> Wiretuner_Publish_V1_ListPublishesResponse {
        try online()
        return lock.withLock {
            let start = Int(request.cursor) ?? 0
            let end = min(start + pageSize, publishes.count)
            return .with {
                $0.publishes = Array(publishes[start..<end])
                $0.nextCursor = end < publishes.count ? String(end) : ""
            }
        }
    }

    func setPublishAccess(_ request: Wiretuner_Publish_V1_SetPublishAccessRequest, token: String) async throws
        -> Wiretuner_Publish_V1_SetPublishAccessResponse {
        try online()
        return lock.withLock {
            guard let index = publishes.firstIndex(where: { $0.publishID == request.publishID }) else { return .init() }
            publishes[index].access = request.access
            return .with { $0.publish = publishes[index] }
        }
    }

    func deletePublish(_ request: Wiretuner_Publish_V1_DeletePublishRequest, token: String) async throws -> Wiretuner_Publish_V1_DeletePublishResponse {
        try online()
        lock.withLock { publishes.removeAll { $0.publishID == request.publishID } }
        return .init()
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [PublishProgress] = []
    func add(_ progress: PublishProgress) { lock.withLock { entries.append(progress) } }
    var all: [PublishProgress] { lock.withLock { entries } }
}

@Suite struct PublishUploaderTests {
    static let documentID = "0190c0de-0000-7000-8000-000000000001"

    /// A 40 MB bundle: an index page, a stylesheet and forty 1 MB images, two of them identical.
    static func bundle() -> [PublishBundleFile] {
        var files = [PublishBundleFile(path: "index.html", data: Data("<html></html>".utf8), mediaType: PublishBundleFile.mediaType(forPath: "index.html")),
                     PublishBundleFile(path: "style.css", data: Data("body{}".utf8), mediaType: PublishBundleFile.mediaType(forPath: "style.css"))]
        for index in 0..<40 {
            let fill = UInt8(index == 39 ? 0 : index)
            files.append(PublishBundleFile(path: "images/\(index).png", data: Data(repeating: fill, count: 1_000_000), mediaType: "image/png"))
        }
        return files
    }

    @Test func publishingFortyMegabytesOverTenMegabitsShowsProgressAndResumesAfterADrop() async throws {
        let server = FakePublishServer()
        server.dropAfter = 20_500_000
        let uploader = PublishUploader(documentID: Self.documentID, blobs: server, publishes: server, chunkSize: 256 * 1024, token: { "t" })
        let files = Self.bundle()
        var job = await uploader.job(files, serverSeq: 12, settingName: "Setting 1", access: .anyoneWithLink)
        let log = ProgressLog()
        await #expect(throws: FakePublishServer.Dropped.self) { try await uploader.run(&job, progress: log.add) }
        let before = job.confirmed.count
        #expect(before == 22 && job.publish == nil) // 2 small files and 20 images got through
        // Progress rose in steps while uploading, and never past the total.
        let uploading = log.all.filter { $0.phase == .uploading }
        #expect(uploading.count > 40 && uploading.allSatisfy { $0.sentBytes <= $0.totalBytes })
        #expect(zip(uploading, uploading.dropFirst()).allSatisfy { $0.sentBytes <= $1.sentBytes })
        let sentBeforeDrop = server.uploads.count

        // Resume: only the blobs not yet confirmed are sent.
        let resumed = ProgressLog()
        let publish = try await uploader.run(&job, progress: resumed.add)
        #expect(server.uploads.count - sentBeforeDrop == 41 - before)
        #expect(publish.current && publish.fileCount == 42 && publish.access == .anyoneWithLink && publish.serverSeq == 12)
        #expect(resumed.all.last?.fraction == 1 && resumed.all.first?.phase == .checking)
        if case .published(let done)? = resumed.all.last?.phase { #expect(done == publish) } else { Issue.record("not published") }
        #expect(server.seconds > 30 && server.seconds < 40) // ~41 MB at 10 Mbit/s, once each plus the dropped chunk
        // Running the finished job again answers the publish without a call.
        #expect(try await uploader.run(&job) == publish && server.creates == 1)
    }

    @Test func republishingAnUnchangedBundleUploadsNoBlobBytes() async throws {
        let server = FakePublishServer()
        let uploader = PublishUploader(documentID: Self.documentID, blobs: server, publishes: server, token: { "t" })
        var first = await uploader.job(Self.bundle(), serverSeq: 1, settingName: "S")
        try await uploader.run(&first)
        let bytes = server.uploadedBytes
        var second = await uploader.job(Self.bundle(), serverSeq: 2, settingName: "S")
        let log = ProgressLog()
        let publish = try await uploader.run(&second, progress: log.add)
        #expect(server.uploadedBytes == bytes && publish.serverSeq == 2 && publish.access == .members)
        #expect(log.all.first { $0.phase == .uploading }?.totalBytes == 0)
        #expect(log.all.first { $0.phase == .uploading }?.fraction == 1)
    }

    @Test func cancellingStopsBetweenChunksAndDeletesNothing() async throws {
        let server = FakePublishServer()
        let uploader = PublishUploader(documentID: Self.documentID, blobs: server, publishes: server, chunkSize: 1024, token: { "t" })
        let job = await uploader.job(Self.bundle(), serverSeq: 1, settingName: "S")
        let task = Task {
            var copy = job
            return try await uploader.run(&copy)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(server.publishes.isEmpty)
    }

    @Test func offlinePublishingFailsAndIsNotQueued() async throws {
        let server = FakePublishServer()
        server.offline = true
        let uploader = PublishUploader(documentID: Self.documentID, blobs: server, publishes: server, token: { "t" })
        var job = await uploader.job(Self.bundle(), serverSeq: 1, settingName: "S")
        await #expect(throws: SyncCallError.self) { try await uploader.run(&job) }
        #expect(job.confirmed.isEmpty && uploader.documentID == Self.documentID)
    }

    @Test func mediaTypesByExtension() {
        let expected = ["a.html": "text/html; charset=utf-8", "a.HTM": "text/html; charset=utf-8", "s.css": "text/css; charset=utf-8",
                        "x.js": "text/javascript; charset=utf-8", "i.svg": "image/svg+xml", "i.png": "image/png", "i.jpeg": "image/jpeg",
                        "i.jpg": "image/jpeg", "i.gif": "image/gif", "i.webp": "image/webp", "i.avif": "image/avif", "f.woff2": "font/woff2",
                        "d.json": "application/json", "r.txt": "text/plain; charset=utf-8", "b.bin": "application/octet-stream"]
        for (path, type) in expected {
            #expect(PublishBundleFile.mediaType(forPath: path) == type, "\(path)")
        }
    }

    @Test func thePublishedLinksSheetListsRefreshesOnTheEventAndWorksOfflineReadOnly() async throws {
        let server = FakePublishServer()
        let uploader = PublishUploader(documentID: Self.documentID, blobs: server, publishes: server, token: { "t" })
        let links = PublishedLinks(documentID: Self.documentID, transport: server, token: { "t" })
        let listings = await links.listings()
        var iterator = listings.makeAsyncIterator()
        for seq in 1...3 {
            var job = await uploader.job(Array(Self.bundle().prefix(2)), serverSeq: UInt64(seq), settingName: "S")
            try await uploader.run(&job)
        }
        // Another client's publish arrives as the document event: the sheet refreshes (every page).
        await links.handle(.document(.with { $0.publishesChanged = Wiretuner_Sync_V1_PublishesChanged() }))
        let listing = try #require(await iterator.next())
        #expect(listing.isCurrent && listing.publishes.map(\.serverSeq) == [3, 2, 1])
        #expect(await links.currentURL == "https://pub.example/d/\(Self.documentID)/")
        // Other events do not list.
        await links.handle(.document(.with { $0.renamed = Wiretuner_Sync_V1_Renamed() }))
        await links.handle(.stable(1))
        #expect(await links.refreshes == 1)

        // Change access, download as folder, unpublish.
        let newest = listing.publishes[0].publishID
        try await links.setAccess(.anyoneWithLink, of: newest)
        #expect(server.publishes[0].access == .anyoneWithLink)
        let files = try await links.files(of: newest, blobs: server)
        #expect(files.map(\.path) == ["index.html", "style.css"] && files[0].data == Data("<html></html>".utf8))
        try await links.unpublish(newest)
        #expect(await links.refresh().publishes.count == 2)

        // Offline: the cached list, read-only.
        server.offline = true
        let offline = await links.refresh()
        #expect(!offline.isCurrent && offline.publishes.count == 2)
    }

    typealias Method = Wiretuner_Publish_V1_PublishService.Method

    @Test func everyPublishCallRunsOverGRPC() async throws {
        let fake = FakePublishServer()
        let recorded = FakeGRPCService.Calls()
        var router = RPCRouter<InProcessTransport.Server>()
        @Sendable func unary<Output: Sendable>(_ metadata: Metadata, _ body: () async throws -> Output) async throws -> StreamingServerResponse<Output> {
            recorded.metadata.withLock { $0.append(metadata) }
            do {
                return StreamingServerResponse(single: ServerResponse(message: try await body()))
            } catch let error as SyncCallError {
                throw FakeGRPCService.status(error)
            }
        }
        router.registerHandler(forMethod: Method.CreatePublish.descriptor, deserializer: ProtobufDeserializer<Method.CreatePublish.Input>(),
                               serializer: ProtobufSerializer<Method.CreatePublish.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary(single.metadata) { try await fake.createPublish(single.message, token: "") }
        }
        router.registerHandler(forMethod: Method.GetPublish.descriptor, deserializer: ProtobufDeserializer<Method.GetPublish.Input>(),
                               serializer: ProtobufSerializer<Method.GetPublish.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary(single.metadata) { try await fake.getPublish(single.message, token: "") }
        }
        router.registerHandler(forMethod: Method.ListPublishes.descriptor, deserializer: ProtobufDeserializer<Method.ListPublishes.Input>(),
                               serializer: ProtobufSerializer<Method.ListPublishes.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary(single.metadata) { try await fake.listPublishes(single.message, token: "") }
        }
        router.registerHandler(forMethod: Method.SetPublishAccess.descriptor, deserializer: ProtobufDeserializer<Method.SetPublishAccess.Input>(),
                               serializer: ProtobufSerializer<Method.SetPublishAccess.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary(single.metadata) { try await fake.setPublishAccess(single.message, token: "") }
        }
        router.registerHandler(forMethod: Method.DeletePublish.descriptor, deserializer: ProtobufDeserializer<Method.DeletePublish.Input>(),
                               serializer: ProtobufSerializer<Method.DeletePublish.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary(single.metadata) { try await fake.deletePublish(single.message, token: "") }
        }
        let inProcess = InProcessTransport()
        let server = GRPCServer(transport: inProcess.server, router: router)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.serve() }
            let transport = GRPCPublishTransport(transport: inProcess.client, identity: .init(clientVersion: "1.0/1", deviceID: "device-1"))
            let uploader = PublishUploader(documentID: Self.documentID, blobs: fake, publishes: transport, token: { "tok" })
            var job = await uploader.job(Array(Self.bundle().prefix(2)), serverSeq: 1, settingName: "S")
            let publish = try await uploader.run(&job)
            let links = PublishedLinks(documentID: Self.documentID, transport: transport, token: { "tok" })
            #expect(await links.refresh().publishes.count == 1)
            try await links.setAccess(.members, of: publish.publishID)
            #expect(try await links.files(of: publish.publishID, blobs: fake).count == 2)
            try await links.unpublish(publish.publishID)
            // A rejection arrives as a SyncCallError.
            var missing = Wiretuner_Publish_V1_CreatePublishRequest()
            missing.publishID = "x"
            missing.manifest.files = [.with { $0.sha256 = Data(repeating: 1, count: 32) }]
            await #expect(throws: SyncCallError.self) { try await transport.createPublish(missing, token: "tok") }
            server.beginGracefulShutdown()
            await transport.close()
        }
        let calls = recorded.metadata.withLock { $0 }
        #expect(calls.count >= 7 && calls.allSatisfy { Array($0[stringValues: "authorization"]) == ["Bearer tok"] })
        _ = try GRPCPublishTransport.http2(api: URL(string: "http://localhost:1")!, identity: .init(clientVersion: "1", deviceID: "d"))
        _ = try GRPCPublishTransport.http2(api: URL(string: "https://example.invalid")!, identity: .init(clientVersion: "1", deviceID: "d"))
    }
}
