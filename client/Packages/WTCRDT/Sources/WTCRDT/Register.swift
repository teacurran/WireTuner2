/// A last-writer-wins register (docs/spec/crdt-model.adoc, "Merge rules"): a value and the id of
/// the operation that wrote it.  `value` is nil when the register holds *unset* -- a clear
/// competes with concurrent writes like any other value.  Otherwise it is the field's protobuf
/// records exactly as the operation carried them (tag and payload, every occurrence in order), so
/// a reader decodes it with the generated message types and a field newer than this replica is
/// kept byte for byte.
public struct Register: Hashable, Sendable, CustomStringConvertible {
    public var value: [UInt8]?
    public var op: OpID

    public init(value: [UInt8]?, op: OpID) {
        self.value = value
        self.op = op
    }

    /// Whether the register holds a value rather than unset.
    public var isSet: Bool { value != nil }

    public var description: String { "\(value.map(Bytes.hex) ?? "unset")@\(op)" }
}

/// One register write as the change log retains it (docs/spec/crdt-model.adoc, "Merge rules"):
/// the node, the register, the value (nil = unset) and the writing operation.  Losing writes stay
/// in the log so the conflict review can show them and offer them back.
public struct Write: Hashable, Sendable, CustomStringConvertible {
    public var node: OpID
    public var path: RegisterPath
    public var value: [UInt8]?
    public var op: OpID

    public init(node: OpID, path: RegisterPath, value: [UInt8]?, op: OpID) {
        self.node = node
        self.path = path
        self.value = value
        self.op = op
    }

    public var description: String { "\(node)/\(path)=\(value.map(Bytes.hex) ?? "unset")@\(op)" }
}
