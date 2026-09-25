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
    /// The attribute stack's order, bottom first: which list each row comes from, the rows of
    /// one list in the order `props` holds them.  The three lists share one position space in the
    /// document (attribute-stack.adoc, "Data model"), which `props` cannot show, so a node read
    /// from a state records it and `NodeCopier` recreates the interleaving.  Nil (or one that
    /// does not match the lists' lengths) reads as the fills, then the strokes, then the effects.
    public var stackOrder: [AppearanceList]?

    public init(props: Wiretuner_Doc_V1_NodeProps, children: [NodeTree] = [], source: OpID? = nil, stackOrder: [AppearanceList]? = nil) {
        self.props = props
        self.children = children
        self.source = source
        self.stackOrder = stackOrder
    }

    /// `node` as merged, with its live children (deleted descendants are left out) and its stack
    /// order.
    public init(_ node: OpID, state: EngineState) {
        var order: [AppearanceList]?
        if case .object? = StackOwner.of(node, in: state) {
            let rows = AppearanceEditing.stack(node, in: state)
            if !rows.isEmpty { order = rows.map(\.list) }
        }
        self.init(props: state.props(node), children: state.liveChildren(node).map { NodeTree($0, state: state) }, source: node, stackOrder: order)
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
        case .chart?: .chart
        case .symbol?: .symbol
        case .instance?: .instance
        case .barcode?: .barcode
        case .connector?: .connector
        case .placedFile?: .placedFile
        case .text?: .text
        case .blend?: .blend
        case .extrude?: .extrude
        case .envelope?: .envelope
        case .perspective?: .perspective
        case .image?: .image
        case .svgAnimation?: .svgAnimation
        default: nil
        }
    }

    /// The node's own transform (identity when unset).  A connector's reads as the identity and
    /// is never written (its `common.transform` is unused): move its free points with
    /// `transformConnectors(by:)`.
    public var transform: AffineTransform {
        get {
            if case .connector? = props.kind { return .identity }
            return NodeValues.common(props).map { PathEditing.transform($0.transform) } ?? .identity
        }
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
            case .chart?: assign(&props.chart.common)
            case .symbol?: assign(&props.symbol.common)
            case .instance?: assign(&props.instance.common)
            case .barcode?: assign(&props.barcode.common)
            case .placedFile?: assign(&props.placedFile.common)
            case .text?: assign(&props.text.common)
            case .blend?: assign(&props.blend.common)
            case .extrude?: assign(&props.extrude.common)
            case .envelope?: assign(&props.envelope.common)
            case .perspective?: assign(&props.perspective.common)
            case .image?: assign(&props.image.common)
            case .svgAnimation?: assign(&props.svgAnimation.common)
            default: break
            }
        }
    }

    /// The node's attribute stack in `stackOrder` as `PasteAttributes.insert` takes it (effects'
    /// `attached_to` naming their element's place); nil when the node's kind has no stack or the
    /// stack is empty.
    var stack: [AttributePayload.Element]? {
        guard let kind, NodeValues.appearanceField(kind) != nil, let appearance = NodeValues.appearance(props) else { return nil }
        let counts: [AppearanceList: Int] = [.fills: appearance.fills.count, .strokes: appearance.strokes.count, .effects: appearance.effects.count]
        guard counts.values.contains(where: { $0 > 0 }) else { return nil }
        var order = stackOrder ?? []
        if AppearanceList.allCases.contains(where: { list in order.count(where: { $0 == list }) != counts[list] }) {
            order = AppearanceList.allCases.flatMap { Array(repeating: $0, count: counts[$0]!) }
        }
        var next: [AppearanceList: Int] = [:]
        var rows: [(list: AppearanceList, index: Int)] = []
        for list in order {
            rows.append((list, next[list, default: 0]))
            next[list, default: 0] += 1
        }
        // Each element's place (1 = bottom) by its source id, for `attached_to`.
        func id(_ row: (list: AppearanceList, index: Int)) -> Wiretuner_Doc_V1_ElementId {
            switch row.list {
            case .fills: appearance.fills[row.index].id
            case .strokes: appearance.strokes[row.index].id
            case .effects: appearance.effects[row.index].id
            }
        }
        var place: [Wiretuner_Doc_V1_ElementId: UInt64] = [:]
        for (offset, row) in rows.enumerated() where place[id(row)] == nil { place[id(row)] = UInt64(offset + 1) }
        return rows.map { row -> AttributePayload.Element in
            switch row.list {
            case .fills: return .fill(appearance.fills[row.index])
            case .strokes: return .stroke(appearance.strokes[row.index])
            case .effects:
                var effect = appearance.effects[row.index]
                if effect.hasAttachedTo {
                    if let target = place[effect.attachedTo] {
                        effect.attachedTo = Ops.elementID(OpID(counter: target, replica: 0))
                    } else {
                        effect.clearAttachedTo()
                    }
                }
                return .effect(effect)
            }
        }
    }

    /// Every node of the tree, depth first (parents before children).
    public var flattened: [NodeTree] { [self] + children.flatMap(\.flattened) }

    /// The tree with the stored points of every connector in it mapped by `matrix` (pasteboard
    /// space): a connector ignores enclosing transforms, so a paste's or duplicate's offset moves
    /// its ends here instead.
    public mutating func transformConnectors(by matrix: AffineTransform) {
        if case .connector? = props.kind, !matrix.isIdentity {
            for path in [\Wiretuner_Doc_V1_ConnectorProps.start, \.end] {
                let point = matrix.apply(Point(x: props.connector[keyPath: path].point.x, y: props.connector[keyPath: path].point.y))
                props.connector[keyPath: path].point.x = point.x
                props.connector[keyPath: path].point.y = point.y
            }
        }
        for index in children.indices {
            children[index].transformConnectors(by: matrix)
        }
    }
}

