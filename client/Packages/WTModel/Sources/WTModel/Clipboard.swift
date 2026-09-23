import WTCRDT
import WTGeometry
import WTProto

/// The native pasteboard payload (OBJ-010, copying.adoc "Data model"): subtrees of copied objects
/// in stacking order with their full `NodeProps`, their layers' names, the copied bounds and the
/// source document.  Never stored in a document.
///
/// Deviation: `clipboard.proto` is not in `proto/` yet (the proto track owns it), so the payload
/// is encoded here by hand in exactly the wire format of the sketched `ClipboardPayload` message
/// (nodes 1, layer_names 2, assets 3, bounds 4, source_document 5; `ClipboardNode` props 1,
/// children 2, source_id 3).  No assets are carried: swatches, styles, symbols and brushes are
/// not nodes yet, and colours are inline.
public struct ClipboardPayload: Hashable, Sendable {
    /// The pasteboard type.
    public static let pasteboardType = "com.wiretuner.objects"

    /// Top-level copied objects, bottom first; each root's transform maps to the pasteboard
    /// (enclosing groups baked in).
    public var nodes: [NodeTree]
    /// The source layer name of each top-level node, for *Remember layer info*.
    public var layerNames: [String]
    /// The copied objects' bounds, source pasteboard space.
    public var bounds: Rect?
    public var sourceDocument: String

    public init(nodes: [NodeTree], layerNames: [String] = [], bounds: Rect? = nil, sourceDocument: String = "") {
        self.nodes = nodes
        self.layerNames = layerNames
        self.bounds = bounds
        self.sourceDocument = sourceDocument
    }

    /// A copy of the live objects `nodes` of `state` (locked ones included: a locked object can be
    /// copied, arranging.adoc).
    public init(copying nodes: [OpID], from state: EngineState, document: String = "") {
        let objects = Objects.stackingOrder(nodes.filter { Objects.isObject($0, in: state) }, in: state)
        let order = LayerOrder(state)
        var bounds = Rect.null
        self.init(nodes: objects.map { node in
            var tree = NodeTree(node, state: state)
            tree.transform = Objects.pasteboardTransform(of: node, in: state)
            return tree
        }, layerNames: objects.map { node in order.layer(of: node, in: state).flatMap { order.layer($0)?.name } ?? "" },
        sourceDocument: document)
        for node in objects {
            if let rect = Objects.bounds(of: node, in: state) { bounds = bounds.union(rect) }
        }
        self.bounds = bounds.isNull ? nil : bounds
    }

    public var isEmpty: Bool { nodes.isEmpty }

    // MARK: Encoding

    /// The payload's protobuf encoding.
    public func encoded() -> [UInt8] {
        var out: [UInt8] = []
        for node in nodes { out += Wire.field(1, Self.encode(node)) }
        for name in layerNames { out += Wire.field(2, Array(name.utf8)) }
        if let bounds {
            var rect = Wiretuner_Doc_V1_Rect()
            rect.x = bounds.minX
            rect.y = bounds.minY
            rect.width = bounds.width
            rect.height = bounds.height
            out += Wire.field(4, Wire.bytes { try rect.serializedBytes() })
        }
        if !sourceDocument.isEmpty { out += Wire.field(5, Array(sourceDocument.utf8)) }
        return out
    }

    private static func encode(_ node: NodeTree) -> [UInt8] {
        var out = Wire.field(1, Wire.bytes { try node.props.serializedBytes() })
        for child in node.children { out += Wire.field(2, encode(child)) }
        if let source = node.source { out += Wire.field(3, Wire.bytes { try source.proto.serializedBytes() }) }
        return out
    }

    /// The payload `bytes` encode; nil when they are not one.
    public init?(decoding bytes: [UInt8]) {
        guard let fields = WireReader.fields(bytes), fields.allSatisfy({ $0.wireType == 2 }) else { return nil }
        var nodes: [NodeTree] = []
        var names: [String] = []
        var bounds: Rect?
        var source = ""
        for field in fields {
            switch field.number {
            case 1:
                guard let node = Self.decode(field.payload) else { return nil }
                nodes.append(node)
            case 2:
                names.append(String(decoding: field.payload, as: UTF8.self))
            case 4:
                guard let rect = try? Wiretuner_Doc_V1_Rect(serializedBytes: field.payload) else { return nil }
                bounds = Rect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            case 5:
                source = String(decoding: field.payload, as: UTF8.self)
            default:
                continue
            }
        }
        self.init(nodes: nodes, layerNames: names, bounds: bounds, sourceDocument: source)
    }

