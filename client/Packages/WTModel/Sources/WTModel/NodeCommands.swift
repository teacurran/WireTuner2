import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Creates a live rectangle or ellipse (rectangles-ellipses-lines.adoc, "Data model") on top of
/// the drawing layer: `size` in its local frame (top-left at the origin), `transform` placing it.
public struct CreateShape: Command {
    public enum Kind: Hashable, Sendable {
        case rectangle(CornerRadii)
        case ellipse
    }

    public var kind: Kind
    public var size: Size
    public var transform: AffineTransform
    public var appearance: Wiretuner_Doc_V1_AppearanceProps
    /// The layer to draw on (the active layer), as for `CreatePath`.
    public var layer: OpID?
    public var label: String {
        if case .ellipse = kind { return "Ellipse" }
        return "Rectangle"
    }

    public init(_ kind: Kind, size: Size, transform: AffineTransform = .identity,
                appearance: Wiretuner_Doc_V1_AppearanceProps = Appearances.standard, layer: OpID? = nil) {
        self.layer = layer
        self.kind = kind
        self.size = size
        self.transform = transform
        self.appearance = appearance
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
            throw PathEditError.invalidValue("size")
        }
        let layer = try PathEditing.ensureLayer(&builder, state: state, preferred: self.layer)
        var props = Wiretuner_Doc_V1_NodeProps()
        var storedSize = Wiretuner_Doc_V1_Size()
        storedSize.width = size.width
        storedSize.height = size.height
        let nodeKind: NodeKind
        switch kind {
        case .rectangle(let radii):
            nodeKind = .rect
            props.rect.size = storedSize
            props.rect.corners.uniform = radii.topLeft == radii.topRight && radii.topLeft == radii.bottomRight && radii.topLeft == radii.bottomLeft
            props.rect.corners.topLeft = radii.topLeft
            props.rect.corners.topRight = radii.topRight
            props.rect.corners.bottomRight = radii.bottomRight
            props.rect.corners.bottomLeft = radii.bottomLeft
            if !transform.isIdentity { props.rect.common.transform = PathEditing.proto(transform) }
        case .ellipse:
            nodeKind = .ellipse
            props.ellipse.size = storedSize
            if !transform.isIdentity { props.ellipse.common.transform = PathEditing.proto(transform) }
        }
        let position = try PathEditing.topPosition(in: layer, state: state)
        let node = builder.append(Ops.create(parent: layer, position: position, props: props))
        let appearancePath = RegisterPath([nodeKind.rawValue, NodeValues.appearanceField(nodeKind)!])
        for op in try PathEditing.appearanceInserts(node, kind: nodeKind, appearancePath: appearancePath, appearance) {
            builder.append(op)
        }
    }
}

/// Writes objects' transforms (`CommonProps.transform`, one ATOMIC register each): a move.
public struct SetTransforms: Command {
    public var transforms: [(node: OpID, transform: AffineTransform)]
    public var label: String

    public init(_ transforms: [(node: OpID, transform: AffineTransform)], label: String = "Move") {
        self.transforms = transforms
        self.label = label
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for (node, transform) in transforms {
            guard state.isLive(node), let kind = state.nodeKind(node), kind != .layer else { throw PathEditError.notAPath(node) }
            let value = transform.isIdentity ? Wiretuner_Doc_V1_Transform() : PathEditing.proto(transform)
            builder.append(Ops.set(node, [RegisterPath([kind.rawValue, 1, 4])], values: NodeValues.with(kind: kind, transform: value)))
        }
    }
}

/// Writes a rectangle's or ellipse's `size` (one ATOMIC register: both dimensions together).
public struct SetShapeSize: Command {
    public var node: OpID
    public var size: Size
    public var label: String { "Resize" }

    public init(node: OpID, size: Size) {
        self.node = node
        self.size = size
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.isLive(node), let kind = state.nodeKind(node), kind == .rect || kind == .ellipse else { throw PathEditError.notAPath(node) }
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { throw PathEditError.invalidValue("size") }
        var props = Wiretuner_Doc_V1_NodeProps()
        var value = Wiretuner_Doc_V1_Size()
        value.width = size.width
        value.height = size.height
        if kind == .rect { props.rect.size = value } else { props.ellipse.size = value }
        builder.append(Ops.set(node, [ShapeFields.size(kind)], values: props))
    }
}

/// Deletes nodes (their `deleted` register; restorable).
public struct DeleteNodes: Command {
    public var nodes: [OpID]
    public var label: String { "Delete" }

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let order = LayerOrder(state)
        var deleted: [OpID] = []
        for node in nodes where state.isLive(node) && state.store.isCreated(node) && !Objects.isEffectivelyLocked(node, in: state, layers: order) {
            builder.append(Ops.setDeleted(node))
            deleted.append(node)
        }
        // Deleting a block in the middle of a linked chain closes the gap (TYPE-007).
        let texts = Set(deleted.flatMap { TextChains.textNodes(at: $0, in: state) })
        for op in TextChains.splice(deleting: texts, in: state) { builder.append(op) }
    }
}

extension Wiretuner_Doc_V1_Change {
    /// The id of each op, in order (op `i` takes the counters after the ops before it).
    public var opIDs: [OpID] {
        var counter = startCounter
        return ops.map { op in
            let id = OpID(counter: counter, replica: replica)
            counter &+= EngineState.counters(op)
            return id
        }
    }

    /// The nodes the change's `CreateNode` ops created, in order.
    public var createdNodes: [OpID] {
        zip(ops, opIDs).compactMap { op, id in
            if case .create = op.op { return id }
            return nil
        }
    }

    /// The objects (not layers) the change created, in order.
    public var createdObjects: [OpID] {
        zip(ops, opIDs).compactMap { op, id in
            guard case .create(let create) = op.op else { return nil }
            if case .layer? = create.props.kind { return nil }
            return id
        }
    }

    /// The element ids an `ElementInsert` into `sequence` of `node` created, in order.
    public func insertedElements(_ node: OpID, _ sequence: RegisterPath) -> [OpID] {
        zip(ops, opIDs).flatMap { op, id -> [OpID] in
            guard case .elementInsert(let insert) = op.op, OpID(insert.node) == node,
                  RegisterPath(insert.sequence) == sequence else { return [] }
            return (0..<insert.positions.count).map { OpID(counter: id.counter + UInt64($0), replica: id.replica) }
        }
    }
}
