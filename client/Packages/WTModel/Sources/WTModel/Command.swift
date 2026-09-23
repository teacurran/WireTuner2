import WTCRDT
import WTProto

/// The ops of one local change being built (docs/spec/crdt-model.adoc, "Operations"): op `i`
/// takes the counter after the counters the ops before it took, so `append` returns each op's id
/// -- the id of a node a `CreateNode` makes, or of the first element or character an insert makes
/// -- and later ops of the same change can refer to it.
public struct ChangeBuilder: Sendable {
    /// The replica making the change.
    public let replica: UInt64
    /// The counter of the change's first op.
    public let startCounter: UInt64
    /// The counter the next appended op takes.
    public private(set) var nextCounter: UInt64
    /// The ops so far, in order.
    public private(set) var ops: [Wiretuner_Doc_V1_Op] = []

    /// A builder for a change of `replica` whose first op takes `startCounter`.
    public init(replica: UInt64, startCounter: UInt64) {
        self.replica = replica
        self.startCounter = startCounter
        nextCounter = startCounter
    }

    /// Appends `op` and returns its id.
    @discardableResult
    public mutating func append(_ op: Wiretuner_Doc_V1_Op) -> OpID {
        let id = OpID(counter: nextCounter, replica: replica)
        ops.append(op)
        nextCounter &+= EngineState.counters(op)
        return id
    }
}

/// How an undo step may absorb the next one (docs/_includes/objects/undo.adoc, "What counts as one
/// action").
public enum UndoCoalescing: Sendable, Hashable {
    /// The command is its own undo step (unless a group is open, `Document.beginGroup`).
    case none
    /// Typing into the TEXT field `field` of `node`: consecutive typing joins one step until a word
    /// ends (`endsWord`: this keystroke typed a space, punctuation or a newline) or the user pauses
    /// for a second.
    case typing(node: OpID, field: RegisterPath, endsWord: Bool)
    /// A keyed text edit (TYPE-002, creating-text.adoc "Undo grouping of typing"): the change
    /// joins the open undo step when that step is open under `joins` (and the typing pause has not
    /// passed), and leaves its step open under `opens` (nil closes it).  The text commands key
    /// each keystroke by the character it continues from, so moving the caret, a word boundary,
    /// switching between typing and deleting or any other command starts a new step.
    case text(joins: CoalesceKey?, opens: CoalesceKey?)
}

/// A user action that writes to the document (docs/spec/client.adoc, "Undo"): it builds the ops
/// of one change against the current state; `Document.perform` numbers, applies, persists and
/// records it, and the change's label is the undo menu's title.
public protocol Command: Sendable {
    /// What the action is called in the Edit menu and history: "Move 3 Objects".
    var label: String { get }
    /// Whether the undo step may join its neighbours.
    var coalescing: UndoCoalescing { get }
    /// Whether the change is an undo step at all: false for a new document's template
    /// (`DocumentTemplate`), which is part of the document rather than something the user did.
    var recordsUndo: Bool { get }
    /// Appends the change's ops to `builder`, reading `state` (the merged state before the
    /// change).  Appending nothing performs nothing.
    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws
}

extension Command {
    public var coalescing: UndoCoalescing { .none }
    public var recordsUndo: Bool { true }
}

/// A command of fixed ops, for callers that already hold them (tools emitting one change per
/// drag, tests).  Ops that refer to other ops of the same change must be built with a
/// `ChangeBuilder` instead, since their ids depend on the change's start counter.
public struct OpsCommand: Command {
    public let label: String
    public let ops: [Wiretuner_Doc_V1_Op]
    public let coalescing: UndoCoalescing

    public init(_ label: String, ops: [Wiretuner_Doc_V1_Op], coalescing: UndoCoalescing = .none) {
        self.label = label
        self.ops = ops
        self.coalescing = coalescing
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for op in ops {
            builder.append(op)
        }
    }
}
