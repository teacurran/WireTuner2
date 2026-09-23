/// One protobuf message read at the wire level: its records (tag plus payload) in order, without
/// a schema.  The engine walks `SetFields.values` with the merge table this way rather than
/// through generated types, so a field newer than this replica merges and survives unchanged
/// (docs/spec/crdt-model.adoc, "Schema evolution").
struct WireMessage {
    static let varint = 0
    static let fixed64 = 1
    static let len = 2
    static let fixed32 = 5

    private static let maxFieldNumber: UInt64 = 0x1FFF_FFFF

    /// One record: field number, wire type, and where the record and its payload start and end
    /// (for a VARINT record the payload start is its end; the value follows the tag).
    struct Field {
        let number: UInt32
        let wireType: Int
        let start: Int
        let payloadStart: Int
        let end: Int
    }

    private let bytes: [UInt8]
    private let fields: [Field]

    /// Parses `bytes`, or returns nil when they are not a well-formed message (truncated, an
    /// over-long varint, field number 0 or above 2^29-1, a group, an unknown wire type).
    static func parse(_ bytes: [UInt8]) -> WireMessage? {
        var fields: [Field] = []
        var cursor = Cursor(bytes: bytes)
        while !cursor.atEnd {
            let start = cursor.pos
            let tag = cursor.varint()
            let number = tag >> 3
            guard !cursor.failed, number >= 1, number <= maxFieldNumber else { return nil }
            let wireType = Int(tag & 7)
            let payloadStart = cursor.skipPayload(wireType)
            guard !cursor.failed else { return nil }
            fields.append(Field(number: UInt32(number), wireType: wireType, start: start,
                                payloadStart: payloadStart, end: cursor.pos))
        }
        return WireMessage(bytes: bytes, fields: fields)
    }

    /// Whether any record has field number `number`.
    func has(_ number: UInt32) -> Bool {
        fields.contains { $0.number == number }
    }

    /// Every record of `number`, concatenated in order, or nil when there is none.
    func records(_ number: UInt32) -> [UInt8]? {
        var out: [UInt8]?
        for field in fields where field.number == number {
            out = (out ?? []) + bytes[field.start..<field.end]
        }
        return out
    }

    /// The embedded message in field `number`: the payloads of its LEN records concatenated
    /// (protobuf merges repeated occurrences of a message field), or nil when there is none or it
    /// does not parse.
    func message(_ number: UInt32) -> WireMessage? {
        var out: [UInt8]?
        for field in fields where field.number == number && field.wireType == Self.len {
            out = (out ?? []) + bytes[field.payloadStart..<field.end]
        }
        return out.flatMap(Self.parse)
    }

    /// Each LEN record of `number` parsed on its own, in order; nil for one that does not parse.
    /// The elements an `ElementInsert` carries are the occurrences of the SEQUENCE field.
    func occurrences(_ number: UInt32) -> [WireMessage?] {
        fields.filter { $0.number == number && $0.wireType == Self.len }
            .map { Self.parse(Array(bytes[$0.payloadStart..<$0.end])) }
    }

    /// The payload of each LEN record of `number`, in order.
    func payloads(_ number: UInt32) -> [[UInt8]] {
        fields.filter { $0.number == number && $0.wireType == Self.len }
            .map { Array(bytes[$0.payloadStart..<$0.end]) }
    }

    /// The payload of the last LEN record of `number`, or nil when there is none.
    func lastPayload(_ number: UInt32) -> [UInt8]? {
        guard let field = fields.last(where: { $0.number == number && $0.wireType == Self.len }) else { return nil }
        return Array(bytes[field.payloadStart..<field.end])
    }

    /// The field number of the last record, or nil for an empty message.
    var lastField: UInt32? { fields.last?.number }

    /// The wire type of the last record, or nil for an empty message.
    var lastWireType: Int? { fields.last?.wireType }

    /// The value bytes of the last record as on the wire (a VARINT's varint, a fixed value's
    /// bytes, a LEN record's payload), or nil for an empty message.
    var lastRecordPayload: [UInt8]? {
        guard let field = fields.last else { return nil }
        guard field.wireType == Self.varint else { return Array(bytes[field.payloadStart..<field.end]) }
        var cursor = Cursor(bytes: Array(bytes[field.start..<field.end]))
        _ = cursor.varint()  // the tag
        return Array(cursor.bytes[cursor.pos...])
    }

    /// The protobuf scalar types by the wire type of one unpacked value.
    private static let varintTypes: Set<String> = ["int32", "int64", "uint32", "uint64", "sint32", "sint64", "bool", "enum"]
    private static let fixed64Types: Set<String> = ["fixed64", "sfixed64", "double"]
    private static let fixed32Types: Set<String> = ["fixed32", "sfixed32", "float"]
    /// Message types a SET may hold, compared as ids.
    static let idTypes: Set<String> = ["wiretuner.doc.v1.ElementId", "wiretuner.doc.v1.OpId"]

