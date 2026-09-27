import Foundation
import Synchronization
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// Timings short enough for tests.
func fastOptions(gateway: Bool = false) -> SyncClient.Options {
    var options = SyncClient.Options()
    options.gatewayMode = gateway
    options.ackInterval = .milliseconds(40)
    options.presenceInterval = .milliseconds(10)
    options.presenceKeepAlive = .milliseconds(300)
    options.heartbeatTimeout = .seconds(3)
    options.backoffBase = .milliseconds(5)
    options.backoffMax = .milliseconds(40)
    options.idlePoll = .milliseconds(30)
    options.publishInterval = .milliseconds(5)
    options.random = { 0.5 }
    return options
}

/// `fastOptions` for a test that asserts one uninterrupted session (the transitions it sees, the
/// calls the server counts): `FakeSyncServer` sends no heartbeats, so with the 3 s heartbeat a
/// loaded machine that starves the client's tasks for 3 s ends the session and the test sees a
/// reconnect it is not about.  The heartbeat itself is `SyncClientTests`' subject, with its own
/// timeout.
func steadyOptions() -> SyncClient.Options {
    var options = fastOptions()
    options.heartbeatTimeout = .seconds(600)
    return options
}

struct Timeout: Error, CustomStringConvertible {
    let description: String
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(_ what: String = "condition", timeout: Duration = .seconds(20),
                _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw Timeout(description: "timed out waiting for \(what)")
}

/// Collects what a stream yields.
final class Collector<Element: Sendable>: Sendable {
    private let items = Mutex<[Element]>([])
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<Element>) {
        let task = Task { [weak self] in
            for await item in stream {
                self?.items.withLock { $0.append(item) }
            }
        }
        self.task.withLock { $0 = task }
    }

    var all: [Element] { items.withLock { $0 } }

    deinit {
        task.withLock { $0?.cancel() }
    }
}

/// One client against a fake server.
struct Harness {
    let scratch = Scratch()
    let server: FakeSyncServer
    let store: LocalStore
    let tokens: FakeTokens
    let client: SyncClient
    let transitions: Collector<SyncTransition>
    let events: Collector<SyncEvent>

    init(server: FakeSyncServer = FakeSyncServer(), options: SyncClient.Options = fastOptions(), name: String = "doc",
         replicas: Replicas = Replicas(), tokens: FakeTokens = FakeTokens(), presence: FakePresence? = nil,
         sink: (@Sendable (LocalStore) async -> any RemoteChangeSink)? = nil,
         transport: ((FakeSyncServer) -> any SyncTransport)? = nil) async throws {
        self.server = server
        self.tokens = tokens
        store = try await LocalStore.open(documentID: server.documentID, at: scratch.url(name),
                                          options: WTSyncTests.options(replicas: replicas))
        let chosenSink = await sink?(store)
        client = SyncClient(store: store, sink: chosenSink, transport: transport?(server) ?? FakeTransport(server: server),
                            tokens: tokens, presence: presence, options: options)
        transitions = Collector(client.transitions())
        events = Collector(client.events())
    }

    /// Performs `count` local changes, each creating a layer, and tells the client.
    func edit(_ count: Int, from start: Int = 0) async throws {
        for index in start..<(start + count) {
            _ = try await store.perform(createLayer("L\(index)"), recording: Fixture.recording())
        }
        await client.localChangesAvailable()
    }

    func waitFor(_ state: SyncState, timeout: Duration = .seconds(20)) async throws {
        do {
            try await eventually("state \(state)", timeout: timeout) { await client.state == state }
        } catch {
            let trail = transitions.all.map { "\($0.from) -> \($0.to) (\($0.cause))" }.joined(separator: "; ")
            throw Timeout(description: "timed out waiting for \(state), at \(await client.state): \(trail)")
        }
    }

    /// Waits until a transition matching `match` was published.
    func waitForTransition(_ what: String, _ match: @escaping (SyncTransition) -> Bool) async throws {
        try await eventually(what) { transitions.all.contains(where: match) }
    }

    /// Waits until an event matching `match` was published.
    func waitForEvent(_ what: String, _ match: @escaping (SyncEvent) -> Bool) async throws {
        try await eventually(what) { events.all.contains(where: match) }
    }

    /// Every local change reached the server exactly once and in order, and the client applied
    /// the whole log: the two merged states agree.
    func expectConverged(sameState: Bool = true) async throws {
        let replica = await store.replica
        try await eventually("outbox empty and log applied") {
            let outbox = try await store.outboxCount()
            let applied = await store.lastServerSeq
            let head = await server.head
            return outbox == 0 && applied == head
        }
        let seqs = await server.acceptedSeqs(replica)
        #expect(seqs == (0..<UInt64(seqs.count)).map { $0 + 1 })
        if sameState {
            let local = await store.read { $0.stateHash }
            #expect(local == (await server.stateHash()))
        }
    }

    func stop() async throws {
        await client.stop()
        try await store.close()
    }
}

/// A remote change from another replica: one layer created at counter `seq`.
func remoteChange(_ replica: UInt64 = 7, seq: UInt64) -> Wiretuner_Doc_V1_Change {
    Fixture.change(replica, seq: seq, start: seq, [Fixture.createLayer("R\(replica)-\(seq)")])
}
