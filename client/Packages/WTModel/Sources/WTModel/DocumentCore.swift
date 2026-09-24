import Foundation
import WTCRDT
import WTProto

/// The state of one open document replica that every backend keeps: the merge state, the
/// replica's identity and seq counter, how far it has applied the server's log, and the undo
/// stack (docs/spec/crdt-model.adoc, "Undo"; docs/spec/offline.adoc).  Its mutations are
/// synchronous so that a backend can apply a change and persist it in one database transaction
/// (`WTSync.LocalStore`); `MemoryBackend` keeps it without persistence.
public struct DocumentCore: Sendable {
    /// The merged state.
    public private(set) var state: EngineState
    /// This replica's id (docs/spec/crdt-model.adoc, "Identifiers").
    public private(set) var replica: UInt64
    /// The seq the next local change takes (1, 2, 3 ... per replica, no gaps).
    public private(set) var nextSeq: UInt64
    /// The highest server sequence applied from the server's log: the next change's causal past.
    public private(set) var lastServerSeq: UInt64
    /// The undo and redo lists.
    public private(set) var undoStack: UndoStack
    /// The newest stable point the server has published to this replica (its horizon,
    /// crdt-model.adoc "Stable points, horizons and collection points"): an undo never names a
    /// tombstone whose delete is stable here, since another replica may have collected it.
    public private(set) var horizon: UInt64

    public init(state: EngineState, replica: UInt64, nextSeq: UInt64 = 1, lastServerSeq: UInt64 = 0,
                undoStack: UndoStack = UndoStack(), horizon: UInt64 = 0) {
        precondition(replica != 0)   // replica 0 is reserved for the well-known nodes
        self.state = state
        self.replica = replica
        self.nextSeq = nextSeq
        self.lastServerSeq = lastServerSeq
        self.undoStack = undoStack
        self.horizon = horizon
    }

    /// Records a stable point the server published; the horizon only moves forward.
    public mutating func advanceHorizon(to stableSeq: UInt64) {
        horizon = max(horizon, stableSeq)
    }

    /// `inverse` without what undoing it may no longer name: the re-insertion of deleted text is
    /// not offered for characters whose tombstones are stable at the horizon (or already
    /// collected), since the re-inserted run would be placed after such a tombstone.
    func offered(_ inverse: Inverse) -> Inverse {
        Inverse(steps: inverse.steps.compactMap { step in
            guard case .textDeleted(let node, let path, let chars) = step else { return step }
            let text = state.text(node, path)
            let kept = chars.filter { char in
                guard let deleter = text?.deletedOp(char.id) else { return false }
                return !state.isStable(deleter, at: horizon)
            }
            return kept.isEmpty ? nil : .textDeleted(node: node, text: path, chars: kept)
        })
    }

    /// How a local change is recorded on the undo stack.
    public struct Recording: Sendable, Hashable {
        /// The open drag group (`Document.beginGroup`), if any.
        public var group: UInt64?
        /// The *Undo levels* preference: the most steps the undo list keeps.
        public var limit: Int
        /// The time of the change: its `wall_time_ms` and the typing pause.
        public var now: Date

        public init(group: UInt64? = nil, limit: Int, now: Date) {
            self.group = group
            self.limit = limit
            self.now = now
        }
    }

    /// What applying a local change, an undo or a redo did: the change applied (nil when an undo
    /// or redo found nothing left to change), the undo edit to persist (nil when the change changed
    /// nothing undoable), and the change as it enters the outbox -- without its local-only writes
    /// (`LocalOnly.strip`, crdt-model.adoc "Local-only fields") -- with the local-only registers it
    /// wrote, which a persistent backend keeps beside the outbox so they survive a relaunch.
    public struct Outcome: Sendable {
        public var change: Wiretuner_Doc_V1_Change?
        public var edit: UndoEdit?
        /// `change` without its local-only writes: what the outbox keeps and the server receives.
        public var outbox: Wiretuner_Doc_V1_Change?
        /// The local-only registers `change` wrote, as the writes now holding them.
        public var localOnly: [Write] = []

        init(change: Wiretuner_Doc_V1_Change?, edit: UndoEdit?, state: EngineState) {
            self.change = change
            self.edit = edit
            outbox = change.map { state.localOnlyCarried ? LocalOnly.strip($0, schema: state.schema) : $0 }
            localOnly = change == nil ? [] : state.localOnlyWrites
        }
    }

