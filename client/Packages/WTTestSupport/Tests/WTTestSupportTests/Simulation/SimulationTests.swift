import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
import WTSync
@testable import WTTestSupport

/// The simulator's parts: the generator, the clock, the network proxy, and the checks failing
/// with their report.
@Suite struct SimulationPartsTests {
    @Test func theGeneratorIsDeterministic() {
        var a = SimRandom(seed: 42)
        var b = SimRandom(seed: 42)
        #expect((0..<5).map { _ in a.next() } == (0..<5).map { _ in b.next() })
        #expect(a.state == b.state)
        #expect((0..<100).allSatisfy { _ in (3...5).contains(a.within(3...5)) })
        #expect((0..<100).allSatisfy { _ in (0..<1).contains(a.unit()) })
        #expect(!a.chance(0) && a.chance(1))
        #expect([7].contains(a.pick([7])))
        #expect(a.fork(1).state == a.fork(1).state && a.fork(1).state != a.fork(2).state)
        #expect(SimRandom.mix(1, 2, 3) == SimRandom.mix(1, [2, 3]) && SimRandom.mix(1, 2, 3) != SimRandom.mix(1, 3, 2))
        #expect((0..<1).contains(SimRandom.unit(9, 1)))
    }

    @Test func theClockRunsScaledAndJumps() async throws {
        let clock = SimClock(scale: 0.001, origin: Date(timeIntervalSince1970: 0))
        clock.advance(by: .seconds(3_600))
        clock.advance(by: .seconds(-5))
        #expect(clock.elapsed >= .seconds(3_600))
        #expect(clock.nowMs() >= 3_600_000)
        #expect(clock.real(.seconds(10)) == .milliseconds(10))
        try await clock.sleep(.zero)
        try await clock.sleep(.seconds(5))
        #expect(clock.elapsed >= .seconds(3_605))
        #expect(clock.skewed(by: .seconds(-60))() < clock.now())
        #expect(SimClock.seconds(.milliseconds(1_500)) == 1.5)
    }

    @Test func theLogStampsWritesAndTails() throws {
        let log = SimulationLog(clock: SimClock())
        log.record("one")
        log.record("two")
        #expect(log.all.count == 2 && log.tail(1).first?.hasSuffix("two") == true)
        let url = FileManager.default.temporaryDirectory.appending(components: "WTSimulationLog-\(UUID().uuidString)", "trace.log")
        try log.write(to: url, header: "header")
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("header\n\n["))
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func seedsAndReportsFollowTheEnvironment() {
        #expect(Simulation.seed(5, environment: [:]) == 5)
        #expect(Simulation.seed(5, environment: ["WT_SIM_SEED": "12"]) == 12)
        #expect(Simulation.reportDirectory(["WT_SIM_REPORTS": "/tmp/x"]).path == "/tmp/x")
        #expect(Simulation.reportDirectory([:]).lastPathComponent == "WTSimulation")
        #expect(Simulation.Failure(description: "d").description == "d")
    }

