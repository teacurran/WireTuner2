import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Register paths of `ConnectorProps` (kind `connector` = 25, connectors.adoc "Data model").
public enum ConnectorFields {
    public static let kind = NodeKind.connector.rawValue
    /// `start` and `end`: one ATOMIC register each (node, side and point together).
    public static let start = RegisterPath([kind, 2])
    public static let end = RegisterPath([kind, 3])
    /// `run_offsets`: one ATOMIC register (the whole list).
    public static let runOffsets = RegisterPath([kind, 5])
    /// The most `run_offsets` entries the schema accepts.
    public static let runOffsetLimit = 64

    /// The register of `end`.
    public static func path(_ end: ConnectorEndName) -> RegisterPath { end == .start ? start : self.end }
}

/// Which end of a connector.
public enum ConnectorEndName: Hashable, Sendable, CaseIterable {
    case start
    case end
}

/// Reading connectors (DRAW-035/037, connectors.adoc): the stored ends as written, the
/// `ConnectorSpec` WTRender routes with every read normalization applied, and the geometry
/// helpers the Connector tool needs.  A connector's geometry is never stored: its route is
/// derived from its ends and the rendered bounds of the objects they are attached to, in
/// pasteboard space; `common.transform` is ignored.
public enum Connectors {
    // MARK: Reading

    /// The ends of connector `node` as stored (attached ends keep their reference even when it
    /// dangles), its run offsets and its attribute stack.
    public static func props(_ node: OpID, in state: EngineState) -> Wiretuner_Doc_V1_ConnectorProps {
        state.props(node).connector
    }

    /// `end` as stored: the referenced node (nil when unset), the side (nil for
    /// `CONNECTOR_SIDE_UNSPECIFIED`) and the point.
    public static func storedEnd(_ end: Wiretuner_Doc_V1_ConnectorEnd) -> (node: OpID?, side: ConnectorSide?, point: Point) {
        let node = end.hasNode && end.node.hasID ? OpID(end.node.id) : nil
        return (node, side(end.side), Point(x: end.point.x, y: end.point.y))
    }

    /// The render-side side of a stored side; nil for unspecified (the side facing the other end).
    public static func side(_ side: Wiretuner_Doc_V1_ConnectorSide) -> ConnectorSide? {
        switch side {
        case .top: .top
        case .bottom: .bottom
        case .left: .left
        case .right: .right
        default: nil
        }
    }

    /// The stored side of a render-side side.
    public static func proto(_ side: ConnectorSide?) -> Wiretuner_Doc_V1_ConnectorSide {
        switch side {
        case .top?: .top
        case .bottom?: .bottom
        case .left?: .left
        case .right?: .right
        case nil: .unspecified
        }
    }

    /// The stored form of `end` (an end with no node writes no reference).
    public static func proto(_ end: ConnectorEnd) -> Wiretuner_Doc_V1_ConnectorEnd {
        var value = Wiretuner_Doc_V1_ConnectorEnd()
        if let node = end.node {
            value.node.id = OpID(node).proto
            value.side = proto(end.side)
        }
        value.point.x = end.point.x
        value.point.y = end.point.y
        return value
    }

    /// Whether an end may attach to `node`: a live object -- every ancestor live too -- shown on
    /// an ordinary layer, of a kind with bounds other than a connector.  An end naming anything
    /// else (deleted, unknown, a connector, an object on the Guides layer, a layer, a symbol's
    /// artwork) reads as free at its point.
    public static func isAttachable(_ node: OpID, in state: EngineState, layers: LayerOrder) -> Bool {
        guard let kind = state.nodeKind(node), Objects.kinds.contains(kind), kind != .connector, isLiveChain(node, in: state),
              let layer = layers.layer(of: node, in: state) else { return false }
        return layers.layer(layer)?.role == .ordinary
    }