    /// Builds `command`'s change against the current state, applies it locally and records its
    /// inverse; nil when the command appended no ops.  Throws only what the command throws, before
    /// anything changed.
    public mutating func perform(_ command: any Command, recording: Recording) throws -> Outcome? {
        var builder = ChangeBuilder(replica: replica, startCounter: state.clock.peek)
        try command.execute(&builder, state: state)
        guard !builder.ops.isEmpty else { return nil }
        let change = makeChange(label: command.label, startCounter: builder.startCounter, ops: builder.ops, now: recording.now)
        let inverse = state.applyLocal(change)
        let (joining, open): (CoalesceKey?, CoalesceKey?) = switch command.coalescing {
        case .typing(let node, let field, let endsWord) where recording.group == nil:
            (.typing(node: node, field: field), endsWord ? nil : .typing(node: node, field: field))
        case .text(let joins, let opens) where recording.group == nil:
            (joins, opens)
        default:
            (recording.group.map(CoalesceKey.group), recording.group.map(CoalesceKey.group))
        }
        let edit = command.recordsUndo
            ? undoStack.recording(inverse, label: command.label, joining: joining, open: open, now: recording.now, limit: recording.limit)
            : nil
        if let edit {
            undoStack.apply(edit)
        }
        return Outcome(change: change, edit: edit, state: state)
    }

    /// Undoes the top undo step: emits the change restoring what this user wrote where the state
    /// still holds it (skipping whatever someone else has changed since), labelled "Undo <label>",
    /// and moves the step to the redo list with the inverse that redoes it.  When nothing of the
    /// step is left to undo no change is emitted, and the step still moves (undo.adoc: the menu
    /// item still works and the redo item appears).  Nil when the undo list is empty.
    public mutating func undo(recording: Recording) -> Outcome? {
        guard let top = undoStack.undo.last else { return nil }
        let (change, inverse) = reverse(top, verb: "Undo", now: recording.now)
        let edit = UndoEdit.undo(redo: UndoEntry(label: top.label, inverse: inverse, updatedAt: recording.now))
        undoStack.apply(edit)
        return Outcome(change: change, edit: edit, state: state)
    }

    /// Redoes the top redo step, symmetric to `undo`: re-applies where the state still holds the
    /// undone value.  Nil when the redo list is empty.
    public mutating func redo(recording: Recording) -> Outcome? {
        guard let top = undoStack.redo.last else { return nil }
        let (change, inverse) = reverse(top, verb: "Redo", now: recording.now)
        let edit = UndoEdit.redo(undo: UndoEntry(label: top.label, inverse: inverse, updatedAt: recording.now),
                                 limit: recording.limit)
        undoStack.apply(edit)
        return Outcome(change: change, edit: edit, state: state)
    }

    private mutating func reverse(_ entry: UndoEntry, verb: String, now: Date) -> (Wiretuner_Doc_V1_Change?, Inverse) {
        guard var change = state.undoChange(offered(entry.inverse), replica: replica, seq: nextSeq, startCounter: state.clock.peek,
                                            baseServerSeq: lastServerSeq, label: UndoStack.title(verb, entry.label)) else {
            return (nil, Inverse(steps: []))
        }
        change.wallTimeMs = Self.milliseconds(now)
        nextSeq += 1
        let reversal = state.applyLocal(change)
        undoStack.rebase(reversal: reversal, state: state)
        return (change, reversal)
    }

    /// Applies a change from the server's log at `serverSeq`.  The echo of one of this replica's
    /// own changes changes nothing but records its server sequence (the ack).
    public mutating func receive(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64) {
        state.apply(change, serverSeq: serverSeq)
        lastServerSeq = max(lastServerSeq, serverSeq)
    }

    /// Replays a change read back from the local store (`serverSeq` when known); `lastServerSeq`
    /// is the store's own record, so it does not move.
    public mutating func replay(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64?) {
        state.apply(change, serverSeq: serverSeq)
    }

    /// Restores the local-only registers a persistent backend kept (`Outcome.localOnly`) after the
    /// shared state was loaded or replaced: they are in no change and no snapshot.
    public mutating func restoreLocalOnly(_ writes: [Write]) {
        state.restoreLocalOnly(writes)
    }

    /// Records the server sequence of this replica's change `seq` (its ack).
    public mutating func acknowledge(seq: UInt64, serverSeq: UInt64) {
        state.acknowledge(replica: replica, seq: seq, serverSeq: serverSeq)
    }

    /// Continues as replica `replica` from seq 1 (replica rotation, docs/spec/offline.adoc
    /// "Replica expiry and salvage").
    public mutating func rotate(to replica: UInt64) {
        precondition(replica != 0)   // replica 0 is reserved for the well-known nodes
        self.replica = replica
        nextSeq = 1
    }

    private mutating func makeChange(label: String, startCounter: UInt64, ops: [Wiretuner_Doc_V1_Op], now: Date) -> Wiretuner_Doc_V1_Change {
        var change = Wiretuner_Doc_V1_Change()
        change.replica = replica
        change.seq = nextSeq
        change.startCounter = startCounter
        change.baseServerSeq = lastServerSeq
        change.wallTimeMs = Self.milliseconds(now)
        change.label = label
        change.ops = ops
        nextSeq += 1
        return change
    }

    static func milliseconds(_ date: Date) -> Int64 {
        max(0, Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))
    }
}
