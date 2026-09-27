import Foundation
import Testing
import WTCRDT
import WTModel
@testable import WTTestSupport

/// COLLAB-018's client end-to-end run (branches.adoc; SRV-011's done-when driven through the
/// simulator): a branch edited while its parent advanced is merged; the parent's clients -- and a
/// client joining afterwards, which reads the parent from the server's log alone -- converge on
/// the server's merged state, and every branch change is in the parent's log.
@Suite(.serialized) @MainActor struct BranchMergeScenarioTests {
    @Test func aBranchMergedIntoAnAdvancedParentConvergesWithTheServer() async throws {
        let sim = try await Simulation(name: "branch-merge", seed: Simulation.seed(1818), scale: 0.005)
        defer { Task { await sim.shutdown() } }
        let server = try #require(sim.server)
        let priya = try await sim.addClient("priya", user: SimUser(id: "u-priya", name: "Priya"))
        let tom = try await sim.addClient("tom", user: SimUser(id: "u-tom", name: "Tom"))
        let shapes = try await Workload.createShapes(tom, count: 6)
        try await sim.settle()
        let token = await server.issueToken(for: priya.user.id, lifetime: .seconds(3600))
        let branch = "doc-branch-merge"
        _ = try await server.createBranch(.with {
            $0.parentDocumentID = sim.documentID
            $0.branchDocumentID = branch
            $0.name = "Autumn palette"
        }, token: token, device: priya.device)
        let onBranch = try await sim.addClient("priya-branch", user: priya.user, device: "priya-branch", document: branch)
        try await sim.settle([onBranch])
        // The branch and the parent both move on: the same shapes edited on each side.
        var random = SimRandom(seed: 18)
        for index in 0..<40 {
            _ = await Workload.randomEdit(onBranch, shapes, &random)
            _ = await Workload.randomEdit(index.isMultiple(of: 2) ? priya : tom, shapes, &random)
        }
        try await sim.settle([priya, tom, onBranch])
        try await sim.expectConverged([onBranch], document: branch)
        try await sim.expectConverged([priya, tom])
        let before = await server.log(sim.documentID).count
        let merged = try #require(try await server.mergeBranch(branch, token: token, device: priya.device))
        #expect(merged.lowerBound == UInt64(before) + 1 && merged.count > 0, "the branch's changes are replayed at the parent's head")
        try await sim.settle([priya, tom])
        try await sim.expectConverged([priya, tom])
        // A client that joins now bootstraps from the server's log and reads the same state.
        let late = try await sim.addClient("late", user: SimUser(id: "u-late", name: "Late"))
        try await sim.settle([priya, tom, late])
        try await sim.expectConverged([priya, tom, late])
        let labels = Set(await server.log(sim.documentID).map(\.change.label))
        #expect(Set(onBranch.performed).isSubset(of: labels), "every branch change reached the parent")
    }
}