    /// Whether `node` and every ancestor below the layer list are live.
    static func isLiveChain(_ node: OpID, in state: EngineState) -> Bool {
        var current: OpID? = node
        while let id = current, id != WellKnown.layers {
            guard state.isLive(id) || state.nodeKind(id) == .layer else { return false }
            current = state.store.placement(id)?.parent
        }
        return current != nil
    }

    /// The connector as WTRender routes it: an end whose node is not attachable is free at its
    /// point (its side dropped), `CONNECTOR_SIDE_UNSPECIFIED` reads as nil (the side facing the
    /// other end), the routing is orthogonal (the schema has no routing field), `run_offsets` pass
    /// through (the router reads a length mismatch as automatic) and only strokes are kept.
    public static func spec(_ node: OpID, in state: EngineState, layers: LayerOrder, appearance: Appearance? = nil) -> ConnectorSpec {
        let props = props(node, in: state)
        let resolved = appearance ?? Appearances.resolve(props.appearance, order: AppearanceEditing.stack(node, in: state))
        return attached(storedSpec(node, props, appearance: resolved), in: state, layers: layers)
    }

    /// The connector as stored, before the ends are checked against the document: every end that
    /// names a node keeps it (with its side), routing orthogonal, `run_offsets` as written and only
    /// the strokes of `appearance`.  Depends on the connector's own registers only, so the scene
    /// keeps it until the connector itself changes; `attached(_:in:layers:)` completes it.
    static func storedSpec(_ node: OpID, _ props: Wiretuner_Doc_V1_ConnectorProps, appearance: Appearance) -> ConnectorSpec {
        func end(_ stored: Wiretuner_Doc_V1_ConnectorEnd) -> ConnectorEnd {
            let (target, side, point) = storedEnd(stored)
            return target.map { ConnectorEnd(node: NodeID($0), side: side, point: point) } ?? ConnectorEnd(point: point)
        }
        let strokes = appearance.items.filter { if case .stroke = $0 { return true } else { return false } }
        return ConnectorSpec(id: NodeID(node), start: end(props.start), end: end(props.end), routing: .orthogonal,
                             runOffsets: props.runOffsets, appearance: Appearance(strokes))
    }

    /// `stored` with every end whose node is not attachable freed at its point (its side dropped).
    static func attached(_ stored: ConnectorSpec, in state: EngineState, layers: LayerOrder) -> ConnectorSpec {
        func end(_ value: ConnectorEnd) -> ConnectorEnd {
            guard let target = value.node, isAttachable(OpID(target), in: state, layers: layers) else { return ConnectorEnd(point: value.point) }
            return value
        }
        var spec = stored
        spec.start = end(stored.start)
        spec.end = end(stored.end)
        return spec
    }

    /// The nodes whose change can move connector `node`'s route: each referenced node (live or
    /// not, so a restore reconnects), its ancestors up to its layer (a moved group or layer
    /// moves it), and its descendants (a group's bounds follow its members).
    public static func dependencySources(of node: OpID, in state: EngineState) -> [OpID] {
        let props = props(node, in: state)
        return dependencySources(of: node, targets: [props.start, props.end].compactMap { storedEnd($0).node }, in: state)
    }

    /// The nodes whose change can move a connector joining `targets` (its ends' nodes, as stored).
    static func dependencySources(of node: OpID, targets: [OpID], in state: EngineState) -> [OpID] {
        var result: [OpID] = []
        var seen: Set<OpID> = [node]
        func add(_ id: OpID) {
            if seen.insert(id).inserted { result.append(id) }
        }
        func descendants(_ id: OpID, depth: Int) {
            guard depth < 64 else { return }
            for child in state.store.children(id) {
                add(child)
                descendants(child, depth: depth + 1)
            }
        }
        for target in targets {
            add(target)
            var current = state.store.placement(target)?.parent
            while let id = current, id != WellKnown.layers, id != WellKnown.document {
                add(id)
                current = state.store.placement(id)?.parent
            }
            descendants(target, depth: 0)
        }
        return result
    }

