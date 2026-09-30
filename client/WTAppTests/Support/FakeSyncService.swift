import Foundation
import WTCRDT
import WTModel
import WTProto
import WTSync
@testable import WireTuner

/// An in-memory sync service for the app's tests (the WTSync tests' `FakeSyncServer`, reduced to
/// what the windows need): one document's log, Welcome and replay on Subscribe, pushes appended in
/// order and fanned out, acks with an optional collection point, presence recorded, blobs that
/// always exist.  A hosted test cannot listen on a port, so the client talks to it through the
/// `SyncTransport` seam.
actor FakeSyncServer {
    private(set) var log: [Wiretuner_Sync_V1_SequencedChange] = []
    private var accepted: [UInt64: UInt64] = [:]
    private var subscribers: [UUID: AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error>.Continuation] = [:]
    private(set) var presences: [Wiretuner_Sync_V1_PresenceUpdate] = []
    private(set) var acks: [UInt64] = []
    private(set) var subscribes = 0
    var collectionPoint: (seq: UInt64, timeMs: Int64)?
    var role: Wiretuner_Account_V1_DocumentRole = .editor
    /// Whether the document has been created (`DocumentService.Create`): until it has, Subscribe
    /// and pushes answer `NOT_FOUND` as the server does (DOC-019).  nil: it always exists.
    var exists: (@Sendable (String) -> Bool)?
    /// Subscribes refused because the document did not exist yet.
    private(set) var refusedSubscribes = 0

    init() {}

    /// `NOT_FOUND` when `documentID` has not been created yet.
    func checkExists(_ documentID: String) throws {
        guard let exists, !exists(documentID) else { return }
        throw SyncCallError(code: SyncCallError.notFound, message: "no document \(documentID)")
    }

    var head: UInt64 { UInt64(log.count) }
    var subscriberCount: Int { subscribers.count }

    func update(_ body: @Sendable (isolated FakeSyncServer) -> Void) {
        body(self)
    }

    /// Appends `change` (in order per replica) and sends it to every subscription.
    @discardableResult
    func accept(_ change: Wiretuner_Doc_V1_Change, author: String = "") -> UInt64 {
        if let last = accepted[change.replica], change.seq <= last {
            return log.first { $0.change.replica == change.replica && $0.change.seq == change.seq }?.serverSeq ?? head
        }
        accepted[change.replica] = change.seq
        let entry = Wiretuner_Sync_V1_SequencedChange.with {
            $0.serverSeq = head + 1
            $0.change = change
            $0.author.displayName = author
        }
        log.append(entry)
        send(.with { $0.change = entry })
        return entry.serverSeq
    }

    func send(_ frame: Wiretuner_Sync_V1_ServerFrame) {
        for continuation in subscribers.values { continuation.yield(frame) }
    }

    /// Ends every subscription with an error (the connection dropped).
    func disconnect() {
        for continuation in subscribers.values {
            continuation.finish(throwing: SyncCallError(code: SyncCallError.unavailable, message: "connection lost"))
        }
        subscribers = [:]
    }

    func subscribe(_ request: Wiretuner_Sync_V1_SubscribeRequest, continuation: AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error>.Continuation) {
        subscribes += 1
        do {
            try checkExists(request.documentID)
        } catch {
            refusedSubscribes += 1
            continuation.finish(throwing: error)
            return
        }
        continuation.yield(.with {
            $0.welcome = .with {
                $0.role = role
                $0.headSeq = head
                $0.lastAcceptedSeq = accepted[request.replica] ?? 0
                $0.featureLevel = 1
            }
        })
        for entry in log where entry.serverSeq > request.afterServerSeq { continuation.yield(.with { $0.change = entry }) }
        continuation.yield(.with { $0.presence = Wiretuner_Sync_V1_PresenceSnapshot() })
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
    }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
    }

    func record(presence: Wiretuner_Sync_V1_PresenceUpdate) {
        presences.append(presence)
    }

    func ack(_ applied: UInt64) -> Wiretuner_Sync_V1_AckResponse {
        acks.append(applied)
        return .with {
            $0.stableSeq = min(applied, head)
            $0.collectSeq = collectionPoint?.seq ?? 0
            $0.collectTimeMs = collectionPoint?.timeMs ?? 0
        }
    }
}

/// The client's side of `FakeSyncServer`.
struct FakeSyncTransport: SyncTransport, BlobTransport {
    let server: FakeSyncServer

