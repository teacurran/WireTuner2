import WTProto

/// The address of one register, element or set inside a node: segments from `NodeProps` down,
/// each a field number or, directly after a SEQUENCE field, an element id
/// (docs/spec/crdt-model.adoc, "Field paths and registers").
///
/// Paths order by their canonical encoding compared bytewise, which is the same as comparing
/// segments in order with a prefix first.
public struct RegisterPath: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// Canonical tag of a field-number segment (then the number as a big-endian uint32).
    static let fieldTag: UInt8 = 0x01
    /// Canonical tag of an element segment (then the element id as two big-endian uint64s).
    static let elementTag: UInt8 = 0x02

    /// One step of a path.
    public enum Segment: Hashable, Sendable, CustomStringConvertible {
        case field(UInt32)
        case element(OpID)

        public var description: String {
            switch self {
            case .field(let number): "\(number)"
            case .element(let id): "<\(id)>"
            }
        }
    }

    /// The segments, outermost first.
    public let segments: [Segment]
    /// The canonical encoding the state hash uses (crdt-model.adoc, "Canonical encoding").
    public let canonical: [UInt8]

    /// A path of segments, outermost first; at least one.
    public init(segments: [Segment]) {
        precondition(!segments.isEmpty, "a register path has at least one segment")
        self.segments = segments
        var out: [UInt8] = []
        out.reserveCapacity(segments.count * 5)
        for segment in segments {
            switch segment {
            case .field(let number):
                out.append(Self.fieldTag)
                Bytes.u32(number, into: &out)
            case .element(let id):
                out.append(Self.elementTag)
                Bytes.id(id, into: &out)
            }
        }
        canonical = out
    }

    /// A path of field numbers, outermost first; at least one.
    public init(_ fields: [UInt32]) {
        self.init(segments: fields.map(Segment.field))
    }

    /// The path a wire `FieldPath` names, or nil when it is empty or has an unset segment.
    public init?(_ path: Wiretuner_Doc_V1_FieldPath) {
        var segments: [Segment] = []
        for segment in path.segments {
            switch segment.segment {
            case .field(let number): segments.append(.field(number))
            case .element(let id): segments.append(.element(OpID(counter: id.counter, replica: id.replica)))
            case nil: return nil
            }
        }
        guard !segments.isEmpty else { return nil }
        self.init(segments: segments)
    }

    /// The wire `FieldPath` for this path.
    public var proto: Wiretuner_Doc_V1_FieldPath {
        var path = Wiretuner_Doc_V1_FieldPath()
        path.segments = segments.map { segment in
            var wire = Wiretuner_Doc_V1_PathSegment()
            switch segment {
            case .field(let number):
                wire.field = number
            case .element(let id):
                var element = Wiretuner_Doc_V1_ElementId()
                element.counter = id.counter
                element.replica = id.replica
                wire.element = element
            }
            return wire
        }
        return path
    }

    /// The field numbers of the path, element segments left out.
    public var fields: [UInt32] {
        segments.compactMap { if case .field(let number) = $0 { number } else { nil } }
    }

    /// This path with `field` appended.
    public func child(_ field: UInt32) -> RegisterPath {
        RegisterPath(segments: segments + [.field(field)])
    }

    /// This path with the element segment `id` appended.
    public func element(_ id: OpID) -> RegisterPath {
        RegisterPath(segments: segments + [.element(id)])
    }

    /// The path without its last segment, or nil for a one-segment path.
    public var parent: RegisterPath? {
        segments.count > 1 ? RegisterPath(segments: Array(segments.dropLast())) : nil
    }

    /// The value this path addresses inside an encoded message of the root type (a sparse
    /// `NodeProps`): the records of the last field, reached through the embedded messages of the
    /// others (element segments are transparent: the sparse message holds only the element the
    /// path names), or nil when absent -- the same bytes a `SetFields` carrying `message` writes
    /// into this register.
    public func value(in message: [UInt8]) -> [UInt8]? {
        let fields = self.fields
        guard let last = fields.last else { return nil }
        var current = WireMessage.parse(message)
        for field in fields.dropLast() {
            current = current?.message(field)
        }
        return current?.records(last)
    }

    public static func < (lhs: RegisterPath, rhs: RegisterPath) -> Bool {
        lhs.canonical.lexicographicallyPrecedes(rhs.canonical)
    }

    /// The segments joined by dots, e.g. `150.1.6` or `1000.7.<3:1>.2`.
    public var description: String { segments.map(\.description).joined(separator: ".") }
}