/// Deep copies of nodes (layers.adoc "Duplicate layer", copying.adoc "Paste", OBJ-012): a
/// `CreateNode` with the node's props (the engine ignores SEQUENCE and SET fields there), then one
/// `ElementInsert` per SEQUENCE field with every live element under a fresh element id, nested
/// sequences after their parent element, then the children.  Generic over every kind: the
/// sequences are found through the schema's merge table, at the wire level.
///
/// An object's attribute stack is inserted by `PasteAttributes.insert` in the tree's
/// `stackOrder`, so a copy keeps the source's interleaving of fills, strokes and effects (each
/// list positioned on its own would regroup them) and each attached effect stays attached to
/// the copy of its element.
///
/// Not copied: SET members and TEXT fields (no kind WTModel copies has them yet), a group's
/// `layer_origins` (written once at grouping time) and a layer's `merged_into`.  A group's
/// `clip_path` is rewritten to the copy of the clipping child.  A connector end attached to a node
/// copied with it is re-attached to the copy (same side and point); an end attached to anything
/// outside the copy is left unset -- a free end at its point (connectors.adoc).
public enum NodeCopier {
    /// Appends the ops creating a copy of `tree` under `parent` at `position`; returns the copy's
    /// id.
    @discardableResult
    public static func create(_ tree: NodeTree, parent: OpID, position: [UInt8], schema: Schema,
                              builder: inout ChangeBuilder) throws -> OpID {
        var mapping: [OpID: OpID] = [:]
        let root = try create(tree, parent: parent, position: position, schema: schema, builder: &builder, mapping: &mapping)
        rewriteReferences(in: [tree], mapping: mapping, builder: &builder)
        return root
    }

    /// Appends the ops pointing references inside copied trees at the copies, once every copy
    /// exists (`mapping`: source → copy, across every tree of one paste): a group's `clip_path`,
    /// and each connector end attached to a copied node (left free by the create).
    static func rewriteReferences(in trees: [NodeTree], mapping: [OpID: OpID], builder: inout ChangeBuilder) {
        let all = trees.flatMap(\.flattened)
        for original in all {
            guard case .connector(let connector)? = original.props.kind, let source = original.source, let copy = mapping[source] else { continue }
            for (end, path) in [(connector.start, ConnectorFields.start), (connector.end, ConnectorFields.end)] {
                guard let target = Connectors.storedEnd(end).node, let copied = mapping[target] else { continue }
                var props = Wiretuner_Doc_V1_NodeProps()
                var value = end
                value.node.id = copied.proto
                if path == ConnectorFields.start { props.connector.start = value } else { props.connector.end = value }
                builder.append(Ops.set(copy, [path], values: props))
            }
        }
        for original in all {
            guard case .group(let group)? = original.props.kind, group.hasClipPath, let source = original.source,
                  let copy = mapping[source] else { continue }
            var props = Wiretuner_Doc_V1_NodeProps()
            if let target = mapping[OpID(group.clipPath.id)] {
                props.group.clipPath.id = target.proto
            }
            builder.append(Ops.set(copy, [RegisterPath([NodeKind.group.rawValue, 4])], values: props))
        }
    }

    /// Creates the copy of `tree` without rewriting references (`rewriteReferences` does, once
    /// every tree of the paste exists).
    static func create(_ tree: NodeTree, parent: OpID, position: [UInt8], schema: Schema,
                       builder: inout ChangeBuilder, mapping: inout [OpID: OpID]) throws -> OpID {
        var props = tree.props
        switch props.kind {
        case .group?:
            props.group.layerOrigins = []
            props.group.clearClipPath()
        case .layer?:
            props.layer.clearMergedInto()
            props.layer.role = .unspecified
        case .connector?:
            // Attached ends are written after every node exists (above); until then, free.
            for path in [\Wiretuner_Doc_V1_ConnectorProps.start, \.end] where props.connector[keyPath: path].hasNode {
                props.connector[keyPath: path].clearNode()
                props.connector[keyPath: path].side = .unspecified
            }
        default:
            break
        }
        // The stack is inserted as one interleaved run (below), not list by list.
        let stack = tree.stack
        if let kind = tree.kind, stack != nil { props = NodeValues.replacing(Self.withoutLists(NodeValues.appearance(props)!), of: kind, in: props) }
        let node = builder.append(Ops.create(parent: parent, position: position, props: props))
        if let source = tree.source { mapping[source] = node }
        if let kind = tree.kind, let stack { try PasteAttributes.insert(stack, into: node, kind: kind, schema: schema, builder: &builder) }
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

    /// `appearance` without its fills, strokes and effects (its other fields kept).
    static func withoutLists(_ appearance: Wiretuner_Doc_V1_AppearanceProps) -> Wiretuner_Doc_V1_AppearanceProps {
        var result = appearance
        result.fills = []
        result.strokes = []
        result.effects = []
        return result
    }

    /// Inserts every element of each SEQUENCE field of the message `message` (encoded as
    /// `payload`, at `prefix` on the copy); `wrap` encloses a message at `prefix` into a whole
    /// `NodeProps`.
    static func copySequences(_ message: String, payload: [UInt8], prefix: RegisterPath, node: OpID, schema: Schema,
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
