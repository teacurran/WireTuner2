/// A replica's Lamport clock (docs/spec/crdt-model.adoc, "Identifiers"): the next counter is one
/// more than the largest counter this replica has created *or seen*.
public struct LamportClock: Sendable, Hashable {
    /// The largest counter created or seen so far.
    public private(set) var max: UInt64

    /// A clock resumed at `max` (0: nothing created or seen, the next counter is 1).
    public init(max: UInt64 = 0) {
        self.max = max
    }

    /// The counter the next created operation takes, without taking it.
    public var peek: UInt64 { max &+ 1 }

    /// Records a counter seen in an operation, created here or elsewhere.
    public mutating func observe(_ counter: UInt64) {
        max = Swift.max(max, counter)
    }

    /// Takes `count` consecutive counters for a change of `count` operations and returns the
    /// first; the change's op `i` has counter `first + i`.
    public mutating func allocate(_ count: Int) -> UInt64 {
        precondition(count >= 1, "a change has at least one operation")
        let first = max &+ 1
        max &+= UInt64(count)
        return first
    }
}
