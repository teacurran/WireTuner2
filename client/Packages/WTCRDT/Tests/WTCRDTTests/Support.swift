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

/// Scenarios on the conformance test kind (`TestProps`, NodeProps field 1000, with its TEXT field
/// at 9), written as the vectors write changes: `Wiretuner_Conformance_V1_Change` in text format.
enum Scenario {
    /// The generated merge table plus crdt-conformance/schema/test-kinds.textproto.
    static let schema: Schema = {
        var failures: [String] = []
        return ConformanceRunner.schema(ConformanceRunner.Vector(), &failures)
    }()

    static let node = OpID(counter: 1, replica: 7)
    static let text = RegisterPath([1000, 9])
    static let label = RegisterPath([1000, 2])
    static let tags = RegisterPath([1000, 3])
    static let stops = RegisterPath([1000, 8])
    static let nodeText = "node { counter: 1 replica: 7 }"
    static let textPath = "text { segments { field: 1000 } segments { field: 9 } }"

    /// A change parsed from text format and converted to doc.v1.
    static func change(_ text: String) -> Wiretuner_Doc_V1_Change {
        ConformanceRunner.docChange(try! Wiretuner_Conformance_V1_Change(textFormatString: text))
    }

    /// An op of `change(...)` with the given body, for replica `replica` at `counter`.
    static func change(_ replica: UInt64, _ seq: UInt64, _ counter: UInt64, _ ops: String...) -> Wiretuner_Doc_V1_Change {
        change(replica, seq, counter, base: 0, ops)
    }

    /// A change of `ops` whose causal past is the server log up to `base`.
    static func change(_ replica: UInt64, _ seq: UInt64, _ counter: UInt64, base: UInt64, _ ops: [String]) -> Wiretuner_Doc_V1_Change {
        change("replica: \(replica) seq: \(seq) start_counter: \(counter) base_server_seq: \(base) "
            + ops.map { "ops { \($0) }" }.joined(separator: " "))
    }

    /// An engine over `schema` with the test node 1:7 created (label "T") and `extra` applied.
    static func engine(_ extra: Wiretuner_Doc_V1_Change...) -> EngineState {
        var engine = EngineState(schema: schema)
        engine.apply(change(7, 1, 1, #"create { parent { counter: 4 } position: "\x80" props { test { label: "T" } } }"#),
                     serverSeq: 1)
        for change in extra {
            engine.apply(change)
        }
        return engine
    }

    static func insert(_ chars: String, left: OpID? = nil, right: OpID? = nil) -> String {
        var op = "text_insert { \(nodeText) \(textPath)"
        if let left { op += " left_origin { counter: \(left.counter) replica: \(left.replica) }" }
        if let right { op += " right_origin { counter: \(right.counter) replica: \(right.replica) }" }
        return op + " chars: \"\(chars)\" }"
    }

    static func anchor(_ id: OpID?, before: Bool) -> String {
        (id.map { "char { counter: \($0.counter) replica: \($0.replica) } " } ?? "") + (before ? "before: true" : "")
    }

    static func mark(_ start: OpID?, _ startBefore: Bool, _ end: OpID?, _ endBefore: Bool, _ value: String) -> String {
        "text_mark { \(nodeText) \(textPath) start { \(anchor(start, before: startBefore)) } end { \(anchor(end, before: endBefore)) } value { \(value) } }"
    }
}

/// The observable document (what a user sees), for apply-then-invert identity: live nodes with
/// their placement and register values, live sequence elements, set members, and each text's
/// string, attributed runs and live newlines' paragraph values.  No OpIds: an undo writes new ones.
enum View {
    static func of(_ engine: EngineState) -> [String] {
        let store = engine.store
        var out: [String] = []
        for node in store.nodes where store.deleted(node)?.current.value != true {
            let placement = store.placement(node)
            out.append("node \(node) kind \(store.kind(node)) parent \(placement.map { "\($0.parent)/\(Bytes.hex($0.position))" } ?? "none")")
            let texts = store.textPaths(node)
            for (path, register) in store.registers(node) {
                guard let value = register.value, !hidden(store, node, path, texts) else { continue }
                out.append("  \(path) = \(Bytes.hex(value))")
            }
            var sequences: Set<RegisterPath> = []
            for (path, _) in store.elements(node) where !hidden(store, node, path, texts) {
                sequences.insert(path.parent!)
            }
            for sequence in sequences.sorted() {
                let live = store.elementOrder(node, sequence).filter { !store.element(node, sequence.element($0))!.isDeleted }
                out.append("  \(sequence): " + live.map { "\($0)@\(Bytes.hex(store.element(node, sequence.element($0))!.position.current.value))" }
                    .joined(separator: " "))
            }
            for path in store.setPaths(node) {
                out.append("  \(path) members " + store.members(node, path).map(Bytes.hex).joined(separator: " "))
            }
            for path in texts {
                let text = store.text(node, path)!
                var runs: [(length: Int, values: [String])] = []
                for run in text.runs {
                    let values = run.attributes.map { Bytes.hex($0.value) }
                    if let last = runs.last, last.values == values {
                        runs[runs.count - 1].length += run.length
                    } else {
                        runs.append((length: run.length, values: values))
                    }
                }
                out.append("  \(path) \"\(text.string)\" " + runs.map { "[\($0.length)" + $0.values.map { " " + $0 }.joined() + "]" }.joined())
                for char in text.liveChars where text.codepoint(char) == 0x0A {
                    let prefix = path.element(char)
                    let values = store.registers(node).filter { $0.path.segments.starts(with: prefix.segments) && $0.path != prefix }
                        .compactMap { entry in entry.register.value.map { "\(entry.path.segments.dropFirst(prefix.segments.count).map(\.description).joined(separator: "."))=\(Bytes.hex($0))" } }
                    out.append("  paragraph at \(text.offset(of: char)!): " + values.joined(separator: " "))
                }
            }
        }
        return out
    }

    // Registers and elements under a tombstoned element or any character are not shown directly.
    private static func hidden(_ store: NodeStore, _ node: OpID, _ path: RegisterPath, _ texts: [RegisterPath]) -> Bool {
        for index in path.segments.indices {
            guard case .element = path.segments[index], index > 0 else { continue }
            let prefix = RegisterPath(segments: Array(path.segments[...index]))
            if texts.contains(prefix.parent!) || store.element(node, prefix)?.isDeleted == true && prefix != path {
                return true
            }
        }
        return false
    }
}
