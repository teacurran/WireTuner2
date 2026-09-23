import Foundation
import WTCRDT
import WTProto

/// One place a colour is used (`ColorRegisterWalker` of editing-colors.adoc, "Client"): a
/// `ColorRef` register of a node -- a fill, a stroke, a gradient stop, an effect -- a `ColorRef`
/// inside an ATOMIC message register, a text mark's glyph fill, or a tint swatch's base.
public struct ColorUse: Hashable, Sendable {
    public enum Location: Hashable, Sendable {
        /// A `ColorRef` register at this path (rewritable in place).
        case register(RegisterPath)
        /// A `ColorRef` somewhere inside the ATOMIC message register at this path.
        case nested(RegisterPath)
        /// The `fill` of the text mark `mark` in the TEXT field at `text`.
        case mark(text: RegisterPath, mark: OpID)
        /// A tint swatch's `parent` (the reference is a `swatch` reference to the base).
        case tintBase
    }

    /// The node holding the reference.
    public let node: OpID
    public let location: Location
    public let ref: Wiretuner_Doc_V1_ColorRef

    public init(node: OpID, location: Location, ref: Wiretuner_Doc_V1_ColorRef) {
        self.node = node
        self.location = location
        self.ref = ref
    }

    /// The use without its value: what the dependents index keys on.
    public struct Key: Hashable, Sendable {
        public let node: OpID
        public let location: Location
    }

    public var key: Key { Key(node: node, location: location) }

    /// The swatch the reference names (a tint's base for an unnamed tint), if any.
    public var swatch: OpID? { ColorResolver.swatch(of: ref) }
}

/// Enumerates the colour uses of a node through the merge table, so every `ColorRef` field of
/// every kind -- present and future -- is found without a list of fields.
public enum ColorUses {
    static let colorRef = "wiretuner.doc.v1.ColorRef"

    /// Every colour use `node` holds, in register order, then its text marks.
    public static func uses(of node: OpID, in state: EngineState) -> [ColorUse] {
        let kind = state.store.kind(node)
        guard kind != 0 else { return [] }
        var result: [ColorUse] = []
        if kind == SwatchFields.kind {
            let props = state.props(node).swatch
            if props.hasParent {
                var ref = Wiretuner_Doc_V1_ColorRef()
                ref.swatch = props.parent
                result.append(ColorUse(node: node, location: .tintBase, ref: ref))
            }
        }
        for (path, register) in state.store.registers(node) {
            guard let value = register.value, let row = leaf(path, schema: state.schema), row.type == "message",
                  let typeName = row.typeName else { continue }
            for record in WireRecords(value) where record.field == UInt32(row.fieldNumber) {
                if typeName == colorRef {
                    if let ref = try? Wiretuner_Doc_V1_ColorRef(serializedBytes: record.payload) {
                        result.append(ColorUse(node: node, location: .register(path), ref: ref))
                    }
                } else {
                    for ref in nested(record.payload, message: typeName, schema: state.schema, depth: 0) {
                        result.append(ColorUse(node: node, location: .nested(path), ref: ref))
                    }
                }
            }
        }
        for path in state.store.textPaths(node) {
            guard let text = state.store.text(node, path) else { continue }
            for mark in text.marks.values.sorted(by: { $0.id < $1.id }) {
                guard let value = try? Wiretuner_Doc_V1_TextMarkValue(serializedBytes: mark.value),
                      case .fill(let ref)? = value.value else { continue }
                result.append(ColorUse(node: node, location: .mark(text: path, mark: mark.id), ref: ref))
            }
        }
        return result
    }

    /// The merge-table row of the field a register path ends at.
    static func leaf(_ path: RegisterPath, schema: Schema) -> Schema.FieldPolicy? {
        var message = Schema.root
        var row: Schema.FieldPolicy?
        for segment in path.segments {
            guard case .field(let number) = segment else { continue }
            if let previous = row {
                guard let next = previous.policy == .sequence ? previous.elementMessage : previous.typeName else { return nil }
                message = next
            }
            guard let found = schema.field(message, Int(number)) else { return nil }
            row = found
        }
        return row
    }

