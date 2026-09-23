import WTCRDT
import WTProto

/// Why a layer command was refused (layers.adoc, "Guides layer invariants", "Removing layers").
public enum LayerError: Error, Equatable, Sendable {
    case notALayer(OpID)
    /// The Guides layer cannot be renamed, merged or removed.
    case guidesLayer
    /// A document always keeps at least one printing layer.
    case lastPrintingLayer
    /// A locked layer takes no objects.
    case lockedLayer(OpID)
}

/// Shared checks of the layer commands.
enum Layers {
    /// The layer `id` as read, when it is a live layer.
    static func live(_ id: OpID, _ order: LayerOrder) throws -> LayerInfo {
        guard order.isLive(id), let info = order.layer(id) else { throw LayerError.notALayer(id) }
        return info
    }

    /// A live, non-Guides layer.
    static func ordinary(_ id: OpID, _ order: LayerOrder) throws -> LayerInfo {
        let info = try live(id, order)
        guard info.role == .ordinary else { throw LayerError.guidesLayer }
        return info
    }

    /// Throws when no printing, non-Guides layer would be left once `removed` stop printing.
    static func keepsPrinting(without removed: Set<OpID>, _ order: LayerOrder) throws {
        guard order.printingLayers.contains(where: { !removed.contains($0.id) }) else { throw LayerError.lastPrintingLayer }
    }

    static func values(_ build: (inout Wiretuner_Doc_V1_LayerProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        build(&props.layer)
        return props
    }

    /// A key directly above `layer` in tree order (at the top when nil).
    static func keyAbove(_ layer: OpID?, state: EngineState) throws -> [UInt8] {
        guard let layer else { return try PathEditing.topPosition(in: WellKnown.layers, state: state) }
        return try Arranging.keys(next: layer, above: true, count: 1, in: state)[0]
    }

    /// "layer" or "N layers".
    static func count(_ n: Int) -> String { n == 1 ? "layer" : "\(n) layers" }
}

/// *New* (LIB-002): a layer directly above the active layer (at the top without one), printing
/// like it, visible and unlocked.  The caller makes it active.
public struct CreateLayer: Command {
    public var name: String
    public var above: OpID?
    public var label: String { "New Layer" }

    public init(name: String = "Layer", above: OpID? = nil) {
        self.name = name
        self.above = above
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let order = LayerOrder(state)
        let active = above.flatMap { order.isLive($0) ? order.layer($0) : nil }
        let props = Layers.values { layer in
            layer.common.name = String(name.prefix(256))
            layer.visible = true
            layer.printing = active?.printing ?? true
        }
        builder.append(Ops.create(parent: WellKnown.layers, position: try Layers.keyAbove(active?.id, state: state), props: props))
    }
}

/// *Duplicate* (layers.adoc "Duplicate layer"): the layer's props with " copy" added to the name
/// (an ordinary layer even when copying Guides) and a deep copy of each of its live objects,
/// directly above the original.  Edits to the originals afterwards do not reach the copies.
public struct DuplicateLayer: Command {
    public var layer: OpID
    public var label: String { "Duplicate Layer" }

    public init(_ layer: OpID) {
        self.layer = layer
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let order = LayerOrder(state)
        let info = try Layers.live(layer, order)
        var tree = NodeTree(props: state.props(layer))
        tree.props.layer.common.name = String((info.name + " copy").prefix(256))
        tree.children = order.objects(on: layer, in: state).map { NodeTree($0, state: state) }
        try NodeCopier.create(tree, parent: WellKnown.layers, position: try Layers.keyAbove(layer, state: state), schema: state.schema,
                              builder: &builder)
    }
}

/// Renames a layer; the Guides layer cannot be renamed.
public struct RenameLayer: Command {
    public var layer: OpID
    public var name: String
    public var label: String { "Rename Layer" }

