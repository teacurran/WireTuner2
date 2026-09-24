import Foundation
import Synchronization
import WTCRDT
import WTCRDTSchema
import WTProto
@testable import WTSync

/// An in-process stand-in for the server's `SyncService` (server/api/.../sync/SyncGrpcService):
/// one document, its log, replica bindings with the acceptance rule (`seq = last + 1`, a silent
/// ack for an identical retry, `REPLICA_CONFLICT` for different content, `SEQ_GAP` otherwise),
/// Welcome with the snapshot hint, replay then presence then live frames, FetchChanges and
/// FetchSnapshot -- plus injectable faults: lost responses, delayed (reordered) pushes, one-shot
/// rejections, dropped and duplicated live frames, disconnects, silent streams.
actor FakeSyncServer {
    let documentID: String
    private(set) var log: [Wiretuner_Sync_V1_SequencedChange] = []
    /// Accepted bytes per replica and seq.
    private var accepted: [UInt64: [UInt64: Data]] = [:]
    private var serverSeqOf: [UInt64: [UInt64: UInt64]] = [:]
    var role: Wiretuner_Account_V1_DocumentRole = .editor
    var featureLevel: UInt32 = 1
    var mergeTable = WTCRDTSchemaPackage.mergeTableResource() ?? Data()
    /// The newest snapshot's frames and seq (the server's `snapshot` table).
    private var snapshot: (frames: [Wiretuner_Doc_V1_SnapshotFrame], seq: UInt64)?
    /// FetchChanges answers HISTORY_UNAVAILABLE for ranges starting below this.
    var compactedBelow: UInt64 = 0
    var validToken = "token-1"

    private var subscribers: [UUID: AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error>.Continuation] = [:]

    // Recording.
    private(set) var subscribes: [Wiretuner_Sync_V1_SubscribeRequest] = []
    private(set) var pushes: [(replica: UInt64, seq: UInt64, session: Int)] = []
    /// `Welcome.last_accepted_seq` of each subscription.
    private(set) var welcomes: [UInt64] = []
    private(set) var batches: [[UInt64]] = []
    private(set) var bulkFrames: [[UInt64]] = []
    private(set) var acks: [UInt64] = []
    private(set) var presences: [Wiretuner_Sync_V1_PresenceUpdate] = []
    private(set) var fetchChangesCalls: [(after: UInt64, until: UInt64)] = []
    private(set) var fetchSnapshotCalls = 0
    /// Pushes answered with SEQ_GAP, and pushes of a seq already accepted (silent acks).
    private(set) var gaps = 0
    private(set) var duplicates = 0

    // Faults.
    /// Push of this seq is accepted but the response is lost (the call fails UNAVAILABLE).
    var loseResponse: Set<UInt64> = []
    /// Push of this seq waits this long before reaching the replica queue (reordering).
    var delay: [UInt64: Duration] = [:]
    /// One-shot rejections by seq, before the acceptance rule.
    var reject: [UInt64: SyncCallError] = [:]
    /// Live frames of these server seqs are not delivered (a gap the client must fill).
    var dropLive: Set<UInt64> = []
    /// Every live frame is delivered twice.
    var duplicateLive = false
    /// After Welcome, the subscription goes quiet (no replay, presence or live frames).
    var silentAfterWelcome = false
    /// The next Subscribe calls fail with these errors, in order.
    var subscribeFailures: [SyncCallError] = []
    /// A bulk upload fails (UNAVAILABLE) after this many of its changes were accepted.
    var bulkDisconnectAfter: [Int] = []
    /// A bulk upload's response carries this rejection for this seq.
    var bulkReject: [UInt64: SyncCallError] = [:]
    /// Ack and UpdatePresence fail with this error.
    var ackFailure: SyncCallError?
    var presenceFailure: SyncCallError?
    /// Every live change also disconnects all subscriptions after it is delivered.
    var disconnectAfterLive = false
    /// A collection point to answer every Ack with, as the unknown fields 2 and 3 (D-067).
    var collectionPoint: (seq: UInt64, timeMs: Int64)?
    /// Ack answers say the stable point is at most this (another replica lags behind).
    var stableCap: UInt64?
    /// The acceptance limits (sync-protocol.adoc, "Server log"): a change over them is refused
    /// with `VALIDATION_FAILED` every time it arrives.
    var maxOps: Int?
    var maxBytes: Int?
    private(set) var validationFailures = 0

    init(documentID: String = "D1") {
        self.documentID = documentID
    }

    func update(_ body: @Sendable (isolated FakeSyncServer) -> Void) {
        body(self)
    }

    var head: UInt64 { UInt64(log.count) }

    /// The seqs accepted from `replica`, in log order.
    func acceptedSeqs(_ replica: UInt64) -> [UInt64] {
        log.filter { $0.change.replica == replica }.map(\.change.seq)
    }

    /// The server's own snapshot of its log through `seq` (the snapshotter).
    func takeSnapshot(through seq: UInt64? = nil, schema: Schema = .generated) {
        let through = seq ?? head
        var state = EngineState(schema: schema)
        for entry in log where entry.serverSeq <= through {
            state.apply(entry.change, serverSeq: entry.serverSeq)
        }
        var frames = SnapshotTransfer.frames(state, serverSeq: through)
        if case .header(var header)? = frames.first?.frame {
            header.uncompressedSize = 0   // as the server sends it until SRV-007
            frames[0] = .with { $0.header = header }
        }
        snapshot = (frames, through)
    }

    func setSnapshotFrames(_ frames: [Wiretuner_Doc_V1_SnapshotFrame], seq: UInt64) {
        snapshot = (frames, seq)
    }

    /// The merged state of the whole log.
    func stateHash(schema: Schema = .generated) -> [UInt8] {
        var state = EngineState(schema: schema)
        for entry in log {
            state.apply(entry.change, serverSeq: entry.serverSeq)
        }
        return state.stateHash
    }

    // MARK: Accepting

    private func check(_ token: String) throws {
        guard token == validToken else {
            throw SyncCallError(code: SyncCallError.unauthenticated, reason: .tokenExpired, message: "token expired")
        }
    }

    private func checkWriter() throws {
        guard role == .editor || role == .owner else {
            throw SyncCallError(code: SyncCallError.permissionDenied, reason: .roleInsufficient, message: "not an editor")
        }
    }

    /// The acceptance rule; the server seq of the change (the original one for an identical retry).
    func accept(_ change: Wiretuner_Doc_V1_Change, faults: Bool = true) throws -> UInt64 {
        if faults, let rejection = reject.removeValue(forKey: change.seq) {
            throw rejection
        }
        if retired.contains(change.replica) {
            throw SyncCallError(code: SyncCallError.failedPrecondition, reason: .replicaExpired, message: "retired")
        }
        try checkWriter()
        let bytes = try change.serializedData()
        let last = UInt64(accepted[change.replica]?.count ?? 0)
        if change.seq <= last {
            guard accepted[change.replica]?[change.seq] == bytes else {
                throw SyncCallError(code: SyncCallError.failedPrecondition, reason: .replicaConflict, message: "different content")
            }
            duplicates += 1
            return serverSeqOf[change.replica]![change.seq]!
        }
        guard change.seq == last + 1 else {
            gaps += 1
            throw SyncCallError(code: SyncCallError.aborted, reason: .seqGap, message: "expected \(last + 1), got \(change.seq)")
        }
        guard change.ops.count <= maxOps ?? .max, bytes.count <= maxBytes ?? .max else {
            validationFailures += 1
            throw SyncCallError(code: SyncCallError.invalidArgument, reason: .validationFailed, message: "change outside the limits")
        }
        accepted[change.replica, default: [:]][change.seq] = bytes
        let entry = Wiretuner_Sync_V1_SequencedChange.with {
            $0.serverSeq = head + 1
            $0.change = change
            if let name = authors[change.replica] {
                $0.author.displayName = name
            }
        }
        log.append(entry)
        serverSeqOf[change.replica, default: [:]][change.seq] = entry.serverSeq
        broadcast(entry)
        return entry.serverSeq
    }

    /// Display names the server attaches as `SequencedChange.author`, by replica.
    var authors: [UInt64: String] = [:]

    /// Another client's change, accepted and fanned out.
    @discardableResult
    func inject(_ change: Wiretuner_Doc_V1_Change) throws -> UInt64 {
        let saved = role
        role = .editor
        defer { role = saved }
        return try accept(change, faults: false)
    }

    /// Retires `replica`: its pushes and subscriptions are refused with `REPLICA_EXPIRED`.
    var retired: Set<UInt64> = []

    private func broadcast(_ entry: Wiretuner_Sync_V1_SequencedChange) {
        guard !dropLive.contains(entry.serverSeq) else { return }
        let frame = Wiretuner_Sync_V1_ServerFrame.with { $0.change = entry }
        for continuation in subscribers.values {
            continuation.yield(frame)
            if duplicateLive {
                continuation.yield(frame)
            }
        }
        if disconnectAfterLive {
            disconnect()
        }
    }

    /// Sends a frame to every subscription.
    func send(_ frame: Wiretuner_Sync_V1_ServerFrame) {
        for continuation in subscribers.values {
            continuation.yield(frame)
        }
    }

    /// Fails every subscription (a dropped connection).
    func disconnect() {
        for continuation in subscribers.values {
            continuation.finish(throwing: SyncCallError(code: SyncCallError.unavailable, message: "connection lost"))
        }
        subscribers = [:]
    }

    /// Ends every subscription cleanly.
    func endStreams() {
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers = [:]
    }

    var subscriberCount: Int { subscribers.count }

    // MARK: Calls

    func subscribe(_ request: Wiretuner_Sync_V1_SubscribeRequest, token: String,
                   _ continuation: AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error>.Continuation) {
        subscribes.append(request)
        do {
            try check(token)
            if !subscribeFailures.isEmpty {
                throw subscribeFailures.removeFirst()
            }
            if retired.contains(request.replica) {
                throw SyncCallError(code: SyncCallError.failedPrecondition, reason: .replicaExpired, message: "retired")
            }
        } catch {
            continuation.finish(throwing: error)
            return
        }
        let hint = request.afterServerSeq < (snapshot?.seq ?? 0)
        let replicaLast = UInt64(accepted[request.replica]?.count ?? 0)
        welcomes.append(replicaLast)
        continuation.yield(.with {
            $0.welcome = .with {
                $0.role = role
                $0.mergeTable = mergeTable
                $0.headSeq = head
                $0.lastAcceptedSeq = replicaLast
                $0.snapshotHint = hint
                $0.featureLevel = featureLevel
            }
        })
        if request.hasPresence {
            presences.append(request.presence)
        }
        guard !silentAfterWelcome else {
            subscribers[UUID()] = continuation
            return
        }
        if !hint {
            for entry in log where entry.serverSeq > request.afterServerSeq {
                continuation.yield(.with { $0.change = entry })
            }
        }
        continuation.yield(.with { $0.presence = .with { $0.participants = presences.suffix(1) } })
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
    }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
    }

    func pushChange(_ request: Wiretuner_Sync_V1_PushChangeRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeResponse {
        try check(token)
        let change = request.change
        pushes.append((change.replica, change.seq, subscribes.count))
        if let wait = delay.removeValue(forKey: change.seq) {
            try await Task.sleep(for: wait)
        }
        let serverSeq = try accept(change)
        if loseResponse.remove(change.seq) != nil {
            throw SyncCallError(code: SyncCallError.unavailable, message: "response lost")
        }
        return .with { $0.serverSeq = serverSeq }
    }

    func pushChangeBatch(_ request: Wiretuner_Sync_V1_PushChangeBatchRequest, token: String) throws -> Wiretuner_Sync_V1_PushChangeBatchResponse {
        try check(token)
        batches.append(request.changes.map(\.seq))
        var response = Wiretuner_Sync_V1_PushChangeBatchResponse()
        for change in request.changes {
            do {
                response.serverSeqs.append(try accept(change))
            } catch let error as SyncCallError {
                response.rejected = .with {
                    $0.replica = change.replica
                    $0.seq = change.seq
                    $0.reason = error.reason ?? .unspecified
                    $0.code = Int32(error.code)
                    $0.message = error.message
                }
                break
            }
        }
        return response
    }

    func pushChanges(_ frames: [Wiretuner_Sync_V1_PushChangesRequest], token: String) throws -> Wiretuner_Sync_V1_PushChangesResponse {
        try check(token)
        bulkFrames.append(contentsOf: frames.map { $0.changes.map(\.seq) })
        let limit = bulkDisconnectAfter.isEmpty ? nil : bulkDisconnectAfter.removeFirst()
        var count = 0
        var replica: UInt64 = 0
        var response = Wiretuner_Sync_V1_PushChangesResponse()
        upload: for frame in frames {
            for change in frame.changes {
                replica = change.replica
                if let limit, count == limit {
                    throw SyncCallError(code: SyncCallError.unavailable, message: "connection lost mid-upload")
                }
                if let error = bulkReject.removeValue(forKey: change.seq) {
                    response.rejected = .with {
                        $0.replica = change.replica
                        $0.seq = change.seq
                        $0.reason = error.reason ?? .unspecified
                        $0.code = Int32(error.code)
                        $0.message = error.message
                    }
                    break upload
                }
                do {
                    _ = try accept(change)
                } catch let error as SyncCallError {
                    response.rejected = .with {
                        $0.replica = change.replica
                        $0.seq = change.seq
                        $0.reason = error.reason ?? .unspecified
                        $0.code = Int32(error.code)
                        $0.message = error.message
                    }
                    break upload
                }
                count += 1
            }
        }
        response.lastAcceptedSeq = UInt64(accepted[replica]?.count ?? 0)
        return response
    }

    func updatePresence(_ request: Wiretuner_Sync_V1_UpdatePresenceRequest, token: String) throws {
        try check(token)
        if let presenceFailure { throw presenceFailure }
        presences.append(request.presence)
    }

    func ack(_ request: Wiretuner_Sync_V1_AckRequest, token: String) throws -> Wiretuner_Sync_V1_AckResponse {
        try check(token)
        if let ackFailure { throw ackFailure }
        acks.append(request.appliedServerSeq)
        return .with {
            $0.stableSeq = min(request.appliedServerSeq, head, stableCap ?? .max)
            $0.collectSeq = collectionPoint?.seq ?? 0
            $0.collectTimeMs = collectionPoint?.timeMs ?? 0
        }
    }

    func fetchChanges(_ request: Wiretuner_Sync_V1_FetchChangesRequest, token: String,
                      _ continuation: AsyncThrowingStream<Wiretuner_Sync_V1_FetchChangesResponse, any Error>.Continuation) {
        fetchChangesCalls.append((request.afterServerSeq, request.untilServerSeq))
        do {
            try check(token)
            guard request.afterServerSeq >= compactedBelow else {
                throw SyncCallError(code: SyncCallError.failedPrecondition, reason: .historyUnavailable, message: "compacted")
            }
        } catch {
            continuation.finish(throwing: error)
            return
        }
        let until = request.untilServerSeq == 0 ? head : min(request.untilServerSeq, head)
        let range = log.filter { $0.serverSeq > request.afterServerSeq && $0.serverSeq <= until }
        for start in stride(from: 0, to: range.count, by: 10) {
            continuation.yield(.with {
                $0.changes = Array(range[start..<min(start + 10, range.count)])
                $0.headSeq = head
            })
        }
        continuation.finish()
    }

    func fetchSnapshot(_ request: Wiretuner_Sync_V1_FetchSnapshotRequest, token: String,
                       _ continuation: AsyncThrowingStream<Wiretuner_Sync_V1_FetchSnapshotResponse, any Error>.Continuation) {
        fetchSnapshotCalls += 1
        do {
            try check(token)
            guard let snapshot else {
                throw SyncCallError(code: SyncCallError.failedPrecondition, reason: .historyUnavailable, message: "no snapshot")
            }
            for frame in snapshot.frames {
                continuation.yield(.with { $0.frame = frame })
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}

/// `SyncTransport` straight onto a `FakeSyncServer`.
struct FakeTransport: SyncTransport {
    let server: FakeSyncServer

    func subscribe(_ request: Wiretuner_Sync_V1_SubscribeRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error> {
        AsyncThrowingStream { continuation in
            Task { await server.subscribe(request, token: token, continuation) }
        }
    }

    func pushChange(_ request: Wiretuner_Sync_V1_PushChangeRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeResponse {
        try await server.pushChange(request, token: token)
    }

    func pushChangeBatch(_ request: Wiretuner_Sync_V1_PushChangeBatchRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeBatchResponse {
        try await server.pushChangeBatch(request, token: token)
    }

    func pushChanges(_ frames: [Wiretuner_Sync_V1_PushChangesRequest], token: String) async throws -> Wiretuner_Sync_V1_PushChangesResponse {
        try await server.pushChanges(frames, token: token)
    }

    func updatePresence(_ request: Wiretuner_Sync_V1_UpdatePresenceRequest, token: String) async throws {
        try await server.updatePresence(request, token: token)
    }

    func ack(_ request: Wiretuner_Sync_V1_AckRequest, token: String) async throws -> Wiretuner_Sync_V1_AckResponse {
        try await server.ack(request, token: token)
    }

    func fetchChanges(_ request: Wiretuner_Sync_V1_FetchChangesRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchChangesResponse, any Error> {
        AsyncThrowingStream { continuation in
            Task { await server.fetchChanges(request, token: token, continuation) }
        }
    }

    func fetchSnapshot(_ request: Wiretuner_Sync_V1_FetchSnapshotRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchSnapshotResponse, any Error> {
        AsyncThrowingStream { continuation in
            Task { await server.fetchSnapshot(request, token: token, continuation) }
        }
    }
}

/// Tokens handed out in order; `failNext` makes refreshes throw.
final class FakeTokens: TokenProvider {
    private let state: Mutex<(tokens: [String], index: Int, refreshes: Int, failure: (any Error)?)>

    init(_ tokens: [String] = ["token-1", "token-2", "token-3", "token-4"]) {
        state = Mutex((tokens, 0, 0, nil))
    }

    func accessToken(forceRefresh: Bool) async throws -> String {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            if forceRefresh {
                state.refreshes += 1
                state.index = min(state.index + 1, state.tokens.count - 1)
            }
            return state.tokens[state.index]
        }
    }

    var refreshes: Int { state.withLock { $0.refreshes } }

    func fail(with error: (any Error)?) {
        state.withLock { $0.failure = error }
    }
}

/// Presence that the test moves.
final class FakePresence: PresenceSource {
    private let value = Mutex<Wiretuner_Sync_V1_PresenceUpdate?>(nil)

    func presence() async -> Wiretuner_Sync_V1_PresenceUpdate? {
        value.withLock { $0 }
    }

    func move(tool: String) {
        value.withLock {
            var update = $0 ?? Wiretuner_Sync_V1_PresenceUpdate()
            update.state = .active
            update.tool = tool
            $0 = update
        }
    }
}