    func subscribe(_ request: Wiretuner_Sync_V1_SubscribeRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error> {
        AsyncThrowingStream { continuation in
            Task { await server.subscribe(request, continuation: continuation) }
        }
    }

    func pushChange(_ request: Wiretuner_Sync_V1_PushChangeRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeResponse {
        try await server.checkExists(request.documentID)
        let seq = await server.accept(request.change)
        return .with { $0.serverSeq = seq }
    }

    func pushChangeBatch(_ request: Wiretuner_Sync_V1_PushChangeBatchRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeBatchResponse {
        var response = Wiretuner_Sync_V1_PushChangeBatchResponse()
        for change in request.changes { response.serverSeqs.append(await server.accept(change)) }
        return response
    }

    func pushChanges(_ frames: [Wiretuner_Sync_V1_PushChangesRequest], token: String) async throws -> Wiretuner_Sync_V1_PushChangesResponse {
        var response = Wiretuner_Sync_V1_PushChangesResponse()
        for change in frames.flatMap(\.changes) {
            await server.accept(change)
            response.lastAcceptedSeq = change.seq
        }
        return response
    }

    func updatePresence(_ request: Wiretuner_Sync_V1_UpdatePresenceRequest, token: String) async throws {
        await server.record(presence: request.presence)
    }

    func ack(_ request: Wiretuner_Sync_V1_AckRequest, token: String) async throws -> Wiretuner_Sync_V1_AckResponse {
        await server.ack(request.appliedServerSeq)
    }

    func fetchChanges(_ request: Wiretuner_Sync_V1_FetchChangesRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchChangesResponse, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchSnapshot(_ request: Wiretuner_Sync_V1_FetchSnapshotRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchSnapshotResponse, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func stat(_ request: Wiretuner_Blob_V1_StatRequest, token: String) async throws -> Wiretuner_Blob_V1_StatResponse {
        .with { $0.exists = true }
    }

    func upload(_ header: Wiretuner_Blob_V1_UploadHeader, chunks: AsyncThrowingStream<Data, any Error>, token: String) async throws -> Wiretuner_Blob_V1_UploadResponse {
        Wiretuner_Blob_V1_UploadResponse()
    }

    func download(_ request: Wiretuner_Blob_V1_DownloadRequest, token: String) -> AsyncThrowingStream<Wiretuner_Blob_V1_DownloadResponse, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// A mutable value closures can share in tests.
@MainActor
final class TestBox<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Tokens that always work.
struct StaticTokens: TokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "token" }
}

/// A connector over `FakeSyncServer` with short timings; counts connections and closes.
@MainActor
final class FakeSyncConnector: SyncConnecting {
    let server: FakeSyncServer
    let blobs: URL
    private(set) var connections = 0
    private(set) var closes = 0
    var failure: (any Error)?

    init(server: FakeSyncServer = FakeSyncServer()) {
        self.server = server
        blobs = FileManager.default.temporaryDirectory.appending(path: "WireTunerBlobs-\(UUID().uuidString)")
    }

    static var options: SyncClient.Options {
        var options = SyncClient.Options()
        options.ackInterval = .milliseconds(50)
        options.publishInterval = .milliseconds(5)
        options.presenceInterval = .milliseconds(20)
        options.backoffBase = .milliseconds(10)
        options.backoffMax = .milliseconds(50)
        options.idlePoll = .milliseconds(20)
        options.random = { 0.5 }
        return options
    }

    func connect(store: LocalStore, sink: any RemoteChangeSink, presence: LocalPresence?) throws -> SyncConnection {
        if let failure { throw failure }
        connections += 1
        let transport = FakeSyncTransport(server: server)
        let queue = BlobQueue(store: store, cache: BlobCache(directory: blobs), transport: transport, tokens: StaticTokens())
        let client = SyncClient(store: store, sink: sink, transport: transport, tokens: StaticTokens(), presence: presence, blobs: queue, options: Self.options)
        return SyncConnection(client: client) { [weak self] in await self?.closed() }
    }

    private func closed() {
        closes += 1
    }
}

/// Stores in a throwaway folder.
enum TestStores {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "WireTunerStores-\(UUID().uuidString)")
    }

    /// A document handle over a `LocalStore` at `directory/<id>/store.sqlite`.
    @MainActor
    static func handle(id: String = UUID().uuidString, title: String = "Stored", in directory: URL) -> DocumentHandle {
        DocumentHandle(id: id, title: title) {
            let store = try await LocalStore.open(documentID: id, at: directory.appending(components: id, "store.sqlite"))
            return await WTModel.Document(backend: store)
        }
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(_ timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