    // MARK: Geometry

    /// The rendered bounds an end attaches to on a placed item (pasteboard space): its geometry
    /// grown by half its widest stroke (`ConnectorRendering.attachmentBounds`).
    public static func attachmentBounds(of item: DisplayItem) -> Rect? {
        let node = NodeID(counter: 1, replica: 0)
        return ConnectorRendering.attachmentBounds(of: node, in: DisplayList(canvas: "", items: [item], nodeIDs: [node]))
    }

    /// Where an end attached to `target` on `side` sits in `scene` (nil `side`: the side facing
    /// `toward`): the midpoint of that side of its rendered bounds.  What the Connector tool writes
    /// as the end's `point` when it attaches (the free position should the object be deleted).
    public static func attachmentPoint(of target: OpID, side: ConnectorSide?, toward: Point, in scene: DocumentScene) -> Point? {
        guard let object = scene.object(target), let rect = attachmentBounds(of: object.item) else { return nil }
        return (side ?? ConnectorSide.facing(toward, from: rect)).midpoint(of: rect)
    }

    /// The route of connector `node` as `scene` draws it (attached ends on the objects' rendered
    /// bounds in the scene); nil when the node is not a drawn connector.
    public static func route(_ node: OpID, in state: EngineState, scene: DocumentScene) -> ConnectorRoute? {
        guard let object = scene.object(node), object.kind == .connector else { return nil }
        let spec = spec(node, in: state, layers: LayerOrder(state))
        return ConnectorRouter.route(spec) { id in scene.objects[id].flatMap { attachmentBounds(of: $0.item) } }
    }

    /// The connector's geometric bounds from the model alone (the objects' geometric bounds, no
    /// stroke widths): what the clipboard and the object commands read.
    static func bounds(of node: OpID, in state: EngineState) -> Rect? {
        let spec = spec(node, in: state, layers: LayerOrder(state), appearance: Appearance([]))
        let route = ConnectorRouter.route(spec) { id in Objects.boundsWithoutConnectors(of: OpID(id), in: state) }
        return route.path.controlBounds
    }
}

// MARK: Commands

/// Creates a connector (DRAW-035/036, connectors.adoc "Tool"): one `CreateNode` on top of the
/// drawing layer (or `layer`) with both ends, then its attribute stack (strokes; the default is
/// the standard 1 pt black stroke).  An attached end must name an object an end may attach to
/// (`Connectors.isAttachable`); its `point` is the attachment point at the time, which the end
/// falls back to if the object is deleted.  One change, "Connector".
public struct CreateConnector: Command {
    public var start: ConnectorEnd
    public var end: ConnectorEnd
    public var appearance: Wiretuner_Doc_V1_AppearanceProps
    public var layer: OpID?
    public var label: String { "Connector" }

    public init(start: ConnectorEnd, end: ConnectorEnd, appearance: Wiretuner_Doc_V1_AppearanceProps = Appearances.standard,
                layer: OpID? = nil) {
        self.start = start
        self.end = end
        self.appearance = appearance
        self.layer = layer
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let order = LayerOrder(state)
        for value in [start, end] {
            try ConnectorWriting.validate(value, state: state, layers: order)
        }
        let layer = try PathEditing.ensureLayer(&builder, state: state, preferred: self.layer)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.connector.start = Connectors.proto(start)
        props.connector.end = Connectors.proto(end)
        let node = builder.append(Ops.create(parent: layer, position: try PathEditing.topPosition(in: layer, state: state), props: props))
        var strokes = Wiretuner_Doc_V1_AppearanceProps()
        strokes.strokes = appearance.strokes
        for op in try PathEditing.appearanceInserts(node, kind: .connector, appearancePath: AppearanceEditing.stackPath(.connector)!, strokes) {
            builder.append(op)
        }
    }
}