    /// A proxy in front of a transport that records nothing and answers at once.
    struct Echo: SyncTransport {
        func subscribe(_ request: Wiretuner_Sync_V1_SubscribeRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error> {
            AsyncThrowingStream { continuation in
                for index in 0..<50 { continuation.yield(.with { $0.pong.serverTimeMs = Int64(index) }) }
                continuation.finish()
            }
        }
        func pushChange(_ request: Wiretuner_Sync_V1_PushChangeRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeResponse {
            .with { $0.serverSeq = request.change.seq }
        }
        func pushChangeBatch(_ request: Wiretuner_Sync_V1_PushChangeBatchRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeBatchResponse { .init() }
        func pushChanges(_ frames: [Wiretuner_Sync_V1_PushChangesRequest], token: String) async throws -> Wiretuner_Sync_V1_PushChangesResponse { .init() }
        func updatePresence(_ request: Wiretuner_Sync_V1_UpdatePresenceRequest, token: String) async throws {
            throw SyncCallError(code: SyncCallError.permissionDenied)
        }
        func ack(_ request: Wiretuner_Sync_V1_AckRequest, token: String) async throws -> Wiretuner_Sync_V1_AckResponse { .init() }
        func fetchChanges(_ request: Wiretuner_Sync_V1_FetchChangesRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchChangesResponse, any Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func fetchSnapshot(_ request: Wiretuner_Sync_V1_FetchSnapshotRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchSnapshotResponse, any Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    static func push(_ proxy: ProxyTransport, seq: UInt64) async throws -> UInt64 {
        try await proxy.pushChange(.with { $0.change.replica = 1; $0.change.seq = seq }, token: "t").serverSeq
    }

    @Test func theProxyLosesDelaysAndReorders() async throws {
        let clock = SimClock(scale: 0.001)
        let link = NetworkLink(name: "l", seed: 1, clock: clock, conditions: LinkConditions(requestLoss: 1))
        let lines = Locked<[String]>([])
        link.observe { line in lines.withLock { $0.append(line) } }
        let proxy = ProxyTransport(link: link, upstream: Echo())
        await #expect(throws: SyncCallError.self) { _ = try await Self.push(proxy, seq: 1) }
        link.conditions = LinkConditions(responseLoss: 1)
        await #expect(throws: SyncCallError.self) { _ = try await Self.push(proxy, seq: 1) }
        link.conditions = LinkConditions(latency: .milliseconds(10), jitter: .milliseconds(10), reorder: 1, reorderWindow: .seconds(1))
        #expect(try await Self.push(proxy, seq: 2) == 2)
        _ = try await proxy.pushChangeBatch(.with { $0.changes = [.with { $0.seq = 3 }] }, token: "t")
        _ = try await proxy.pushChanges([], token: "t")
        _ = try await proxy.ack(.init(), token: "t")
        await #expect(throws: SyncCallError.self) { try await proxy.updatePresence(.init(), token: "t") }
        for try await _ in proxy.fetchChanges(.init(), token: "t") {}
        for try await _ in proxy.fetchSnapshot(.init(), token: "t") {}
        var frames = 0
        for try await _ in proxy.subscribe(.init(), token: "t") { frames += 1 }
        #expect(frames == 50)
        let stats = link.stats
        #expect(stats.lostRequests == 1 && stats.lostResponses == 1 && stats.reordered == 1 && stats.streams == 3)
        #expect(lines.withLock { $0 } == ["l: request lost", "l: answer lost"])
    }

    @Test func dropsAndPartitionsFailStreamsAndCallsInFlight() async throws {
        let clock = SimClock(scale: 0.001)
        let link = NetworkLink(name: "l", seed: 1, clock: clock, conditions: LinkConditions(streamDrop: 1))
        let proxy = ProxyTransport(link: link, upstream: Echo())
        var frames = 0
        await #expect(throws: SyncCallError.self) {
            for try await _ in proxy.subscribe(.init(), token: "t") { frames += 1 }
        }
        #expect(frames == 1 && link.stats.droppedConnections == 1)
        // A call in flight when the connection drops loses its answer.
        link.conditions = LinkConditions(latency: .seconds(200))
        let call = Task { try await Self.push(proxy, seq: 1) }
        try await Task.sleep(for: .milliseconds(50))
        link.dropConnection()
        await #expect(throws: SyncCallError.self) { _ = try await call.value }
        link.partition()
        #expect(link.isPartitioned)
        await #expect(throws: SyncCallError.self) { _ = try await Self.push(proxy, seq: 1) }
        await #expect(throws: SyncCallError.self) { for try await _ in proxy.subscribe(.init(), token: "t") {} }
        link.heal()
        link.conditions = .perfect
        #expect(try await Self.push(proxy, seq: 1) == 1)
        #expect(link.stats.refused == 2)
        #expect(CallKind.allCases.count == 8)
    }
}

/// The checks, made to fail: each names the scenario and seed and writes its trace.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct SimulationChecksTests {
    static func reports() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "WTSimulation")
    }

    @Test func aClientThatCannotSendFailsToSettle() async throws {
        let sim = try await Simulation(name: "unsettled", seed: 3, scale: 0.005)
        defer { Task { await sim.shutdown() } }
        let ana = try await sim.addClient("ana")
        let shapes = try await Workload.createShapes(ana, count: 2)
        try await sim.settle()
        ana.goOffline()
        var random = sim.random
        await Workload.move(ana, shapes, &random)
        let failure = await #expect(throws: Simulation.Failure.self) { try await sim.settle([ana], timeout: .milliseconds(200)) }
        #expect(failure?.description.contains("did not settle") == true)
        #expect(failure?.description.contains("WT_SIM_SEED=3") == true)
        #expect(FileManager.default.fileExists(atPath: Self.reports().appending(path: "unsettled-seed3.log").path))
        let outbox = await #expect(throws: Simulation.Failure.self) { try await sim.expectConverged([ana]) }
        #expect(outbox?.description.contains("still has 1 changes") == true)
        let waiting = await #expect(throws: Simulation.Failure.self) {
            try await ana.waitFor("saved", timeout: .milliseconds(50)) { $0 == .saved }
        }
        #expect(waiting?.description.contains("timed out waiting for saved") == true)
        #expect(await sim.summary().contains("ana: 2 changes"))
        let empty = await #expect(throws: Simulation.Failure.self) { _ = try await Workload.createShapes(ana, count: 0) }
        #expect(empty?.description == "ana could not create shapes")
    }

