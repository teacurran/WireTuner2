import Foundation
import Synchronization
import WTCRDT
import WTModel
import WTProto
import WTSync

/// Where the simulated clients' calls go: the in-process `SimServer` (the default, and the only
/// backend whose log the checks can read), or a real server -- the compose stack -- reached
/// through `GRPCSyncTransport`, which a test supplies with its own document and token plumbing.
public struct SimulationBackend: Sendable {
    public var name: String
    /// The in-process server, when there is one: its log is checked too.
    public var server: SimServer?
    /// The transport behind a client's network proxy, for one person's device.
    public var upstream: @Sendable (SimUser, String) async throws -> any SyncTransport
    /// Token source for one person (its refreshes fail while `link` is cut).
    public var tokens: @Sendable (SimUser, NetworkLink, Duration) async throws -> any TokenProvider
    /// Creates the document the clients share, owned by the person given.
    public var createDocument: @Sendable (SimUser) async throws -> String
    /// Gives a person a role on a document.
    public var setRole: @Sendable (Wiretuner_Account_V1_DocumentRole, SimUser, String) async throws -> Void

    public init(name: String, server: SimServer? = nil,
                upstream: @escaping @Sendable (SimUser, String) async throws -> any SyncTransport,
                tokens: @escaping @Sendable (SimUser, NetworkLink, Duration) async throws -> any TokenProvider,
                createDocument: @escaping @Sendable (SimUser) async throws -> String,
                setRole: @escaping @Sendable (Wiretuner_Account_V1_DocumentRole, SimUser, String) async throws -> Void) {
        self.name = name
        self.server = server
        self.upstream = upstream
        self.tokens = tokens
        self.createDocument = createDocument
        self.setRole = setRole
    }

    /// The in-process server.
    public static func inProcess(_ server: SimServer) -> SimulationBackend {
        let documents = Locked(0)
        return SimulationBackend(
            name: "in-process", server: server,
            upstream: { _, device in SimServerTransport(server: server, device: device) },
            tokens: { user, link, lifetime in
                await server.add(user)
                return SimTokens(server: server, account: user.id, lifetime: lifetime, link: link)
            },
            createDocument: { owner in
                await server.add(owner)
                let id = "doc-\(documents.withLock { value in value += 1; return value })"
                await server.createDocument(id, owner: owner.id)
                return id
            },
            setRole: { role, user, document in
                await server.add(user)
                await server.setRole(role, for: user.id, on: document)
            })
    }
}

/// The multi-client simulator (TEST-001, docs/spec/testing.adoc "Multi-client simulation"): N
/// clients -- each a `LocalStore`, a WTModel `Document` and a real `SyncClient` -- behind their own
/// network proxies, against the in-process `SimServer` or the compose server, on one simulated
/// clock.  A scenario adds clients, edits through them, scripts faults (latency, loss, reordered
/// pipelined pushes, dropped streams, partitions, days offline with skewed clocks, server, Valkey
/// and Postgres failures, role changes, expiring tokens), then `settle()`s and
/// `expectConverged()`: the invariants every run must keep, whatever the faults.
///
/// A failing check throws `Simulation.Failure` naming the scenario and seed, the command that
/// replays it (`WT_SIM_SEED`), each client's state, the nodes whose hashes differ, and the end
/// of the trace; the whole trace goes to `$WT_SIM_REPORTS` (default
/// `$TMPDIR/WTSimulation`)`/<scenario>-seed<seed>.log`.
@MainActor
public final class Simulation {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String