    private static func decode(_ bytes: [UInt8]) -> NodeTree? {
        guard let fields = WireReader.fields(bytes) else { return nil }
        var tree = NodeTree(props: Wiretuner_Doc_V1_NodeProps())
        for field in fields where field.wireType == 2 {
            switch field.number {
            case 1:
                guard let props = try? Wiretuner_Doc_V1_NodeProps(serializedBytes: field.payload) else { return nil }
                tree.props = props
            case 2:
                guard let child = decode(field.payload) else { return nil }
                tree.children.append(child)
            case 3:
                guard let id = try? Wiretuner_Doc_V1_OpId(serializedBytes: field.payload) else { return nil }
                tree.source = OpID(id)
            default:
                continue
            }
        }
        return tree
    }
}

/// Paste (OBJ-010/OBJ-011, copying.adoc "Paste"): one `CreateNode` per copied node, children after
/// parents, fresh ids, references inside the payload rewritten.  One change "Paste" or "Paste N
/// objects".
public struct Paste: Command {
    public enum Placement: Hashable, Sendable {
        /// On top of the active layer (`layer`, or the drawing layer); centred on `center` when
        /// given, else at the copied position.
        case top(layer: OpID?, center: Point?)
        /// Directly above `anchor` in its parent (inside its group), at the copied position.
        case inFront(of: OpID)
        /// Directly below `anchor`; in a clip group never below the clip path.
        case behind(OpID)
    }

    public var payload: ClipboardPayload
    public var placement: Placement
    /// *Remember layer info*: a top-level paste goes onto the layer of the copied layer's name,
    /// created (above the active layer) when missing.
    public var rememberLayerInfo: Bool

    public init(_ payload: ClipboardPayload, placement: Placement = .top(layer: nil, center: nil), rememberLayerInfo: Bool = false) {
        self.payload = payload
        self.placement = placement
        self.rememberLayerInfo = rememberLayerInfo
    }

    public var label: String { payload.nodes.count == 1 ? "Paste" : "Paste \(payload.nodes.count) objects" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !payload.isEmpty else { return }
        switch placement {
        case .top(let layer, let center):
            var delta = Vector.zero
            if let center, let bounds = payload.bounds { delta = center - bounds.center }
            let active = try PathEditing.ensureLayer(&builder, state: state, preferred: layer)
            var created: [String: OpID] = [:]
            let order = LayerOrder(state)
            for (index, tree) in payload.nodes.enumerated() {
                var parent = active
                if rememberLayerInfo, index < payload.layerNames.count, !payload.layerNames[index].isEmpty {
                    let name = payload.layerNames[index]
                    if let existing = order.layers.first(where: { $0.name == name && $0.role == .ordinary && !$0.locked })?.id ?? created[name] {
                        parent = existing
                    } else {
                        var props = Wiretuner_Doc_V1_NodeProps()
                        props.layer.common.name = name
                        props.layer.visible = true
                        props.layer.printing = true
                        parent = builder.append(Ops.create(parent: WellKnown.layers, position: try Layers.keyAbove(active, state: state), props: props))
                        created[name] = parent
                    }
                }
                let top = state.store.children(parent).last.flatMap { state.store.placement($0)?.position }
                let key = try PathEditing.keys(between: top, and: nil, count: 1)[0]
                try place(tree, delta: delta, parent: parent, key: key, state: state, builder: &builder)
            }
        case .inFront(let anchor), .behind(let anchor):
            guard state.store.exists(anchor), let parent = Objects.parent(of: anchor, in: state) else { throw ObjectEditError.notAnObject(anchor) }
            var above = true
            if case .behind = placement { above = Arranging.clipPath(of: parent, in: state) == anchor }
            let keys = try Arranging.keys(next: anchor, above: above, count: payload.nodes.count, in: state)
            for (tree, key) in zip(payload.nodes, keys) {
                try place(tree, delta: .zero, parent: parent, key: key, state: state, builder: &builder)
            }
        }
    }

    /// Creates `tree` under `parent`: its pasteboard transform, moved by `delta`, expressed in the
    /// parent's space.
    private func place(_ tree: NodeTree, delta: Vector, parent: OpID, key: [UInt8], state: EngineState, builder: inout ChangeBuilder) throws {
        var copy = tree
        let toParent = Objects.pasteboardTransform(ofSpace: parent, in: state).inverse
        copy.transform = tree.transform.concatenating(.translation(delta)).concatenating(toParent)
        try NodeCopier.create(copy, parent: parent, position: key, schema: state.schema, builder: &builder)
    }
}

/// menu:Edit[Cut]'s document half: the objects are deleted ("Cut"); the caller puts their
/// `ClipboardPayload` on the pasteboard first.  Locked objects are copied but not cut.
public struct CutObjects: Command {
    public var nodes: [OpID]
    public var label: String { "Cut" }

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in Objects.editable(nodes, in: state) {
            builder.append(Ops.setDeleted(node))
        }
    }
}

