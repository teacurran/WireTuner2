import WTCRDT
import WTProto

/// *Remember layer info* (LIB-006, layers.adoc "Remembering layer information" and "Remember layer
/// info"): objects carry the *name* of the layer they came from in `CommonProps.origin_layer`
/// (ATOMIC string) when they are joined, clipped or turned into guides, and go back to the live
/// layer of that name when split, released or released from the Guides layer.  Grouping keeps
/// its members' layers in `GroupProps.layer_origins` instead (OBJ-016, `GroupObjects`/`Ungroup`),
/// and copy carries the names in the pasteboard payload (`ClipboardPayload.layerNames`, read by
/// `Paste`), so neither writes `origin_layer`.
///
/// The helpers are the whole contract for the commands that remember: call `record` for each
/// object before it leaves its layer (only when the preference is on), and `restoreLayer` for
/// each object coming back (a nil answer means "the command's ordinary destination").
public enum LayerMemory {
    /// The name `origin_layer` holds on `node`, when set and not empty.
    public static func originLayer(of node: OpID, in state: EngineState) -> String? {
        guard let name = NodeValues.common(state.props(node))?.originLayer, !name.isEmpty else { return nil }
        return name
    }

    /// The live, ordinary, unlocked layer named `name` -- the one a remembered object returns to
    /// and a paste matches (the bottom-most when several share the name).
    public static func layer(named name: String, in order: LayerOrder) -> OpID? {
        order.layers.first { $0.name == name && $0.role == .ordinary && !$0.locked }?.id
    }

    /// The `SetFields` writing the name of the layer `node` is shown on into its `origin_layer`;
    /// nil when it is on no layer, on an unnamed one, or already remembers that name.
    public static func record(_ node: OpID, in state: EngineState, order: LayerOrder? = nil) -> Wiretuner_Doc_V1_Op? {
        let order = order ?? LayerOrder(state)
        guard let kind = state.nodeKind(node), let layer = order.layer(of: node, in: state),
              let name = order.layer(layer)?.name, !name.isEmpty, originLayer(of: node, in: state) != name else { return nil }
        return write(node, kind: kind, name)
    }

    /// Appends `record` for each of `nodes` to `builder`.
    public static func record(_ nodes: [OpID], in state: EngineState, builder: inout ChangeBuilder) {
        let order = LayerOrder(state)
        for node in nodes {
            if let op = record(node, in: state, order: order) { builder.append(op) }
        }
    }

    /// The `SetFields` writing `name` into `origin_layer` of `node` (of `kind`); an empty name
    /// clears it (writes the register unset).
    public static func write(_ node: OpID, kind: NodeKind, _ name: String) -> Wiretuner_Doc_V1_Op {
        let values = name.isEmpty ? Wiretuner_Doc_V1_NodeProps() : NodeValues.common(kind: kind) { $0.originLayer = name }
        return Ops.set(node, [CommonFields.originLayer(kind)], values: values)
    }

    /// The live layer `node` remembers, when it names one that takes objects.
    public static func restoreLayer(of node: OpID, in state: EngineState, order: LayerOrder? = nil) -> OpID? {
        guard let name = originLayer(of: node, in: state) else { return nil }
        return layer(named: name, in: order ?? LayerOrder(state))
    }

    /// The layer named `name` for a paste into this document: the existing one, one this change
    /// already created (`created`), or a new visible, printing layer created above `active` in
    /// the same change (layers.adoc: two concurrent pastes each create one; nothing is listed).
    public static func layer(named name: String, above active: OpID?, created: inout [String: OpID], state: EngineState,
                             builder: inout ChangeBuilder) throws -> OpID {
        if let existing = layer(named: name, in: LayerOrder(state)) ?? created[name] { return existing }
        var props = Wiretuner_Doc_V1_NodeProps()
        props.layer.common.name = name
        props.layer.visible = true
        props.layer.printing = true
        let layer = builder.append(Ops.create(parent: WellKnown.layers, position: try Layers.keyAbove(active, state: state), props: props))
        created[name] = layer
        return layer
    }
}

/// Turns objects into guide objects (grid-guides.adoc, "To turn a path into a guide"): moves them
/// to the top of the Guides layer; with *Remember layer info* each first records the name of the
/// layer it leaves.  One change: "Convert to Guide" / "Convert N objects to guides".
public struct ConvertToGuides: Command {
    public var nodes: [OpID]
    public var rememberLayerInfo: Bool

    public init(_ nodes: [OpID], rememberLayerInfo: Bool = false) {
        self.nodes = nodes
        self.rememberLayerInfo = rememberLayerInfo
    }

    public var label: String { nodes.count == 1 ? "Convert to Guide" : "Convert \(nodes.count) objects to guides" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let order = LayerOrder(state)
        guard let guides = order.guides, let info = order.layer(guides) else { throw LayerError.guidesLayer }
        guard !info.locked else { throw LayerError.lockedLayer(guides) }
        let objects = Objects.stackingOrder(Objects.editable(nodes, in: state), in: state).filter { order.layer(of: $0, in: state) != guides }
        let keys = try PathEditing.keys(between: state.store.children(guides).last.flatMap { state.store.placement($0)?.position }, and: nil,
                                        count: objects.count)
        for (object, key) in zip(objects, keys) {
            if rememberLayerInfo, let op = LayerMemory.record(object, in: state, order: order) { builder.append(op) }
            builder.append(Ops.move(object, parent: guides, position: key))
        }
    }
}

/// Releases guide objects (layers.adoc, "Remember layer info": guide release): moves objects on
/// the Guides layer to the top of `layer` (the active layer, else the drawing layer) -- or, with
/// *Remember layer info*, of the live layer whose name each remembers, clearing the memory.  One
/// change: "Release to Layer" / "Release N objects to layers".
public struct ReleaseGuideObjects: Command {
    public var nodes: [OpID]
    public var layer: OpID?
    public var rememberLayerInfo: Bool

    public init(_ nodes: [OpID], layer: OpID? = nil, rememberLayerInfo: Bool = false) {
        self.nodes = nodes
        self.layer = layer
        self.rememberLayerInfo = rememberLayerInfo
    }

    public var label: String { nodes.count == 1 ? "Release to Layer" : "Release \(nodes.count) objects to layers" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let order = LayerOrder(state)
        guard let guides = order.guides else { return }
        let objects = Objects.stackingOrder(Objects.editable(nodes, in: state), in: state).filter { Objects.parent(of: $0, in: state) == guides }
        guard !objects.isEmpty else { return }
        let fallback = try PathEditing.ensureLayer(&builder, state: state, preferred: layer)
        var tops: [OpID: [UInt8]?] = [:]
        for object in objects {
            let destination = rememberLayerInfo ? LayerMemory.restoreLayer(of: object, in: state, order: order) ?? fallback : fallback
            let top = tops[destination] ?? state.store.children(destination).last.flatMap { state.store.placement($0)?.position }
            let key = try PathEditing.keys(between: top, and: nil, count: 1)[0]
            tops[destination] = key
            builder.append(Ops.move(object, parent: destination, position: key))
            if rememberLayerInfo, LayerMemory.originLayer(of: object, in: state) != nil, let kind = state.nodeKind(object) {
                builder.append(LayerMemory.write(object, kind: kind, ""))
            }
        }
    }
}
