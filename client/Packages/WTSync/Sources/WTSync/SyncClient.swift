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
/// WTApp opens the store, creates the `Document` over it, creates the client with the document as
/// its sink, calls `start()`, calls `localChangesAvailable()` after each local change, observes
/// `states()`, `transitions()` and `events()`, and calls `stop()` when the window closes.
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

    // The session.
    private var sessionUp = false
    private var sessionToken = ""
    private var welcome: Signal?
    private var replica: UInt64 = 0
    private var applied: UInt64 = 0
    private var ackedServerSeq: UInt64 = 0
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

    /// A client for the document in `store`; remote changes go to `sink`, whose backend must be
    /// `store` (the store itself for a headless upload).
    public init(store: LocalStore, sink: (any RemoteChangeSink)? = nil, transport: any SyncTransport,
                tokens: any TokenProvider, presence: (any PresenceSource)? = nil, options: Options = Options()) {
        documentID = store.documentID
        self.store = store
        self.sink = sink ?? store
        self.transport = transport
        self.tokens = tokens
        presenceSource = presence
        self.options = options
    }

    // MARK: Public API

    /// Starts running sessions (idempotent).
    public func start() {
        guard runner == nil else { return }
        runner = Task { await run() }
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
        await publish("stopped")
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
        let outbox = (try? await store.outboxCount()) ?? 0
        guard sessionUp else { return attempted ? .offline(outbox) : .opening }
        if let backlog { return .uploadingBacklog(backlog.percent(acked: acked)) }
        if outbox > 0 { return .syncing(outbox) }
        let blobs = (try? await store.pendingBlobCount()) ?? 0
        return blobs > 0 ? .uploadingBlobs(blobs) : .saved
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
            guard !Task.isCancelled else { break }
            if wasUp || end == .rotated {
                attempt = 0
            }
            if end == .signIn || end == .halted {
                // Unless `retry()` or `signedIn()` already cleared what halted the session.
                parked = needsSignIn || errorDetail != nil || readOnly != nil
            }
            await publish(end.cause)
            if end == .rotated || parked {
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
        self.welcome = welcome
        replica = await store.replica
        applied = await store.lastServerSeq
        ackedServerSeq = applied
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
                    await welcome.wait()
                    return try await self.pushLoop()
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
                try await rotate()
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
        self.welcome?.fire()
        nudge.fire()
        await publish("session up")
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

    /// Acknowledges the applied sequence when it moved (it drives causal stability).
    private func sendAck() async throws {
        guard applied > ackedServerSeq else { return }
        let target = applied
        var request = Wiretuner_Sync_V1_AckRequest()
        request.documentID = documentID
        request.replica = replica
        request.appliedServerSeq = target
        let token = try await accessToken()
        do {
            let response = try await transport.ack(request, token: token)
            ackedServerSeq = max(ackedServerSeq, target)
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

    private var canPush: Bool { readOnly == nil && errorDetail == nil }

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
            try await rotate()
        case .roleInsufficient?:
            readOnly = .roleInsufficient
            draining = true
            await publish("role insufficient")
        case .clientTooOld?:
            readOnly = .clientTooOld
            draining = true
            await publish("client too old")
        case .validationFailed?:
            try await drop(change, error.message)
            draining = true
        default:
            guard error.code == SyncCallError.unauthenticated else { throw error }
            try await refreshToken(replacing: token)
            draining = true
        }
    }

    /// A change the server's validators refused: it is sent again as `Noop`s, keeping the seq and
    /// counter range, and reported.  The local effects stay (see docs/spec/sync-protocol.adoc).
    private func drop(_ change: Wiretuner_Doc_V1_Change, _ message: String) async throws {
        let noop = noopChange(change)
        try await store.replaceUnsent(noop)
        sent[change.seq] = noop
        logger.fault("change \(change.seq) failed server validation: \(message, privacy: .public)")
        report(.changeDropped(seq: change.seq, message: message))
    }

    /// Replica rotation (docs/spec/offline.adoc, "Replica expiry and salvage"); a second conflict
    /// without an accepted push in between is an error.
    private func rotate() async throws {
        guard !rotatedWithoutAccept else {
            errorDetail = "This document's replica is in use elsewhere, even after rotating it."
            throw SessionEnd.halted
        }
        let old = replica
        replica = try await store.rotateReplica()
        rotatedWithoutAccept = true
        acked = 0
        highestSent = 0
        nextSeq = 1
        sent = [:]
        queue = []
        report(.replicaRotated(from: old, to: replica))
        throw SessionEnd.rotated
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
