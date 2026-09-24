import Foundation
import os
import WTCRDT
import WTCRDTSchema
import WTModel
import WTProto

/// One open document's sync session (docs/spec/sync-protocol.adoc; SYNC-003, SYNC-004, SYNC-005):
/// the subscription, catch-up, the outbox going up, acks, presence, and the published sync state.
///
/// `start()` runs sessions until `stop()`: each session subscribes from the highest applied
/// `server_seq`, reads `Welcome` (role, merge table, head, where pushes resume, the snapshot hint),
/// catches up -- through the subscription's replay, or `FetchSnapshot` and `FetchChanges` when
/// hinted -- then applies live changes in `server_seq` order through the `RemoteChangeSink` while
/// the outbox goes up: pipelined `PushChange` calls (up to 32 in flight), one `PushChangeBatch` at
/// a time in gateway mode, or `PushChanges` for a backlog at or over the bulk threshold.  A session
/// ends on a stream failure, 45 s of silence, `RECONNECT` or a replica rotation; the next one
/// starts after a jittered exponential backoff and resolves the pushes that were in flight from
/// `Welcome.last_accepted_seq`.
///
/// Once a session has downloaded up to `Welcome.head_seq` and before anything is pushed, it
/// reconciles (SYNC-006, SYNC-010): salvaged changes of a retired replica are re-issued, or the
/// outbox's divergence from the remote changes is measured, and a review may hold the outbox
/// until `resolveReview`.
///
/// WTApp opens the store, creates the `Document` over it, creates the client with the document as
/// its sink (with a `LocalPresence` and a `BlobQueue`), calls `start()`, calls
/// `localChangesAvailable()` after each local change, observes `states()`, `transitions()` and
/// `events()` (a `PresenceModel` binds to the latter; `reviewNeeded` opens the review sheet),
/// and calls `stop()` when the window closes.
public actor SyncClient {
    /// Limits and timings (docs/spec/sync-protocol.adoc); tests shorten the timings.
    public struct Options: Sendable {
        /// Pipelined `PushChange` calls in flight, and changes per `PushChangeBatch`.
        public var window = 32
        /// Gateway mode: one `PushChangeBatch` in flight instead of pipelined pushes, and no bulk.
        public var gatewayMode = false
        /// The bulk threshold (docs/spec/offline.adoc): this many coalesced changes, or bytes.
        public var bulkChanges = 200
        public var bulkBytes = 512 * 1024
        /// The largest `PushChanges` frame.
        public var frameBytes = 1 << 20
        /// How often applied changes are acknowledged.
        public var ackInterval: Duration = .seconds(2)
        /// While the stable point is below the applied seq (someone has not acknowledged it yet),
        /// `Ack` is repeated to learn when it rises, backing off from `ackInterval` to this.
        public var ackPollMax: Duration = .seconds(60)
        /// The server's limits for one change: an unsent change over them is split before it is
        /// sent (D-067's report, TEST-001).
        public var changeLimits = ChangeLimits.server
        /// How often presence is read (20 Hz), and the longest it goes unsent (the server expires
        /// an entry 15 s after its last update).
        public var presenceInterval: Duration = .milliseconds(50)
        public var presenceKeepAlive: Duration = .seconds(10)
        /// Silence on the subscription after which the session is abandoned.
        public var heartbeatTimeout: Duration = .seconds(45)
        /// Reconnect backoff: `base * 2^attempt`, at most `max`, scaled by a random 0.5...1.
        public var backoffBase: Duration = .milliseconds(500)
        public var backoffMax: Duration = .seconds(30)
        /// How often an idle pusher looks at the outbox without being told.
        public var idlePoll: Duration = .seconds(1)
        /// Counts and percentages are published at most this often.
        public var publishInterval: Duration = .milliseconds(250)
        /// The highest document feature level this client renders.
        public var featureLevel: UInt32 = 1
        /// Coalescing rules for the outbox.
        public var rules: Coalescer.Rules = .standard
        /// Uniform in 0..<1: the backoff jitter.
        public var random: @Sendable () -> Double = { Double.random(in: 0..<1) }
        /// The review thresholds (preferences.adoc), read at each reconcile (SYNC-006).
        public var reconcile: @Sendable () -> ReconcilePreferences = { .standard }
        /// Wall-clock time: the gap since the previous sync, and the time salvaged changes take.
        public var clock: @Sendable () -> Date = { Date() }
        /// *Undo levels* for the changes salvage re-issues.
        public var undoLevels = 100

        public init() {}
    }

    /// Why a session ended.
    enum SessionEnd: Error, Equatable {
        case streamEnded
        case heartbeat
        case reconnect
        case rotated
        case signIn
        case halted
        case restarted
        case violation(String)
        case failed(String)

        var cause: String {
            switch self {
            case .streamEnded: "subscription ended"
            case .heartbeat: "heartbeat timeout"
            case .reconnect: "server asked to reconnect"
            case .rotated: "replica rotated"
            case .signIn: "sign-in required"
            case .halted: "halted"
            case .restarted: "restarted from the server's state"
            case .violation(let what): "protocol violation: \(what)"
            case .failed(let what): what
            }
        }
    }

    enum PushOutcome: Sendable {
        case accepted(seq: UInt64, serverSeq: UInt64)
        case batch([Wiretuner_Doc_V1_Change], Wiretuner_Sync_V1_PushChangeBatchResponse, token: String)
        case rejected(Wiretuner_Doc_V1_Change, SyncCallError, token: String)
        case failed(any Error)
    }

    public nonisolated let documentID: String
    let store: LocalStore
    let sink: any RemoteChangeSink
    let transport: any SyncTransport
    let tokens: any TokenProvider
    let presenceSource: (any PresenceSource)?
    /// The document's blob queue, online while a session is (SYNC-008).
    public nonisolated let blobs: BlobQueue?
    let options: Options
    private let logger = Logger(subsystem: "app.wiretuner", category: "sync")

    private let stateBroadcast = Broadcast<SyncState>()
    private let transitionBroadcast = Broadcast<SyncTransition>()
    private let eventBroadcast = Broadcast<SyncEvent>()
    /// Wakes the pusher: a local change, a role change, a retry.
    private let nudge = Signal()
    /// Wakes the run loop from backoff or a parked state.
    private let wake = Signal()

    /// The published state.
    public private(set) var state: SyncState = .opening
    private var runner: Task<Void, Never>?
    private var lastPublish = ContinuousClock.now - .seconds(3600)
    private var publishPending = false

    // Standing: survives sessions.
    private var token: String?
    private var needsSignIn = false
    private var readOnly: ReadOnlyReason?
    private var errorDetail: String?
    private var parked = false
    private var attempted = false
    private var rotatedWithoutAccept = false
    private var snapshotFailures = 0
    private var featureLevel: UInt32 = 0
    private var blobWatcher: Task<Void, Never>?

    // Reconcile (SYNC-006, SYNC-010).
    /// The review holding the outbox until `resolveReview`, if any.
    public private(set) var pendingReview: ReviewModel?
    /// The last merge that did not hold the outbox: what *Review what changed* opens read-only.
    public private(set) var lastMerge: ReviewModel?
    /// Display names of remote replicas, from `SequencedChange.author`.
    private var authors: [UInt64: String] = [:]
    private var reconciled: Signal?
    private var restart: Signal?
    private var welcomeHead: UInt64 = 0
    private var sessionBase: UInt64 = 0
    private var snapshotInstalled = false
    /// Counts `resolveReview` calls: a measurement that started before one does not hold again.
    private var reviewEpoch = 0

    // The session.
    private var sessionUp = false
    private var sessionToken = ""
    private var welcome: Signal?
    private var replica: UInt64 = 0
    private var applied: UInt64 = 0
    private var ackedServerSeq: UInt64 = 0
    /// The stable point the last `Ack` answered, and whether that answer raised it and no `Ack`
    /// has confirmed it since (D-067: the server credits this replica's changes with the
    /// publication it confirmed by acking again).
    private var lastStable: UInt64 = 0
    private var confirmDue = false
    /// The highest local seq made before the last answer arrived: those changes were made under an
    /// older horizon, so the answer is confirmed only once they are accepted.
    private var confirmMark: UInt64 = 0
    /// When the stable point may be asked about again, and the delay after that.
    private var nextPoll = ContinuousClock.now
    private var pollDelay: Duration = .zero
    private var lastAccepted: UInt64 = 0
    private var lastFrame = ContinuousClock.now
    private var lastPresence: Wiretuner_Sync_V1_PresenceUpdate?
    private var lastPresenceAt: ContinuousClock.Instant?

    // The outbox going up.  `sent` holds the exact bytes of every change sent and not yet known
    // accepted, so a resend after `SEQ_GAP` or a dropped stream is identical (else the server
    // would answer `REPLICA_CONFLICT`); coalescing never rewrites a change once sent.
    private var acked: UInt64 = 0
    private var highestSent: UInt64 = 0
    private var nextSeq: UInt64 = 1
    private var sent: [UInt64: Wiretuner_Doc_V1_Change] = [:]
    private var queue: [Wiretuner_Doc_V1_Change] = []
    private var draining = false
    private var pausedUntil: ContinuousClock.Instant?
    private var backlog: Backlog?
    /// The seq of an unsent change over `changeLimits`: the queue stops before it, and once
    /// everything before it is accepted the outbox is split through salvage.
    private var oversized: UInt64?

    /// A client for the document in `store`; remote changes go to `sink`, whose backend must be
    /// `store` (the store itself for a headless upload).
    public init(store: LocalStore, sink: (any RemoteChangeSink)? = nil, transport: any SyncTransport,
                tokens: any TokenProvider, presence: (any PresenceSource)? = nil, blobs: BlobQueue? = nil,
                options: Options = Options()) {
        documentID = store.documentID
        self.store = store
        self.sink = sink ?? store
        self.transport = transport
        self.tokens = tokens
        presenceSource = presence
        self.blobs = blobs
        self.options = options
    }

    // MARK: Public API

    /// Starts running sessions (idempotent).
    public func start() {
        guard runner == nil else { return }
        runner = Task { await run() }
        if let blobs {
            let events = blobs.events()
            blobWatcher = Task { [weak self] in
                for await _ in events {
                    await self?.schedulePublish("blob queue")
                }
            }
            Task { await blobs.start() }
        }
    }

    /// Acknowledges what was applied, says `GONE`, and ends the session.
    public func stop() async {
        guard let runner else { return }
        if sessionUp {
            try? await sendAck()
            if var gone = lastPresence, let token {
                gone.state = .gone
                try? await transport.updatePresence(presenceRequest(gone), token: token)
            }
        }
        runner.cancel()
        await runner.value
        self.runner = nil
        sessionUp = false
        blobWatcher?.cancel()
        blobWatcher = nil
        await blobs?.stop()
        await publish("stopped")
    }

    // MARK: Review (SYNC-006, SYNC-010)

    /// How the user settled the review holding the outbox.
    public enum ReviewResolution: Sendable, Hashable {
        /// Upload the merge -- *Keep the merged result*, *Done* after per-object choices (which
        /// were performed as ordinary changes), dismissing the sheet, or *Send* after salvage.
        case upload
        /// Revert the document to the server's state and upload nothing: *Save my version as a
        /// copy…* or *Keep my changes on a branch*, after the fork or branch holds the local work.
        case discardLocalChanges
    }

    /// Settles the pending review; does nothing when none is pending.
    public func resolveReview(_ resolution: ReviewResolution) async throws {
        guard let review = pendingReview else { return }
        reviewEpoch += 1
        switch resolution {
        case .upload:
            try await store.setReviewHold(nil)
            pendingReview = nil
            if review.mode != .recovered {
                lastMerge = review
            }
            nudge.fire()
            await publish("review resolved")
        case .discardLocalChanges:
            let old = replica
            replica = try await store.discardLocalChanges()
            pendingReview = nil
            resetOutboxTracking()
            report(.replicaRotated(from: old, to: replica))
            report(.stateReplaced(serverSeq: 0))
            restart?.fire()
            await publish("local changes discarded")
        }
    }

    /// Tells the pusher the outbox grew.
    public func localChangesAvailable() {
        nudge.fire()
        schedulePublish("local change")
    }

    /// *Retry now*: leaves a halted state (a removed access, an unrecoverable error) and
    /// reconnects without waiting for the backoff.
    public func retry() {
        errorDetail = nil
        if readOnly == .accessRemoved {
            readOnly = nil
        }
        parked = false
        rotatedWithoutAccept = false
        snapshotFailures = 0
        wake.fire()
        nudge.fire()
    }

    /// The user signed in again: reconnect with a fresh token.
    public func signedIn() {
        needsSignIn = false
        token = nil
        parked = false
        wake.fire()
    }

    /// The state now and every change after.
    public func states() -> AsyncStream<SyncState> {
        stateBroadcast.stream(initial: state)
    }

    /// Every transition with its cause.
    public nonisolated func transitions() -> AsyncStream<SyncTransition> {
        transitionBroadcast.stream()
    }

    /// Presence, document events, catch-up progress and reports.
    public nonisolated func events() -> AsyncStream<SyncEvent> {
        eventBroadcast.stream()
    }

    // MARK: State

    private func computeState() async -> SyncState {
        if let errorDetail { return .error(errorDetail) }
        if needsSignIn { return .needsSignIn }
        if let readOnly { return .readOnly(readOnly) }
        if pendingReview?.holdsOutbox == true { return .needsReview }
        let outbox = (try? await store.outboxCount()) ?? 0
        guard sessionUp else { return attempted ? .offline(outbox) : .opening }
        if let backlog { return .uploadingBacklog(backlog.percent(acked: acked)) }
        if outbox > 0 { return .syncing(outbox) }
        let pending = (try? await store.pendingBlobCount()) ?? 0
        if pending > 0, await blobs?.isStorageFull == true { return .storageFull(pending) }
        return pending > 0 ? .uploadingBlobs(pending) : .saved
    }

    /// Recomputes and publishes the state now.
    private func publish(_ cause: String) async {
        let next = await computeState()
        lastPublish = .now
        guard next != state else { return }
        let transition = SyncTransition(from: state, to: next, cause: cause)
        logger.info("sync \(self.documentID, privacy: .public): \(transition.from.description, privacy: .public) -> \(transition.to.description, privacy: .public) (\(cause, privacy: .public))")
        state = next
        transitionBroadcast.yield(transition)
        stateBroadcast.yield(next)
    }

    /// Publishes at most every `publishInterval`: counts change with every ack and echo.
    private func schedulePublish(_ cause: String) {
        guard !publishPending else { return }
        publishPending = true
        let delay = max(.zero, options.publishInterval - (ContinuousClock.now - lastPublish))
        Task {
            try? await Task.sleep(for: delay)
            await self.flushPublish(cause)
        }
    }

    private func flushPublish(_ cause: String) async {
        publishPending = false
        await publish(cause)
    }

    /// Logs a refused ack or presence update: the next one carries the whole state again.
    private func report(refusal call: String, _ error: SyncCallError) {
        let text = "\(call) refused: \(error.description)"
        logger.notice("\(text, privacy: .public)")
    }

    private func report(_ event: SyncEvent) {
        eventBroadcast.yield(event)
    }

    // MARK: Sessions

    private func run() async {
        var attempt = 0
        await restoreHold()
        await publish("started")
        while !Task.isCancelled {
            if parked {
                await wake.wait()
                continue
            }
            let end = await session()
            let wasUp = sessionUp
            sessionUp = false
            attempted = true
            await blobs?.setOnline(false)
            if wasUp {
                report(.connection(false))
                await markSynced(options.clock())
            }
            guard !Task.isCancelled else { break }
            if wasUp || end == .rotated || end == .restarted {
                attempt = 0
            }
            if end == .signIn || end == .halted {
                // Unless `retry()` or `signedIn()` already cleared what halted the session.
                parked = needsSignIn || errorDetail != nil || readOnly != nil
            }
            await publish(end.cause)
            if end == .rotated || end == .restarted || parked {
                continue
            }
            await wake.wait(timeout: backoff(attempt))
            attempt += 1
        }
    }

    /// The delay before reconnect attempt `attempt`.
    func backoff(_ attempt: Int) -> Duration {
        let exponential = options.backoffBase * Double(1 << min(attempt, 20))
        return min(exponential, options.backoffMax) * (0.5 + 0.5 * options.random())
    }

    private func session() async -> SessionEnd {
        let welcome = Signal(latching: true)
        let reconciled = Signal(latching: true)
        let restart = Signal(latching: true)
        self.welcome = welcome
        self.reconciled = reconciled
        self.restart = restart
        snapshotInstalled = false
        // A store opened on another Mac rotated with unsent changes of the old replica: salvage
        // them onto the server's state (offline.adoc, "Replica expiry and salvage").
        if (try? await store.retiredOutbox())?.isEmpty == false {
            let old = await store.replica
            if let fresh = try? await store.beginSalvage(reason: .conflict) {
                resetOutboxTracking()
                report(.replicaRotated(from: old, to: fresh))
                report(.stateReplaced(serverSeq: 0))
            }
        }
        replica = await store.replica
        applied = await store.lastServerSeq
        ackedServerSeq = applied
        sessionBase = applied
        lastStable = 0
        confirmDue = false
        confirmMark = await store.nextSeq - 1
        nextPoll = .now
        pollDelay = options.ackInterval
        do {
            let token = try await accessToken()
            sessionToken = token
            var request = Wiretuner_Sync_V1_SubscribeRequest()
            request.documentID = documentID
            request.replica = replica
            request.afterServerSeq = applied
            if let presence = await presenceSource?.presence() {
                request.presence = presence
                lastPresence = presence
                lastPresenceAt = .now
            }
            let frames = transport.subscribe(request, token: token)
            lastFrame = .now
            return try await withThrowingTaskGroup(of: SessionEnd.self) { group in
                group.addTask { try await self.read(frames) }
                group.addTask { try await self.watchdog() }
                group.addTask {
                    await reconciled.wait()
                    return try await self.pushLoop()
                }
                group.addTask {
                    await restart.wait()
                    return .restarted
                }
                group.addTask {
                    await welcome.wait()
                    return try await self.ackLoop()
                }
                if presenceSource != nil {
                    group.addTask {
                        await welcome.wait()
                        return try await self.presenceLoop()
                    }
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch let end as SessionEnd {
            return end
        } catch let error as SyncCallError {
            return await classify(error)
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// What a refused call that ended the session means.
    private func classify(_ error: SyncCallError) async -> SessionEnd {
        do {
            switch error.reason {
            case .tokenExpired?:
                try await refreshToken(replacing: sessionToken)
            case .replicaConflict?, .replicaExpired?:
                try await rotate(error.reason == .replicaExpired ? .expired : .conflict)
            case .roleInsufficient?, .clientTooOld?:
                readOnly = error.reason == .clientTooOld ? .clientTooOld : .roleInsufficient
                return .halted
            default:
                switch error.code {
                case SyncCallError.unauthenticated:
                    try await refreshToken(replacing: sessionToken)
                case SyncCallError.permissionDenied:
                    readOnly = .accessRemoved
                    return .halted
                case SyncCallError.notFound:
                    errorDetail = "The document no longer exists."
                    return .halted
                case SyncCallError.invalidArgument:
                    // A request this Mac will make the same way however often it retries (a
                    // malformed `wt-device`, say): the error state until *Retry now*.
                    errorDetail = "The server refused this Mac's request: \(error.message)"
                    return .halted
                default:
                    break
                }
            }
        } catch let end as SessionEnd {
            return end
        } catch {
            return .failed(String(describing: error))
        }
        return .failed(error.description)
    }

    private func read(_ frames: AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error>) async throws -> SessionEnd {
        for try await frame in frames {
            try await handle(frame)
        }
        return .streamEnded
    }

    private func watchdog() async throws -> SessionEnd {
        let tick = min(options.heartbeatTimeout / 4, .seconds(1))
        repeat {
            try await Task.sleep(for: tick)
        } while ContinuousClock.now - lastFrame <= options.heartbeatTimeout
        return .heartbeat
    }

    // MARK: Frames

    private func handle(_ frame: Wiretuner_Sync_V1_ServerFrame) async throws {
        lastFrame = .now
        if case .welcome(let welcome)? = frame.frame {
            try await handleWelcome(welcome)
            return
        }
        guard sessionUp else { throw SessionEnd.violation("the first frame is not Welcome") }
        switch frame.frame {
        case .change(let change)?:
            try await apply(change)
        case .presence(let snapshot)?:
            report(.presence(snapshot))
        case .presenceUpdate(let update)?:
            report(.presenceUpdate(update))
        case .event(let event)?:
            try await handle(event)
        default:
            break
        }
    }

    private func handleWelcome(_ welcome: Wiretuner_Sync_V1_Welcome) async throws {
        if let version = Self.tableVersion(welcome.mergeTable), version != WTMergeTable.version {
            report(.mergeTableDiffers(server: version))
        }
        featureLevel = welcome.featureLevel
        apply(role: welcome.role)
        lastAccepted = welcome.lastAcceptedSeq
        advanceAcked(to: welcome.lastAcceptedSeq)
        nextSeq = acked + 1
        draining = false
        if welcome.snapshotHint {
            try await catchUp(head: welcome.headSeq)
        }
        sessionUp = true
        welcomeHead = welcome.headSeq
        self.welcome?.fire()
        report(.connection(true))
        await publish("session up")
        if applied >= welcomeHead {
            await reconcile()
        }
    }

    /// The `version` of a serialized merge table (docs/spec/crdt-model.adoc, "Schema evolution").
    static func tableVersion(_ table: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: table) as? [String: Any])?["version"] as? String
    }

    private func apply(role: Wiretuner_Account_V1_DocumentRole) {
        if featureLevel > options.featureLevel {
            readOnly = .clientTooOld
        } else if role == .viewer || role == .commenter {
            readOnly = .role
        } else if (role == .editor || role == .owner) && (readOnly == .role || readOnly == .roleInsufficient) {
            readOnly = nil
        }
    }

    private func handle(_ event: Wiretuner_Sync_V1_DocumentEvent) async throws {
        report(.document(event))
        switch event.event {
        case .reconnect?:
            throw SessionEnd.reconnect
        case .roleChanged(let changed)?:
            apply(role: changed.role)
            nudge.fire()
            await publish("role changed")
        case .accessRemoved?:
            readOnly = .accessRemoved
            await publish("access removed")
        default:
            break
        }
    }

    /// A change from the log: skipped when already applied; a gap before it is filled from
    /// `FetchChanges` first, so changes are applied in `server_seq` order.
    private func apply(_ change: Wiretuner_Sync_V1_SequencedChange) async throws {
        guard change.serverSeq > applied else { return }
        if change.serverSeq > applied + 1 {
            try await fetchTail(after: applied, until: change.serverSeq - 1)
        }
        try await deliver(change)
    }

    private func deliver(_ change: Wiretuner_Sync_V1_SequencedChange) async throws {
        try await sink.applyRemote(change.change, serverSeq: change.serverSeq)
        applied = change.serverSeq
        if !change.author.displayName.isEmpty {
            authors[change.change.replica] = change.author.displayName
        }
        if sessionUp, reconciled?.isFired == false, applied >= welcomeHead {
            await reconcile()
        }
        if change.change.replica == replica {
            // The echo of this replica's own change: its ops are already applied; it keeps the
            // applied sequence contiguous, acknowledges the change, and is the backlog's progress.
            advanceAcked(to: change.change.seq)
            schedulePublish("own change sequenced")
        }
    }

    // MARK: Catch-up (SYNC-004)

    /// Catches up to `head` after a snapshot hint: a document never seen here bootstraps from the
    /// newest snapshot; one with local state replays `FetchChanges` from its applied sequence, and
    /// falls back to the snapshot when that history is no longer available.
    private func catchUp(head: UInt64) async throws {
        if applied == 0 {
            try await bootstrap(head: head)
        } else {
            do {
                try await fetchTail(after: applied, until: head)
            } catch let error as SyncCallError where error.reason == .historyUnavailable {
                try await bootstrap(head: head)
            }
        }
        // Accepted changes a snapshot holds never echo: Welcome said they got in.
        try await store.acknowledgeAccepted(through: lastAccepted, serverSeq: applied)
    }

    private func bootstrap(head: UInt64) async throws {
        do {
            let token = try await accessToken()
            var request = Wiretuner_Sync_V1_FetchSnapshotRequest()
            request.documentID = documentID
            var frames: [Wiretuner_Doc_V1_SnapshotFrame] = []
            var progress = CatchUpProgress(phase: .snapshot, completed: 0, total: 0)
            for try await response in transport.fetchSnapshot(request, token: token) {
                lastFrame = .now
                frames.append(response.frame)
                if case .header(let header)? = response.frame.frame {
                    progress.total = header.compressedSize
                }
                if case .chunk(let chunk)? = response.frame.frame {
                    progress.completed += UInt64(chunk.count)
                }
                report(.catchUp(progress))
            }
            let schema = store.schema
            let snapshot: (state: EngineState, serverSeq: UInt64)
            do {
                snapshot = try await Task.detached(priority: .userInitiated) { [frames] in
                    try SnapshotDownload.state(frames, schema: schema)
                }.value
            } catch {
                snapshotFailures += 1
                if snapshotFailures > 1 {
                    errorDetail = "The document's snapshot could not be read: \(error)"
                    throw SessionEnd.halted
                }
                throw SessionEnd.failed("snapshot unreadable: \(error)")
            }
            snapshotFailures = 0
            if snapshot.serverSeq > applied {
                try await store.installSnapshot(snapshot.state, serverSeq: snapshot.serverSeq)
                snapshotInstalled = true
                applied = snapshot.serverSeq
                report(.stateReplaced(serverSeq: snapshot.serverSeq))
            }
        } catch let error as SyncCallError where error.reason == .historyUnavailable {
            // No snapshot yet: the whole log is still hot.
        }
        try await fetchTail(after: applied, until: head)
    }

    /// Applies `FetchChanges` from `after` through `until`, in order.
    private func fetchTail(after: UInt64, until: UInt64) async throws {
        guard until > after else { return }
        let token = try await accessToken()
        var request = Wiretuner_Sync_V1_FetchChangesRequest()
        request.documentID = documentID
        request.afterServerSeq = after
        request.untilServerSeq = until
        for try await response in transport.fetchChanges(request, token: token) {
            lastFrame = .now
            for change in response.changes where change.serverSeq > applied {
                guard change.serverSeq == applied + 1 else {
                    throw SessionEnd.violation("FetchChanges went from \(applied) to \(change.serverSeq)")
                }
                try await deliver(change)
            }
            report(.catchUp(CatchUpProgress(phase: .changes, completed: applied - after, total: until - after)))
        }
        guard applied >= until else { throw SessionEnd.violation("FetchChanges ended at \(applied) before \(until)") }
    }

    // MARK: Tokens

    private func accessToken() async throws -> String {
        if let token { return token }
        return try await fetchToken(force: false)
    }

    /// Asks for a new token after `used` was refused, unless another call already replaced it.
    private func refreshToken(replacing used: String) async throws {
        if let token, token != used { return }
        token = nil
        _ = try await fetchToken(force: true)
    }

    private func fetchToken(force: Bool) async throws -> String {
        do {
            let fresh = try await tokens.accessToken(forceRefresh: force)
            token = fresh
            return fresh
        } catch TokenFailure.signInRequired {
            needsSignIn = true
            await publish("token refresh failed")
            throw SessionEnd.signIn
        }
    }

    // MARK: Acks and presence

    private func ackLoop() async throws -> SessionEnd {
        while true {
            try await Task.sleep(for: options.ackInterval)
            try await sendAck()
        }
    }

    /// Acknowledges the applied sequence (it drives causal stability) when it moved; again when
    /// the last answer raised the stable point, so the server records that publication as this
    /// replica's horizon (D-067); and, backing off, while the stable point is below the applied
    /// seq, to learn when it rises.  A confirming ack waits until every change made before the
    /// answer arrived is accepted: the server credits the changes that reach it after the
    /// confirmation with the confirmed horizon, so an older change must not be among them.
    private func sendAck() async throws {
        let moved = applied > ackedServerSeq
        let polling = lastStable < applied && ContinuousClock.now >= nextPoll
        guard moved || confirmDue || polling, acked >= confirmMark else { return }
        let target = applied
        var request = Wiretuner_Sync_V1_AckRequest()
        request.documentID = documentID
        request.replica = replica
        request.appliedServerSeq = target
        let token = try await accessToken()
        do {
            let response = try await transport.ack(request, token: token)
            ackedServerSeq = max(ackedServerSeq, target)
            confirmDue = response.stableSeq > lastStable
            pollDelay = confirmDue || moved ? options.ackInterval : min(pollDelay * 2, options.ackPollMax)
            nextPoll = .now + pollDelay
            lastStable = max(lastStable, response.stableSeq)
            confirmMark = await store.nextSeq - 1
            report(.stable(response.stableSeq))
            await sink.advanceHorizon(to: response.stableSeq)
            if let point = CollectionPoint(response) {
                report(.collectionPoint(seq: point.seq, timeMs: point.timeMs))
            }
        } catch let error as SyncCallError where error.code == SyncCallError.unauthenticated {
            try await refreshToken(replacing: token)
        } catch let error as SyncCallError {
            report(refusal: "ack", error)
        }
    }

    private func presenceRequest(_ presence: Wiretuner_Sync_V1_PresenceUpdate) -> Wiretuner_Sync_V1_UpdatePresenceRequest {
        var request = Wiretuner_Sync_V1_UpdatePresenceRequest()
        request.documentID = documentID
        request.replica = replica
        request.presence = presence
        return request
    }

    /// Sends the caller's presence when it changed, at most 20 times a second, and at least every
    /// `presenceKeepAlive`.  A lost update costs nothing: the next carries the whole state.
    private func presenceLoop() async throws -> SessionEnd {
        while true {
            try await Task.sleep(for: options.presenceInterval)
            guard let presence = await presenceSource?.presence() else { continue }
            if presence == lastPresence, let at = lastPresenceAt, ContinuousClock.now - at < options.presenceKeepAlive {
                continue
            }
            lastPresence = presence
            lastPresenceAt = .now
            let token = try await accessToken()
            do {
                try await transport.updatePresence(presenceRequest(presence), token: token)
            } catch let error as SyncCallError where error.code == SyncCallError.unauthenticated {
                try await refreshToken(replacing: token)
            } catch let error as SyncCallError {
                report(refusal: "presence", error)
            }
        }
    }

    // MARK: Pushing (SYNC-003, SYNC-005)

    private var canPush: Bool { readOnly == nil && errorDetail == nil && pendingReview?.holdsOutbox != true }

    /// Sends the outbox for as long as the session lasts.
    private func pushLoop() async throws -> SessionEnd {
        try await withThrowingTaskGroup(of: PushOutcome.self) { group in
            var inFlight = 0
            while true {
                try Task.checkCancellation()
                if inFlight == 0 {
                    if draining {
                        // Every call of the window has answered: resend from the last acked seq.
                        draining = false
                        nextSeq = acked + 1
                    }
                    if let until = pausedUntil {
                        pausedUntil = nil
                        try await Task.sleep(until: until, clock: .continuous)
                    }
                    if canPush {
                        try await splitOversized()
                    }
                    if canPush && !options.gatewayMode {
                        let upcoming = try await upcoming()
                        if isBacklog(upcoming) {
                            try await upload(upcoming)
                            continue
                        }
                    }
                }
                if canPush && !draining {
                    let token = try await accessToken()
                    if options.gatewayMode {
                        if inFlight == 0 {
                            let batch = try await nextBatch()
                            if !batch.isEmpty {
                                group.addTask { await self.send(batch, token: token) }
                                inFlight += 1
                            }
                        }
                    } else {
                        while inFlight < options.window, let change = try await nextToSend() {
                            group.addTask { await self.send(change, token: token) }
                            inFlight += 1
                        }
                    }
                }
                if inFlight == 0 {
                    await publish("outbox idle")
                    await nudge.wait(timeout: options.idlePoll)
                    continue
                }
                let outcome = try await group.next()!
                inFlight -= 1
                try await handle(outcome)
                schedulePublish("push answered")
            }
        }
    }

    private nonisolated func send(_ change: Wiretuner_Doc_V1_Change, token: String) async -> PushOutcome {
        var request = Wiretuner_Sync_V1_PushChangeRequest()
        request.documentID = documentID
        request.change = change
        do {
            let response = try await transport.pushChange(request, token: token)
            return .accepted(seq: change.seq, serverSeq: response.serverSeq)
        } catch let error as SyncCallError {
            return .rejected(change, error, token: token)
        } catch {
            return .failed(error)
        }
    }

    private nonisolated func send(_ batch: [Wiretuner_Doc_V1_Change], token: String) async -> PushOutcome {
        var request = Wiretuner_Sync_V1_PushChangeBatchRequest()
        request.documentID = documentID
        request.changes = batch
        do {
            return .batch(batch, try await transport.pushChangeBatch(request, token: token), token: token)
        } catch {
            return .failed(error)
        }
    }

    private func handle(_ outcome: PushOutcome) async throws {
        switch outcome {
        case .accepted(let seq, let serverSeq):
            try await accepted(seq: seq, serverSeq: serverSeq)
        case .batch(let changes, let response, let token):
            for (change, serverSeq) in zip(changes, response.serverSeqs) {
                try await accepted(seq: change.seq, serverSeq: serverSeq)
            }
            // Accepted as a prefix: resume after it, handling the first refusal.
            draining = response.serverSeqs.count < changes.count
            if response.hasRejected, let rejected = changes.first(where: { $0.seq == response.rejected.seq }) {
                try await reject(rejected, SyncCallError(response.rejected), token: token)
            }
        case .rejected(let change, let error, let token):
            try await reject(change, error, token: token)
        case .failed(let error):
            throw error
        }
    }

    private func accepted(seq: UInt64, serverSeq: UInt64) async throws {
        try await store.acknowledge(seq: seq, serverSeq: serverSeq)
        advanceAcked(to: seq)
        rotatedWithoutAccept = false
    }

    /// What a refused change means (docs/spec/sync-protocol.adoc, "Rejections").
    private func reject(_ change: Wiretuner_Doc_V1_Change, _ error: SyncCallError, token: String) async throws {
        logger.notice("push of seq \(change.seq) refused: \(error.description, privacy: .public)")
        switch error.reason {
        case .seqGap?:
            draining = true
        case .tokenExpired?:
            try await refreshToken(replacing: token)
            draining = true
        case .rateLimited?:
            pausedUntil = .now + (error.retryAfter ?? .seconds(1))
            draining = true
        case .replicaConflict?, .replicaExpired?:
            try await rotate(error.reason == .replicaExpired ? .expired : .conflict)
        case .roleInsufficient?:
            readOnly = .roleInsufficient
            draining = true
            await publish("role insufficient")
        case .clientTooOld?:
            readOnly = .clientTooOld
            draining = true
            await publish("client too old")
        case .validationFailed?:
            guard noopChange(change) != change else {
                // Even the one-Noop replacement was refused: sending it again cannot help.
                errorDetail = "A change could not be sent: the server refused it (\(error.message))."
                logger.fault("replacement of change \(change.seq) refused: \(error.message, privacy: .public)")
                throw SessionEnd.halted
            }
            try await drop(change, error.message)
            draining = true
        default:
            guard error.code == SyncCallError.unauthenticated else { throw error }
            try await refreshToken(replacing: token)
            draining = true
        }
    }

    /// A change the server's validators refused: it is sent again as one `Noop`, keeping the seq
    /// and start counter (`noopChange`), and reported.  The local effects stay (see
    /// docs/spec/sync-protocol.adoc).
    private func drop(_ change: Wiretuner_Doc_V1_Change, _ message: String) async throws {
        let noop = noopChange(change)
        try await store.replaceUnsent(noop)
        sent[change.seq] = noop
        logger.fault("change \(change.seq) failed server validation: \(message, privacy: .public)")
        report(.changeDropped(seq: change.seq, message: message))
    }

    /// Replica rotation (docs/spec/offline.adoc, "Replica expiry and salvage"): with unsent
    /// changes the store starts salvage -- they are set aside, the local state is dropped, and the
    /// next session re-issues them on the server's state (`reconcile`); a second conflict without an
    /// accepted push in between is an error.
    private func rotate(_ reason: SalvageReport.Reason) async throws {
        guard !rotatedWithoutAccept else {
            errorDetail = "This document's replica is in use elsewhere, even after rotating it."
            throw SessionEnd.halted
        }
        let old = replica
        let salvaging = try await store.hasUnsentChanges()
        replica = salvaging ? try await store.beginSalvage(reason: reason) : try await store.rotateReplica()
        rotatedWithoutAccept = true
        resetOutboxTracking()
        report(.replicaRotated(from: old, to: replica))
        if salvaging {
            report(.stateReplaced(serverSeq: 0))
        }
        throw SessionEnd.rotated
    }

    /// Forgets what was sent: the replica changed.
    private func resetOutboxTracking() {
        acked = 0
        highestSent = 0
        nextSeq = 1
        sent = [:]
        queue = []
        oversized = nil
        confirmMark = 0
    }

    /// Runs once a session has caught up to the head `Welcome` named, before anything is pushed
    /// (offline.adoc, "Reconnecting with a backlog"): re-issues salvaged changes, or measures the
    /// divergence of the outbox from the remote changes since the previous head and applies the
    /// decision rules (reconcile.adoc) -- a review that holds the outbox, or a merge reported for
    /// the toast.  Then the pusher and the blob queue start.
    /// A store that cannot be read (closed, diverged) reconciles nothing; its failure surfaces
    /// through the outbox and the state like any other.
    private func reconcile() async {
        let now = options.clock()
        let epoch = reviewEpoch
        let recording = DocumentCore.Recording(limit: options.undoLevels, now: now)
        if let salvage = try? await store.applySalvage(recording: recording, limits: options.changeLimits) {
            report(.stateReplaced(serverSeq: applied))
            report(.salvaged(salvage))
            if salvage.needsReview {
                try? await store.setReviewHold(LocalStore.ReviewHold(kind: .recovered, baseSeq: applied, report: salvage))
                hold(ReviewModel(recovered: salvage))
            }
        } else {
            let held = try? await store.reviewHold()
            if let report = held?.report, held?.kind == .recovered {
                hold(ReviewModel(recovered: report))
            } else if (try? await store.outboxCount()) ?? 0 == 0 {
                try? await store.setReviewHold(nil)
                pendingReview = nil
            } else {
                let base = min(held?.baseSeq ?? sessionBase, sessionBase)
                if applied > base || held != nil {
                    await measure(since: base, now: now, epoch: epoch)
                }
            }
        }
        await markSynced(now)
        reconciled?.fire()
        nudge.fire()
        await blobs?.setOnline(true)
        await publish("reconciled")
    }

    private func measure(since base: UInt64, now: Date, epoch: Int) async {
        guard let divergence = try? await store.divergence(since: base, gap: gap(now), remoteComplete: !snapshotInstalled),
              epoch == reviewEpoch else { return }
        let decision = divergence.decision(options.reconcile())
        let review = ReviewModel(divergence, decision: decision, names: authors)
        if decision.holdsOutbox {
            try? await store.setReviewHold(LocalStore.ReviewHold(kind: .merge, baseSeq: base))
            hold(review)
        } else {
            try? await store.setReviewHold(nil)
            pendingReview = nil
            lastMerge = review
            report(.merged(review))
        }
    }

    /// Records the moment the store caught up -- unless a review holds the outbox: the gap a later
    /// measurement reads then still runs from before the offline work it asks about, so a
    /// relaunch or a reconnect does not take the pending review for a brief drop (D-070).
    private func markSynced(_ now: Date) async {
        guard pendingReview?.holdsOutbox != true else { return }
        try? await store.markSynced(at: now)
    }

    /// The time since the previous sync.
    private func gap(_ now: Date) async -> Duration {
        let last = (try? await store.lastSyncedAt()) ?? nil
        return .seconds(max(0, now.timeIntervalSince(last ?? now)))
    }

    /// A review still holding the outbox from an earlier run: the sheet can open offline.
    private func restoreHold() async {
        guard let held = try? await store.reviewHold() else { return }
        if let report = held.report, held.kind == .recovered {
            hold(ReviewModel(recovered: report))
        } else {
            await measure(since: held.baseSeq, now: options.clock(), epoch: reviewEpoch)
        }
    }

    private func hold(_ review: ReviewModel) {
        pendingReview = review
        report(.reviewNeeded(review))
    }

    /// Everything accepted through `seq`: the server accepts a replica's changes in seq order.
    private func advanceAcked(to seq: UInt64) {
        guard seq > acked else { return }
        if seq - acked < UInt64(sent.count) {
            for accepted in (acked + 1)...seq {
                sent[accepted] = nil
            }
        } else {
            sent = sent.filter { $0.key > seq }
        }
        acked = seq
        if highestSent < acked {
            highestSent = acked
            queue = []   // refilled after the new acked seq
        }
        nextSeq = max(nextSeq, acked + 1)
    }

    private func refillQueue() async throws {
        let pending = try await store.pendingUpload(rules: options.rules, fixedThrough: highestSent)
        queue = pending.filter { $0.seq > highestSent }
        if let first = queue.first, first.seq > highestSent + 1 {
            // The changes in between are acknowledged in the store already.
            advanceAcked(to: first.seq - 1)
        }
        // A change over the server's limits would be refused: the queue stops before it.  A
        // change of one op cannot be split, and goes up to be refused and replaced (`drop`).
        let limits = options.changeLimits
        oversized = nil
        if let index = queue.firstIndex(where: { $0.ops.count > 1 && !limits.admits($0) }) {
            oversized = queue[index].seq
            queue.removeSubrange(index...)
        }
    }

    /// Splits the outbox once everything sent before the oversized change is accepted and recorded
    /// so in the store (a bulk upload's changes are recorded when they echo): salvage (offline.adoc,
    /// "Replica expiry and salvage") re-issues every unacknowledged change on the server's state as
    /// changes within `changeLimits`, from a fresh replica -- the one way to renumber changes whose
    /// ids are already applied locally.
    private func splitOversized() async throws {
        guard let seq = oversized, queue.isEmpty, highestSent <= acked,
              try await store.oldestUnacknowledgedSeq() == seq else { return }
        logger.notice("change \(seq) is over the server's limits: splitting the outbox")
        let old = replica
        replica = try await store.beginSalvage(reason: .oversized)
        resetOutboxTracking()
        report(.replicaRotated(from: old, to: replica))
        report(.stateReplaced(serverSeq: 0))
        throw SessionEnd.rotated
    }

    /// The next change to send: a resend from `sent`, else the next coalesced outbox change.
    private func nextToSend() async throws -> Wiretuner_Doc_V1_Change? {
        if nextSeq <= highestSent, let change = sent[nextSeq] {
            nextSeq += 1
            return change
        }
        nextSeq = max(nextSeq, highestSent + 1)
        if queue.isEmpty {
            try await refillQueue()
        }
        guard !queue.isEmpty else { return nil }
        let change = queue.removeFirst()
        sent[change.seq] = change
        highestSent = change.seq
        nextSeq = change.seq + 1
        return change
    }

    private func nextBatch() async throws -> [Wiretuner_Doc_V1_Change] {
        var batch: [Wiretuner_Doc_V1_Change] = []
        while batch.count < options.window, let change = try await nextToSend() {
            batch.append(change)
        }
        return batch
    }

    /// Every change still to go up, resends first.
    private func upcoming() async throws -> [Wiretuner_Doc_V1_Change] {
        let resends = nextSeq <= highestSent ? (nextSeq...highestSent).compactMap { sent[$0] } : []
        if queue.isEmpty {
            try await refillQueue()
        }
        return resends + queue
    }

    private func isBacklog(_ changes: [Wiretuner_Doc_V1_Change]) -> Bool {
        guard !changes.isEmpty else { return false }
        if changes.count >= options.bulkChanges { return true }
        return changes.reduce(0) { $0 + encodedSize($1) } >= options.bulkBytes
    }

    /// Uploads a backlog through `PushChanges`; progress is read from the own echoes on the
    /// subscription, and a dropped upload resumes from the next `Welcome.last_accepted_seq`.
    private func upload(_ changes: [Wiretuner_Doc_V1_Change]) async throws {
        for change in changes {
            sent[change.seq] = change
        }
        highestSent = max(highestSent, changes[changes.count - 1].seq)
        nextSeq = highestSent + 1
        queue = []
        backlog = Backlog(changes)
        await publish("backlog upload")
        defer { backlog = nil }
        let frames = BulkFrames.pack(changes, documentID: documentID, maxBytes: options.frameBytes)
        let response: Wiretuner_Sync_V1_PushChangesResponse
        let token = try await accessToken()
        do {
            response = try await transport.pushChanges(frames, token: token)
        } catch let error as SyncCallError where error.code == SyncCallError.unauthenticated {
            try await refreshToken(replacing: token)
            nextSeq = acked + 1
            return
        }
        advanceAcked(to: response.lastAcceptedSeq)
        nextSeq = acked + 1
        if response.hasRejected, let change = sent[response.rejected.seq] {
            try await reject(change, SyncCallError(response.rejected), token: token)
        }
    }
}
