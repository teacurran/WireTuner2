/// A value and the op that wrote it.
public struct Stamped<Value: Hashable & Sendable>: Hashable, Sendable {
    public let value: Value
    public let op: OpID

    public init(_ value: Value, _ op: OpID) {
        self.value = value
        self.op = op
    }
}

/// A last-writer-wins register outside the field-path registers: a node's `deleted` flag, a
/// sequence element's position and `deleted` flag (docs/spec/crdt-model.adoc, "Merge rules").
/// Like a register it retains every write, so the conflict review can show the losing ones.
public struct Cell<Value: Hashable & Sendable>: Hashable, Sendable {
    /// The winning write: the greatest OpId.
    public private(set) var current: Stamped<Value>
    /// Every write, in arrival order.
    public private(set) var writes: [Stamped<Value>]

    init(_ value: Value, _ op: OpID) {
        current = Stamped(value, op)
        writes = [current]
    }

    /// Applies a write by the last-writer-wins rule; a replay of an op already written is ignored.
    mutating func write(_ value: Value, _ op: OpID) {
        guard !writes.contains(where: { $0.op == op }) else { return }
        writes.append(Stamped(value, op))
        if op > current.op {
            current = Stamped(value, op)
        }
    }

    /// The writes that do not hold the cell, in OpId order.
    public var losing: [Stamped<Value>] {
        writes.filter { $0.op != current.op }.sorted { $0.op < $1.op }
    }
}
