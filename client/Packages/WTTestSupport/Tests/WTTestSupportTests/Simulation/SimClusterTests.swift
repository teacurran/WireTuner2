import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
import WTSync
@testable import WTTestSupport

/// The API nodes in front of the in-process server (`SimCluster`), called directly.
@Suite struct SimClusterTests {
    static let doc = SimServerTests.doc

    static func cluster(nodes: Int = 2) async -> (SimCluster, String) {
        let (server, alice, _) = await SimServerTests.server()
        return (SimCluster(server: server, clock: await server.clock, nodes: nodes, fanOutDelay: .milliseconds(20)), alice)
    }

    static func subscribe(_ transport: SimClusterTransport, token: String, replica: UInt64 = 7) -> AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error> {
        transport.subscribe(.with { $0.documentID = doc; $0.replica = replica }, token: token)
    }

    /// Frames until a change frame arrives (after the welcome and the presence snapshot).
    static func nextChange(_ iterator: inout AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error>.AsyncIterator) async throws -> Wiretuner_Sync_V1_SequencedChange? {
        while let frame = try await iterator.next() {
            if case .change(let entry)? = frame.frame { return entry }
        }
        return nil
    }

    @Test func callsTakeTheLiveNodesInTurnAndChangesCrossTheBus() async throws {
        let (cluster, alice) = await Self.cluster()
        let transport = SimClusterTransport(cluster: cluster, device: SimServerTests.d1)
        // The subscription opens on node 0; the push goes to node 1, so its change is relayed.
        var frames = Self.subscribe(transport, token: alice).makeAsyncIterator()
        while await cluster.subscriptions(on: 0) == 0 { try await Task.sleep(for: .milliseconds(1)) }
        let pushed = try await transport.pushChange(.with { $0.documentID = Self.doc; $0.change = SimServerTests.change(7, seq: 1) }, token: alice)
        #expect(pushed.serverSeq == 1)
        #expect(try await Self.nextChange(&frames)?.serverSeq == 1)
        var stats = await cluster.stats
        #expect(stats.calls == [1, 1] && stats.relayed == 1)
        // A batch lands on node 0, the subscription's own: no bus hop.
        _ = try await transport.pushChangeBatch(.with { $0.documentID = Self.doc; $0.changes = [SimServerTests.change(7, seq: 2)] }, token: alice)
        #expect(try await Self.nextChange(&frames)?.serverSeq == 2)
        stats = await cluster.stats
        #expect(stats.calls == [2, 1] && stats.relayed == 1)
        _ = try await transport.pushChanges([.with { $0.documentID = Self.doc; $0.changes = [SimServerTests.change(7, seq: 3)] }], token: alice)
        _ = try await transport.ack(.with { $0.documentID = Self.doc; $0.replica = 7; $0.appliedServerSeq = 3 }, token: alice)
        try await transport.updatePresence(.with { $0.documentID = Self.doc; $0.replica = 7 }, token: alice)
        var fetched: [UInt64] = []
        for try await response in transport.fetchChanges(.with { $0.documentID = Self.doc; $0.afterServerSeq = 0 }, token: alice) {
            fetched += response.changes.map(\.serverSeq)
        }
        #expect(fetched == [1, 2, 3])
        await #expect(throws: SyncCallError.self) {
            for try await _ in transport.fetchSnapshot(.with { $0.documentID = Self.doc }, token: alice) {}
        }
        #expect(await cluster.stats.calls.reduce(0, +) == 8)
    }

    @Test func aRestartEndsThatNodesSubscriptionsAndTakesItOutOfTheRotation() async throws {
        let (cluster, alice) = await Self.cluster()
        let transport = SimClusterTransport(cluster: cluster, device: SimServerTests.d1)
        let first = Self.subscribe(transport, token: alice)
        let second = Self.subscribe(transport, token: alice, replica: 8)
        while await cluster.subscriptions(on: 0) + (await cluster.subscriptions(on: 1)) < 2 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await cluster.subscriptions(on: 0) == 1)
        await cluster.restart(node: 0, downFor: .seconds(3_600))
        #expect(await !cluster.isUp(0))
        #expect(await cluster.isUp(1))
        #expect(await cluster.subscriptions(on: 0) == 0)
        #expect(await cluster.subscriptions(on: 1) == 1)
        var ended: (any Error)?
        do { for try await _ in first {} } catch { ended = error }
        #expect((ended as? SyncCallError)?.code == SyncCallError.unavailable)
        // Every call now goes to node 1.
        let before = await cluster.stats.calls
        _ = try? await transport.ack(.with { $0.documentID = Self.doc; $0.replica = 8; $0.appliedServerSeq = 0 }, token: alice)
        _ = try? await transport.ack(.with { $0.documentID = Self.doc; $0.replica = 8; $0.appliedServerSeq = 0 }, token: alice)
        #expect(await cluster.stats.calls == [before[0], before[1] + 2])
        #expect(await cluster.stats.restarts == 1)
        _ = second
    }

    @Test func withNoLiveNodeEveryCallIsUnavailable() async throws {
        let (cluster, alice) = await Self.cluster(nodes: 1)
        let transport = SimClusterTransport(cluster: cluster, device: SimServerTests.d1)
        await cluster.restart(node: 0, downFor: .seconds(3_600))
        await #expect(throws: SyncCallError.self) {
            _ = try await transport.pushChange(.with { $0.documentID = Self.doc; $0.change = SimServerTests.change(7, seq: 1) }, token: alice)
        }
        await #expect(throws: SyncCallError.self) {
            for try await _ in Self.subscribe(transport, token: alice) {}
        }
        await #expect(throws: SyncCallError.self) {
            for try await _ in transport.fetchChanges(.with { $0.documentID = Self.doc }, token: alice) {}
        }
        #expect(await cluster.stats.refused == 3)
    }

    @MainActor @Test func aSimulationRunsThroughTheNodes() async throws {
        let (sim, cluster) = try await Simulation.clustered(name: "cluster-smoke", seed: 11)
        defer { Task { await sim.shutdown() } }
        #expect(sim.backend.name == "2-node")
        let ana = try await sim.addClient("ana")
        let ben = try await sim.addClient("ben")
        let shapes = try await Workload.createShapes(ana, count: 3)
        var random = sim.random.fork(1)
        await Workload.move(ben, shapes, &random)
        try await sim.settle()
        try await sim.expectConverged()
        #expect(await cluster.stats.calls.allSatisfy { $0 > 0 })
    }
}
