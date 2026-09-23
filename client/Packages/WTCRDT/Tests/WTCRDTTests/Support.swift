import Foundation
@testable import WTCRDT
import WTCRDTSchema
import WTProto

/// A tiny protobuf wire writer for tests that need bytes no generated message produces.
struct Wire {
    private(set) var bytes: [UInt8] = []

    func varint(_ field: UInt64, _ value: UInt64) -> Wire { tag(field, 0).raw(value) }
    func string(_ field: UInt64, _ value: String) -> Wire { self.bytes(field, Array(value.utf8)) }
    func message(_ field: UInt64, _ inner: Wire) -> Wire { bytes(field, inner.bytes) }

    func bytes(_ field: UInt64, _ payload: [UInt8]) -> Wire {
        var wire = tag(field, 2).raw(UInt64(payload.count))
        wire.bytes += payload
        return wire
    }

    func fixed64(_ field: UInt64, _ value: UInt64) -> Wire {
        var wire = tag(field, 1)
        for i in 0..<8 { wire.bytes.append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(i)))) }
        return wire
    }

    func fixed32(_ field: UInt64, _ value: UInt32) -> Wire {
        var wire = tag(field, 5)
        for i in 0..<4 { wire.bytes.append(UInt8(truncatingIfNeeded: value >> (8 * UInt32(i)))) }
        return wire
    }

    func tag(_ field: UInt64, _ wireType: UInt64) -> Wire { raw(field << 3 | wireType) }

    func raw(_ value: UInt64) -> Wire {
        var wire = self
        var value = value
        while value >= 0x80 {
            wire.bytes.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        wire.bytes.append(UInt8(value))
        return wire
    }

    func rawBytes(_ extra: UInt8...) -> Wire {
        var wire = self
        wire.bytes += extra
        return wire
    }
}

/// Builders for the changes the engine tests apply (mirrors wt-crdt's test `Changes`).
enum Changes {
    static let name = RegisterPath([150, 1, 1])
    static let locked = RegisterPath([150, 1, 3])
    static let transform = RegisterPath([150, 1, 4])
    static let url = RegisterPath([150, 1, 6])
    static let wrap = RegisterPath([150, 1, 13])

    static func change(_ replica: UInt64, _ start: UInt64, _ ops: Wiretuner_Doc_V1_Op...) -> Wiretuner_Doc_V1_Change {
        change(replica, start, ops)
    }

    static func change(_ replica: UInt64, _ start: UInt64, _ ops: [Wiretuner_Doc_V1_Op]) -> Wiretuner_Doc_V1_Change {
        var change = Wiretuner_Doc_V1_Change()
        change.replica = replica
        change.seq = 1
        change.startCounter = start
        change.ops = ops
        return change
    }

    static func create(_ props: Wiretuner_Doc_V1_NodeProps) -> Wiretuner_Doc_V1_Op {
        var create = Wiretuner_Doc_V1_CreateNode()
        create.parent = OpID.wellKnown(4).proto
        create.props = props
        var op = Wiretuner_Doc_V1_Op()
        op.create = create
        return op
    }

    static func set(_ node: OpID, _ values: Wiretuner_Doc_V1_NodeProps, _ paths: RegisterPath...) -> Wiretuner_Doc_V1_Op {
        set(node, values, paths.map(\.proto))
    }

    static func set(_ node: OpID, _ values: Wiretuner_Doc_V1_NodeProps, _ paths: [Wiretuner_Doc_V1_FieldPath]) -> Wiretuner_Doc_V1_Op {
        var set = Wiretuner_Doc_V1_SetFields()
        set.node = node.proto
        set.values = values
        set.paths = paths
        var op = Wiretuner_Doc_V1_Op()
        op.set = set
        return op
    }

    static func clear(_ node: OpID, _ paths: RegisterPath...) -> Wiretuner_Doc_V1_Op {
        set(node, Wiretuner_Doc_V1_NodeProps(), paths.map(\.proto))
    }

    static func layer(_ edit: (inout Wiretuner_Doc_V1_CommonProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var common = Wiretuner_Doc_V1_CommonProps()
        edit(&common)
        var layer = Wiretuner_Doc_V1_LayerProps()
        layer.common = common
        var props = Wiretuner_Doc_V1_NodeProps()
        props.layer = layer
        return props
    }

    /// A NodeProps holding arbitrary wire bytes (kept as unknown fields where they are unknown).
    static func raw(_ wire: Wire) -> Wiretuner_Doc_V1_NodeProps {
        try! Wiretuner_Doc_V1_NodeProps(serializedBytes: wire.bytes)
    }

    static func bytes(_ props: Wiretuner_Doc_V1_NodeProps) -> [UInt8] {
        try! props.serializedBytes()
    }
}

/// The hand-written merge table of wt-crdt's test `Tables`, under NodeProps kind 1000.
enum Tables {
    static let k: UInt32 = 1000

    static func row(_ number: Int, _ policy: Schema.Policy, _ type: String, _ repeated: Bool,
                    _ typeName: String?, _ oneof: String? = nil) -> Schema.FieldPolicy {
        Schema.FieldPolicy(fieldNumber: number, name: "f\(number)", policy: policy, onDangling: .unset,
                           localOnly: false, type: type, repeated: repeated, typeName: typeName,
                           elementMessage: nil, oneof: oneof)
    }

    static func message(_ name: String, _ rows: [Schema.FieldPolicy]) -> (String, WTMergeTable.MessagePolicy) {
        (name, WTMergeTable.MessagePolicy(name: name, fields: Dictionary(uniqueKeysWithValues: rows.map { ($0.fieldNumber, $0) })))
    }

    static let shapes = Schema(
        messages: Dictionary(uniqueKeysWithValues: [
            message(Schema.root, [row(Int(k), .structure, "message", false, "t.K", "kind")]),
            message("t.K", [
                row(1, .atomic, "string", false, nil),
                row(2, .structure, "message", false, "t.K"),
                row(3, .sequence, "message", true, "t.K"),
                row(4, .structure, "message", true, "t.C"),
                row(5, .structure, "message", false, nil),
                row(6, .variant, "message", false, "t.V"),
                row(7, .atomic, "message", false, "wiretuner.doc.v1.NodeRef"),
                row(8, .structure, "message", true, "wiretuner.doc.v1.NodeRef"),
            ]),
            message("t.V", [
                row(1, .atomic, "enum", false, "t.Kind"),
                row(2, .structure, "message", false, "t.C"),
                row(3, .structure, "message", false, "t.C"),
                row(4, .atomic, "string", false, nil),
            ]),
            message("t.C", [row(1, .atomic, "double", false, nil)]),
        ]),
        variants: ["t.V": Schema.VariantPolicy(kindField: 1, caseFields: [2, 3])]
    )
}