/// Moves one end of a connector (an end drag with the Connector tool): writes the whole
/// `ConnectorEnd` -- node, side and point -- as its one ATOMIC register, so attaching to another
/// object or side, and freeing the end at a point, are each one write.  One change, "Move
/// Connector End"; a drag's intermediate writes join one undo step through `Document.beginGroup`.
public struct SetConnectorEnd: Command {
    public var node: OpID
    public var which: ConnectorEndName
    public var value: ConnectorEnd
    public var label: String { "Move Connector End" }

    public init(_ node: OpID, _ which: ConnectorEndName, to value: ConnectorEnd) {
        self.node = node
        self.which = which
        self.value = value
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try ConnectorWriting.requireEditable(node, state: state)
        try ConnectorWriting.validate(value, state: state, layers: LayerOrder(state))
        var props = Wiretuner_Doc_V1_NodeProps()
        if which == .start { props.connector.start = Connectors.proto(value) } else { props.connector.end = Connectors.proto(value) }
        builder.append(Ops.set(node, [ConnectorFields.path(which)], values: props))
    }
}

/// Slides a connector's intermediate runs (a run-handle drag): writes the whole `run_offsets`
/// list, in route order, positive to the right of each run's direction (at most 64 entries; an
/// empty list returns the connector to automatic routing).  One change, "Reshape Connector".
public struct SetConnectorRunOffsets: Command {
    public var node: OpID
    public var offsets: [Double]
    public var label: String { "Reshape Connector" }

    public init(_ node: OpID, offsets: [Double]) {
        self.node = node
        self.offsets = offsets
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try ConnectorWriting.requireEditable(node, state: state)
        guard offsets.count <= ConnectorFields.runOffsetLimit, offsets.allSatisfy(\.isFinite) else { throw ObjectEditError.invalidValue("run_offsets") }
        var props = Wiretuner_Doc_V1_NodeProps()
        props.connector.runOffsets = offsets.map(Measure.rounded)
        builder.append(Ops.set(node, [ConnectorFields.runOffsets], values: props))
    }
}

/// menu:Modify[Alter Path > Reverse Direction] for connectors: swaps `start` and `end` and
/// reverses `run_offsets`, negating each offset, in one `SetFields` per connector.  Negated
/// because an offset moves its run to the right of the run's direction and reversing the
/// connector reverses every run, so the same offsets would push the reshaped runs to the other
/// side; negated and reversed, the line keeps its shape and only its arrowheads swap ends.
/// Locked connectors are skipped.  One change, "Reverse Direction".
public struct ReverseConnectors: Command {
    public var nodes: [OpID]
    public var label: String { "Reverse Direction" }

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in Objects.editable(nodes, in: state) where state.nodeKind(node) == .connector {
            let current = Connectors.props(node, in: state)
            var props = Wiretuner_Doc_V1_NodeProps()
            props.connector.start = current.end
            props.connector.end = current.start
            var paths = [ConnectorFields.start, ConnectorFields.end]
            if !current.runOffsets.isEmpty {
                props.connector.runOffsets = current.runOffsets.reversed().map { $0 == 0 ? 0 : -$0 }
                paths.append(ConnectorFields.runOffsets)
            }
            builder.append(Ops.set(node, paths, values: props))
        }
    }
}

enum ConnectorWriting {
    /// Throws unless `node` is a live, editable connector.
    static func requireEditable(_ node: OpID, state: EngineState) throws {
        guard state.nodeKind(node) == .connector, Objects.editable([node], in: state) == [node] else { throw ObjectEditError.notAnObject(node) }
    }

    /// Throws for a point that is not finite or an end attached to something an end cannot
    /// attach to.
    static func validate(_ end: ConnectorEnd, state: EngineState, layers: LayerOrder) throws {
        guard end.point.isFinite else { throw ObjectEditError.invalidValue("point") }
        if let node = end.node, !Connectors.isAttachable(OpID(node), in: state, layers: layers) {
            throw ObjectEditError.notAnObject(OpID(node))
        }
    }
}
