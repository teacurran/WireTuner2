import WTProto

/// An operation id (docs/spec/crdt-model.adoc, "Identifiers"): a Lamport `counter` and the
/// `replica` that created the operation.  The order -- counter, then replica, both unsigned -- is
/// the total order that decides every last-writer-wins tie.  It never involves wall-clock time.
public struct OpID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var counter: UInt64
    public var replica: UInt64

    /// The zero id: the document root, and "no id" in wire messages.
    public static let zero = OpID(counter: 0, replica: 0)

    public init(counter: UInt64, replica: UInt64) {
        self.counter = counter
        self.replica = replica
    }

    /// The id of a well-known node (`WellKnown` in doc/v1/node.proto): replica 0.
    public static func wellKnown(_ counter: UInt64) -> OpID {
        OpID(counter: counter, replica: 0)
    }

    /// Converts the wire message.
    public init(_ id: Wiretuner_Doc_V1_OpId) {
        self.init(counter: id.counter, replica: id.replica)
    }

    /// The wire message for this id.
    public var proto: Wiretuner_Doc_V1_OpId {
        var id = Wiretuner_Doc_V1_OpId()
        id.counter = counter
        id.replica = replica
        return id
    }

    public static func < (lhs: OpID, rhs: OpID) -> Bool {
        (lhs.counter, lhs.replica) < (rhs.counter, rhs.replica)
    }

    /// `counter:replica`, as the spec writes ids.
    public var description: String { "\(counter):\(replica)" }
}
