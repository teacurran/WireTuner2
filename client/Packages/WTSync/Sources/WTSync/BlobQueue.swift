import CryptoKit
import Foundation
import os
import Synchronization
import WTProto

/// What the blob queue reports: uploads finishing or failing, the storage quota, and blobs arriving
/// for the renderer, which draws a placeholder until then.
public enum BlobEvent: Sendable, Hashable {
    case uploaded(hash: String)
    case uploadFailed(hash: String, reason: String, retryIn: Duration)
    /// Uploads refused by the storage quota; `waiting` blobs (not the thumbnail) wait for `retry()`.
    case storageFull(waiting: Int)
    /// A blob is in the cache at `url`: redraw what showed its placeholder.
    case available(hash: String, url: URL)
    case downloadFailed(hash: String, reason: String)
}

/// A blob going up or coming down, as far as it has got (the canvas's upload ring and the
/// placeholder's download ring, IMG-006).
public struct BlobTransfer: Hashable, Sendable {
    public enum Direction: Hashable, Sendable {
        case upload
        case download
    }

    public var hash: String
    public var direction: Direction
    /// Bytes sent or received so far.
    public var completed: Int64
    /// The blob's size.
    public var total: Int64

    public init(hash: String, direction: Direction, completed: Int64, total: Int64) {
        self.hash = hash
        self.direction = direction
        self.completed = completed
        self.total = total
    }

    /// 0...1.
    public var fraction: Double { total > 0 ? min(max(Double(completed) / Double(total), 0), 1) : 0 }
}

/// Whether a referenced blob can be drawn now.
public enum BlobAvailability: Sendable, Hashable {
    case available(URL)
    /// Not cached: a placeholder is drawn and `BlobEvent.available` follows when it arrives.
    case pending
}