    /// The members of the SET field `number` of protobuf `type` (`typeName` for messages), each in
    /// its canonical form (docs/spec/crdt-model.adoc, "Sets"): a string's or bytes' payload; a
    /// varint scalar's value as a big-endian uint64; a fixed-width scalar's little-endian wire
    /// bytes; an ElementId or OpId as its counter and replica, big-endian uint64s.  Packed and
    /// unpacked scalars are both read.  A record of the wrong wire type, or a packed record or id
    /// message that does not parse, holds no members.  Nil for a type a SET cannot hold.
    func members(_ number: UInt32, type: String, typeName: String?) -> [[UInt8]]? {
        let records = fields.filter { $0.number == number }
        var out: [[UInt8]] = []
        if type == "string" || type == "bytes" {
            for field in records where field.wireType == Self.len {
                out.append(Array(bytes[field.payloadStart..<field.end]))
            }
        } else if Self.varintTypes.contains(type) {
            for field in records {
                out += scalars(field, unpacked: Self.varint) { cursor in
                    var member: [UInt8] = []
                    Bytes.u64(cursor.varint(), into: &member)
                    return member
                }
            }
        } else if let width = Self.fixed64Types.contains(type) ? 8 : Self.fixed32Types.contains(type) ? 4 : nil {
            for field in records {
                out += scalars(field, unpacked: width == 8 ? Self.fixed64 : Self.fixed32) { cursor in
                    cursor.take(width)
                }
            }
        } else if type == "message", let typeName, Self.idTypes.contains(typeName) {
            for field in records where field.wireType == Self.len {
                guard let id = Self.parse(Array(bytes[field.payloadStart..<field.end])) else { continue }
                var member: [UInt8] = []
                Bytes.u64(id.lastVarint(1), into: &member)
                Bytes.u64(id.lastFixed64(2), into: &member)
                out.append(member)
            }
        } else {
            return nil
        }
        return out
    }

    // The values of one scalar record: the record itself when it has the unpacked wire type, the
    // packed values when it is LEN and parses completely, else none.
    private func scalars(_ field: Field, unpacked: Int, _ read: (inout Cursor) -> [UInt8]) -> [[UInt8]] {
        let start = field.wireType == unpacked ? field.start : field.payloadStart
        guard field.wireType == unpacked || field.wireType == Self.len else { return [] }
        var cursor = Cursor(bytes: Array(bytes[start..<field.end]))
        if field.wireType == unpacked {
            _ = cursor.varint()  // the tag
            return [read(&cursor)]
        }
        var values: [[UInt8]] = []
        while !cursor.atEnd {
            let value = read(&cursor)
            guard !cursor.failed else { return [] }
            values.append(value)
        }
        return values
    }

    /// The value of the last VARINT record of `number`, or 0.
    func lastVarint(_ number: UInt32) -> UInt64 {
        guard let field = fields.last(where: { $0.number == number && $0.wireType == Self.varint }) else { return 0 }
        var cursor = Cursor(bytes: Array(bytes[field.start..<field.end]))
        _ = cursor.varint()  // the tag
        return cursor.varint()
    }

    /// The value of the last FIXED64 record of `number` (little-endian), or 0.
    func lastFixed64(_ number: UInt32) -> UInt64 {
        guard let field = fields.last(where: { $0.number == number && $0.wireType == Self.fixed64 }) else { return 0 }
        return bytes[field.payloadStart..<field.end].reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// The field number of the last LEN record whose number is in `candidates`, or 0 if none: the
    /// set case of a oneof of messages, as a protobuf parser reads it.
    func lastMessage(of candidates: Set<UInt32>) -> UInt32 {
        fields.last { $0.wireType == Self.len && candidates.contains($0.number) }?.number ?? 0
    }

    /// A read position that latches `failed` instead of throwing.
    private struct Cursor {
        let bytes: [UInt8]
        var pos = 0
        var failed = false

        var atEnd: Bool { pos >= bytes.count }

        /// The next `count` bytes, or none (latching `failed`) when fewer remain.
        mutating func take(_ count: Int) -> [UInt8] {
            guard bytes.count - pos >= count else {
                failed = true
                return []
            }
            pos += count
            return Array(bytes[(pos - count)..<pos])
        }

        mutating func varint() -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while shift < 70 && !atEnd {
                let byte = bytes[pos]
                pos += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 {
                    return value
                }
                shift += 7
            }
            failed = true
            return 0
        }

        // Moves past the record's payload; returns where the payload starts (after a LEN's length).
        mutating func skipPayload(_ wireType: Int) -> Int {
            let length: UInt64
            switch wireType {
            case WireMessage.varint:
                _ = varint()
                return pos
            case WireMessage.fixed64:
                length = 8
            case WireMessage.len:
                length = varint()
            case WireMessage.fixed32:
                length = 4
            default:
                failed = true
                return pos
            }
            let payloadStart = pos
            if failed || length > UInt64(bytes.count - pos) {
                failed = true
            } else {
                pos += Int(length)
            }
            return payloadStart
        }
    }
}
