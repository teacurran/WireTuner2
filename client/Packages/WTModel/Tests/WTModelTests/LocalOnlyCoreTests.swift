import Foundation
import Testing
import WTCRDT
@testable import WTModel
import WTProto

/// Local-only fields through `DocumentCore` (crdt-model.adoc, "Local-only fields"): a command's
/// local-only writes apply here, leave the outbox, come back with `restoreLocalOnly`, and read
/// through `props` over a value an older replica merged into the shared state.
@Suite struct LocalOnlyCoreTests {
    static let zoom = RegisterPath([2, 40, 1])
    static let recording = DocumentCore.Recording(limit: 100, now: Date(timeIntervalSince1970: 1_000))

    static func zoomTo(_ magnification: Double) -> OpsCommand {
        OpsCommand("Zoom", ops: [Ops.set(WellKnown.settings, [zoom, RegisterPath([2, 7])], values: SettingsFields.values {
            $0.view.magnification = magnification
            $0.guidesLocked = true
        })])
    }

    @Test func theOutboxLeavesLocalOnlyWritesBehind() throws {
        var core = DocumentCore(state: EngineState(), replica: 1)
        let performed = try core.perform(Self.zoomTo(4), recording: Self.recording)
        let outcome = try #require(performed)
        let change = try #require(outcome.change)
        let outbox = try #require(outcome.outbox)
        #expect(change.ops[0].set.paths.count == 2)
        #expect(outbox.ops[0].set.paths.map(RegisterPath.init) == [RegisterPath([2, 7])])
        #expect(!outbox.ops[0].set.values.settings.hasView)
        #expect(outcome.localOnly.map(\.path) == [Self.zoom])
        #expect(core.state.props(WellKnown.settings).settings.view.magnification == 4)

        // Undo restores the zoom here and sends nothing of it.
        let undone = core.undo(recording: Self.recording)
        let undo = try #require(undone)
        #expect(core.state.props(WellKnown.settings).settings.view.magnification == 0)
        #expect(undo.localOnly.map(\.path) == [Self.zoom])
        #expect(undo.outbox?.ops.allSatisfy { !$0.set.paths.map(RegisterPath.init).contains(Self.zoom) } == true)
        let redone = core.redo(recording: Self.recording)
        let redo = try #require(redone)
        #expect(redo.localOnly.count == 1 && core.state.props(WellKnown.settings).settings.view.magnification == 4)

        // Another replica receiving the outbox has the shared write only; the hashes agree.
        var other = DocumentCore(state: EngineState(), replica: 2)
        other.receive(outbox, serverSeq: 1)
        other.receive(undo.outbox!, serverSeq: 2)
        other.receive(redo.outbox!, serverSeq: 3)
        core.acknowledge(seq: 1, serverSeq: 1)
        #expect(other.state.props(WellKnown.settings).settings.view.magnification == 0)
        #expect(other.state.props(WellKnown.settings).settings.guidesLocked)
        #expect(other.state.stateHash == core.state.stateHash)
    }

    @Test func restoredLocalOnlyRegistersReadAgain() throws {
        var core = DocumentCore(state: EngineState(), replica: 1)
        let performed = try core.perform(Self.zoomTo(2), recording: Self.recording)
        let outcome = try #require(performed)
        var reopened = DocumentCore(state: try Snapshot.decode(Snapshot.encode(core.state, serverSeq: 0), schema: .generated), replica: 1)
        #expect(reopened.state.props(WellKnown.settings).settings.view.magnification == 0)
        reopened.restoreLocalOnly(outcome.localOnly)
        #expect(reopened.state.props(WellKnown.settings).settings.view.magnification == 2)
        // A command without local-only writes reports none; no change, no outbox.
        let locked = try reopened.perform(OpsCommand("Lock", ops: [Ops.set(WellKnown.settings, [RegisterPath([2, 7])],
                                                                            values: SettingsFields.values { $0.guidesLocked = true })]),
                                          recording: Self.recording)
        let plain = try #require(locked)
        #expect(plain.localOnly.isEmpty && plain.outbox == plain.change)
    }

    @Test func aLocalValueStandsOverOneAnOlderReplicaShared() throws {
        // A snapshot from before local-only paths were ignored holds the zoom as a shared register.
        var legacy = EngineState(schema: Schema.generated.with("wiretuner.doc.v1.SettingsProps", row: Self.shared(40)))
        legacy.apply(Self.change(9, 1, Ops.set(WellKnown.settings, [Self.zoom, RegisterPath([2, 40, 5])], values: SettingsFields.values {
            $0.view.magnification = 8
            $0.view.snapToPoint = true
        })))
        var core = DocumentCore(state: try Snapshot.decode(Snapshot.encode(legacy, serverSeq: 0), schema: .generated), replica: 1)
        #expect(core.state.props(WellKnown.settings).settings.view.magnification == 8)
        _ = try core.perform(Self.zoomTo(3), recording: Self.recording)
        #expect(core.state.props(WellKnown.settings).settings.view.magnification == 3)
        // Cleared here, the shared value no longer shows; the other shared field still does.
        _ = try core.perform(OpsCommand("Clear", ops: [Ops.set(WellKnown.settings, [Self.zoom], values: Wiretuner_Doc_V1_NodeProps())]),
                             recording: Self.recording)
        let view = core.state.props(WellKnown.settings).settings.view
        #expect(view.magnification == 0 && view.snapToPoint)
    }

    static func shared(_ number: Int) -> Schema.FieldPolicy {
        let row = Schema.generated.field("wiretuner.doc.v1.SettingsProps", number)!
        return Schema.FieldPolicy(fieldNumber: row.fieldNumber, name: row.name, policy: row.policy, onDangling: row.onDangling,
                                  localOnly: false, type: row.type, repeated: row.repeated, typeName: row.typeName,
                                  elementMessage: row.elementMessage, oneof: row.oneof)
    }

    static func change(_ replica: UInt64, _ start: UInt64, _ ops: Wiretuner_Doc_V1_Op...) -> Wiretuner_Doc_V1_Change {
        var change = Wiretuner_Doc_V1_Change()
        change.replica = replica
        change.seq = 1
        change.startCounter = start
        change.ops = ops
        return change
    }
}
