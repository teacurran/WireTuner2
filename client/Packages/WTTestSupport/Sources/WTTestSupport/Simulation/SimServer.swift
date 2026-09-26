import Foundation
import WTCRDT
import WTCRDTSchema
import WTProto
import WTSync

/// A person on the simulated server.
public struct SimUser: Sendable, Hashable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Who makes a call: the account the bearer token names and the device (`wt-device`), which
/// together are what a replica id is bound to.
public struct SimCaller: Sendable, Hashable {
    public var account: String
    public var device: String
}

/// The collection point (C, T) of D-067.
public struct SimCollectionPoint: Sendable, Hashable {
    public var seq: UInt64
    public var timeMs: Int64

    public init(seq: UInt64, timeMs: Int64) {
        self.seq = seq
        self.timeMs = timeMs
    }
}

/// The in-process sync server of the simulator (docs/spec/testing.adoc, "Multi-client
/// simulation"): `SyncService` as docs/spec/sync-protocol.adoc and server.adoc specify and SRV-005,
/// SRV-006 and SRV-013 built it, for any number of documents, people and devices.
///
/// * *Device ids*: a `wt-device` that is not a UUID is refused with `INVALID_ARGUMENT` before
///   anything else is read (`PrincipalInterceptor`), so no two clients share a binding by accident.
/// * *Acceptance* in the server's order: a valid token (`UNAUTHENTICATED`/`TOKEN_EXPIRED` once it
///   has expired on the simulated clock), a writer's role (`ROLE_INSUFFICIENT`), a live replica
///   (`REPLICA_EXPIRED`), a replica bound to this account and device or unbound -- first use binds
///   it (`REPLICA_CONFLICT`), `seq = last + 1` (a silent ack for an identical retry,
///   `REPLICA_CONFLICT` for different content, `SEQ_GAP` otherwise), the limits (10,000 ops,
///   4 MiB, at least one op: `VALIDATION_FAILED`).
/// * *Subscribe*: `Welcome` (role, merge table, head, the replica's last accepted seq, the snapshot
///   hint when the newest snapshot is past `after_server_seq`), the replay unless hinted, a
///   `PresenceSnapshot`, then live frames; `Pong` after a quiet interval; `RoleChanged` and
///   `AccessRemoved` to the person's own subscriptions only, the latter ending them.
/// * *Catch-up*: `FetchChanges` in frames of at most 256 changes, `until` clamped to the head;
///   `FetchSnapshot` of the newest snapshot, `HISTORY_UNAVAILABLE` without one.
/// * *Stability* (server.adoc, Jobs): `Ack` answers `stable_seq = min(last ack over live
///   replicas)` and the collection point; each change is recorded with its author's horizon (the
///   publication it confirmed by acking again, capped by `base_server_seq`); `runStabilityJob()`
///   retires replicas silent for `retireAfter` of simulated time and computes (C, T);
///   `takeSnapshot()` is the snapshotter, collecting at (C, T).
/// * *Fork* (`DocumentService.Fork`, *Save my version as a copy*): a new document holding the
///   source's log through a seq plus the caller's changes.
/// * *Faults* a scenario scripts: a node restart (every subscription fails, calls answer
///   `UNAVAILABLE` for a while; graceful restarts send `RECONNECT` first), a Valkey restart (live
///   frames published meanwhile never reach the subscriptions, which fail when the bus is back),
///   a Postgres failover (calls fail meanwhile, and the push in flight commits but loses its
///   reply).
///
/// Not modelled, since the client cannot tell: protovalidate and the merge-table check of each op
/// path (the simulator only sends what WTModel builds), rate limits, presence expiry and colours.
public actor SimServer {
    public struct Options: Sendable {
        /// `Pong` after this much real time without a frame on a subscription.
        public var pongAfter: Duration = .milliseconds(400)
        /// Replicas silent this long (simulated) are retired by `runStabilityJob()` (90 days).
        public var retireAfter: Duration = .seconds(90 * 24 * 3600)
        /// The snapshotter runs after every this many accepted changes of a document (0: only when
        /// asked, `takeSnapshot`).
        public var snapshotEvery = 0
        /// The acceptance limits (sync-protocol.adoc, "Server log").
        public var maxOps = 10_000
        public var maxBytes = 4 << 20
        /// The largest multi-change `PushChanges` frame and `FetchChanges` frame (1 MiB, 256 changes).
        public var frameBytes = 1 << 20
        public var frameChanges = 256

        public init() {}
    }

    /// What the server did, for a scenario's assertions and the failure report.
    public struct Stats: Sendable, Hashable {
        public var subscribes = 0
        public var pushes = 0
        public var batches = 0
        public var bulkUploads = 0
        public var accepted = 0
        public var duplicates = 0
        public var gaps = 0
        public var conflicts = 0
        public var expired = 0
        public var roleRefusals = 0
        public var tokenRefusals = 0
        public var validationFailures = 0
        /// Calls refused for a `wt-device` that is not a UUID.
        public var malformedDevices = 0
        public var unavailable = 0
        public var acks = 0
        public var fetchChanges = 0
        public var fetchSnapshots = 0
        public var snapshots = 0
        public var forks = 0
        /// `CreateBranch` calls that created a branch.
        public var branches = 0
        public var retired = 0
        public var droppedLiveFrames = 0
        /// Pushes accepted whose reply was lost (the failover's commit-then-crash).
        public var lostReplies = 0
    }

    struct ReplicaRow {
        var lastAck: UInt64 = 0
        var lastSeenMs: Int64
        var published = SimCollectionPoint(seq: 0, timeMs: 0)
        var horizon = SimCollectionPoint(seq: 0, timeMs: 0)
        var retired = false
    }

    struct Doc {
        var id: String
        var log: [Wiretuner_Sync_V1_SequencedChange] = []
        /// The horizon each log entry was recorded with (index = server_seq - 1).
        var horizons: [SimCollectionPoint] = []
        /// Accepted bytes per replica, index = seq - 1, and their server seqs.
        var accepted: [UInt64: [Data]] = [:]
        var serverSeqOf: [UInt64: [UInt64]] = [:]
        var bindings: [UInt64: SimCaller] = [:]
        var roles: [String: Wiretuner_Account_V1_DocumentRole] = [:]
        var replicas: [UInt64: ReplicaRow] = [:]
        var snapshot: (frames: [Wiretuner_Doc_V1_SnapshotFrame], seq: UInt64)?
        var collectionPoint: SimCollectionPoint?
        /// `document.stable_seq`: only ever raised.
        var stableSeq: UInt64 = 0
        var presence: [UInt64: Wiretuner_Sync_V1_PresenceUpdate] = [:]
        /// A branch's parent (COLLAB-019): its roles are the parent's.
        var parent: String?

        var head: UInt64 { UInt64(log.count) }
    }

    struct Subscriber {
        var document: String
        var caller: SimCaller
        var replica: UInt64
        var continuation: AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error>.Continuation
        var lastFrame: ContinuousClock.Instant
    }

    public let clock: SimClock
    public var options: Options
    public private(set) var stats = Stats()
    private var documents: [String: Doc] = [:]
    private var users: [String: SimUser] = [:]
    private var subscribers: [UUID: Subscriber] = [:]
    private var tokenSerial = 0
    private var heartbeat: Task<Void, Never>?
    private var downUntil: ContinuousClock.Instant?
    private var busDownUntil: ContinuousClock.Instant?
    private var databaseDownUntil: ContinuousClock.Instant?
    private var loseNextReply = false
    private let mergeTable = WTCRDTSchemaPackage.mergeTableResource() ?? Data()

    public init(clock: SimClock, options: Options = Options()) {
        self.clock = clock
        self.options = options
    }

    // MARK: Administration

    /// Registers `user`.
    public func add(_ user: SimUser) {
        users[user.id] = user
    }

    /// Creates document `id` owned by `owner`.
    public func createDocument(_ id: String, owner: String) {
        var doc = Doc(id: id)
        doc.roles[owner] = .owner
        documents[id] = doc
    }

    public func hasDocument(_ id: String) -> Bool {
        documents[id] != nil
    }

    /// Sets `account`'s role on `document`, telling that person's live subscriptions
    /// (`RoleChanged`); `.unspecified` removes the access (`AccessRemoved`, which ends them).
    public func setRole(_ role: Wiretuner_Account_V1_DocumentRole, for account: String, on document: String) {
        guard documents[document] != nil else { return }
        if role == .unspecified {
            documents[document]?.roles[account] = nil
            for (id, subscriber) in subscribers where subscriber.document == document && subscriber.caller.account == account {
                subscriber.continuation.yield(.with { $0.event.accessRemoved = Wiretuner_Sync_V1_AccessRemoved() })
                subscriber.continuation.finish()
                subscribers[id] = nil
            }
            return
        }
        documents[document]?.roles[account] = role
        send(to: document, account: account, .with { $0.event.roleChanged.role = role })
    }

    /// A bearer token for `account` valid for `lifetime` of simulated time.
    public func issueToken(for account: String, lifetime: Duration) -> String {
        tokenSerial += 1
        let expiry = clock.nowMs() + Int64(SimClock.seconds(lifetime) * 1_000)
        return "sim.\(account).\(expiry).\(tokenSerial)"
    }

    // MARK: Reading

    public func head(_ document: String) -> UInt64 {
        documents[document]?.head ?? 0
    }

    public func log(_ document: String) -> [Wiretuner_Sync_V1_SequencedChange] {
        documents[document]?.log ?? []
    }

    /// The seqs accepted from `replica`, in log order.
    public func acceptedSeqs(_ replica: UInt64, in document: String) -> [UInt64] {
        log(document).filter { $0.change.replica == replica }.map(\.change.seq)
    }

    public func isRetired(_ replica: UInt64, in document: String) -> Bool {
        documents[document]?.replicas[replica]?.retired ?? false
    }

    public func collectionPoint(_ document: String) -> SimCollectionPoint? {
        documents[document]?.collectionPoint
    }

    public func snapshotSeq(_ document: String) -> UInt64? {
        documents[document]?.snapshot?.seq
    }

    public var subscriberCount: Int { subscribers.count }

    /// The document's head, snapshot, collection point and replica rows, for a failure report.
    public func describe(_ document: String) -> String {
        guard let doc = documents[document] else { return "no document \(document)" }
        var lines = ["\(document): head \(doc.head), snapshot \(doc.snapshot.map { "\($0.seq)" } ?? "none"), "
                     + "collection point \(doc.collectionPoint.map { "(\($0.seq), \($0.timeMs))" } ?? "none")"]
        for (replica, row) in doc.replicas.sorted(by: { $0.key < $1.key }) {
            lines.append("  replica \(replica): ack \(row.lastAck), seen \(row.lastSeenMs), published \(row.published.seq), "
                         + "horizon \(row.horizon.seq)\(row.retired ? ", retired" : "")")
        }
        return lines.joined(separator: "\n")
    }

    /// The merged state of the whole log, collected at the collection point when `collected`.
    public func state(_ document: String, collected: Bool = false) -> EngineState {
        var state = EngineState()
        for entry in log(document) {
            state.apply(entry.change, serverSeq: entry.serverSeq)
        }
        if collected, let point = documents[document]?.collectionPoint {
            state.collect(stableSeq: point.seq, now: point.timeMs)
        }
        return state
    }

    // MARK: Jobs

    /// The snapshotter: the log through the head, collected at the collection point.
    public func takeSnapshot(_ document: String) {
        guard let doc = documents[document] else { return }
        let state = state(document, collected: true)
        documents[document]?.snapshot = (SnapshotTransfer.frames(state, serverSeq: doc.head), doc.head)
        stats.snapshots += 1
    }

    /// The Stability job (server.adoc, Jobs): retires replicas silent for `retireAfter`, then
    /// computes the collection point from the live replicas' horizons and the changes' horizons.
    public func runStabilityJob() {
        let now = clock.nowMs()
        let window = Int64(SimClock.seconds(options.retireAfter) * 1_000)
        for id in documents.keys.sorted() {
            guard var doc = documents[id] else { continue }
            for (replica, row) in doc.replicas where !row.retired && now - row.lastSeenMs >= window {
                doc.replicas[replica]?.retired = true
                stats.retired += 1
            }
            let live = doc.replicas.values.filter { !$0.retired }
            doc.stableSeq = max(doc.stableSeq, min(doc.head, live.map(\.lastAck).min() ?? 0))
            if let first = live.first {
                var point = live.reduce(first.horizon) {
                    SimCollectionPoint(seq: min($0.seq, $1.horizon.seq), timeMs: min($0.timeMs, $1.horizon.timeMs))
                }
                var lowered = true
                while lowered {
                    lowered = false
                    for index in Int(point.seq)..<doc.horizons.count where doc.horizons[index].seq < point.seq {
                        point.seq = doc.horizons[index].seq
                        lowered = true
                        break
                    }
                }
                for index in Int(point.seq)..<doc.horizons.count {
                    point.timeMs = min(point.timeMs, doc.horizons[index].timeMs)
                }
                doc.collectionPoint = point.seq > 0 ? point : nil
            }
            documents[id] = doc
        }
    }

    /// Publishes (C, T) for `document` directly, as the Stability job would: for a test that needs
    /// a given collection point without scripting the acks that let the job reach it.  `seq` must
    /// be a stable point: every live replica applied it and nothing sequenced after it names what a
    /// collection there drops.
    public func publishCollectionPoint(_ point: SimCollectionPoint, for document: String) {
        documents[document]?.collectionPoint = point
    }

    // MARK: Faults

    /// A node restart: every subscription fails and calls answer `UNAVAILABLE` for `downFor`
    /// (simulated).  A graceful restart (a drain) sends `RECONNECT` and ends the subscriptions
    /// instead.
    public func restart(downFor: Duration, graceful: Bool = false) {
        if graceful {
            for subscriber in subscribers.values {
                subscriber.continuation.yield(.with { $0.event.reconnect = Wiretuner_Sync_V1_Reconnect() })
                subscriber.continuation.finish()
            }
            subscribers = [:]
        } else {
            failSubscriptions("server restarting")
        }
        downUntil = .now + clock.real(downFor)
    }

    /// A Valkey restart: live frames published during `outage` (simulated) are lost; when the bus
    /// is back every subscription fails, so its client resubscribes from what it applied.
    public func restartBus(outage: Duration) {
        busDownUntil = .now + clock.real(outage)
        for id in documents.keys {
            documents[id]?.presence = [:]
        }
        let wait = clock.real(outage)
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            await self?.busRecovered()
        }
    }

    private func busRecovered() {
        busDownUntil = nil
        failSubscriptions("fan-out bus reconnected")
    }

    /// A Postgres failover to the replica: calls fail for `outage` (simulated), and the next
    /// accepted push loses its reply (it committed on the old primary just before it went).
    public func failOverDatabase(outage: Duration) {
        databaseDownUntil = .now + clock.real(outage)
        loseNextReply = true
    }

    /// Ends every subscription and the heartbeat.
    public func shutdown() {
        heartbeat?.cancel()
        heartbeat = nil
        for subscriber in subscribers.values {
            subscriber.continuation.finish()
        }
        subscribers = [:]
    }

    private func failSubscriptions(_ message: String) {
        for subscriber in subscribers.values {
            subscriber.continuation.finish(throwing: SyncCallError(code: SyncCallError.unavailable, message: message))
        }
        subscribers = [:]
    }

    // MARK: Checks

    /// `PrincipalInterceptor`: a `wt-device` that is not a UUID is `INVALID_ARGUMENT` (with no
    /// reason: nothing a client can drop or rotate fixes it).
    private func checkDevice(_ device: String) throws {
        guard UUID(uuidString: device) == nil else { return }
        stats.malformedDevices += 1
        throw SyncCallError(code: SyncCallError.invalidArgument, message: "wt-device must be a UUID, got \"\(device)\"")
    }

    private func available(database: Bool = true) throws {
        let now = ContinuousClock.now
        if let downUntil, now < downUntil {
            stats.unavailable += 1
            throw SyncCallError(code: SyncCallError.unavailable, message: "server restarting")
        }
        if database, let databaseDownUntil, now < databaseDownUntil {
            stats.unavailable += 1
            throw SyncCallError(code: SyncCallError.unavailable, message: "database failing over")
        }
    }

    /// The account `token` names, or `UNAUTHENTICATED`.
    private func account(_ token: String) throws -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "sim", users[String(parts[1])] != nil, let expiry = Int64(parts[2]) else {
            stats.tokenRefusals += 1
            throw SyncCallError(code: SyncCallError.unauthenticated, message: "invalid token")
        }
        guard clock.nowMs() < expiry else {
            stats.tokenRefusals += 1
            throw SyncCallError(code: SyncCallError.unauthenticated, reason: .tokenExpired, message: "token expired")
        }
        return String(parts[1])
    }

    private func document(_ id: String) throws -> Doc {
        guard let doc = documents[id] else {
            throw SyncCallError(code: SyncCallError.notFound, reason: .documentNotFound, message: "no document \(id)")
        }
        return doc
    }

    private func role(_ doc: Doc, _ account: String) throws -> Wiretuner_Account_V1_DocumentRole {
        let roles = doc.parent.flatMap { documents[$0]?.roles } ?? doc.roles
        guard let role = roles[account] else {
            throw SyncCallError(code: SyncCallError.permissionDenied, message: "no access")
        }
        return role
    }

    private func live(_ doc: Doc, _ replica: UInt64) throws {
        if doc.replicas[replica]?.retired == true {
            stats.expired += 1
            throw SyncCallError(code: SyncCallError.failedPrecondition, reason: .replicaExpired, message: "replica \(replica) retired")
        }
    }

    private func bound(_ doc: Doc, _ replica: UInt64, _ caller: SimCaller) throws {
        if let binding = doc.bindings[replica], binding != caller {
            stats.conflicts += 1
            throw SyncCallError(code: SyncCallError.failedPrecondition, reason: .replicaConflict,
                                message: "replica \(replica) is bound to another device")
        }
    }

    // MARK: Accepting

    /// The acceptance rule; the change's server seq (the original one for an identical retry).
    private func accept(_ change: Wiretuner_Doc_V1_Change, in id: String, caller: SimCaller) throws -> UInt64 {
        var doc = try document(id)
        let role = try role(doc, caller.account)
        guard role == .editor || role == .owner else {
            stats.roleRefusals += 1
            throw SyncCallError(code: SyncCallError.permissionDenied, reason: .roleInsufficient, message: "not an editor")
        }
        try live(doc, change.replica)
        try bound(doc, change.replica, caller)
        let bytes = try change.serializedData()
        let last = UInt64(doc.accepted[change.replica]?.count ?? 0)
        if change.seq >= 1 && change.seq <= last {
            guard doc.accepted[change.replica]![Int(change.seq - 1)] == bytes else {
                stats.conflicts += 1
                throw SyncCallError(code: SyncCallError.failedPrecondition, reason: .replicaConflict, message: "seq \(change.seq) with different content")
            }
            stats.duplicates += 1
            return doc.serverSeqOf[change.replica]![Int(change.seq - 1)]
        }
        guard change.seq == last + 1 else {
            stats.gaps += 1
            throw SyncCallError(code: SyncCallError.aborted, reason: .seqGap, message: "expected \(last + 1), got \(change.seq)")
        }
        guard !change.ops.isEmpty, change.ops.count <= options.maxOps, bytes.count <= options.maxBytes else {
            stats.validationFailures += 1
            throw SyncCallError(code: SyncCallError.invalidArgument, reason: .validationFailed, message: "change outside the limits")
        }
        let now = clock.nowMs()
        doc.bindings[change.replica] = caller
        var row = doc.replicas[change.replica] ?? ReplicaRow(lastSeenMs: now)
        row.lastSeenMs = now
        doc.replicas[change.replica] = row
        let entry = Wiretuner_Sync_V1_SequencedChange.with {
            $0.serverSeq = doc.head + 1
            $0.change = change
            if let user = users[caller.account] {
                $0.author.displayName = user.name
            }
        }
        doc.log.append(entry)
        doc.horizons.append(SimCollectionPoint(seq: min(row.horizon.seq, change.baseServerSeq), timeMs: row.horizon.timeMs))
        doc.accepted[change.replica, default: []].append(bytes)
        doc.serverSeqOf[change.replica, default: []].append(entry.serverSeq)
        documents[id] = doc
        stats.accepted += 1
        broadcast(entry, in: id)
        if options.snapshotEvery > 0 && doc.head % UInt64(options.snapshotEvery) == 0 {
            takeSnapshot(id)
        }
        return entry.serverSeq
    }

    /// `accept`, reporting a refusal as the flattened `ChangeRejected`.
    private func acceptReporting(_ change: Wiretuner_Doc_V1_Change, in id: String, caller: SimCaller) -> Result<UInt64, SyncCallError> {
        do {
            return .success(try accept(change, in: id, caller: caller))
        } catch let error as SyncCallError {
            return .failure(error)
        } catch {
            return .failure(SyncCallError(code: SyncCallError.invalidArgument, reason: .validationFailed, message: "\(error)"))
        }
    }

    private static func rejected(_ change: Wiretuner_Doc_V1_Change, _ error: SyncCallError) -> Wiretuner_Sync_V1_ChangeRejected {
        .with {
            $0.replica = change.replica
            $0.seq = change.seq
            $0.reason = error.reason ?? .unspecified
            $0.code = Int32(error.code)
            $0.message = error.message
        }
    }

    private func broadcast(_ entry: Wiretuner_Sync_V1_SequencedChange, in document: String) {
        if let busDownUntil, ContinuousClock.now < busDownUntil {
            stats.droppedLiveFrames += 1
            return
        }
        send(to: document, account: nil, .with { $0.change = entry })
    }

    /// Tells every session on `document` about `event`: how the services beside sync (publishes,
    /// `SimPublishService`) announce their changes, as the API's document events do.
    public func announce(_ event: Wiretuner_Sync_V1_DocumentEvent, on document: String) {
        send(to: document, account: nil, .with { $0.event = event })
    }

    private func send(to document: String, account: String?, _ frame: Wiretuner_Sync_V1_ServerFrame) {
        let now = ContinuousClock.now
        for (id, subscriber) in subscribers where subscriber.document == document && (account == nil || subscriber.caller.account == account) {
            subscriber.continuation.yield(frame)
            subscribers[id]?.lastFrame = now
        }
    }

    // MARK: Calls

    func subscribe(_ request: Wiretuner_Sync_V1_SubscribeRequest, token: String, device: String,
                   _ continuation: AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error>.Continuation) {
        stats.subscribes += 1
        let doc: Doc
        let role: Wiretuner_Account_V1_DocumentRole
        let caller: SimCaller
        do {
            try available()
            try checkDevice(device)
            caller = SimCaller(account: try account(token), device: device)
            doc = try document(request.documentID)
            role = try self.role(doc, caller.account)
            try live(doc, request.replica)
            try bound(doc, request.replica, caller)
        } catch {
            continuation.finish(throwing: error)
            return
        }
        let id = request.documentID
        var row = doc.replicas[request.replica] ?? ReplicaRow(lastSeenMs: clock.nowMs())
        row.lastAck = max(row.lastAck, min(request.afterServerSeq, doc.head))
        documents[id]?.replicas[request.replica] = row
        let hint = (doc.snapshot?.seq ?? 0) > request.afterServerSeq
        continuation.yield(.with {
            $0.welcome = .with {
                $0.role = role
                $0.mergeTable = mergeTable
                $0.headSeq = doc.head
                $0.lastAcceptedSeq = UInt64(doc.accepted[request.replica]?.count ?? 0)
                $0.snapshotHint = hint
                $0.featureLevel = 1
            }
        })
        if request.hasPresence {
            documents[id]?.presence[request.replica] = request.presence
        }
        if !hint {
            for entry in doc.log where entry.serverSeq > request.afterServerSeq {
                continuation.yield(.with { $0.change = entry })
            }
        }
        let participants = (documents[id]?.presence ?? [:]).sorted { $0.key < $1.key }.map(\.value)
        continuation.yield(.with { $0.presence.participants = participants })
        let key = UUID()
        subscribers[key] = Subscriber(document: id, caller: caller, replica: request.replica, continuation: continuation, lastFrame: .now)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(key) }
        }
        startHeartbeat()
    }

    private func unsubscribe(_ key: UUID) {
        guard let subscriber = subscribers.removeValue(forKey: key) else { return }
        documents[subscriber.document]?.presence[subscriber.replica] = nil
    }

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        let interval = options.pongAfter / 2
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.pong()
            }
        }
    }

    private func pong() {
        let now = ContinuousClock.now
        for (id, subscriber) in subscribers where now - subscriber.lastFrame >= options.pongAfter {
            subscriber.continuation.yield(.with { $0.pong.serverTimeMs = clock.nowMs() })
            subscribers[id]?.lastFrame = now
        }
    }

    func pushChange(_ request: Wiretuner_Sync_V1_PushChangeRequest, token: String, device: String) throws -> Wiretuner_Sync_V1_PushChangeResponse {
        stats.pushes += 1
        try available()
        try checkDevice(device)
        let caller = SimCaller(account: try account(token), device: device)
        let serverSeq = try accept(request.change, in: request.documentID, caller: caller)
        try loseReplyIfFailingOver()
        return .with { $0.serverSeq = serverSeq }
    }

    /// The failover's commit-then-crash: the call committed, its reply is lost.
    private func loseReplyIfFailingOver() throws {
        guard loseNextReply else { return }
        loseNextReply = false
        stats.unavailable += 1
        stats.lostReplies += 1
        throw SyncCallError(code: SyncCallError.unavailable, message: "primary lost after commit")
    }

    func pushChangeBatch(_ request: Wiretuner_Sync_V1_PushChangeBatchRequest, token: String, device: String) throws -> Wiretuner_Sync_V1_PushChangeBatchResponse {
        stats.batches += 1
        try available()
        try checkDevice(device)
        let caller = SimCaller(account: try account(token), device: device)
        guard (1...32).contains(request.changes.count) else {
            stats.validationFailures += 1
            throw SyncCallError(code: SyncCallError.invalidArgument, reason: .validationFailed, message: "1 to 32 changes")
        }
        var response = Wiretuner_Sync_V1_PushChangeBatchResponse()
        for change in request.changes {
            switch acceptReporting(change, in: request.documentID, caller: caller) {
            case .success(let serverSeq):
                response.serverSeqs.append(serverSeq)
            case .failure(let error):
                response.rejected = Self.rejected(change, error)
                return response
            }
        }
        if !response.serverSeqs.isEmpty {
            try loseReplyIfFailingOver()
        }
        return response
    }

    func pushChanges(_ frames: [Wiretuner_Sync_V1_PushChangesRequest], token: String, device: String) throws -> Wiretuner_Sync_V1_PushChangesResponse {
        stats.bulkUploads += 1
        try available()
        try checkDevice(device)
        let caller = SimCaller(account: try account(token), device: device)
        guard let document = frames.first?.documentID else {
            throw SyncCallError(code: SyncCallError.invalidArgument, reason: .validationFailed, message: "empty upload")
        }
        var response = Wiretuner_Sync_V1_PushChangesResponse()
        var replica: UInt64 = 0
        upload: for frame in frames {
            guard frame.documentID == document, frame.changes.count <= options.frameChanges,
                  frame.changes.count <= 1 || ((try? frame.serializedData().count) ?? 0) <= options.frameBytes else {
                stats.validationFailures += 1
                throw SyncCallError(code: SyncCallError.invalidArgument, reason: .validationFailed, message: "frame outside the limits")
            }
            for change in frame.changes {
                replica = change.replica
                if case .failure(let error) = acceptReporting(change, in: document, caller: caller) {
                    response.rejected = Self.rejected(change, error)
                    break upload
                }
            }
        }
        response.lastAcceptedSeq = UInt64(documents[document]?.accepted[replica]?.count ?? 0)
        try loseReplyIfFailingOver()
        return response
    }

    func updatePresence(_ request: Wiretuner_Sync_V1_UpdatePresenceRequest, token: String, device: String) throws {
        try available(database: false)
        try checkDevice(device)
        let account = try account(token)
        _ = try role(try document(request.documentID), account)
        var update = request.presence
        update.session = request.replica
        if let user = users[account] {
            update.user.displayName = user.name
        }
        documents[request.documentID]?.presence[request.replica] = update
        if busDownUntil.map({ ContinuousClock.now >= $0 }) ?? true {
            send(to: request.documentID, account: nil, .with { $0.presenceUpdate = update })
        }
    }

    func ack(_ request: Wiretuner_Sync_V1_AckRequest, token: String, device: String) throws -> Wiretuner_Sync_V1_AckResponse {
        stats.acks += 1
        try available()
        try checkDevice(device)
        let account = try account(token)
        var doc = try document(request.documentID)
        _ = try role(doc, account)
        try live(doc, request.replica)
        let now = clock.nowMs()
        var row = doc.replicas[request.replica] ?? ReplicaRow(lastSeenMs: now)
        row.horizon = row.published
        row.lastAck = max(row.lastAck, min(request.appliedServerSeq, doc.head))
        row.lastSeenMs = now
        doc.replicas[request.replica] = row
        doc.stableSeq = max(doc.stableSeq, doc.replicas.values.filter { !$0.retired }.map(\.lastAck).min() ?? 0)
        let stable = doc.stableSeq
        doc.replicas[request.replica]?.published = SimCollectionPoint(seq: stable, timeMs: now)
        documents[request.documentID] = doc
        return .with {
            $0.stableSeq = stable
            $0.collectSeq = doc.collectionPoint?.seq ?? 0
            $0.collectTimeMs = doc.collectionPoint?.timeMs ?? 0
        }
    }

    func fetchChanges(_ request: Wiretuner_Sync_V1_FetchChangesRequest, token: String, device: String,
                      _ continuation: AsyncThrowingStream<Wiretuner_Sync_V1_FetchChangesResponse, any Error>.Continuation) {
        stats.fetchChanges += 1
        do {
            try available()
            try checkDevice(device)
            let doc = try document(request.documentID)
            _ = try role(doc, try account(token))
            let until = request.untilServerSeq == 0 ? doc.head : min(request.untilServerSeq, doc.head)
            let range = request.afterServerSeq < until ? Array(doc.log[Int(request.afterServerSeq)..<Int(until)]) : []
            for start in stride(from: 0, to: range.count, by: options.frameChanges) {
                continuation.yield(.with {
                    $0.changes = Array(range[start..<min(start + options.frameChanges, range.count)])
                    $0.headSeq = doc.head
                })
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    func fetchSnapshot(_ request: Wiretuner_Sync_V1_FetchSnapshotRequest, token: String, device: String,
                       _ continuation: AsyncThrowingStream<Wiretuner_Sync_V1_FetchSnapshotResponse, any Error>.Continuation) {
        stats.fetchSnapshots += 1
        do {
            try available()
            try checkDevice(device)
            let doc = try document(request.documentID)
            _ = try role(doc, try account(token))
            guard let snapshot = doc.snapshot,
                  request.atOrBeforeServerSeq == 0 || snapshot.seq <= request.atOrBeforeServerSeq else {
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

    /// `DocumentService.Fork`: document `newID`, owned by the caller, holding `source`'s log
    /// through `atServerSeq` and then `changes`, in order.
    public func fork(_ source: String, newID: String, atServerSeq: UInt64, changes: [Wiretuner_Doc_V1_Change], token: String) throws {
        try available()
        let account = try account(token)
        let doc = try document(source)
        _ = try role(doc, account)
        stats.forks += 1
        var copy = Doc(id: newID)
        copy.roles[account] = .owner
        let base = doc.log.prefix(Int(min(atServerSeq, doc.head))).map(\.change)
        for change in base + changes {
            let entry = Wiretuner_Sync_V1_SequencedChange.with {
                $0.serverSeq = copy.head + 1
                $0.change = change
            }
            copy.log.append(entry)
            copy.horizons.append(SimCollectionPoint(seq: 0, timeMs: 0))
            copy.accepted[change.replica, default: []].append((try? change.serializedData()) ?? Data())
            copy.serverSeqOf[change.replica, default: []].append(entry.serverSeq)
        }
        documents[newID] = copy
    }
}

extension SimServer {
    /// `BranchService.CreateBranch` as built (SRV-011, COLLAB-019; branches.adoc, "Server"): editor
    /// on the parent; the branch holds the parent's log through `fork_server_seq` (0: the head) and
    /// then `initial_changes`, each continuing its replica's seqs and bound to the caller on the
    /// branch; roles resolve through the parent.  A retry with the same id and parent answers the
    /// branch; the id taken by anything else is `DOCUMENT_EXISTS`.
    public func createBranch(_ request: Wiretuner_Docs_V1_CreateBranchRequest, token: String, device: String) throws
        -> Wiretuner_Docs_V1_CreateBranchResponse {
        try available()
        try checkDevice(device)
        let caller = SimCaller(account: try account(token), device: device)
        let parent = try document(request.parentDocumentID)
        let role = try role(parent, caller.account)
        guard role == .editor || role == .owner else {
            throw SyncCallError(code: SyncCallError.permissionDenied, reason: .roleInsufficient, message: "not an editor")
        }
        func answer(_ branch: Doc, fork: UInt64) -> Wiretuner_Docs_V1_CreateBranchResponse {
            .with {
                $0.branch.branchDocumentID = branch.id
                $0.branch.parentDocumentID = parent.id
                $0.branch.name = request.name
                $0.branch.forkServerSeq = fork
                $0.branch.headSeq = branch.head
            }
        }
        if let existing = documents[request.branchDocumentID] {
            guard existing.parent == parent.id else {
                throw SyncCallError(code: SyncCallError.failedPrecondition, reason: .documentExists, message: "id taken")
            }
            return answer(existing, fork: request.forkServerSeq)
        }
        let fork = request.forkServerSeq == 0 ? parent.head : request.forkServerSeq
        guard fork <= parent.head else {
            throw SyncCallError(code: SyncCallError.failedPrecondition, reason: .historyUnavailable, message: "beyond the head")
        }
        var branch = Doc(id: request.branchDocumentID)
        branch.parent = parent.id
        for entry in parent.log.prefix(Int(fork)) {
            branch.log.append(entry)
            branch.horizons.append(SimCollectionPoint(seq: 0, timeMs: 0))
            branch.accepted[entry.change.replica, default: []].append((try? entry.change.serializedData()) ?? Data())
            branch.serverSeqOf[entry.change.replica, default: []].append(entry.serverSeq)
        }
        let now = clock.nowMs()
        for change in request.initialChanges {
            if let binding = parent.bindings[change.replica], binding.account != caller.account {
                stats.conflicts += 1
                throw SyncCallError(code: SyncCallError.failedPrecondition, reason: .replicaConflict, message: "replica bound elsewhere")
            }
            let expected = UInt64(branch.accepted[change.replica]?.count ?? 0) + 1
            guard change.seq == expected else {
                stats.gaps += 1
                throw SyncCallError(code: SyncCallError.aborted, reason: .seqGap, message: "expected \(expected), got \(change.seq)")
            }
            let entry = Wiretuner_Sync_V1_SequencedChange.with {
                $0.serverSeq = branch.head + 1
                $0.change = change
                if let user = users[caller.account] { $0.author.displayName = user.name }
            }
            branch.log.append(entry)
            branch.horizons.append(SimCollectionPoint(seq: 0, timeMs: 0))
            branch.accepted[change.replica, default: []].append((try? change.serializedData()) ?? Data())
            branch.serverSeqOf[change.replica, default: []].append(entry.serverSeq)
            branch.bindings[change.replica] = caller
            branch.replicas[change.replica] = ReplicaRow(lastSeenMs: now)
        }
        documents[branch.id] = branch
        stats.branches += 1
        return answer(branch, fork: fork)
    }

    /// The parent of `document`, when it is a branch.
    public func parent(of document: String) -> String? {
        documents[document]?.parent
    }
}

extension SimServerTransport: DocumentCopyTransport {
    public func fork(_ request: Wiretuner_Docs_V1_ForkRequest, token: String) async throws -> Wiretuner_Docs_V1_ForkResponse {
        try await server.fork(request.sourceDocumentID, newID: request.newDocumentID, atServerSeq: request.atServerSeq,
                              changes: request.changes, token: token)
        return .with { $0.document.id = request.newDocumentID }
    }

    public func createBranch(_ request: Wiretuner_Docs_V1_CreateBranchRequest, token: String) async throws
        -> Wiretuner_Docs_V1_CreateBranchResponse {
        try await server.createBranch(request, token: token, device: device)
    }
}

/// `SyncTransport` straight onto a `SimServer`, as one device: the wire between the network
/// proxy and the server.
public struct SimServerTransport: SyncTransport {
    public let server: SimServer
    public let device: String

    public init(server: SimServer, device: String) {
        self.server = server
        self.device = device
    }

    public func subscribe(_ request: Wiretuner_Sync_V1_SubscribeRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error> {
        AsyncThrowingStream { continuation in
            Task { await server.subscribe(request, token: token, device: device, continuation) }
        }
    }

    public func pushChange(_ request: Wiretuner_Sync_V1_PushChangeRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeResponse {
        try await server.pushChange(request, token: token, device: device)
    }

    public func pushChangeBatch(_ request: Wiretuner_Sync_V1_PushChangeBatchRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeBatchResponse {
        try await server.pushChangeBatch(request, token: token, device: device)
    }

    public func pushChanges(_ frames: [Wiretuner_Sync_V1_PushChangesRequest], token: String) async throws -> Wiretuner_Sync_V1_PushChangesResponse {
        try await server.pushChanges(frames, token: token, device: device)
    }

    public func updatePresence(_ request: Wiretuner_Sync_V1_UpdatePresenceRequest, token: String) async throws {
        try await server.updatePresence(request, token: token, device: device)
    }

    public func ack(_ request: Wiretuner_Sync_V1_AckRequest, token: String) async throws -> Wiretuner_Sync_V1_AckResponse {
        try await server.ack(request, token: token, device: device)
    }

    public func fetchChanges(_ request: Wiretuner_Sync_V1_FetchChangesRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchChangesResponse, any Error> {
        AsyncThrowingStream { continuation in
            Task { await server.fetchChanges(request, token: token, device: device, continuation) }
        }
    }

    public func fetchSnapshot(_ request: Wiretuner_Sync_V1_FetchSnapshotRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchSnapshotResponse, any Error> {
        AsyncThrowingStream { continuation in
            Task { await server.fetchSnapshot(request, token: token, device: device, continuation) }
        }
    }
}
