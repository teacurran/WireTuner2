import WTCRDT
import WTGeometry
import WTProto

/// A node and its live descendants as plain values: what a deep copy, a duplicate and the
/// clipboard carry (copying.adoc, "Data model": each node's full `NodeProps` with the register
/// values current at copy time, children bottom first, and the source id for rewriting references
/// inside the copy).
public struct NodeTree: Hashable, Sendable {
    public var props: Wiretuner_Doc_V1_NodeProps
    public var children: [NodeTree]
    /// The node this was read from (references between copied nodes are rewritten through it).
    public var source: OpID?

    public init(props: Wiretuner_Doc_V1_NodeProps, children: [NodeTree] = [], source: OpID? = nil) {
        self.props = props
        self.children = children
        self.source = source
    }

    /// `node` as merged, with its live children (deleted descendants are left out).
    public init(_ node: OpID, state: EngineState) {
        self.init(props: state.props(node), children: state.liveChildren(node).map { NodeTree($0, state: state) }, source: node)
    }

    /// The kind WTModel knows this node as.
    public var kind: NodeKind? {
        switch props.kind {
        case .path?: .path
        case .rect?: .rect
        case .ellipse?: .ellipse
        case .polygon?: .polygon
        case .group?: .group
        case .layer?: .layer
        default: nil
        }
    }

    /// The node's own transform (identity when unset).
    public var transform: AffineTransform {
        get { NodeValues.common(props).map { PathEditing.transform($0.transform) } ?? .identity }
        set {
            // Identity leaves the register unset, as creation does.
            func assign(_ common: inout Wiretuner_Doc_V1_CommonProps) {
                if newValue.isIdentity { common.clearTransform() } else { common.transform = PathEditing.proto(newValue) }
            }
            switch props.kind {
            case .path?: assign(&props.path.common)
            case .rect?: assign(&props.rect.common)
            case .ellipse?: assign(&props.ellipse.common)
            case .polygon?: assign(&props.polygon.common)
            case .group?: assign(&props.group.common)
            case .layer?: assign(&props.layer.common)
            default: break
            }
        }
    }

    /// Every node of the tree, depth first (parents before children).
    public var flattened: [NodeTree] { [self] + children.flatMap(\.flattened) }
}

/// Deep copies of nodes (layers.adoc "Duplicate layer", copying.adoc "Paste", OBJ-012): a
/// `CreateNode` with the node's props (the engine ignores SEQUENCE and SET fields there), then one
/// `ElementInsert` per SEQUENCE field with every live element under a fresh element id, nested
/// sequences after their parent element, then the children.  Generic over every kind: the
/// sequences are found through the schema's merge table, at the wire level.
///
/// Not copied: SET members and TEXT fields (no kind WTModel copies has them yet), a group's
/// `layer_origins` (written once at grouping time) and a layer's `merged_into`.  A group's
/// `clip_path` is rewritten to the copy of the clipping child.
public enum NodeCopier {
    /// Appends the ops creating a copy of `tree` under `parent` at `position`; returns the copy's
    /// id.
    @discardableResult
    public static func create(_ tree: NodeTree, parent: OpID, position: [UInt8], schema: Schema,
                              builder: inout ChangeBuilder) throws -> OpID {
        var mapping: [OpID: OpID] = [:]
        let root = try create(tree, parent: parent, position: position, schema: schema, builder: &builder, mapping: &mapping)
        for original in tree.flattened {
            guard case .group(let group)? = original.props.kind, group.hasClipPath, let source = original.source,
                  let copy = mapping[source] else { continue }
            var props = Wiretuner_Doc_V1_NodeProps()
            if let target = mapping[OpID(group.clipPath.id)] {
                props.group.clipPath.id = target.proto
            }
            builder.append(Ops.set(copy, [RegisterPath([NodeKind.group.rawValue, 4])], values: props))
        }
        return root
    }