    @Test func aReviewNobodySettlesFailsTheSettle() async throws {
        let sim = try await Simulation(name: "unreviewed", seed: 4, scale: 0.005)
        defer { Task { await sim.shutdown() } }
        let ana = try await sim.addClient("ana", keepsMergedResult: false)
        let ben = try await sim.addClient("ben")
        let shapes = try await Workload.createShapes(ben, count: 1)
        try await sim.settle()
        ana.goOffline()
        await Workload.rename(ana, shapes, "mine")
        await Workload.rename(ben, shapes, "theirs")
        try await sim.settle([ben])
        sim.advance(by: .seconds(3_600))   // offline work, not a dropped connection (D-070)
        ana.goOnline()
        try await ana.waitFor("review") { $0 == .needsReview }
        let failure = await #expect(throws: Simulation.Failure.self) { try await sim.settle() }
        #expect(failure?.description.contains("waits for a review nobody will settle") == true)
        try await ana.keepMerged()
        try await sim.settle()
        try await sim.expectConverged()
    }

    @Test func aDivergentStateIsNamedByNode() async throws {
        var a = EngineState()
        let b = EngineState()
        #expect(Simulation.differingNodes(a, b).isEmpty)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.layer.common.name = "x"
        var change = Wiretuner_Doc_V1_Change()
        change.replica = 5
        change.seq = 1
        change.startCounter = 1
        change.ops = [Ops.create(parent: OpID.wellKnown(4), position: [0x80], props: props)]
        a.apply(change, serverSeq: 1)
        #expect(Simulation.differingNodes(a, b).contains(OpID(counter: 1, replica: 5)))
        #expect(Simulation.normalized(a, nil).stateHash == a.stateHash)
    }

    /// A change the server refuses as invalid is replaced by `Noop`s and reported (sync-protocol.adoc,
    /// *Rejections*); its effect stays in the local state, the recorded deviation.
    @Test func aChangeTheServerRefusesIsReported() async throws {
        var options = SimServer.Options()
        options.maxBytes = 120
        let sim = try await Simulation(name: "refused", seed: 5, scale: 0.005, serverOptions: options)
        defer { Task { await sim.shutdown() } }
        let ana = try await sim.addClient("ana")
        _ = try await Workload.createShapes(ana, count: 5)
        try await sim.settle()
        #expect(ana.events.contains { if case .changeDropped = $0 { true } else { false } })
        #expect(await sim.server?.stats.validationFailures == 1)
        #expect(await sim.server?.log(sim.documentID).first?.change.ops.allSatisfy { if case .noop? = $0.op { true } else { false } } == true)
        // The shapes stay on this Mac only, so the check names where it parts from the server.
        let diverged = await #expect(throws: Simulation.Failure.self) { try await sim.expectConverged() }
        #expect(diverged?.description.contains("ana diverges from server at nodes [") == true)
    }

