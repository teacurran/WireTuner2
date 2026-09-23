import WTProto

/// The address of one register inside a node: the field numbers from `NodeProps` down to an
/// ATOMIC field (docs/spec/crdt-model.adoc, "Merge policies").  Element segments (inside a
/// SEQUENCE) arrive with CRDT-004; the canonical encoding already reserves their tag.
///
/// Paths order by their canonical encoding compared bytewise, which is the same as comparing
/// field numbers segment by segment with a prefix first.
public struct RegisterPath: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// Canonical tag of a field-number segment (then the number as a big-endian uint32).
    static let fieldTag: UInt8 = 0x01

    /// The field numbers, outermost first.
    public let fields: [UInt32]
    /// The canonical encoding the state hash uses (crdt-model.adoc, "Snapshots").
    public let canonical: [UInt8]

    /// A path of field numbers, outermost first; at least one.
    public init(_ fields: [UInt32]) {
        precondition(!fields.isEmpty, "a register path has at least one field")
        self.fields = fields
        var out: [UInt8] = []
        out.reserveCapacity(fields.count * 5)
        for field in fields {
            out.append(Self.fieldTag)
            Bytes.u32(field, into: &out)
        }
        canonical = out
    }

    /// The register path a wire `FieldPath` names, or nil when it is empty or has a segment that
    /// is not a field number.
    public init?(_ path: Wiretuner_Doc_V1_FieldPath) {
        var fields: [UInt32] = []
        for segment in path.segments {
            guard case .field(let number)? = segment.segment else { return nil }
            fields.append(number)
        }
        guard !fields.isEmpty else { return nil }
        self.init(fields)
    }

    /// The wire `FieldPath` for this path.
    public var proto: Wiretuner_Doc_V1_FieldPath {
        var path = Wiretuner_Doc_V1_FieldPath()
        path.segments = fields.map { field in
            var segment = Wiretuner_Doc_V1_PathSegment()
            segment.field = field
            return segment
        }
        return path
    }

    /// This path with `field` appended.
    public func child(_ field: UInt32) -> RegisterPath {
        RegisterPath(fields + [field])
    }

    /// The value this path addresses inside an encoded message of the root type (a sparse
    /// `NodeProps`): the records of the last field, reached through the embedded messages of the
    /// others, or nil when absent -- the same bytes a `SetFields` carrying `message` writes into
    /// this register.
    public func value(in message: [UInt8]) -> [UInt8]? {
        var current = WireMessage.parse(message)
        for field in fields.dropLast() {
            current = current?.message(field)
        }
        return current?.records(fields[fields.count - 1])
    }

    public static func < (lhs: RegisterPath, rhs: RegisterPath) -> Bool {
        lhs.canonical.lexicographicallyPrecedes(rhs.canonical)
    }

    /// The field numbers joined by dots, e.g. `150.1.6`.
    public var description: String { fields.map(String.init).joined(separator: ".") }
}
