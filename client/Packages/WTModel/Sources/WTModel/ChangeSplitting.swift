import WTCRDT
import WTProto

// Splitting a command whose change would exceed the server's 10,000 ops per change (crdt-model.adoc,
// "Limits") into consecutive changes (TYPE-008's large text imports; importing-text.adoc, "Server").
// Unlike `SetUnitsPerEm`, whose ops name only nodes that exist, a text import refers to the block
// and the characters it creates, whose ids come from the change's counters.  The whole change is
// built once, as the document replica's next change, and cut into slices: performed in order with
// nothing in between -- one undo group, on the model's actor, as a change group always is -- the
// parts carry exactly its ops and ids.  A part that finds itself at another counter rebuilds the
// whole command against the planned state with its builder started as many counters earlier as the
// parts before it took, and keeps its slice (the ids still line up; positions drawn at random by the
// command may differ from the plan's).

/// Splits commands into change groups.
public enum ChangeSplitting {
    /// The server's limit on ops in one change.
    public static let opLimit = 10_000

    /// `command` as the changes to perform in order in one undo group: itself when its change fits
    /// `limit` ops, else parts labelled "<label> [i/n]" of at most `limit` ops each.  With
    /// `replica` (the document's), the whole change is built once now, as that replica's next
    /// change, and each part performed as planned appends its slice as built; a part performed at
    /// another counter rebuilds instead.
    public static func split(_ command: any Command, in state: EngineState, replica: UInt64? = nil, limit: Int = opLimit) throws -> [any Command] {
        let start = state.clock.peek
        var probe = ChangeBuilder(replica: replica ?? 1, startCounter: start)
        try command.execute(&probe, state: state)
        let count = probe.ops.count
        guard count > limit, limit > 0 else { return [command] }
        let planned = replica.map { (replica: $0, start: start, ops: probe.ops) }
        let slices = stride(from: 0, to: count, by: limit).map { $0..<min($0 + limit, count) }
        return slices.enumerated().map { index, slice in
            let before = probe.ops[..<slice.lowerBound].reduce(UInt64(0)) { $0 + EngineState.counters($1) }
            return ChangePart(command: command, state: state, slice: slice, offset: before, planned: planned,
                              label: "\(command.label) [\(index + 1)/\(slices.count)]")
        }
    }
}

/// One slice of a split command.
struct ChangePart: Command {
    let command: any Command
    /// The state the split was planned on (every part builds against it).
    let state: EngineState
    let slice: Range<Int>
    /// Counters the parts before this one took.
    let offset: UInt64
    /// The whole change as built at planning, for the replica and first counter it was built for.
    let planned: (replica: UInt64, start: UInt64, ops: [Wiretuner_Doc_V1_Op])?
    let label: String

    var coalescing: UndoCoalescing { .none }
    /// A part records undo as the whole command would (a document's first change does not).
    var recordsUndo: Bool { command.recordsUndo }

    func execute(_ builder: inout ChangeBuilder, state _: EngineState) throws {
        if let planned, planned.replica == builder.replica, planned.start &+ offset == builder.startCounter {
            for op in planned.ops[slice] { builder.append(op) }
            return
        }
        var whole = ChangeBuilder(replica: builder.replica, startCounter: builder.startCounter &- offset)
        try command.execute(&whole, state: state)
        for op in whole.ops[slice.clamped(to: whole.ops.indices)] { builder.append(op) }
    }
}
