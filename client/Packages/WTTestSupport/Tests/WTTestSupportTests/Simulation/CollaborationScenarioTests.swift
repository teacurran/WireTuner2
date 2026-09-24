import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
import WTSync
@testable import WTTestSupport

/// Collaboration scenarios against the in-process server: a role lowered with unsent work
/// (COLLAB-014, sharing.adoc "When your access changes mid-session") and offline work kept on a
/// branch made on this Mac (COLLAB-017, branches.adoc "Offline-created branch").
@MainActor
@Suite(.serialized, .timeLimit(.minutes(8))) struct CollaborationScenarioTests {
    /// Performs edits through `client` until `count` changes were made; returns their labels.
    static func edits(_ client: SimClient, _ shapes: [OpID], count: Int, _ random: inout SimRandom) async -> [String] {
        let start = client.performed.count
        while client.performed.count - start < count {
            await Workload.randomEdit(client, shapes, &random)
        }
        return Array(client.performed[start...])
    }

    /// Lowering a person with 500 unsent changes to viewer freezes the outbox and sends nothing;
    /// *Save as a Copy* yields a document whose state is the local state before the freeze; raising
    /// the role again re-enables editing without reopening, and both converge.
    @Test(arguments: PushMode.allCases) func aLoweredRoleWithUnsentWorkSavesACopy(mode: PushMode) async throws {
        let sim = try await Simulation(name: "access-\(mode)", seed: Simulation.seed(1414), scale: 0.005)
        defer { Task { await sim.shutdown() } }
        let server = try #require(sim.server)
        let ana = try await sim.addClient("ana", gateway: mode.gateway)
        let ben = try await sim.addClient("ben", gateway: mode.gateway)
        let shapes = try await Workload.createShapes(ana, count: 10)
        try await sim.settle()
        let access = AccessController(store: ben.store, client: ben.client, sync: SimServerTransport(server: server, device: ben.device),
                                      copies: SimCopyTransport(server: server, device: ben.device, link: ben.link), tokens: ben.tokens)
        await access.start()
        var random = sim.random.fork(14)
        ben.goOffline()
        let unsent = await Self.edits(ben, shapes, count: 500, &random)
        _ = await Self.edits(ana, shapes, count: 20, &random)
        try await sim.grant(.viewer, to: ben.user)
        try await sim.settle([ana])
        ben.goOnline()
        try await ben.waitFor("read-only") { $0 == .readOnly(.role) }
        let head = await server.head(sim.documentID)
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            let frozen = await access.status.unsent
            let applied = await ben.store.lastServerSeq
            if frozen == 500 && applied >= head { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await access.status.unsent == 500)
        #expect(await ben.store.lastServerSeq == head, "a viewer keeps receiving")
        // Nothing of the frozen work reached the shared document, and no local change is taken.
        let labels = Set(await server.log(sim.documentID).map(\.change.label))
        #expect(labels.isDisjoint(with: unsent))
        #expect(await ben.perform(SetNameOrNote([shapes[0]], .name, "refused")) == nil)
        let before = await ben.store.read { $0.stateHash }
        let copyID = try await access.saveAsCopy(name: "Ben's version", newDocumentID: "copy-\(mode)")
        ben.noteDiscarded(unsent)
        // The copy, opened on another Mac, holds the local state as it was before the freeze.
        let copy = try await sim.addClient("ben-copy", user: ben.user, document: copyID, gateway: mode.gateway)
        try await sim.settle([copy])
        #expect(copy.state.stateHash == before)
        try await sim.expectConverged([copy], document: copyID)
        // Ben's document, still read-only, reverts to the shared state.
        let shared = await server.head(sim.documentID)
        let reverted = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < reverted {
            let outbox = try await ben.store.outboxCount()
            let applied = await ben.store.lastServerSeq
            if outbox == 0 && applied == shared { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await ben.document.settle()
        #expect(ben.state.stateHash == (await server.state(sim.documentID)).stateHash)
        // Raised again: editable without reopening; a new change uploads and everyone converges.
        try await sim.grant(.editor, to: ben.user)
        let editable = ContinuousClock.now + .seconds(30)
        while await !access.status.editable, ContinuousClock.now < editable {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await access.status == AccessController.Status())
        _ = await Self.edits(ben, shapes, count: 5, &random)
        try await sim.settle([ana, ben])
        try await sim.expectConverged([ana, ben])
        await access.stop()
    }

    /// Unsent changes kept on a branch while offline: the parent reverts, the branch is not on the
    /// server until the network is back, then `CreateBranch` takes the first 1,000 and the branch's
    /// session the rest; the branch's server state equals the local branch, and the parent's local
    /// state equals the remote head.
    @Test(arguments: PushMode.allCases) func offlineWorkKeptOnABranch(mode: PushMode) async throws {
        let sim = try await Simulation(name: "branch-\(mode)", seed: Simulation.seed(1717), scale: 0.005)
        defer { Task { await sim.shutdown() } }
        let server = try #require(sim.server)
        let ana = try await sim.addClient("ana", gateway: mode.gateway)
        let ben = try await sim.addClient("ben", gateway: mode.gateway)
        let shapes = try await Workload.createShapes(ana, count: 10)
        try await sim.settle()
        var random = sim.random.fork(17)
        ben.goOffline()
        let unsent = await Self.edits(ben, shapes, count: mode == .native ? 5_000 : 1_500, &random)
        _ = await Self.edits(ana, shapes, count: 30, &random)
        try await sim.settle([ana])
        // Offline, Ben keeps his changes on a branch: the branch store takes them, the parent reverts.
        let local = await ben.store.read { $0.stateHash }
        let entry = try await BranchStores.keepChangesOnBranch(parent: ben.store, name: "Ben's offline edits",
                                                                root: sim.directory.appending(component: "branches"))
        try await ben.client.discardUnsent()
        ben.noteDiscarded(unsent)
        #expect(try await ben.store.outboxCount() == 0)
        let branch = try await sim.addClient("ben-branch", user: ben.user, device: "device-ben", hardware: "MAC-ben", store: entry.url,
                                             document: entry.documentID, gateway: mode.gateway, start: false)
        branch.goOffline()
        #expect(branch.state.stateHash == local)
        let creator = BranchCreator(transport: SimCopyTransport(server: server, device: branch.device, link: branch.link), tokens: branch.tokens)
        await #expect(throws: (any Error).self) { try await creator.ensureOnServer(branch.store) }
        #expect(try await branch.store.branchMeta()?.onServer == false)
        #expect(await !server.hasDocument(entry.documentID))
        // Back online: the branch is created, its session sends the rest.
        ben.goOnline()
        branch.link.heal()
        #expect(try await creator.ensureOnServer(branch.store))
        #expect(await server.parent(of: entry.documentID) == sim.documentID)
        await branch.start()
        try await sim.settle()
        try await sim.expectConverged([ana, ben])
        try await sim.expectConverged([branch], document: entry.documentID)
        #expect(branch.state.stateHash == local)
        #expect(ben.state.stateHash == (await server.state(sim.documentID)).stateHash)
        let branchLabels = Set(await server.log(entry.documentID).map(\.change.label))
        #expect(branchLabels.isSuperset(of: unsent))
        #expect(await server.stats.branches == 1)
    }
}