    /// TEST-001 finding (b): a change refused for its op count is replaced by one `Noop`, which is
    /// within any limit, so each such change is refused once -- not once per counter, forever.
    @Test func aChangeRefusedForItsOpCountIsRefusedOnce() async throws {
        var options = SimServer.Options()
        options.maxOps = 3
        let sim = try await Simulation(name: "refused-ops", seed: 5, scale: 0.005, serverOptions: options)
        defer { Task { await sim.shutdown() } }
        let ana = try await sim.addClient("ana")
        _ = try await Workload.createShapes(ana, count: 5)
        try await sim.settle()
        let refusals = await sim.server?.stats.validationFailures ?? 0
        let dropped = ana.events.filter { if case .changeDropped = $0 { true } else { false } }.count
        #expect(refusals > 0 && refusals == dropped, "\(refusals) refusals for \(dropped) dropped changes")
        try await Task.sleep(for: .milliseconds(300))
        #expect(await sim.server?.stats.validationFailures == refusals)
        #expect(!ana.reached { if case .error = $0 { true } else { false } })
    }

    /// A client that knows the limit splits a change over it before sending (through salvage), so
    /// nothing is refused and everyone converges.
    @Test func aChangeOverTheLimitsIsSplitAndConverges() async throws {
        var options = SimServer.Options()
        options.maxOps = 3
        let sim = try await Simulation(name: "split-ops", seed: 6, scale: 0.005, serverOptions: options)
        defer { Task { await sim.shutdown() } }
        let ana = try await sim.addClient("ana") { $0.changeLimits = ChangeLimits(ops: 3) }
        let ben = try await sim.addClient("ben") { $0.changeLimits = ChangeLimits(ops: 3) }
        let shapes = try await Workload.createShapes(ana, count: 5)
        try await sim.settle()
        var random = sim.random.fork(6)
        for _ in 0..<5 {
            await Workload.move(ben, shapes, &random)
        }
        try await sim.settle()
        try await sim.expectConverged()
        #expect(await sim.server?.stats.validationFailures == 0)
        #expect(await sim.server?.log(sim.documentID).allSatisfy { $0.change.ops.count <= 3 } == true)
        #expect(ana.events.contains { if case .salvaged(let report) = $0 { report.reason == .oversized } else { false } })
    }

    /// A custom backend (how a test puts the compose server behind the proxies), and a published
    /// collection point reaching the clients, which record it as their horizon.
    @Test func aCustomBackendAndAPublishedCollectionPoint() async throws {
        let sim = try await Simulation(name: "custom", seed: 6, scale: 0.005) { clock in
            var backend = SimulationBackend.inProcess(SimServer(clock: clock))
            backend.name = "custom"
            return backend
        }
        defer { Task { await sim.shutdown() } }
        #expect(sim.backend.name == "custom")
        let server = try #require(sim.server)
        let ana = try await sim.addClient("ana")
        let ben = try await sim.addClient("ben")
        let shapes = try await Workload.createShapes(ana, count: 3)
        await Workload.delete(ana, [shapes[0]])
        try await sim.settle()
        sim.advance(by: .seconds(40 * 86_400))
        await server.publishCollectionPoint(SimCollectionPoint(seq: await server.head(sim.documentID), timeMs: sim.clock.nowMs()),
                                            for: sim.documentID)
        await Workload.rename(ben, [shapes[1]], "after")
        try await sim.settle()
        try await ana.waitFor("collection point") { _ in ana.events.contains { if case .collectionPoint = $0 { true } else { false } } }
        try await sim.expectConverged()
    }
}
