import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTSync
@testable import WTTestSupport

/// OBJ-036's merge test through TEST-001's simulator (undo.adoc, "Undo in a shared document"):
/// Ana and Ben move one rectangle over the in-process server; Ana's undo leaves Ben's matrix
/// standing, and her redo restores her value only while nobody has written it since.  Every step
/// ends converged on both clients and the server, in both push modes.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(4))) struct UndoScenarioTests {
    static let conditions = LinkConditions(latency: .milliseconds(40), jitter: .milliseconds(20))

    static func tx(_ node: OpID, _ client: SimClient) -> Double {
        Objects.transform(of: node, in: client.state).tx
    }

    /// Moves `node` by `dx` on `client`.
    static func move(_ client: SimClient, _ node: OpID, by dx: Double) async throws {
        try #require(await client.perform(MoveObjects([node], by: Vector(dx: dx, dy: 0))) != nil)
    }

    /// `client`'s undo (or redo), sent at once; the emitted change, nil for a step that wrote nothing.
    static func undo(_ client: SimClient, redo: Bool = false) async throws -> Wiretuner_Doc_V1_Change? {
        let change = redo ? try await client.document.redo() : try await client.document.undo()
        await client.client.localChangesAvailable()
        return change
    }

    @Test(arguments: PushMode.allCases) func aRemoteMoveStandsAgainstUndoAndRedoOnlyRestoresAnUntouchedValue(mode: PushMode) async throws {
        let sim = try await Simulation(name: "undo-moves-\(mode)", seed: Simulation.seed(3601), scale: 0.005)
        defer { Task { await sim.shutdown() } }
        let ana = try await sim.addClient("ana", gateway: mode.gateway, conditions: Self.conditions)
        let ben = try await sim.addClient("ben", gateway: mode.gateway, conditions: Self.conditions)
        let rect = try #require(try await Workload.createShapes(ana, count: 1).first)
        try await sim.settle()
        let start = Self.tx(rect, ana)

        // A moves, B moves, A undoes: B's matrix stands, and the redo item still appears.
        try await Self.move(ana, rect, by: 10)
        try await sim.settle()
        try await Self.move(ben, rect, by: 20)
        try await sim.settle()
        #expect(try await Self.undo(ana) == nil, "a partial undo writes nothing")
        #expect(ana.document.canRedo)
        try await sim.settle()
        try await sim.expectConverged()
        #expect(Self.tx(rect, ana) == start + 30 && Self.tx(rect, ben) == start + 30)

        // A moves and undoes; nobody writes again: A's redo restores A's value everywhere.
        try await Self.move(ana, rect, by: 5)
        try await sim.settle()
        #expect(try await Self.undo(ana) != nil)
        try await sim.settle()
        #expect(Self.tx(rect, ben) == start + 30)
        #expect(try await Self.undo(ana, redo: true) != nil)
        try await sim.settle()
        try await sim.expectConverged()
        #expect(Self.tx(rect, ana) == start + 35 && Self.tx(rect, ben) == start + 35)

        // A moves and undoes; B writes again: A's redo leaves B's value.
        try await Self.move(ana, rect, by: 5)
        try await sim.settle()
        #expect(try await Self.undo(ana) != nil)
        try await sim.settle()
        try await Self.move(ben, rect, by: 100)
        try await sim.settle()
        #expect(try await Self.undo(ana, redo: true) == nil)
        try await sim.settle()
        try await sim.expectConverged()
        #expect(Self.tx(rect, ana) == start + 135 && Self.tx(rect, ben) == start + 135)
    }
}
