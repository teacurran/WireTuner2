import Foundation
import Synchronization
import WTProto
import WTSync

/// How one client's network behaves (docs/spec/testing.adoc, "Multi-client simulation").  Every
/// duration is simulated time; probabilities are 0...1.
public struct LinkConditions: Sendable, Hashable {
    /// One-way latency of every call, response and stream frame.
    public var latency: Duration
    /// Up to this much more, drawn per call and per frame.
    public var jitter: Duration
    /// The chance a pipelined `PushChange` is held back by up to `reorderWindow`, so later pushes
    /// overtake it (the load balancer reordering of sync-protocol.adoc).
    public var reorder: Double
    public var reorderWindow: Duration
    /// The chance a unary call is lost on the way (it never reaches the server) or on the way back
    /// (the server acted, the client sees `UNAVAILABLE`).
    public var requestLoss: Double
    public var responseLoss: Double
    /// The chance, after each subscription frame, that the connection drops: the stream fails
    /// mid-window and every call in flight loses its answer.
    public var streamDrop: Double

    public init(latency: Duration = .zero, jitter: Duration = .zero, reorder: Double = 0, reorderWindow: Duration = .zero,
                requestLoss: Double = 0, responseLoss: Double = 0, streamDrop: Double = 0) {
        self.latency = latency
        self.jitter = jitter
        self.reorder = reorder
        self.reorderWindow = reorderWindow
        self.requestLoss = requestLoss
        self.responseLoss = responseLoss
        self.streamDrop = streamDrop
    }

    /// No latency, no loss.
    public static let perfect = LinkConditions()
}

/// What a link did, for assertions and the failure report.
public struct LinkStats: Sendable, Hashable {
    public var calls = 0
    public var streams = 0
    public var frames = 0
    public var reordered = 0
    public var lostRequests = 0
    public var lostResponses = 0
    public var droppedConnections = 0
    public var refused = 0
}

/// The calls a link tells apart when it draws a fault.
public enum CallKind: UInt64, Sendable, CaseIterable {
    case subscribe = 1, push, batch, bulk, presence, ack, fetchChanges, fetchSnapshot
}

/// One client's network: its conditions, whether it is cut off, and the connection generation
/// that a drop or a partition moves on, failing the subscription and every call still in flight.
public final class NetworkLink: Sendable {
    public let name: String
    public let seed: UInt64
    public let clock: SimClock

    struct Plan {
        var requestDelay: Duration
        var responseDelay: Duration
        var loseRequest: Bool
        var loseResponse: Bool
    }

    private struct State {
        var conditions: LinkConditions
        var partitioned = false
        var generation: UInt64 = 0
        var streams: [UUID: @Sendable (any Error) -> Void] = [:]
        var attempts: [[UInt64]: UInt64] = [:]
        var ordinals: [CallKind: UInt64] = [:]
        var stats = LinkStats()
    }

    private let state: Mutex<State>
    private let events: Mutex<[@Sendable (String) -> Void]>

    public init(name: String, seed: UInt64, clock: SimClock, conditions: LinkConditions = .perfect) {
        self.name = name
        self.seed = seed
        self.clock = clock
        state = Mutex(State(conditions: conditions))
        events = Mutex([])
    }

    /// Calls `observer` with a line for every fault the link applies.
    public func observe(_ observer: @escaping @Sendable (String) -> Void) {
        events.withLock { $0.append(observer) }
    }

    private func note(_ line: String) {
        for observer in events.withLock({ $0 }) {
            observer("\(name): \(line)")
        }
    }

    public var conditions: LinkConditions {
        get { state.withLock { $0.conditions } }
        set { state.withLock { $0.conditions = newValue } }
    }

    public var stats: LinkStats { state.withLock { $0.stats } }

    public var isPartitioned: Bool { state.withLock { $0.partitioned } }

    /// Cuts the link: the connection drops and every call fails at once until `heal()`.
    public func partition() {
        state.withLock { $0.partitioned = true }
        dropConnection("partitioned")
    }

    public func heal() {
        state.withLock { $0.partitioned = false }
        note("healed")
    }

    /// The connection drops: the subscription and catch-up streams fail and calls in flight lose
    /// their answers.  The next call opens a new connection.
    public func dropConnection(_ reason: String = "connection dropped") {
        let failing = state.withLock { state -> [@Sendable (any Error) -> Void] in
            state.generation += 1
            state.stats.droppedConnections += 1
            defer { state.streams = [:] }
            return Array(state.streams.values)
        }
        note(reason)
        for fail in failing {
            fail(SyncCallError(code: SyncCallError.unavailable, message: "\(name): \(reason)"))
        }
    }

