import Foundation
import WTProto
import WTSync

/// Several API nodes in front of one `SimServer` (docs/spec/server.adoc, "Deployment": stateless
/// nodes behind a load balancer, one Postgres, one Valkey fan-out bus), for the collaboration
/// scenarios that run "against two server nodes" (COLLAB-003).
///
/// * *Routing*: the load balancer gives every call -- each push, ack and download, and each new
///   subscription -- the next live node in turn, so one client's pipelined pushes land on
///   different nodes; a subscription stays on the node it opened on.
/// * *Fan-out*: a live change reaches the subscriptions on the node that accepted it at once and
///   those on the other nodes after `fanOutDelay` of simulated time (the hop through the bus).
/// * *A node restart* ends that node's subscriptions (`UNAVAILABLE`) and takes it out of the
///   rotation for a while; the clients resubscribe through the live nodes.  With no live node
///   every call answers `UNAVAILABLE`.
///
/// The log, roles, replicas and faults of the shared state stay the `SimServer`'s.
public actor SimCluster {
    /// What the nodes did.
    public struct Stats: Sendable, Hashable {
        /// Calls routed to each node (subscriptions included).
        public var calls: [Int]
        /// Live changes that crossed from the accepting node to another node's subscription.
        public var relayed = 0
        public var restarts = 0
        /// Calls refused because no node was live.
        public var refused = 0
    }

    struct ChangeKey: Hashable {
        let replica: UInt64
        let seq: UInt64
    }

    public nonisolated let server: SimServer
    public nonisolated let clock: SimClock
    public nonisolated let nodeCount: Int
    /// The bus hop between nodes (simulated time).
    public nonisolated let fanOutDelay: Duration
    public private(set) var stats: Stats
    private var downUntil: [ContinuousClock.Instant?]
    private var streams: [UUID: (node: Int, continuation: AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error>.Continuation)] = [:]
    private var acceptedOn: [ChangeKey: Int] = [:]
    private var turn = 0

    public init(server: SimServer, clock: SimClock, nodes: Int = 2, fanOutDelay: Duration = .milliseconds(60)) {
        precondition(nodes > 0)
        self.server = server
        self.clock = clock
        nodeCount = nodes
        self.fanOutDelay = fanOutDelay
        stats = Stats(calls: Array(repeating: 0, count: nodes))
        downUntil = Array(repeating: nil, count: nodes)
    }

    /// Whether `node` is in the rotation.
    public func isUp(_ node: Int) -> Bool {
        downUntil[node].map { ContinuousClock.now >= $0 } ?? true
    }

    /// Subscriptions open on `node`.
    public func subscriptions(on node: Int) -> Int {
        streams.values.filter { $0.node == node }.count
    }

    /// Restarts `node`: its subscriptions fail and it takes no calls for `downFor` (simulated).
    public func restart(node: Int, downFor: Duration) {
        stats.restarts += 1
        downUntil[node] = .now + clock.real(downFor)
        for (id, stream) in streams where stream.node == node {
            stream.continuation.finish(throwing: SyncCallError(code: SyncCallError.unavailable, message: "node \(node) restarting"))
            streams[id] = nil
        }
    }

    /// The node the load balancer gives the next call, or `UNAVAILABLE`.
    func route() throws -> Int {
        for step in 0..<nodeCount {
            let node = (turn + step) % nodeCount
            if isUp(node) {
                turn = node + 1
                stats.calls[node] += 1
                return node
            }
        }
        stats.refused += 1
        throw SyncCallError(code: SyncCallError.unavailable, message: "no live node")
    }

    /// Routes a push of `changes` and records the node that takes them (before the call, since
    /// the server fans a change out as it accepts it).
    func routePush(_ changes: [Wiretuner_Doc_V1_Change]) throws -> Int {
        let node = try route()
        for change in changes {
            acceptedOn[ChangeKey(replica: change.replica, seq: change.seq)] = node
        }
        return node
    }

    /// How long a subscription on `node` holds `frame` back: the bus hop for a live change another
    /// node accepted, else nothing.
    func relayDelay(_ frame: Wiretuner_Sync_V1_ServerFrame, to node: Int) -> Duration? {
        guard case .change(let entry)? = frame.frame,
              let origin = acceptedOn[ChangeKey(replica: entry.change.replica, seq: entry.change.seq)], origin != node else { return nil }
        stats.relayed += 1
        return clock.real(fanOutDelay)
    }

    func register(_ id: UUID, node: Int, _ continuation: AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error>.Continuation) {
        streams[id] = (node, continuation)
    }

    func unregister(_ id: UUID) {
        streams[id] = nil
    }
}

