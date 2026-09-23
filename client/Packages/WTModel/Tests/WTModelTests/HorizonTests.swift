import Foundation
import Testing
import WTCRDT
@testable import WTModel
import WTProto

/// Undo does not re-insert deleted text whose tombstones are stable at the replica's horizon
/// (crdt-model.adoc, "Stable points, horizons and collection points").
@Suite struct HorizonTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)

    /// A text block holding "abc" with "b" then "c" deleted, each change acknowledged by the server.
    func typedAndDeleted() throws -> (core: DocumentCore, block: OpID) {
        var core = DocumentCore(state: EngineState(), replica: 7)
        let recording = DocumentCore.Recording(limit: 10, now: Self.now)
        let created = try #require(try core.perform(OpsCommand("Create", ops: [Ops.create(parent: Fixture.layers, position: [0x80], props: Fixture.textBlock())]), recording: recording))
        let block = OpID(counter: created.change!.startCounter, replica: 7)
        let typed = try #require(try core.perform(OpsCommand("Typing", ops: [Ops.textInsert(block, Fixture.text, "abc")]), recording: recording))
        let b = OpID(counter: typed.change!.startCounter + 1, replica: 7)
        let c = OpID(counter: typed.change!.startCounter + 2, replica: 7)
        _ = try core.perform(OpsCommand("Delete b", ops: [Ops.textDelete(block, Fixture.text, first: b, count: 1)]), recording: recording)
        _ = try core.perform(OpsCommand("Delete c", ops: [Ops.textDelete(block, Fixture.text, first: c, count: 1)]), recording: recording)
        for seq in UInt64(1)...4 {
            core.acknowledge(seq: seq, serverSeq: seq)
        }
        return (core, block)
    }

    @Test func undoReinsertsTextWhoseDeleteIsNotStable() throws {
        var (core, block) = try typedAndDeleted()
        #expect(core.horizon == 0)
        core.advanceHorizon(to: 3)
        core.advanceHorizon(to: 2)
        #expect(core.horizon == 3)
        let recording = DocumentCore.Recording(limit: 10, now: Self.now)
        // "Delete c" (server seq 4) is not stable at 3: undoing it brings the c back.
        #expect(core.undo(recording: recording)?.change != nil)
        #expect(core.state.text(block, Fixture.text)?.string == "ac")
        // "Delete b" (server seq 3) is stable at 3: nothing is left to offer, no change is emitted.
        #expect(core.undo(recording: recording)?.change == nil)
        #expect(core.state.text(block, Fixture.text)?.string == "ac")
    }

    @Test func offeredDropsOnlyTheStableCharacters() throws {
        var (core, block) = try typedAndDeleted()
        core.advanceHorizon(to: 3)
        let chars = [DeletedChar(id: OpID(counter: 99, replica: 7), scalar: 65, attributes: [], paragraph: [])]
        let unknown = Inverse.Step.textDeleted(node: block, text: Fixture.text, chars: chars)
        let other = Inverse.Step.created(node: block)
        #expect(core.offered(Inverse(steps: [unknown, other])).steps == [other])
    }
}