    private static func create(_ tree: NodeTree, parent: OpID, position: [UInt8], schema: Schema,
                               builder: inout ChangeBuilder, mapping: inout [OpID: OpID]) throws -> OpID {
        var props = tree.props
        switch props.kind {
        case .group?:
            props.group.layerOrigins = []
            props.group.clearClipPath()
        case .layer?:
            props.layer.clearMergedInto()
            props.layer.role = .unspecified
        default:
            break
        }
        let node = builder.append(Ops.create(parent: parent, position: position, props: props))
        if let source = tree.source { mapping[source] = node }
        let bytes: [UInt8] = try props.serializedBytes()
        if let kind = WireReader.fields(bytes)?.last, kind.wireType == 2,
           let typeName = schema.field(Schema.root, Int(kind.number))?.typeName {
            try copySequences(typeName, payload: kind.payload, prefix: RegisterPath([kind.number]), node: node, schema: schema,
                              wrap: { Wire.field(kind.number, $0) }, builder: &builder)
        }
        let keys = try PathEditing.keys(between: nil, and: nil, count: tree.children.count)
        for (child, key) in zip(tree.children, keys) {
            _ = try create(child, parent: node, position: key, schema: schema, builder: &builder, mapping: &mapping)
        }
        return node
    }

    /// Inserts every element of each SEQUENCE field of the message `message` (encoded as
    /// `payload`, at `prefix` on the copy); `wrap` encloses a message at `prefix` into a whole
    /// `NodeProps`.
    private static func copySequences(_ message: String, payload: [UInt8], prefix: RegisterPath, node: OpID, schema: Schema,
                                      wrap: ([UInt8]) -> [UInt8], builder: inout ChangeBuilder) throws {
        guard let fields = WireReader.fields(payload) else { return }
        for row in schema.fields(message) {
            let number = UInt32(row.fieldNumber)
            let records = fields.filter { $0.number == number && $0.wireType == 2 }
            guard !records.isEmpty, let typeName = row.typeName else { continue }
            switch row.policy {
            case .structure where !row.repeated, .variant where !row.repeated:
                try copySequences(typeName, payload: records.last!.payload, prefix: prefix.child(number), node: node, schema: schema,
                                  wrap: { wrap(Wire.field(number, $0)) }, builder: &builder)
            case .sequence:
                let path = prefix.child(number)
                let values = try Wiretuner_Doc_V1_NodeProps(serializedBytes: wrap(records.flatMap(\.record)))
                let keys = try PathEditing.keys(between: nil, and: nil, count: records.count)
                let first = builder.append(Ops.elementInsert(node, path, positions: keys, values: values))
                for (index, record) in records.enumerated() {
                    let element = OpID(counter: first.counter + UInt64(index), replica: first.replica)
                    let body = (WireReader.fields(record.payload) ?? []).filter { $0.number != 1 }.flatMap(\.record)
                    try copySequences(typeName, payload: body, prefix: path.element(element), node: node, schema: schema,
                                      wrap: { wrap(Wire.field(number, Wire.field(1, Wire.elementID(element)) + $0)) }, builder: &builder)
                }
            default:
                continue
            }
        }
    }
}

/// Minimal protobuf wire reading: the top-level fields of a message.
enum WireReader {
    struct Field {
        var number: UInt32
        var wireType: Int
        /// The whole record, tag included.
        var record: [UInt8]
        /// A length-delimited field's contents (empty for the other wire types).
        var payload: [UInt8]
    }

    /// The fields of `bytes` in order; nil when they are not well-formed protobuf.
    static func fields(_ bytes: [UInt8]) -> [Field]? {
        var out: [Field] = []
        var index = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            let start = index
            guard let tag = varint(), tag >> 3 > 0 else { return nil }
            let wireType = Int(tag & 7)
            var payload: [UInt8] = []
            switch wireType {
            case 0:
                guard varint() != nil else { return nil }
            case 1, 5:
                let width = wireType == 1 ? 8 : 4
                guard index + width <= bytes.count else { return nil }
                index += width
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - index) else { return nil }
                payload = Array(bytes[index..<(index + Int(length))])
                index += Int(length)
            default:
                return nil
            }
            out.append(Field(number: UInt32(tag >> 3), wireType: wireType, record: Array(bytes[start..<index]), payload: payload))
        }
        return out
    }
}