    // MARK: Plans

    /// Starts a call keyed by `keys`: the generation it runs on and its fate.
    func begin(_ kind: CallKind, _ keys: [UInt64]) throws -> (generation: UInt64, plan: Plan) {
        let (generation, conditions, attempt, refused) = state.withLock { state -> (UInt64, LinkConditions, UInt64, Bool) in
            state.stats.calls += 1
            if state.partitioned {
                state.stats.refused += 1
                return (state.generation, state.conditions, 0, true)
            }
            let key = [kind.rawValue] + keys
            let attempt = state.attempts[key, default: 0]
            state.attempts[key] = attempt + 1
            return (state.generation, state.conditions, attempt, false)
        }
        if refused {
            throw SyncCallError(code: SyncCallError.unavailable, message: "\(name): no route to the server")
        }
        let key = [kind.rawValue] + keys + [attempt]
        func unit(_ salt: UInt64) -> Double { SimRandom.unit(seed, SimRandom.mix(salt, key)) }
        var request = conditions.latency + conditions.jitter * unit(1)
        if kind == .push && conditions.reorder > 0 && unit(2) < conditions.reorder {
            request += conditions.reorderWindow * unit(3)
            state.withLock { $0.stats.reordered += 1 }
        }
        let plan = Plan(requestDelay: request, responseDelay: conditions.latency + conditions.jitter * unit(4),
                        loseRequest: unit(5) < conditions.requestLoss, loseResponse: unit(6) < conditions.responseLoss)
        return (generation, plan)
    }

    /// Throws `UNAVAILABLE` when the connection a call started on has dropped, or when `lost`.
    func check(_ generation: UInt64, lost: Bool = false, response: Bool = false) throws {
        let current = state.withLock { $0.generation }
        if current != generation {
            throw SyncCallError(code: SyncCallError.unavailable, message: "\(name): connection dropped")
        }
        if lost {
            state.withLock {
                if response { $0.stats.lostResponses += 1 } else { $0.stats.lostRequests += 1 }
            }
            note(response ? "answer lost" : "request lost")
            throw SyncCallError(code: SyncCallError.unavailable, message: "\(name): \(response ? "response" : "request") lost")
        }
    }

    /// Registers a stream the next drop fails; nil when the link is cut.
    func register(_ fail: @escaping @Sendable (any Error) -> Void) -> (id: UUID, generation: UInt64)? {
        state.withLock { state in
            state.stats.streams += 1
            guard !state.partitioned else {
                state.stats.refused += 1
                return nil
            }
            let id = UUID()
            state.streams[id] = fail
            return (id, state.generation)
        }
    }

    func unregister(_ id: UUID) {
        _ = state.withLock { $0.streams.removeValue(forKey: id) }
    }

    func nextOrdinal(_ kind: CallKind) -> UInt64 {
        state.withLock { state in
            let ordinal = state.ordinals[kind, default: 0]
            state.ordinals[kind] = ordinal + 1
            return ordinal
        }
    }

    /// The transit time of frame `index` of stream `ordinal`, and whether the connection drops
    /// after it.
    func frame(_ kind: CallKind, ordinal: UInt64, index: UInt64) -> (transit: Duration, drop: Bool) {
        let conditions = state.withLock { state -> LinkConditions in
            state.stats.frames += 1
            return state.conditions
        }
        let key = [kind.rawValue, ordinal, index]
        let transit = conditions.latency + conditions.jitter * SimRandom.unit(seed, SimRandom.mix(7, key))
        let drop = kind == .subscribe && conditions.streamDrop > 0 && SimRandom.unit(seed, SimRandom.mix(8, key)) < conditions.streamDrop
        return (transit, drop)
    }
}

/// The network proxy in front of a client (docs/spec/testing.adoc, "Multi-client simulation"): a
/// `SyncTransport` that forwards every call to `upstream` -- the in-process server's wire, or
/// `GRPCSyncTransport` to the compose server -- through its `NetworkLink`, applying latency,
/// reordering of pipelined pushes, loss, dropped connections and partitions.  It sits at the call
/// level rather than on TCP: gRPC multiplexes the calls over one HTTP/2 connection, so a byte-level
/// proxy could delay or cut the connection but not reorder two pushes or lose one answer.
public struct ProxyTransport: SyncTransport {
    public let link: NetworkLink
    public let upstream: any SyncTransport