/// `SyncTransport` onto a `SimCluster`, as one device: each call through the load balancer.
public struct SimClusterTransport: SyncTransport {
    public let cluster: SimCluster
    public let device: String

    public init(cluster: SimCluster, device: String) {
        self.cluster = cluster
        self.device = device
    }

    var upstream: SimServerTransport { SimServerTransport(server: cluster.server, device: device) }

    public func subscribe(_ request: Wiretuner_Sync_V1_SubscribeRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [cluster, upstream] in
                let node: Int
                do { node = try await cluster.route() } catch {
                    continuation.finish(throwing: error)
                    return
                }
                let id = UUID()
                await cluster.register(id, node: node, continuation)
                do {
                    for try await frame in upstream.subscribe(request, token: token) {
                        if let delay = await cluster.relayDelay(frame, to: node) {
                            try await Task.sleep(for: delay)
                        }
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await cluster.unregister(id)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func pushChange(_ request: Wiretuner_Sync_V1_PushChangeRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeResponse {
        _ = try await cluster.routePush([request.change])
        return try await upstream.pushChange(request, token: token)
    }

    public func pushChangeBatch(_ request: Wiretuner_Sync_V1_PushChangeBatchRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeBatchResponse {
        _ = try await cluster.routePush(request.changes)
        return try await upstream.pushChangeBatch(request, token: token)
    }

    public func pushChanges(_ frames: [Wiretuner_Sync_V1_PushChangesRequest], token: String) async throws -> Wiretuner_Sync_V1_PushChangesResponse {
        _ = try await cluster.routePush(frames.flatMap(\.changes))
        return try await upstream.pushChanges(frames, token: token)
    }

    public func updatePresence(_ request: Wiretuner_Sync_V1_UpdatePresenceRequest, token: String) async throws {
        _ = try await cluster.route()
        try await upstream.updatePresence(request, token: token)
    }

    public func ack(_ request: Wiretuner_Sync_V1_AckRequest, token: String) async throws -> Wiretuner_Sync_V1_AckResponse {
        _ = try await cluster.route()
        return try await upstream.ack(request, token: token)
    }

    public func fetchChanges(_ request: Wiretuner_Sync_V1_FetchChangesRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchChangesResponse, any Error> {
        relay { $0.fetchChanges(request, token: token) }
    }

    public func fetchSnapshot(_ request: Wiretuner_Sync_V1_FetchSnapshotRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchSnapshotResponse, any Error> {
        relay { $0.fetchSnapshot(request, token: token) }
    }

    /// A download through the next live node.
    func relay<Element: Sendable>(_ open: @escaping @Sendable (SimServerTransport) -> AsyncThrowingStream<Element, any Error>)
        -> AsyncThrowingStream<Element, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [cluster, upstream] in
                do {
                    _ = try await cluster.route()
                    for try await element in open(upstream) {
                        continuation.yield(element)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension SimulationBackend {
    /// `server` behind `cluster`'s nodes: every client's calls go through the load balancer.
    public static func cluster(_ cluster: SimCluster) -> SimulationBackend {
        let local = inProcess(cluster.server)
        return SimulationBackend(name: "\(cluster.nodeCount)-node", server: cluster.server,
                                 upstream: { _, device in SimClusterTransport(cluster: cluster, device: device) },
                                 tokens: local.tokens, createDocument: local.createDocument, setRole: local.setRole)
    }
}