/// menu:Edit[Clone] and menu:Edit[Duplicate] (OBJ-012): a deep copy of each object directly above
/// it, with `offset` (a pasteboard-space transformation; identity for Clone, 10 pt right and down
/// or the remembered transformation for Duplicate) composed onto its transform in its parent's
/// space.  One change.
public struct DuplicateObjects: Command {
    public var nodes: [OpID]
    public var offset: AffineTransform
    public var label: String

    /// Clone: a copy exactly on top.
    public static func clone(_ nodes: [OpID]) -> DuplicateObjects {
        DuplicateObjects(nodes, offset: .identity, label: "Clone")
    }

    /// Duplicate: offset by the remembered transformation, or 10 pt right and 10 pt down.
    public static func duplicate(_ nodes: [OpID], memory: DuplicateMemory? = nil) -> DuplicateObjects {
        let offset = memory.flatMap { $0.applies(to: Set(nodes)) ? $0.matrix : nil } ?? DuplicateMemory.defaultOffset
        return DuplicateObjects(nodes, offset: offset, label: "Duplicate")
    }

    public init(_ nodes: [OpID], offset: AffineTransform, label: String) {
        self.nodes = nodes
        self.offset = offset
        self.label = label
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in Objects.stackingOrder(nodes.filter { Objects.isObject($0, in: state) }, in: state) {
            guard let parent = Objects.parent(of: node, in: state) else { continue }
            let toPasteboard = Objects.pasteboardTransform(ofSpace: parent, in: state)
            var tree = NodeTree(node, state: state)
            tree.transform = tree.transform.concatenating(toPasteboard).concatenating(offset).concatenating(toPasteboard.inverse)
            let key = try Arranging.keys(next: node, above: true, count: 1, in: state)[0]
            try NodeCopier.create(tree, parent: parent, position: key, schema: state.schema, builder: &builder)
        }
    }
}

/// Power duplicating (copying.adoc, "Power duplicating"; `WTModel.DuplicateMemory`): after a
/// Duplicate, the transformations applied to exactly the duplicates are remembered and the next
/// Duplicate applies them instead of the 10 pt offset.  Moving combines with anything, and moving,
/// scaling and rotating combine; a scale followed by a skew (or a skew by a scale) resets the
/// memory to the latter alone.  The window clears it on any other command or selection change.
public struct DuplicateMemory: Hashable, Sendable {
    /// Duplicate's offset with nothing remembered.
    public static let defaultOffset = AffineTransform.translation(Vector(dx: 10, dy: 10))

    /// The duplicates the memory belongs to.
    public var nodes: Set<OpID>
    /// The remembered pasteboard-space transformation; nil until one is recorded.
    public var recorded: AffineTransform?
    public var kinds: Set<TransformKind>

    public init(nodes: Set<OpID>) {
        self.nodes = nodes
        recorded = nil
        kinds = []
    }

    /// What the next Duplicate applies.
    public var matrix: AffineTransform { recorded ?? Self.defaultOffset }

    /// Whether the memory is for exactly `selection`.
    public func applies(to selection: Set<OpID>) -> Bool { selection == nodes }

    /// Records a transformation (`matrix` in pasteboard space, centre included) applied to the
    /// duplicates.
    public mutating func record(_ kind: TransformKind, matrix: AffineTransform) {
        let conflicting: Set<TransformKind> = kind == .skew ? [.scale] : kind == .scale ? [.skew] : []
        if !kinds.isDisjoint(with: conflicting) {
            recorded = matrix
            kinds = [kind]
            return
        }
        recorded = (recorded ?? .identity).concatenating(matrix)
        kinds.insert(kind)
    }
}

/// The last committed transformation, for *Transform Again* (`WTModel.LastTransform`).
public struct LastTransform: Hashable, Sendable {
    public var kind: TransformKind
    public var matrix: AffineTransform
    public var center: Point?
    public var options: TransformOptions

    public init(kind: TransformKind, matrix: AffineTransform, center: Point?, options: TransformOptions) {
        self.kind = kind
        self.matrix = matrix
        self.center = center
        self.options = options
    }

    public init(_ command: TransformObjects) {
        self.init(kind: command.kind, matrix: command.matrix, center: command.center, options: command.options)
    }

    /// The same transformation applied to `nodes`.
    public func again(_ nodes: [OpID]) -> TransformObjects {
        TransformObjects(nodes, matrix: matrix, about: center, kind: kind, options: options)
    }
}

extension Wiretuner_Doc_V1_Change {
    /// The nodes the change created whose parent was not created by it too: the top-level copies
    /// of a paste or duplicate, in order.
    public var createdRoots: [OpID] {
        let created = Set(createdObjects)
        return zip(ops, opIDs).compactMap { op, id in
            guard case .create(let create) = op.op, !created.contains(OpID(create.parent)) else { return nil }
            if case .layer? = create.props.kind { return nil }
            return id
        }
    }
}