    public init(link: NetworkLink, upstream: any SyncTransport) {
        self.link = link
        self.upstream = upstream
    }

    private func unary<T: Sendable>(_ kind: CallKind, _ keys: [UInt64], _ call: @Sendable () async throws -> T) async throws -> T {
        let (generation, plan) = try link.begin(kind, keys)
        try await link.clock.sleep(plan.requestDelay)
        try link.check(generation, lost: plan.loseRequest)
        let result: Result<T, any Error>
        do {
            result = .success(try await call())
        } catch {
            result = .failure(error)
        }
        try await link.clock.sleep(plan.responseDelay)
        try link.check(generation, lost: plan.loseResponse, response: true)
        return try result.get()
    }

    private func stream<Element: Sendable>(_ kind: CallKind, _ open: @escaping @Sendable () -> AsyncThrowingStream<Element, any Error>)
        -> AsyncThrowingStream<Element, any Error> {
        let link = self.link
        return AsyncThrowingStream { continuation in
            guard let registration = link.register({ continuation.finish(throwing: $0) }) else {
                continuation.finish(throwing: SyncCallError(code: SyncCallError.unavailable, message: "\(link.name): no route to the server"))
                return
            }
            let ordinal = link.nextOrdinal(kind)
            let task = Task {
                defer { link.unregister(registration.id) }
                do {
                    let opening = link.frame(kind, ordinal: ordinal, index: .max)
                    try await link.clock.sleep(opening.transit)
                    try link.check(registration.generation)
                    var deliverAt = ContinuousClock.now
                    var index: UInt64 = 0
                    for try await element in open() {
                        let (transit, drop) = link.frame(kind, ordinal: ordinal, index: index)
                        deliverAt = max(deliverAt, .now + link.clock.real(transit))
                        try await Task.sleep(until: deliverAt, clock: .continuous)
                        try link.check(registration.generation)
                        continuation.yield(element)
                        if drop {
                            link.dropConnection("connection dropped after frame \(index) of subscription \(ordinal)")
                            return
                        }
                        index += 1
                    }
                    try Task.checkCancellation()
                    try link.check(registration.generation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func subscribe(_ request: Wiretuner_Sync_V1_SubscribeRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error> {
        stream(.subscribe) { [upstream] in upstream.subscribe(request, token: token) }
    }

    public func pushChange(_ request: Wiretuner_Sync_V1_PushChangeRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeResponse {
        try await unary(.push, [request.change.replica, request.change.seq]) { [upstream] in
            try await upstream.pushChange(request, token: token)
        }
    }

    public func pushChangeBatch(_ request: Wiretuner_Sync_V1_PushChangeBatchRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeBatchResponse {
        let first = request.changes.first
        return try await unary(.batch, [first?.replica ?? 0, first?.seq ?? 0, UInt64(request.changes.count)]) { [upstream] in
            try await upstream.pushChangeBatch(request, token: token)
        }
    }

    public func pushChanges(_ frames: [Wiretuner_Sync_V1_PushChangesRequest], token: String) async throws -> Wiretuner_Sync_V1_PushChangesResponse {
        let first = frames.first?.changes.first
        return try await unary(.bulk, [first?.replica ?? 0, first?.seq ?? 0]) { [upstream] in
            try await upstream.pushChanges(frames, token: token)
        }
    }

    public func updatePresence(_ request: Wiretuner_Sync_V1_UpdatePresenceRequest, token: String) async throws {
        try await unary(.presence, [link.nextOrdinal(.presence)]) { [upstream] in
            try await upstream.updatePresence(request, token: token)
        }
    }

    public func ack(_ request: Wiretuner_Sync_V1_AckRequest, token: String) async throws -> Wiretuner_Sync_V1_AckResponse {
        try await unary(.ack, [request.replica, request.appliedServerSeq]) { [upstream] in
            try await upstream.ack(request, token: token)
        }
    }

    public func fetchChanges(_ request: Wiretuner_Sync_V1_FetchChangesRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchChangesResponse, any Error> {
        stream(.fetchChanges) { [upstream] in upstream.fetchChanges(request, token: token) }
    }

    public func fetchSnapshot(_ request: Wiretuner_Sync_V1_FetchSnapshotRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchSnapshotResponse, any Error> {
        stream(.fetchSnapshot) { [upstream] in upstream.fetchSnapshot(request, token: token) }
    }
}
