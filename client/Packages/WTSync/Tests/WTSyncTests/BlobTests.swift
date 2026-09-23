import CryptoKit
import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import Synchronization
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// An in-process stand-in for the server's `BlobService`: stored blobs by hash, uploads recorded,
/// with injectable refusals and a per-chunk delay.
actor FakeBlobServer {
    private(set) var blobs: [Data: Data] = [:]
    private(set) var uploads: [(header: Wiretuner_Blob_V1_UploadHeader, chunks: Int)] = []
    private(set) var stats = 0
    var failures: [SyncCallError] = []
    var statFailures: [SyncCallError] = []
    var chunkDelay: Duration?
    /// Downloads of these hashes send these bytes instead of the blob.
    var corrupt: [Data: Data] = [:]
    var validToken = "token-1"

    func update(_ body: @Sendable (isolated FakeBlobServer) -> Void) {
        body(self)
    }

    func put(_ data: Data) {
        blobs[Data(SHA256.hash(data: data))] = data
    }

    var uploadOrder: [String] { uploads.map { BlobCache.hex($0.header.sha256) } }

    private func check(_ token: String) throws {
        guard token == validToken else { throw SyncCallError(code: SyncCallError.unauthenticated, message: "token") }
    }

    func stat(_ request: Wiretuner_Blob_V1_StatRequest, token: String) throws -> Wiretuner_Blob_V1_StatResponse {
        try check(token)
        stats += 1
        if !statFailures.isEmpty { throw statFailures.removeFirst() }
        guard let data = blobs[request.sha256] else { return .with { $0.exists = false } }
        return .with {
            $0.exists = true
            $0.blob.sha256 = request.sha256
            $0.blob.size = UInt64(data.count)
        }
    }

    func upload(_ header: Wiretuner_Blob_V1_UploadHeader, chunks: AsyncThrowingStream<Data, any Error>, token: String) async throws
        -> Wiretuner_Blob_V1_UploadResponse {
        try check(token)
        if !failures.isEmpty { throw failures.removeFirst() }
        var data = Data()
        var count = 0
        for try await chunk in chunks {
            if let chunkDelay { try await Task.sleep(for: chunkDelay) }
            data.append(chunk)
            count += 1
        }
        uploads.append((header, count))
        blobs[Data(SHA256.hash(data: data))] = data
        return .with { $0.blob.sha256 = header.sha256 }
    }

    func download(_ request: Wiretuner_Blob_V1_DownloadRequest, token: String,
                  _ continuation: AsyncThrowingStream<Wiretuner_Blob_V1_DownloadResponse, any Error>.Continuation) {
        do {
            try check(token)
            guard let data = corrupt.removeValue(forKey: request.sha256) ?? blobs[request.sha256] else {
                throw SyncCallError(code: SyncCallError.notFound, message: "no blob")
            }
            continuation.yield(.with { $0.info.size = UInt64(data.count) })
            for start in stride(from: 0, to: data.count, by: 4) {
                continuation.yield(.with { $0.chunk = data[start..<min(start + 4, data.count)] })
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}

struct FakeBlobTransport: BlobTransport {
    let server: FakeBlobServer

    func stat(_ request: Wiretuner_Blob_V1_StatRequest, token: String) async throws -> Wiretuner_Blob_V1_StatResponse {
        try await server.stat(request, token: token)
    }

    func upload(_ header: Wiretuner_Blob_V1_UploadHeader, chunks: AsyncThrowingStream<Data, any Error>, token: String) async throws
        -> Wiretuner_Blob_V1_UploadResponse {
        try await server.upload(header, chunks: chunks, token: token)
    }

    func download(_ request: Wiretuner_Blob_V1_DownloadRequest, token: String)
        -> AsyncThrowingStream<Wiretuner_Blob_V1_DownloadResponse, any Error> {
        AsyncThrowingStream { continuation in
            Task { await server.download(request, token: token, continuation) }
        }
    }
}

func fastBlobOptions() -> BlobQueue.Options {
    var options = BlobQueue.Options()
    options.chunkSize = 1 << 20
    options.retryBase = .milliseconds(10)
    options.retryMax = .milliseconds(40)
    options.random = { 0.5 }
    return options
}

/// A blob queue over a fresh store and cache.
struct BlobHarness {
    let scratch = Scratch()
    let store: LocalStore
    let server: FakeBlobServer
    let tokens: FakeTokens
    let queue: BlobQueue
    let events: Collector<BlobEvent>

    init(server: FakeBlobServer = FakeBlobServer(), tokens: FakeTokens = FakeTokens(), options: BlobQueue.Options = fastBlobOptions()) async throws {
        self.server = server
        self.tokens = tokens
        store = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: WTSyncTests.options())
        queue = BlobQueue(store: store, cache: BlobCache(directory: scratch.directory.appending(path: "Blobs")),
                          transport: FakeBlobTransport(server: server), tokens: tokens, options: options)
        events = Collector(queue.events())
    }

    func file(_ name: String, bytes: Int, fill: UInt8 = 7) throws -> URL {
        let url = scratch.directory.appending(path: name)
        try Data(repeating: fill, count: bytes).write(to: url)
        return url
    }

    func stop() async throws {
        await queue.stop()
        try await store.close()
    }
}

@Suite(.timeLimit(.minutes(2))) struct BlobTests {
    @Test func theCacheIsContentAddressed() throws {
        let scratch = Scratch()
        let cache = BlobCache(directory: scratch.directory.appending(path: "Blobs"))
        let data = Data("hello".utf8)
        let hash = try cache.insert(data)
        #expect(hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(cache.contains(hash) && !cache.contains("00" + hash.dropFirst(2)))
        #expect(cache.url(for: hash).path.hasSuffix("Blobs/2c/\(hash)"))
        #expect(try Data(contentsOf: cache.url(for: hash)) == data)
        // The same bytes again, from a file, land on the same path.
        let file = scratch.directory.appending(path: "hello.txt")
        try data.write(to: file)
        let inserted = try cache.insert(contentsOf: file, chunkSize: 2)
        #expect(inserted.hash == hash && inserted.size == 5)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.directory.appending(path: "incoming").path).isEmpty)
        #expect(throws: (any Error).self) { try cache.insert(contentsOf: scratch.directory.appending(path: "missing")) }
        #expect(BlobCache.bytes(hex: hash).count == 32 && BlobCache.hex(BlobCache.bytes(hex: hash)) == hash)
        #expect(BlobCache.bytes(hex: "zz0") == Data([0]))
        #expect(try BlobCache.defaultDirectory().path.hasSuffix("Application Support/WireTuner/Blobs"))
    }

    @Test func uploadsGoThumbnailFirstThenLargestLast() async throws {
        let harness = try await BlobHarness()
        let big = try await harness.queue.add(fileAt: harness.file("big", bytes: 3_000), mediaType: "image/png")
        let small = try await harness.queue.add(fileAt: harness.file("small", bytes: 1_000, fill: 1), mediaType: "image/jpeg")
        let thumbnail = try await harness.queue.add(Data(repeating: 9, count: 5_000), mediaType: "image/png", tag: .thumbnail)
        #expect(try await harness.store.pendingBlobCount() == 2)
        await harness.queue.start()
        await harness.queue.start()   // idempotent
        try await Task.sleep(for: .milliseconds(30))
        #expect(await harness.server.uploads.isEmpty)   // offline: nothing goes up
        await harness.queue.setOnline(true)
        try await eventually("uploaded") { try await harness.store.pendingBlobs().isEmpty }
        #expect(await harness.server.uploadOrder == [thumbnail, small, big])
        let headers = await harness.server.uploads.map(\.header)
        #expect(headers.map(\.tag) == [.thumbnail, .unspecified, .unspecified])
        #expect(headers.map(\.mediaType) == ["image/png", "image/jpeg", "image/png"])
        #expect(headers.map(\.size) == [5_000, 1_000, 3_000] && headers.allSatisfy { $0.documentID == "D1" })
        try await eventually("events") { harness.events.all.filter { if case .uploaded = $0 { true } else { false } }.count == 3 }
        try await harness.stop()
    }

    @Test func aBlobTheServerHasIsNotSentAgain() async throws {
        let harness = try await BlobHarness()
        let data = Data(repeating: 3, count: 100)
        await harness.server.put(data)
        let hash = try await harness.queue.add(data, mediaType: "application/octet-stream")
        await harness.queue.setOnline(true)
        await harness.queue.start()
        try await eventually("done") { harness.events.all.contains(.uploaded(hash: hash)) }
        #expect(await harness.server.uploads.isEmpty)
        try await harness.stop()
    }

    @Test func failuresRetryWithBackoff() async throws {
        let harness = try await BlobHarness()
        await harness.server.update { $0.failures = [SyncCallError(code: SyncCallError.unavailable, message: "down"),
                                                     SyncCallError(code: SyncCallError.unavailable, message: "down")] }
        let hash = try await harness.queue.add(Data(repeating: 1, count: 10), mediaType: "")
        await harness.queue.setOnline(true)
        await harness.queue.start()
        try await eventually("uploaded") { harness.events.all.contains(.uploaded(hash: hash)) }
        let retries = harness.events.all.compactMap { if case .uploadFailed(_, _, let delay) = $0 { delay } else { nil } }
        #expect(retries == [.milliseconds(7.5), .milliseconds(15)])
        #expect(await harness.queue.backoff(10) == .milliseconds(30))
        try await harness.stop()
    }

    @Test func aRefusedTokenIsRefreshedOnce() async throws {
        let server = FakeBlobServer()
        await server.update { $0.validToken = "token-2" }
        let harness = try await BlobHarness(server: server)
        let hash = try await harness.queue.add(Data(repeating: 1, count: 10), mediaType: "")
        await harness.queue.setOnline(true)
        await harness.queue.start()
        try await eventually("uploaded") { harness.events.all.contains(.uploaded(hash: hash)) }
        #expect(harness.tokens.refreshes == 1)
        // A fresh token refused again backs off like any failure.
        await server.update { $0.validToken = "nobody" }
        let second = try await harness.queue.add(Data(repeating: 2, count: 10), mediaType: "")
        try await eventually("failed") { harness.events.all.contains { if case .uploadFailed(second, _, _) = $0 { true } else { false } } }
        #expect(harness.tokens.refreshes == 2)
        try await harness.stop()
    }

    @Test func theStorageQuotaParksUploadsButNotTheThumbnail() async throws {
        let harness = try await BlobHarness()
        await harness.server.update { $0.failures = [SyncCallError(code: SyncCallError.resourceExhausted, reason: .storageQuota, message: "full")] }
        let image = try await harness.queue.add(Data(repeating: 1, count: 10), mediaType: "image/png")
        await harness.queue.setOnline(true)
        await harness.queue.start()
        try await eventually("full") { harness.events.all.contains(.storageFull(waiting: 1)) }
        #expect(await harness.queue.isStorageFull)
        let thumbnail = try await harness.queue.add(Data(repeating: 2, count: 10), mediaType: "image/png", tag: .thumbnail)
        try await eventually("thumbnail") { harness.events.all.contains(.uploaded(hash: thumbnail)) }
        #expect(!harness.events.all.contains(.uploaded(hash: image)))
        await harness.queue.retry()
        try await eventually("image") { harness.events.all.contains(.uploaded(hash: image)) }
        #expect(await !harness.queue.isStorageFull)
        try await harness.stop()
    }

    @Test func theSyncStateShowsBlobsAndAFullStore() async throws {
        let server = FakeSyncServer()
        let blobServer = FakeBlobServer()
        await blobServer.update { $0.failures = [SyncCallError(code: SyncCallError.resourceExhausted, reason: .storageQuota, message: "full")] }
        let scratch = Scratch()
        let store = try await LocalStore.open(documentID: server.documentID, at: scratch.url(), options: options())
        let queue = BlobQueue(store: store, cache: BlobCache(directory: scratch.directory.appending(path: "Blobs")),
                              transport: FakeBlobTransport(server: blobServer), tokens: FakeTokens(), options: fastBlobOptions())
        let client = SyncClient(store: store, transport: FakeTransport(server: server), tokens: FakeTokens(), blobs: queue,
                                options: fastOptions())
        #expect(client.blobs === queue)
        try await queue.add(Data(repeating: 1, count: 10), mediaType: "image/png")
        await client.start()
        try await eventually("storage full") { await client.state == .storageFull(1) }
        await queue.retry()
        try await eventually("saved") { await client.state == .saved }
        await client.stop()
        try await store.close()
    }

    @Test func downloadsAreLazyAndAnnounced() async throws {
        let harness = try await BlobHarness()
        let data = Data((0..<50).map { UInt8($0) })
        let hash = BlobCache.hex(SHA256.hash(data: data))
        await harness.queue.start()
        #expect(await harness.queue.blob(hash) == .pending)
        #expect(await harness.queue.blob(hash) == .pending)   // one download, however often asked
        try await Task.sleep(for: .milliseconds(30))
        #expect(await harness.server.stats == 0)   // offline: it waits
        await harness.queue.setOnline(true)
        // Not on the server yet: retried until it is.
        try await eventually("asked") { await harness.server.stats >= 2 }
        await harness.server.put(data)
        try await eventually("available") { harness.events.all.contains(.available(hash: hash, url: harness.queue.cache.url(for: hash))) }
        #expect(await harness.queue.blob(hash) == .available(harness.queue.cache.url(for: hash)))
        #expect(try Data(contentsOf: harness.queue.cache.url(for: hash)) == data)
        try await harness.stop()
    }

    @Test func aDownloadWhoseBytesDoNotMatchIsRetried() async throws {
        let harness = try await BlobHarness()
        let data = Data(repeating: 5, count: 20)
        let hash = BlobCache.hex(SHA256.hash(data: data))
        await harness.server.put(data)
        await harness.server.update { $0.corrupt = [BlobCache.bytes(hex: hash): Data(repeating: 6, count: 20)] }
        await harness.queue.setOnline(true)
        _ = await harness.queue.blob(hash)
        try await eventually("available") { harness.events.all.contains { if case .available(hash, _) = $0 { true } else { false } } }
        #expect(harness.events.all.contains { if case .downloadFailed(hash, _) = $0 { true } else { false } })
        try await harness.stop()
    }

    @Test func stoppingCancelsDownloads() async throws {
        let harness = try await BlobHarness()
        await harness.queue.setOnline(true)
        #expect(await harness.queue.blob(String(repeating: "ab", count: 32)) == .pending)
        try await eventually("asked") { await harness.server.stats >= 1 }
        try await harness.stop()
    }

    /// SYNC-008's done-when: a 100 MiB image placed offline uploads after reconnecting, and edits
    /// made meanwhile never wait for it.
    @Test func aHundredMebibyteImageUploadsWithoutBlockingEdits() async throws {
        let server = FakeBlobServer()
        await server.update { $0.chunkDelay = .milliseconds(3) }
        let harness = try await BlobHarness(server: server)
        let file = try harness.file("photo.tif", bytes: 100 << 20)
        let hash = try await harness.queue.add(fileAt: file, mediaType: "image/tiff")
        await harness.queue.start()
        await harness.queue.setOnline(true)
        try await eventually("uploading") { await server.stats >= 1 }
        var slowest: Duration = .zero
        var edits = 0
        while try await !harness.store.pendingBlobs().isEmpty {
            let start = ContinuousClock.now
            _ = try await harness.store.perform(createLayer("L\(edits)"), recording: Fixture.recording())
            slowest = max(slowest, ContinuousClock.now - start)
            edits += 1
            try await Task.sleep(for: .milliseconds(5))
        }
        let upload = try #require(await server.uploads.first)
        #expect(upload.chunks == 100 && upload.header.size == 100 << 20 && BlobCache.hex(upload.header.sha256) == hash)
        #expect(await server.blobs[BlobCache.bytes(hex: hash)]?.count == 100 << 20)
        print("BlobQueue: 100 MiB upload, \(edits) edits meanwhile, slowest \(slowest)")
        #expect(edits > 10)
        PerfBudget.expect(slowest, within: .milliseconds(250), "slowest edit")
        try await harness.stop()
    }

    @Test func blobsTravelOverGRPC() async throws {
        let blobServer = FakeBlobServer()
        let data = Data(repeating: 4, count: 3 << 20)
        try await FakeGRPCService.withTransport(FakeSyncServer(), blobs: blobServer) { transport in
            let hash = BlobCache.bytes(hex: BlobCache.hex(SHA256.hash(data: data)))
            let absent = try await transport.stat(.with { $0.sha256 = hash }, token: "token-1")
            #expect(!absent.exists)
            let scratch = Scratch()
            let file = scratch.directory.appending(path: "blob")
            try data.write(to: file)
            let header = Wiretuner_Blob_V1_UploadHeader.with {
                $0.sha256 = hash
                $0.size = UInt64(data.count)
            }
            _ = try await transport.upload(header, chunks: BlobChunks.read(file, chunkSize: 1 << 20), token: "token-1")
            #expect(try await transport.stat(.with { $0.sha256 = hash }, token: "token-1").exists)
            var received = Data()
            for try await response in transport.download(.with { $0.sha256 = hash }, token: "token-1") {
                if case .chunk(let chunk)? = response.frame { received.append(chunk) }
            }
            #expect(received == data)
            await #expect(throws: SyncCallError.self) { try await transport.stat(.with { $0.sha256 = hash }, token: "bad") }
            await #expect(throws: SyncCallError.self) {
                for try await _ in transport.download(.with { $0.sha256 = Data(repeating: 0, count: 32) }, token: "token-1") {}
            }
        }
        #expect(await blobServer.uploads.map(\.chunks) == [3])
    }
}