        public init(description: String) {
            self.description = description
        }
    }

    public let name: String
    public let seed: UInt64
    public let clock: SimClock
    public let backend: SimulationBackend
    public let log: SimulationLog
    /// The script's generator: what to edit, when faults start and stop.
    public var random: SimRandom
    public let owner: SimUser
    /// The document every client opens.
    public let documentID: String
    public private(set) var clients: [SimClient] = []
    /// Where the stores live (removed by `shutdown`).
    public let directory: URL
    private let replicaIDs: Locked<SimRandom>
    private var closed = false
    private var granted: Set<String> = []

    /// The in-process server, if the backend is one.
    public var server: SimServer? { backend.server }

    /// A simulation named `name` (the scenario) from `seed`; `scale` real seconds per simulated
    /// second.  `backend` builds the backend on the simulation's clock; the default is a fresh
    /// in-process server.
    public init(name: String, seed: UInt64, scale: Double = 0.01, serverOptions: SimServer.Options = SimServer.Options(),
                owner: SimUser = SimUser(id: "owner", name: "Olu"),
                backend: ((SimClock) async throws -> SimulationBackend)? = nil) async throws {
        self.name = name
        self.seed = seed
        self.owner = owner
        clock = SimClock(scale: scale)
        log = SimulationLog(clock: clock)
        random = SimRandom(seed: seed)
        replicaIDs = Locked(SimRandom(seed: SimRandom.mix(seed, 0x5EED)))
        let serverClock = clock
        if let backend {
            self.backend = try await backend(clock)
        } else {
            self.backend = .inProcess(SimServer(clock: serverClock, options: serverOptions))
        }
        directory = FileManager.default.temporaryDirectory.appending(path: "WTSimulation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        documentID = try await self.backend.createDocument(owner)
        log.record("simulation \(name), seed \(seed), \(self.backend.name) backend, document \(documentID)")
    }

    /// The seed to run: `WT_SIM_SEED` when set (replaying a failure), else `fallback`.
    public nonisolated static func seed(_ fallback: UInt64, environment: [String: String] = ProcessInfo.processInfo.environment) -> UInt64 {
        environment["WT_SIM_SEED"].flatMap { UInt64($0) } ?? fallback
    }

    // MARK: Clients

    /// Gives `user` `role` on the document (and on `document` when given).
    public func grant(_ role: Wiretuner_Account_V1_DocumentRole, to user: SimUser, on document: String? = nil) async throws {
        try await backend.setRole(role, user, document ?? documentID)
        if document == nil { granted.insert(user.id) }
        log.record("\(user.name) is \(role) on \(document ?? documentID)")
    }

    /// Adds a client and starts its sync session.
    ///
    /// - Parameters:
    ///   - user: who is signed in (default: a new editor named after the client).
    ///   - device: its `wt-device`; `hardware` its Mac's platform UUID (both default to the name).
    ///   - store: an existing store file to open (a copied one), else a new one.
    ///   - document: the document to open (default: the simulation's).
    ///   - skew: how far this Mac's clock is off.
    ///   - tokenLifetime: how long each bearer token lives (simulated).
    ///   - configure: adjusts the sync client's options.
    @discardableResult
    public func addClient(_ name: String, user: SimUser? = nil, device: String? = nil, hardware: String? = nil,
                          store: URL? = nil, document: String? = nil, gateway: Bool = false,
                          conditions: LinkConditions = .perfect, skew: Duration = .zero, tokenLifetime: Duration = .seconds(3600),
                          keepsMergedResult: Bool = true, start: Bool = true, configure: ((inout SyncClient.Options) -> Void)? = nil) async throws -> SimClient {
        let user = user ?? SimUser(id: "u-\(name)", name: name)
        let documentID = document ?? self.documentID
        if user.id != owner.id, document == nil, !granted.contains(user.id) {
            try await grant(.editor, to: user)
        }
        let device = device ?? "device-\(name)"
        let link = NetworkLink(name: name, seed: SimRandom.mix(seed, UInt64(clients.count + 1)), clock: clock, conditions: conditions)
        let log = self.log
        link.observe { log.record($0) }
        let clientClock = clock.skewed(by: skew)
        let replicaIDs = self.replicaIDs
        let url = store ?? directory.appending(components: name, "store.sqlite")
        let options = LocalStore.Options(hardwareUUID: { hardware ?? "MAC-\(name)" },
                                         makeReplicaID: { replicaIDs.withLock { $0.next() >> 1 } })
        let localStore = try await LocalStore.open(documentID: documentID, at: url, options: options)
        let facade = await Document(backend: localStore, clock: clientClock)
        let tokens = try await backend.tokens(user, link, tokenLifetime)
        let transport = ProxyTransport(link: link, upstream: try await backend.upstream(user, device))
        var syncOptions = Self.options(gateway: gateway, clock: clientClock)
        configure?(&syncOptions)
        let presence = LocalPresence()
        let syncClient = SyncClient(store: localStore, sink: facade, transport: transport, tokens: tokens, presence: presence, options: syncOptions)
        let client = SimClient(name: name, user: user, device: device, documentID: documentID, link: link, store: localStore,
                               document: facade, client: syncClient, tokens: tokens, presence: presence, clock: clientClock, log: log,
                               keepsMergedResult: keepsMergedResult)
        clients.append(client)
        log.record("\(name) opens \(documentID) as replica \(await localStore.replica) (\(gateway ? "gateway" : "native"), skew \(skew))"
                   + (localStore.report.rotatedFrom.map { ", rotated from \($0)" } ?? ""))
        if start {
            await client.start()
        }
        return client
    }

    /// Sync options for simulated time: the client's timers short, its clock the simulated one.
    public nonisolated static func options(gateway: Bool, clock: @escaping @Sendable () -> Date) -> SyncClient.Options {
        var options = SyncClient.Options()
        options.gatewayMode = gateway
        options.ackInterval = .milliseconds(40)
        options.presenceInterval = .milliseconds(20)
        options.presenceKeepAlive = .milliseconds(500)
        options.heartbeatTimeout = .seconds(3)
        options.backoffBase = .milliseconds(5)
        options.backoffMax = .milliseconds(60)
        options.idlePoll = .milliseconds(30)
        options.publishInterval = .milliseconds(5)
        options.random = { 0.5 }
        options.clock = clock
        return options
    }

    /// Copies `client`'s store as it is on disk this moment (database, WAL, shared memory): what a
    /// backup restored on another Mac, or a cloned disk, starts from.
    public func copyStore(of client: SimClient, as name: String) throws -> URL {
        let source = directory.appending(components: client.name, "store.sqlite")
        let target = directory.appending(components: name, "store.sqlite")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.copyItem(at: from, to: URL(fileURLWithPath: target.path + suffix))
            }
        }
        log.record("copied \(client.name)'s store as \(name)")
        return target
    }

    // MARK: Running

    /// Calls `step` every `interval` of simulated time until `duration` has passed; the step's
    /// index counts from 0.
    public func run(for duration: Duration, every interval: Duration, _ step: (Int) async throws -> Void) async throws {
        let end = clock.elapsed + duration
        var index = 0
        while clock.elapsed < end {
            try await step(index)
            index += 1
            try await clock.sleep(interval)
        }
    }

    /// Calls `step` `count` times, `interval` of simulated time apart (a script whose faults fall
    /// on given steps, however long each step's edits take).
    public func steps(_ count: Int, every interval: Duration, _ step: (Int) async throws -> Void) async throws {
        for index in 0..<count {
            try await step(index)
            try await clock.sleep(interval)
        }
    }

    /// Moves simulated time on by `duration` at once.
    public func advance(by duration: Duration) {
        clock.advance(by: duration)
        log.record("clock advanced by \(duration)")
    }

    /// Restarts the server node (in-process: `SimServer.restart`).  An abrupt restart drops every
    /// client's connection with the calls in flight; a drain (`graceful`) lets them finish.
    public func restartServer(downFor: Duration, graceful: Bool = false) async {
        log.record("server node restart\(graceful ? " (drain)" : ""), down for \(downFor)")
        await server?.restart(downFor: downFor, graceful: graceful)
        if !graceful {
            for client in clients { client.link.dropConnection("server restarted") }
        }
    }

    // MARK: Checks

    /// Waits until every given client (default: every running one on a live link) has sent its
    /// outbox, applied the whole log and is *Saved to cloud*.
    public func settle(_ subset: [SimClient]? = nil, timeout: Duration = .seconds(90)) async throws {
        let waiting = subset ?? clients.filter { !$0.isStopped && !$0.link.isPartitioned }
        let deadline = ContinuousClock.now + timeout
        var stableRounds = 0
        while ContinuousClock.now < deadline {
            if try await settled(waiting) {
                stableRounds += 1
                if stableRounds >= 3 { return }
            } else {
                stableRounds = 0
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw failure("did not settle within \(timeout)", clients: waiting)
    }

    private func settled(_ waiting: [SimClient]) async throws -> Bool {
        var seqs: [String: Set<UInt64>] = [:]
        for client in waiting {
            let state = await client.syncState
            if state == .needsReview && !client.keepsMergedResult {
                throw failure("\(client.name) waits for a review nobody will settle", clients: waiting)
            }
            guard try await client.store.outboxCount() == 0, state == .saved else { return false }
            seqs[client.documentID, default: []].insert(await client.store.lastServerSeq)
        }
        for (document, applied) in seqs {
            guard applied.count == 1 else { return false }
            if let server, applied.first != (await server.head(document)) { return false }
        }
        return true
    }

    /// The hash a state has once collected at the server's collection point: replicas compare
    /// at the same collection point (crdt-model.adoc, "Collecting").
    nonisolated static func normalized(_ state: EngineState, _ point: SimCollectionPoint?) -> EngineState {
        guard let point else { return state }
        var copy = state
        copy.collect(stableSeq: point.seq, now: point.timeMs)
        return copy
    }

    /// The invariants (docs/spec/testing.adoc, "Multi-client simulation"), over the given clients
    /// (default: every one that is not stopped):
    ///
    /// * every client's outbox is empty and it applied the log through the same `server_seq`;
    /// * its `Document` façade shows exactly its store's state;
    /// * every state, collected at the server's collection point, hashes the same -- and the same
    ///   as the server's own log (in-process);
    /// * the log holds each replica's seqs densely from 1 and no op id twice;
    /// * every change a client made is in the log by its label, unless it was discarded or
    ///   salvage dropped all of it;
    /// * no client ever reached the `error` state.
    public func expectConverged(_ subset: [SimClient]? = nil, document: String? = nil) async throws {
        let checked = subset ?? clients.filter { !$0.isStopped }
        let documentID = document ?? self.documentID
        let point = await server?.collectionPoint(documentID)
        var reference: (name: String, state: EngineState)?
        if let server {
            reference = ("server", Self.normalized(await server.state(documentID), point))
        }
        for client in checked {
            await client.document.settle()
            let outbox = try await client.store.outboxCount()
            guard outbox == 0 else { throw failure("\(client.name) still has \(outbox) changes in its outbox", clients: checked) }
            let local = await client.store.read { $0 }
            guard client.document.state.stateHash == local.stateHash else {
                throw failure("\(client.name)'s Document shows a state other than its store's", clients: checked)
            }
            if client.reached({ if case .error = $0 { true } else { false } }) {
                throw failure("\(client.name) reached the error state", clients: checked)
            }
            let state = Self.normalized(local, point)
            if let reference {
                if state.stateHash != reference.state.stateHash {
                    let nodes = Self.differingNodes(reference.state, state).prefix(5).map { "\($0)" }.joined(separator: ", ")
                    throw failure("\(client.name) diverges from \(reference.name) at nodes [\(nodes)]", clients: checked)
                }
            } else {
                reference = (client.name, state)
            }
        }
        if let server {
            let log = await server.log(documentID)
            try checkLog(log, clients: checked)
            if documentID == self.documentID {
                let labels = Set(log.map(\.change.label))
                for client in checked {
                    let expected = Set(client.performed).subtracting(client.discarded).subtracting(client.forgiven)
                    if let missing = expected.subtracting(labels).sorted().first {
                        throw failure("\(client.name)'s change \"\(missing)\" is not in the server's log", clients: checked)
                    }
                }
            }
        }
        log.record("converged: \(checked.map(\.name).joined(separator: ", "))")
    }

    private func checkLog(_ log: [Wiretuner_Sync_V1_SequencedChange], clients: [SimClient]) throws {
        var seqs: [UInt64: UInt64] = [:]
        var ids = Set<OpID>()
        for entry in log {
            let change = entry.change
            let expected = seqs[change.replica, default: 0] + 1
            guard change.seq == expected else {
                throw failure("the log holds seq \(change.seq) of replica \(change.replica) where \(expected) was due", clients: clients)
            }
            seqs[change.replica] = expected
            for id in change.opIDs where !ids.insert(id).inserted {
                throw failure("op id \(id) appears twice in the log (server_seq \(entry.serverSeq))", clients: clients)
            }
        }
    }

    /// The nodes whose hashes differ between two states, in id order.
    nonisolated static func differingNodes(_ a: EngineState, _ b: EngineState) -> [OpID] {
        Set(a.store.nodes).union(b.store.nodes).sorted().filter { StateHash.of(a.store, node: $0) != StateHash.of(b.store, node: $0) }
    }

    /// A failure with the report: what failed, how to replay it, each client, the trace's end.
    public func failure(_ message: String, clients subset: [SimClient]? = nil) -> Failure {
        var lines = ["simulation \(name) failed: \(message)",
                     "seed \(seed) -- replay with WT_SIM_SEED=\(seed) swift test --filter <the test>"]
        for client in subset ?? clients {
            let last = client.transitions.last.map { "\($0.to) (\($0.cause))" } ?? "no transition"
            let stats = client.link.stats
            lines.append("  \(client.name): \(last); \(client.performed.count) changes, \(client.skipped) skipped; link \(stats)")
        }
        let url = Self.reportDirectory().appending(path: "\(name)-seed\(seed).log")
        let header = lines.joined(separator: "\n")
        try? log.write(to: url, header: header)
        lines.append("trace: \(url.path)")
        lines.append(contentsOf: log.tail(40).map { "  " + $0 })
        return Failure(description: lines.joined(separator: "\n"))
    }

    nonisolated static func reportDirectory(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        environment["WT_SIM_REPORTS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appending(path: "WTSimulation")
    }

    /// One line per client and one for the server: what the run did.
    public func summary() async -> String {
        var lines = ["simulation \(name) (seed \(seed)): \(SimClock.seconds(clock.elapsed).rounded())s simulated"]
        for client in clients {
            let stats = client.link.stats
            lines.append("  \(client.name): \(client.performed.count) changes, \(client.skipped) skipped, \(client.reviews) reviews, "
                         + "\(stats.calls) calls, \(stats.reordered) reordered, \(stats.lostRequests + stats.lostResponses) lost, "
                         + "\(stats.droppedConnections) connections dropped")
        }
        if let server {
            lines.append("  server: \(await server.stats)")
        }
        let text = lines.joined(separator: "\n")
        log.record(text)
        return text
    }

    /// Stops every client, closes the stores and removes them, and shuts the server down.
    public func shutdown() async {
        guard !closed else { return }
        closed = true
        for client in clients {
            await client.close()
        }
        await server?.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A value behind a lock, shareable by closures (a `Mutex` cannot be captured).
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        mutex.withLock { body(&$0) }
    }
}
