/// A protobuf wire writer for the encodings the engine produces itself -- snapshots, inverse ops'
/// values, cleared mark values -- field by field in the order written, so both engines emit the
/// same bytes (wt-crdt's `WireWriter` is this type in Java).  Proto3 defaults (a zero scalar, an
/// empty string) are left out unless a caller asks for them.
struct WireWriter {
    private(set) var bytes: [UInt8] = []

    mutating func raw(_ data: [UInt8]) {
        bytes.append(contentsOf: data)
    }

    mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: value) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }

    mutating func tag(_ field: UInt32, _ wireType: Int) {
        varint(UInt64(field) << 3 | UInt64(wireType))
    }

    /// A VARINT field; zero is left out unless `always`.
    mutating func varintField(_ field: UInt32, _ value: UInt64, always: Bool = false) {
        guard value != 0 || always else { return }
        tag(field, WireMessage.varint)
        varint(value)
    }

    /// A FIXED64 field (little-endian); zero is left out.
    mutating func fixed64Field(_ field: UInt32, _ value: UInt64) {
        guard value != 0 else { return }
        tag(field, WireMessage.fixed64)
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    /// A LEN field holding `payload`, written even when empty (message presence).
    mutating func lenField(_ field: UInt32, _ payload: [UInt8]) {
        tag(field, WireMessage.len)
        varint(UInt64(payload.count))
        bytes.append(contentsOf: payload)
    }

    /// A LEN field holding `payload`, left out when empty (a proto3 string or bytes default).
    mutating func bytesField(_ field: UInt32, _ payload: [UInt8]) {
        guard !payload.isEmpty else { return }
        lenField(field, payload)
    }

    /// An `OpId`/`ElementId` message field, written even for the zero id (presence).
    mutating func idField(_ field: UInt32, _ id: OpID) {
        lenField(field, Self.id(id))
    }

    /// An `OpId`/`ElementId` message field, left out for the zero id.
    mutating func optionalIdField(_ field: UInt32, _ id: OpID) {
        guard id != .zero else { return }
        idField(field, id)
    }

    /// The encoding of an `OpId`/`ElementId`: counter (1, varint) and replica (2, fixed64).
    static func id(_ id: OpID) -> [UInt8] {
        var out = WireWriter()
        out.varintField(1, id.counter)
        out.fixed64Field(2, id.replica)
        return out.bytes
    }

    /// A `FieldPath` message: one `PathSegment` per segment (field = 1, element = 2).
    static func path(_ path: RegisterPath) -> [UInt8] {
        var out = WireWriter()
        for segment in path.segments {
            var inner = WireWriter()
            switch segment {
            case .field(let number):
                inner.varintField(1, UInt64(number), always: true)
            case .element(let id):
                inner.idField(2, id)
            }
            out.lenField(1, inner.bytes)
        }
        return out.bytes
    }
}