    /// The `ColorRef`s inside an encoded `message`, found through the merge table's fields.
    static func nested(_ payload: [UInt8], message: String, schema: Schema, depth: Int) -> [Wiretuner_Doc_V1_ColorRef] {
        guard depth < 16 else { return [] }
        var result: [Wiretuner_Doc_V1_ColorRef] = []
        for record in WireRecords(payload) {
            guard let row = schema.field(message, Int(record.field)), row.type == "message", let typeName = row.typeName else { continue }
            if typeName == colorRef {
                if let ref = try? Wiretuner_Doc_V1_ColorRef(serializedBytes: record.payload) { result.append(ref) }
            } else {
                result += nested(record.payload, message: typeName, schema: schema, depth: depth + 1)
            }
        }
        return result
    }

    /// A `SetFields` writing `ref` into the `ColorRef` register at `path` of `node`.
    public static func write(_ ref: Wiretuner_Doc_V1_ColorRef, at path: RegisterPath, of node: OpID) -> Wiretuner_Doc_V1_Op {
        Ops.set(node, [path], values: sparse(path, record: Wire.field(path.fields.last ?? 0, Wire.bytes { try ref.serializedBytes() })))
    }

    /// The sparse `NodeProps` holding `record` (the leaf field's encoding) at `path`: each
    /// field segment wraps what it holds, and an element segment adds the element's `id`.
    static func sparse(_ path: RegisterPath, record: [UInt8]) -> Wiretuner_Doc_V1_NodeProps {
        var bytes = record
        for segment in path.segments.dropLast().reversed() {
            switch segment {
            case .field(let number): bytes = Wire.field(number, bytes)
            case .element(let id): bytes = Wire.field(1, Wire.elementID(id)) + bytes
            }
        }
        return (try? Wiretuner_Doc_V1_NodeProps(serializedBytes: bytes)) ?? Wiretuner_Doc_V1_NodeProps()
    }

    /// The nodes a change names: the node each op writes, and each node it creates.
    public static func touched(by change: Wiretuner_Doc_V1_Change) -> Set<OpID> {
        var nodes: Set<OpID> = []
        var counter = change.startCounter
        for op in change.ops {
            switch op.op {
            case .create?: nodes.insert(OpID(counter: counter, replica: change.replica))
            case .set(let set)?: nodes.insert(OpID(set.node))
            case .move(let move)?: nodes.insert(OpID(move.node))
            case .setDeleted(let deleted)?: nodes.insert(OpID(deleted.node))
            case .elementInsert(let insert)?: nodes.insert(OpID(insert.node))
            case .elementMove(let move)?: nodes.insert(OpID(move.node))
            case .elementDelete(let delete)?: nodes.insert(OpID(delete.node))
            case .textInsert(let insert)?: nodes.insert(OpID(insert.node))
            case .textDelete(let delete)?: nodes.insert(OpID(delete.node))
            case .textMark(let mark)?: nodes.insert(OpID(mark.node))
            case .setAdd(let add)?: nodes.insert(OpID(add.node))
            case .setRemove(let remove)?: nodes.insert(OpID(remove.node))
            case .noop?, nil: break
            }
            counter &+= EngineState.counters(op)
        }
        return nodes
    }
}

extension EngineState {
    /// Whether `node` and every ancestor up to a well-known node is live and placed: what a
    /// user sees.  A node under a deleted group, or never placed, is not.
    public func isEffectivelyLive(_ node: OpID) -> Bool {
        var current = node
        var steps = 0
        while current.replica != 0 {
            guard isLive(current), let placement = store.placement(current), steps < 10_000 else { return false }
            current = placement.parent
            steps += 1
        }
        return true
    }
}

/// The records of an encoded protobuf message: field number, and for a length-delimited record
/// its payload (other wire types are skipped).  Stops at the first malformed record.
struct WireRecords: Sequence, IteratorProtocol {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    init(_ data: Data) {
        self.init([UInt8](data))
    }

    private mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        return nil
    }

    mutating func next() -> (field: UInt32, payload: [UInt8])? {
        while index < bytes.count {
            guard let key = varint() else { return nil }
            let field = UInt32(truncatingIfNeeded: key >> 3)
            switch key & 7 {
            case 0:
                guard varint() != nil else { return nil }
            case 1:
                index += 8
            case 5:
                index += 4
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - index) else { return nil }
                let payload = Array(bytes[index..<(index + Int(length))])
                index += Int(length)
                return (field, payload)
            default:
                return nil
            }
        }
        return nil
    }
}