/// A document's blob queue (docs/spec/offline.adoc, "Reconnecting with a backlog"; SYNC-008): the
/// pending uploads of `blobs_pending` go up while the session is online -- the thumbnail first,
/// then the rest by size, largest last -- each asked about with `Stat` first and streamed from its
/// cached file in 1 MiB chunks, with exponential backoff on failure; referenced blobs missing from
/// the cache are downloaded lazily, verified against their hash, and announced.  It runs beside
/// the store: adding a 100 MiB image hashes and copies it off the store's actor, and an upload
/// reads the file as it goes, so edits never wait for it.
public actor BlobQueue {
    public struct Options: Sendable {
        /// Upload chunk size (blob.proto: at most 1 MiB).
        public var chunkSize = 1 << 20
        /// Retry backoff: `base * 2^attempt`, at most `max`, scaled by a random 0.5...1.
        public var retryBase: Duration = .seconds(1)
        public var retryMax: Duration = .seconds(300)
        public var random: @Sendable () -> Double = { Double.random(in: 0..<1) }

        public init() {}
    }

    public nonisolated let documentID: String
    let store: LocalStore
    public nonisolated let cache: BlobCache
    let transport: any BlobTransport
    let tokens: any TokenProvider
    let options: Options
    private let logger = Logger(subsystem: "app.wiretuner", category: "blobs")

    private let broadcast = Broadcast<BlobEvent>()
    private let transferBroadcast = Broadcast<BlobTransfer>()
    private let inFlight = Mutex<[String: BlobTransfer]>([:])
    private let wake = Signal()
    private var worker: Task<Void, Never>?
    private var online = false
    private var storageFull = false
    private var token: String?
    private var refreshToken = false
    private var refreshed = false
    private var attempts: [String: Int] = [:]
    private var notBefore: [String: ContinuousClock.Instant] = [:]
    private var downloads: [String: Task<Void, Never>] = [:]

    public init(store: LocalStore, cache: BlobCache, transport: any BlobTransport, tokens: any TokenProvider,
                options: Options = Options()) {
        documentID = store.documentID
        self.store = store
        self.cache = cache
        self.transport = transport
        self.tokens = tokens
        self.options = options
    }

    /// Everything the queue reports.
    public nonisolated func events() -> AsyncStream<BlobEvent> {
        broadcast.stream()
    }

    /// Every step of every transfer (a chunk sent or received), and each transfer's end as its
    /// last step (`completed == total`).
    public nonisolated func transfers() -> AsyncStream<BlobTransfer> {
        transferBroadcast.stream()
    }

    /// How far the blob `hash` has got, while it is going up or coming down.
    public nonisolated func transfer(of hash: String) -> BlobTransfer? {
        inFlight.withLock { $0[hash] }
    }

    private nonisolated func report(_ transfer: BlobTransfer) {
        inFlight.withLock { $0[transfer.hash] = transfer }
        transferBroadcast.yield(transfer)
    }

    private nonisolated func finish(_ hash: String) {
        inFlight.withLock { $0[hash] = nil }
    }

    /// The file's chunks, each reported as a step of the upload of `hash`.
    nonisolated func reportingChunks(of url: URL, hash: String, total: Int64, chunkSize: Int) -> AsyncThrowingStream<Data, any Error> {
        let reader = BlobChunks.Reader(url)
        let sent = Mutex<Int64>(0)
        report(BlobTransfer(hash: hash, direction: .upload, completed: 0, total: total))
        return AsyncThrowingStream(unfolding: { [self] in
            guard let chunk = try reader.next(chunkSize) else { return nil }
            let done = sent.withLock { value -> Int64 in
                value += Int64(chunk.count)
                return value
            }
            self.report(BlobTransfer(hash: hash, direction: .upload, completed: done, total: total))
            return chunk
        })
    }

    /// Starts the upload worker (idempotent).
    public func start() {
        guard worker == nil else { return }
        worker = Task { await work() }
    }

    /// Stops uploading and downloading.
    public func stop() async {
        let tasks = [worker].compactMap { $0 } + Array(downloads.values)
        worker = nil
        downloads = [:]
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
    }

    /// Whether the session is up: uploads and downloads run only then (the sync client says).
    public func setOnline(_ online: Bool) {
        self.online = online
        wake.fire()
    }

    /// Whether uploads were refused by the storage quota.
    public var isStorageFull: Bool { storageFull }

    /// *Retry now*: forgets the quota refusal and every backoff.
    public func retry() {
        storageFull = false
        notBefore = [:]
        wake.fire()
    }

    // MARK: Adding

    /// Caches the file at `url` (hashed and copied off this actor) and queues its upload; returns
    /// its hash, which the document's op references.  A thumbnail (`tag`) replaces the pending one.
    @discardableResult
    public func add(fileAt url: URL, mediaType: String, tag: Wiretuner_Blob_V1_BlobTag = .unspecified) async throws -> String {
        let cache = cache
        let chunkSize = options.chunkSize
        let (hash, size) = try await Task.detached(priority: .utility) {
            try cache.insert(contentsOf: url, chunkSize: chunkSize)
        }.value
        try await queue(hash, size: size, mediaType: mediaType, tag: tag)
        return hash
    }

    /// Caches `data` and queues its upload (a rendered thumbnail); returns its hash.
    @discardableResult
    public func add(_ data: Data, mediaType: String, tag: Wiretuner_Blob_V1_BlobTag = .unspecified) async throws -> String {
        let hash = try cache.insert(data)
        try await queue(hash, size: Int64(data.count), mediaType: mediaType, tag: tag)
        return hash
    }

    private func queue(_ hash: String, size: Int64, mediaType: String, tag: Wiretuner_Blob_V1_BlobTag) async throws {
        let label = tag == .thumbnail ? LocalStore.thumbnailTag : nil
        try await store.addPendingBlob(LocalStore.PendingBlob(hash: hash, path: cache.url(for: hash).path, tag: label, size: size,
                                                              mediaType: mediaType))
        wake.fire()
    }

    // MARK: Uploading

    private func work() async {
        while !Task.isCancelled {
            guard online else {
                await wake.wait()
                continue
            }
            let pending = ((try? await store.pendingBlobs()) ?? []).filter { !storageFull || $0.tag != nil }
            let now = ContinuousClock.now
            guard let next = pending.first(where: { (notBefore[$0.hash] ?? now) <= now }) else {
                if let soonest = pending.compactMap({ notBefore[$0.hash] }).min() {
                    await wake.wait(timeout: soonest - now)
                } else {
                    await wake.wait()
                }
                continue
            }
            await upload(next)
        }
    }

    private func accessToken() async throws -> String {
        if let token, !refreshToken { return token }
        let fresh = try await tokens.accessToken(forceRefresh: refreshToken)
        refreshToken = false
        token = fresh
        return fresh
    }

    private func upload(_ blob: LocalStore.PendingBlob) async {
        let sha256 = BlobCache.bytes(hex: blob.hash)
        do {
            let token = try await accessToken()
            let stat = try await transport.stat(.with {
                $0.documentID = documentID
                $0.sha256 = sha256
            }, token: token)
            if !stat.exists {
                let header = Wiretuner_Blob_V1_UploadHeader.with {
                    $0.documentID = documentID
                    $0.sha256 = sha256
                    $0.size = UInt64(blob.size)
                    $0.mediaType = blob.mediaType
                    $0.tag = blob.tag == LocalStore.thumbnailTag ? .thumbnail : .unspecified
                }
                defer { finish(blob.hash) }
                _ = try await transport.upload(header, chunks: reportingChunks(of: URL(fileURLWithPath: blob.path), hash: blob.hash, total: blob.size,
                                                                               chunkSize: options.chunkSize),
                                               token: token)
            }
            try await store.removePendingBlob(hash: blob.hash)
            refreshed = false
            attempts[blob.hash] = nil
            notBefore[blob.hash] = nil
            broadcast.yield(.uploaded(hash: blob.hash))
        } catch let error as SyncCallError where error.reason == .storageQuota {
            storageFull = true
            let waiting = (try? await store.pendingBlobCount()) ?? 0
            logger.notice("blob upload refused by the storage quota; \(waiting) waiting")
            broadcast.yield(.storageFull(waiting: waiting))
        } catch let error as SyncCallError where error.code == SyncCallError.unauthenticated && !refreshed {
            // Once until a call succeeds: a fresh token refused again backs off like any failure.
            refreshed = true
            refreshToken = true
        } catch {
            let attempt = attempts[blob.hash, default: 0]
            attempts[blob.hash] = attempt + 1
            let delay = backoff(attempt)
            notBefore[blob.hash] = .now + delay
            logger.notice("blob upload failed, retrying in \(delay): \(String(describing: error), privacy: .public)")
            broadcast.yield(.uploadFailed(hash: blob.hash, reason: String(describing: error), retryIn: delay))
        }
    }

    /// The delay before retry `attempt`.
    func backoff(_ attempt: Int) -> Duration {
        min(options.retryBase * Double(1 << min(attempt, 20)), options.retryMax) * (0.5 + 0.5 * options.random())
    }

    // MARK: Downloading

    /// Whether the blob `hash` can be drawn now; if not, it is downloaded (once, however often it
    /// is asked for) and `BlobEvent.available` announces it.
    public func blob(_ hash: String) -> BlobAvailability {
        if cache.contains(hash) {
            return .available(cache.url(for: hash))
        }
        if downloads[hash] == nil {
            downloads[hash] = Task { await download(hash) }
        }
        return .pending
    }

    /// Downloads `hash` until it is cached: while the server does not have it yet (a change may
    /// reference a blob still on its way) or a download fails, it retries with backoff.
    private func download(_ hash: String) async {
        var attempt = 0
        while !Task.isCancelled {
            guard online else {
                await wake.wait()
                continue
            }
            do {
                if try await fetch(hash) {
                    downloads[hash] = nil
                    return
                }
            } catch {
                broadcast.yield(.downloadFailed(hash: hash, reason: String(describing: error)))
            }
            try? await Task.sleep(for: backoff(attempt))
            attempt += 1
        }
    }

    /// One download attempt: false when the server does not hold the blob.
    private func fetch(_ hash: String) async throws -> Bool {
        let token = try await accessToken()
        let sha256 = BlobCache.bytes(hex: hash)
        let stat = try await transport.stat(.with {
            $0.documentID = documentID
            $0.sha256 = sha256
        }, token: token)
        guard stat.exists else { return false }
        let total = Int64(stat.blob.size)
        var received: Int64 = 0
        report(BlobTransfer(hash: hash, direction: .download, completed: 0, total: total))
        defer { finish(hash) }
        let temporary = try cache.temporaryURL()
        defer { try? FileManager.default.removeItem(at: temporary) }
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        var hasher = SHA256()
        let request = Wiretuner_Blob_V1_DownloadRequest.with {
            $0.documentID = documentID
            $0.sha256 = sha256
        }
        for try await response in transport.download(request, token: token) {
            if case .chunk(let chunk)? = response.frame {
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                received += Int64(chunk.count)
                report(BlobTransfer(hash: hash, direction: .download, completed: received, total: total))
            }
        }
        let actual = BlobCache.hex(hasher.finalize())
        guard actual == hash else { throw BlobCache.Failure.hashMismatch(expected: hash, actual: actual) }
        let url = try cache.adopt(temporary, as: hash)
        broadcast.yield(.available(hash: hash, url: url))
        return true
    }
}