    public init(_ layer: OpID, to name: String) {
        self.layer = layer
        self.name = name
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try Layers.ordinary(layer, LayerOrder(state))
        builder.append(Ops.set(layer, [LayerFields.name], values: Layers.values { $0.common.name = String(name.prefix(256)) }))
    }
}

/// *Remove* (layers.adoc "Delete layer versus add objects to it"): every object the client sees
/// on each layer is deleted, then the layer, in one change "Remove layer <name>".  Refused for the
/// Guides layer and when no printing layer would remain.
public struct RemoveLayers: Command {
    public var layers: [OpID]
    public var names: [String] = []

    public init(_ layers: [OpID]) {
        self.layers = layers
    }

    public var label: String {
        layers.count == 1 ? "Remove layer \(names.first ?? "")".trimmingSuffix() : "Remove \(layers.count) layers"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let order = LayerOrder(state)
        for layer in layers { _ = try Layers.ordinary(layer, order) }
        try Layers.keepsPrinting(without: Set(layers), order)
        for layer in layers {
            for object in order.objects(on: layer, in: state) { builder.append(Ops.setDeleted(object)) }
            builder.append(Ops.setDeleted(layer))
        }
    }
}

extension RemoveLayers {
    /// The command with the layer names read from `state` for its label.
    public static func named(_ layers: [OpID], in state: EngineState) -> RemoveLayers {
        var command = RemoveLayers(layers)
        let order = LayerOrder(state)
        command.names = layers.compactMap { order.layer($0)?.name }
        return command
    }
}

private extension String {
    func trimmingSuffix() -> String {
        var copy = self
        while copy.last == " " { copy.removeLast() }
        return copy
    }
}

/// Drags a layer to `index` in the stacking order (`LayerOrder.layers`, bottom first), optionally
/// across the separator (`printing`): a `MoveNode` among the layers of the destination group and,
/// when the group changes, `SetFields(printing)`.  Refused when it would leave no printing layer.
public struct ReorderLayer: Command {
    public var layer: OpID
    public var index: Int
    public var printing: Bool?
    public var label: String { "Move Layer" }

    public init(_ layer: OpID, to index: Int, printing: Bool? = nil) {
        self.layer = layer
        self.index = index
        self.printing = printing
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let order = LayerOrder(state)
        let info = try Layers.live(layer, order)
        let others = order.layers.filter { $0.id != layer }
        let target = min(max(index, 0), others.count)
        let printing = printing ?? (target > 0 ? others[target - 1].printing : others.first?.printing ?? info.printing)
        if info.printing && !printing { try Layers.keepsPrinting(without: [layer], order) }
        // Neighbours within the destination group, in tree order.
        let below = others[..<target].last { $0.printing == printing }
        let above = others[target...].first { $0.printing == printing }
        let position: (LayerInfo?) -> [UInt8]? = { $0.flatMap { state.store.placement($0.id)?.position } }
        var lo = position(below), hi = position(above)
        if let l = lo, let h = hi, !FractionalIndex.less(l, h) { lo = nil; hi = h }
        let key = try PathEditing.keys(between: lo, and: hi, count: 1)[0]
        builder.append(Ops.move(layer, parent: WellKnown.layers, position: key))
        if printing != info.printing {
            builder.append(Ops.set(layer, [LayerFields.printing], values: Layers.values { $0.printing = printing }))
        }
    }
}

/// Sets one flag on layers (the check, circle and padlock columns, *All On*/*All Off*,
/// drag-through toggling): one change, labelled "Hide 4 layers", "Lock layer", ...  Turning
/// `printing` off on the last printing layer is refused.
public struct SetLayerFlag: Command {
    public enum Flag: Sendable, Hashable, CaseIterable {
        case visible, locked, printing, keyline
    }

    public var layers: [OpID]
    public var flag: Flag
    public var value: Bool

    public init(_ layers: [OpID], _ flag: Flag, _ value: Bool) {
        self.layers = layers
        self.flag = flag
        self.value = value
    }

