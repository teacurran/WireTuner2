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

    /// One record: field number, wire type, and where the record and its payload start and end.
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
