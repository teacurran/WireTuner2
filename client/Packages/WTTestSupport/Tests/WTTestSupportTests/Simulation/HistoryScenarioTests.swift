import Foundation
import GRPCCore
import Testing
import WTCRDT
import WTModel
import WTProto
import WTSync
@testable import WTTestSupport

/// COLLAB-024 in the simulator (history.adoc, "Offline behavior"): a version named offline is
/// listed as pending at once -- beside the unsent changes of *Not yet synced* -- and after the
/// reconnect becomes a server version at the seq where its last change landed, interleaved with
/// the others' work; a pending name survives the app being killed; the queued call leaves the
/// outbox's order alone.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct HistoryScenarioTests {
    struct Naming {
        let queue: VersionQueue
        let following: Task<Void, Never>
    }

    /// `client`'s version queue over its store, sending through its link and flushing on *Saved to
    /// cloud*, as WTApp's `VersionFeatures` wires a window.
    static func naming(_ client: SimClient, _ versions: SimVersionService) -> Naming {
        let queue = VersionQueue(documentID: client.documentID, store: client.store)
        let transport = versions.transport(link: client.link)
        let tokens = client.tokens
        queue.send = { request in
            do {
                return try await transport.nameVersion(request, token: try await tokens.accessToken(forceRefresh: false))
            } catch let error as SyncCallError where [SyncCallError.notFound, SyncCallError.failedPrecondition].contains(error.code) {
                // What grpc-swift raises for the server's answer, which the queue falls back on.
                throw RPCError(code: error.code == SyncCallError.notFound ? .notFound : .failedPrecondition, message: error.message)
            }
        }
        return Naming(queue: queue, following: queue.follow(client.client.transitions()))
    }

    /// Waits until `queue` holds nothing.
    static func drained(_ queue: VersionQueue, _ sim: Simulation) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if queue.pending.isEmpty { return }
            await queue.flush()
            try await Task.sleep(for: .milliseconds(10))
        }
        throw sim.failure("the pending version was never named")
    }

    /// The seq at which the logged change holding `anchor` landed.
    static func landing(of anchor: LocalChangeRef, in log: [Wiretuner_Sync_V1_SequencedChange]) -> UInt64? {
        log.first { SimVersionService.holds($0.change, counter: anchor.counter, replica: anchor.replica) }?.serverSeq
    }

    @Test(arguments: PushMode.allCases) func aVersionNamedOfflineBecomesAServerVersionAtItsChangesSeq(mode: PushMode) async throws {
        let sim = try await Simulation(name: "history-offline-name-\(mode)", seed: Simulation.seed(2401), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let server = try #require(sim.server)
        let versions = SimVersionService(server: server)
        let priya = try await sim.addClient("priya", gateway: mode.gateway)
        let tom = try await sim.addClient("tom", gateway: mode.gateway)
        let naming = Self.naming(priya, versions)
        defer { naming.following.cancel() }
        let shapes = try await Workload.createShapes(tom, count: 6)
        try await sim.settle()
        let headWhenNamed = await priya.store.lastServerSeq
        priya.goOffline()
        var random = sim.random.fork(24)
        for index in 0..<3 { await Workload.move(priya, [shapes[index]], &random) }
        for index in 0..<4 { await Workload.rename(tom, [shapes[3 + index % 3]], "tom-\(index)") }
        try await sim.settle([tom])
        guard case .pending(let version) = await naming.queue.save(name: "Before print", note: "offline") else {
            throw sim.failure("a version named offline was named at once")
        }
        // Listed at once: pending, with the three unsent changes under *Not yet synced*.
        #expect(naming.queue.pending.map(\.name) == ["Before print"] && version.serverSeq == headWhenNamed)
        let local = try await priya.store.localHistory()
        #expect(local.notYetSynced.count == 3 && local.notYetSynced.first == priya.performed.last)
        #expect(versions.versions(of: sim.documentID).isEmpty)
        sim.advance(by: .seconds(4 * 3600))
        priya.goOnline()
        try await sim.settle()
        try await Self.drained(naming.queue, sim)
        try await sim.expectConverged()
        let named = try #require(versions.versions(of: sim.documentID).first)
        let log = await server.log(sim.documentID)
        let anchor = try #require(version.anchor)
        #expect(named.id == version.id && named.name == "Before print")
        #expect(named.serverSeq == Self.landing(of: anchor, in: log), "the seq at which the last change it includes landed")
        #expect(named.serverSeq > headWhenNamed + 4, "after Tom's changes, which landed first")
        let after = try await priya.store.localHistory()
        #expect(after.notYetSynced.isEmpty)
        // The version's state holds Priya's three moves and Tom's renames that landed before them.
        let atVersion = try #require(try await priya.store.state(atServerSeq: named.serverSeq))
        for shape in shapes.prefix(3) {
            #expect(atVersion.props(shape).rect.common.transform == priya.state.props(shape).rect.common.transform)
        }
        // A retried call answers the same version.
        let token = try await priya.tokens.accessToken(forceRefresh: false)
        let again = try await versions.nameVersion(version.request(documentID: sim.documentID, anchor: anchor), token: token)
        #expect(again == named && versions.versions(of: sim.documentID).count == 1)
    }

    /// The app killed with a name pending: the store opened again (same Mac, same replica) still
    /// holds it, and it is named once the reopened session has uploaded the changes.
    @Test func aPendingNameSurvivesKillingTheApp() async throws {
        let sim = try await Simulation(name: "history-kill", seed: Simulation.seed(2402), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let server = try #require(sim.server)
        let versions = SimVersionService(server: server)
        let priya = try await sim.addClient("priya")
        let shapes = try await Workload.createShapes(priya, count: 3)
        try await sim.settle()
        priya.goOffline()
        var random = sim.random.fork(25)
        await Workload.move(priya, [shapes[0]], &random)
        let naming = Self.naming(priya, versions)
        guard case .pending(let version) = await naming.queue.save(name: "Kept") else { throw sim.failure("named at once while offline") }
        naming.following.cancel()
        await priya.close()
        let reopened = try await sim.addClient("priya-again", user: priya.user, device: "device-priya", hardware: "MAC-priya",
                                               store: sim.directory.appending(components: "priya", "store.sqlite"))
        let replica = await reopened.store.replica
        #expect(replica == version.anchor?.replica)
        let again = Self.naming(reopened, versions)
        defer { again.following.cancel() }
        let kept = await again.queue.pendingVersions()
        #expect(kept == [version])
        try await sim.settle()
        try await Self.drained(again.queue, sim)
        try await sim.expectConverged()
        let named = try #require(versions.versions(of: sim.documentID).first)
        let anchor = try #require(version.anchor)
        let log = await server.log(sim.documentID)
        #expect(named.id == version.id && named.serverSeq == Self.landing(of: anchor, in: log))
        let left = try await reopened.store.pendingCalls(kind: VersionQueue.callKind)
        #expect(left.isEmpty)
    }

    /// Merge: versions named between offline edits on two clients change nothing about what the
    /// outbox sends -- every client and the server hash alike, and Priya's changes are in the log
    /// in the order she made them.
    @Test(arguments: PushMode.allCases) func theQueuedCallLeavesTheOutboxOrderAlone(mode: PushMode) async throws {
        let sim = try await Simulation(name: "history-outbox-order-\(mode)", seed: Simulation.seed(2403), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let server = try #require(sim.server)
        let versions = SimVersionService(server: server)
        let priya = try await sim.addClient("priya", gateway: mode.gateway)
        let tom = try await sim.addClient("tom", gateway: mode.gateway)
        let naming = Self.naming(priya, versions)
        defer { naming.following.cancel() }
        let shapes = try await Workload.createShapes(tom, count: 8)
        try await sim.settle()
        priya.goOffline()
        tom.goOffline()
        var random = sim.random.fork(26)
        for round in 0..<4 {
            for _ in 0..<5 {
                await Workload.randomEdit(priya, shapes, &random)
                await Workload.randomEdit(tom, shapes, &random)
            }
            await naming.queue.save(name: "Round \(round)")
        }
        #expect(naming.queue.pending.count == 4)
        sim.advance(by: .seconds(2 * 3600))
        tom.goOnline()
        priya.goOnline()
        try await sim.settle()
        try await Self.drained(naming.queue, sim)
        try await sim.expectConverged()
        let log = await server.log(sim.documentID)
        let replica = await priya.store.replica
        let mine = log.filter { $0.change.replica == replica }.map(\.change.label)
        let order = priya.performed.filter { Set(mine).contains($0) }
        #expect(mine == order, "the outbox went up in the order it was made")
        let named = versions.versions(of: sim.documentID)
        #expect(named.map(\.name) == ["Round 3", "Round 2", "Round 1", "Round 0"])
        #expect(named.map(\.serverSeq) == named.map(\.serverSeq).sorted(by: >), "each later name at or after the one before")
    }
}