    public var label: String {
        let verb = switch (flag, value) {
        case (.visible, true): "Show"
        case (.visible, false): "Hide"
        case (.locked, true): "Lock"
        case (.locked, false): "Unlock"
        case (.printing, true): "Print"
        case (.printing, false): "Don't print"
        case (.keyline, true): "Keyline"
        case (.keyline, false): "Preview"
        }
        return "\(verb) \(Layers.count(layers.count))"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let order = LayerOrder(state)
        for layer in layers { _ = try Layers.live(layer, order) }
        if flag == .printing, !value { try Layers.keepsPrinting(without: Set(layers), order) }
        let path: RegisterPath = switch flag {
        case .visible: LayerFields.visible
        case .locked: LayerFields.locked
        case .printing: LayerFields.printing
        case .keyline: LayerFields.keyline
        }
        let values = Layers.values { layer in
            switch flag {
            case .visible: layer.visible = value
            case .locked: layer.locked = value
            case .printing: layer.printing = value
            case .keyline: layer.keyline = value
            }
        }
        for layer in layers {
            builder.append(Ops.set(layer, [path], values: values))
        }
    }
}

/// Sets a layer's highlight colour (the swatch column).
public struct SetLayerHighlight: Command {
    public var layer: OpID
    public var color: Wiretuner_Doc_V1_Color
    public var label: String { "Change Highlight Color" }

    public init(_ layer: OpID, color: Wiretuner_Doc_V1_Color) {
        self.layer = layer
        self.color = color
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try Layers.live(layer, LayerOrder(state))
        builder.append(Ops.set(layer, [LayerFields.highlight], values: Layers.values { $0.highlight = color }))
    }
}

/// *Merge Selected Layers* (LIB-003, layers.adoc "Merge layers"): the layers merge onto the lowest
/// of them, which keeps its name and settings.  For each other layer, lowest first, its objects
/// move onto the target above everything already there (keeping the stacking), then the layer is
/// deleted with `merged_into` naming the target -- so objects someone adds to it concurrently are
/// shown on the target.  The Guides layer never takes part.  One change "Merge N layers".
public struct MergeLayers: Command {
    public var layers: [OpID]

    public init(_ layers: [OpID]) {
        self.layers = layers
    }

    /// *Merge Foreground Layers*: every printing layer except Guides onto the lowest of them.
    public static func foreground(in state: EngineState) -> MergeLayers {
        MergeLayers(LayerOrder(state).printingLayers.map(\.id))
    }

    public var label: String { "Merge \(layers.count) layers" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let order = LayerOrder(state)
        let sources = try layers.map { try Layers.ordinary($0, order) }.sorted { order.index(of: $0.id)! < order.index(of: $1.id)! }
        guard let target = sources.first, sources.count > 1 else { return }
        let moving = sources.dropFirst().flatMap { order.objects(on: $0.id, in: state) }
        let last = state.store.children(target.id).last.flatMap { state.store.placement($0)?.position }
        let keys = try PathEditing.keys(between: last, and: nil, count: moving.count)
        for (object, key) in zip(moving, keys) {
            builder.append(Ops.move(object, parent: target.id, position: key))
        }
        for source in sources.dropFirst() {
            builder.append(Ops.set(source.id, [LayerFields.mergedInto], values: Layers.values { $0.mergedInto.id = target.id.proto }))
            builder.append(Ops.setDeleted(source.id))
        }
    }
}

/// Moves objects onto a layer (*Move Objects to Current Layer*, *Move Selection to This Layer*, a
/// click on a layer name): they arrive at the top of the destination in their previous relative
/// order.  Refused onto a locked layer.  Locked objects stay where they are.
public struct MoveObjectsToLayer: Command {
    public var nodes: [OpID]
    public var layer: OpID

    public init(_ nodes: [OpID], to layer: OpID) {
        self.nodes = nodes
        self.layer = layer
    }

    public var label: String { nodes.count == 1 ? "Move to Layer" : "Move \(nodes.count) objects to layer" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let order = LayerOrder(state)
        let info = try Layers.live(layer, order)
        guard !info.locked else { throw LayerError.lockedLayer(layer) }
        let objects = Objects.stackingOrder(Objects.editable(nodes, in: state), in: state)
        let last = state.store.children(layer).last.flatMap { state.store.placement($0)?.position }
        let keys = try PathEditing.keys(between: last, and: nil, count: objects.count)
        for (object, key) in zip(objects, keys) {
            builder.append(Ops.move(object, parent: layer, position: key))
        }
    }
}
