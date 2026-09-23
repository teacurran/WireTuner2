import Foundation
import WTCRDT
import WTModel

/// The bytes of an undo step's inverse in the local store's `undo` table (docs/spec/offline.adoc):
/// a version byte, then each step as a tag and its fields.  Integers are LEB128 varints, byte
/// strings are length-prefixed, an optional is a presence byte, a path is its segments (0 + field
/// number, or 1 + element id), an id is counter then replica.
public enum InverseCodec {
    /// Why bytes could not be read as an inverse.
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    static let version: UInt8 = 1

    /// The encoding of `inverse`.
    public static func encode(_ inverse: Inverse) -> [UInt8] {
        var out = ByteWriter()
        out.byte(version)
        out.varint(UInt64(inverse.steps.count))
        for step in inverse.steps {
            encode(step, into: &out)
        }
        return out.bytes
    }

    /// The inverse `bytes` encode.
    public static func decode(_ bytes: [UInt8]) throws(Failure) -> Inverse {
        var input = ByteReader(bytes)
        guard try input.byte() == version else { throw Failure(description: "unknown inverse encoding version") }
        let count = try input.count()
        var steps: [Inverse.Step] = []
        steps.reserveCapacity(count)
        for _ in 0..<count {
            steps.append(try decodeStep(&input))
        }
        guard input.atEnd else { throw Failure(description: "trailing bytes after the inverse") }
        return .assembled(steps)
    }

    private static func encode(_ step: Inverse.Step, into out: inout ByteWriter) {
        switch step {
        case .created(let node):
            out.byte(1); out.id(node)
        case .register(let node, let path, let prior, let wrote):
            out.byte(2); out.id(node); out.path(path)
            out.optional(prior) { $0.optionalBytes($1.value); $0.id($1.op) }
            out.id(wrote)
        case .placement(let node, let prior, let wrote):
            out.byte(3); out.id(node)
            out.optional(prior) { $0.id($1.parent); $0.bytes($1.position); $0.id($1.op) }
            out.id(wrote)
        case .deleted(let node, let prior, let wrote):
            out.byte(4); out.id(node); out.optional(prior) { $0.flag($1) }; out.id(wrote)
        case .elementInserted(let node, let element):
            out.byte(5); out.id(node); out.path(element)
        case .elementPosition(let node, let element, let prior, let wrote):
            out.byte(6); out.id(node); out.path(element); out.bytes(prior.value); out.id(prior.op); out.id(wrote)
        case .elementDeleted(let node, let element, let prior, let wrote):
            out.byte(7); out.id(node); out.path(element); out.optional(prior) { $0.flag($1) }; out.id(wrote)
        case .memberAdded(let node, let set, let member, let tag, let wasPresent, let field):
            out.byte(8); out.id(node); out.path(set); out.bytes(member); out.id(tag); out.bool(wasPresent); out.field(field)
        case .memberRemoved(let node, let set, let member, let field):
            out.byte(9); out.id(node); out.path(set); out.bytes(member); out.field(field)
        case .textInserted(let node, let text, let chars):
            out.byte(10); out.id(node); out.path(text); out.list(chars) { $0.id($1) }
        case .textDeleted(let node, let text, let chars):
            out.byte(11); out.id(node); out.path(text)
            out.list(chars) { out, char in
                out.id(char.id)
                out.varint(UInt64(char.scalar))
                out.list(char.attributes) { $0.bytes($1) }
                out.list(char.paragraph) { $0.segments($1.suffix); $0.optionalBytes($1.value) }
            }
        case .textMarked(let node, let text, let mark, let key, let value, let prior):
            out.byte(12); out.id(node); out.path(text); out.id(mark)
            out.varint(UInt64(key.field)); out.bytes(key.tag); out.bytes(value)
            out.list(prior) { $0.id($1.char); $0.optionalBytes($1.value) }
        }
    }

    private static func decodeStep(_ input: inout ByteReader) throws(Failure) -> Inverse.Step {
        switch try input.byte() {
        case 1:
            return .created(node: try input.id())
        case 2:
            return .register(node: try input.id(), path: try input.path(),
                             prior: try input.optional { r throws(Failure) in Register(value: try r.optionalBytes(), op: try r.id()) },
                             wrote: try input.id())
        case 3:
            return .placement(node: try input.id(),
                              prior: try input.optional { r throws(Failure) in
                                  Placement(parent: try r.id(), position: try r.bytes(), op: try r.id())
                              },
                              wrote: try input.id())
        case 4:
            return .deleted(node: try input.id(), prior: try input.optional { r throws(Failure) in try r.flag() }, wrote: try input.id())
        case 5:
            return .elementInserted(node: try input.id(), element: try input.path())
        case 6:
            return .elementPosition(node: try input.id(), element: try input.path(),
                                    prior: Stamped(try input.bytes(), try input.id()), wrote: try input.id())
        case 7:
            return .elementDeleted(node: try input.id(), element: try input.path(),
                                   prior: try input.optional { r throws(Failure) in try r.flag() }, wrote: try input.id())
        case 8:
            return .memberAdded(node: try input.id(), set: try input.path(), member: try input.bytes(), tag: try input.id(),
                                wasPresent: try input.bool(), field: try input.field())
        case 9:
            return .memberRemoved(node: try input.id(), set: try input.path(), member: try input.bytes(), field: try input.field())
        case 10:
            return .textInserted(node: try input.id(), text: try input.path(), chars: try input.list { r throws(Failure) in try r.id() })
        case 11:
            return .textDeleted(node: try input.id(), text: try input.path(), chars: try input.list { r throws(Failure) in
                DeletedChar.assembled(
                    id: try r.id(), scalar: try r.uint32(),
                    attributes: try r.list { r throws(Failure) in try r.bytes() },
                    paragraph: try r.list { r throws(Failure) in
                        ParagraphRegister.assembled(suffix: try r.segments(), value: try r.optionalBytes())
                    })
            })
        case 12:
            return .textMarked(node: try input.id(), text: try input.path(), mark: try input.id(),
                               key: MarkKey(field: try input.uint32(), tag: try input.bytes()), value: try input.bytes(),
                               prior: try input.list { r throws(Failure) in PriorFormat.assembled(char: try r.id(), value: try r.optionalBytes()) })
        case let tag:
            throw Failure(description: "unknown inverse step \(tag)")
        }
    }
}

struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func byte(_ value: UInt8) { bytes.append(value) }
    mutating func bool(_ value: Bool) { bytes.append(value ? 1 : 0) }

    mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }

    mutating func bytes(_ value: [UInt8]) {
        varint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    mutating func optionalBytes(_ value: [UInt8]?) {
        optional(value) { $0.bytes($1) }
    }

    mutating func id(_ id: OpID) {
        varint(id.counter)
        varint(id.replica)
    }

    mutating func flag(_ flag: Stamped<Bool>) {
        bool(flag.value)
        id(flag.op)
    }

    mutating func segments(_ segments: [RegisterPath.Segment]) {
        list(segments) { out, segment in
            switch segment {
            case .field(let number):
                out.byte(0)
                out.varint(UInt64(number))
            case .element(let id):
                out.byte(1)
                out.id(id)
            }
        }
    }

    mutating func path(_ path: RegisterPath) { segments(path.segments) }

    mutating func field(_ field: MemberField) {
        varint(UInt64(field.number))
        bytes(Array(field.type.utf8))
        optional(field.typeName) { $0.bytes(Array($1.utf8)) }
    }

    mutating func optional<T>(_ value: T?, _ body: (inout ByteWriter, T) -> Void) {
        guard let value else {
            byte(0)
            return
        }
        byte(1)
        body(&self, value)
    }

    mutating func list<T>(_ values: [T], _ body: (inout ByteWriter, T) -> Void) {
        varint(UInt64(values.count))
        for value in values {
            body(&self, value)
        }
    }
}

struct ByteReader {
    typealias Failure = InverseCodec.Failure
    private let data: [UInt8]
    private var offset = 0

    init(_ data: [UInt8]) {
        self.data = data
    }

    var atEnd: Bool { offset == data.count }

    mutating func byte() throws(Failure) -> UInt8 {
        guard offset < data.count else { throw Failure(description: "truncated inverse") }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func bool() throws(Failure) -> Bool {
        switch try byte() {
        case 0: false
        case 1: true
        default: throw Failure(description: "bad boolean")
        }
    }

    mutating func varint() throws(Failure) -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: UInt64(0), to: 64, by: 7) {
            let byte = try byte()
            value |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return value }
        }
        throw Failure(description: "varint too long")
    }

    mutating func uint32() throws(Failure) -> UInt32 {
        let value = try varint()
        guard value <= UInt32.max else { throw Failure(description: "value out of range") }
        return UInt32(value)
    }

    mutating func count() throws(Failure) -> Int {
        let value = try varint()
        guard value <= UInt64(data.count - offset) else { throw Failure(description: "count past the end") }
        return Int(value)
    }

    mutating func bytes() throws(Failure) -> [UInt8] {
        let length = try count()
        defer { offset += length }
        return Array(data[offset..<offset + length])
    }

    mutating func optionalBytes() throws(Failure) -> [UInt8]? {
        try optional { r throws(Failure) in try r.bytes() }
    }

    mutating func string() throws(Failure) -> String {
        guard let string = String(validating: try bytes(), as: UTF8.self) else { throw Failure(description: "bad string") }
        return string
    }

    mutating func id() throws(Failure) -> OpID {
        OpID(counter: try varint(), replica: try varint())
    }

    mutating func flag() throws(Failure) -> Stamped<Bool> {
        Stamped(try bool(), try id())
    }

    mutating func segments() throws(Failure) -> [RegisterPath.Segment] {
        try list { r throws(Failure) in
            switch try r.byte() {
            case 0: .field(try r.uint32())
            case 1: .element(try r.id())
            default: throw Failure(description: "bad path segment")
            }
        }
    }

    mutating func path() throws(Failure) -> RegisterPath {
        let segments = try segments()
        guard !segments.isEmpty else { throw Failure(description: "empty path") }
        return RegisterPath(segments: segments)
    }

    mutating func field() throws(Failure) -> MemberField {
        MemberField.assembled(number: try uint32(), type: try string(), typeName: try optional { r throws(Failure) in try r.string() })
    }

    mutating func optional<T>(_ body: (inout ByteReader) throws(Failure) -> T) throws(Failure) -> T? {
        try bool() ? try body(&self) : nil
    }

    mutating func list<T>(_ body: (inout ByteReader) throws(Failure) -> T) throws(Failure) -> [T] {
        let count = try count()
        var values: [T] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(try body(&self))
        }
        return values
    }
}
