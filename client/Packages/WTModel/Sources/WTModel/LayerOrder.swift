import WTCRDT
import WTProto

/// Register paths of `LayerProps` (kind `layer` = 150).
public enum LayerFields {
    public static let kind = NodeKind.layer.rawValue
    public static let name = RegisterPath([kind, 1, 1])
    public static let role = RegisterPath([kind, 2])
    public static let visible = RegisterPath([kind, 3])
    public static let locked = RegisterPath([kind, 4])
    public static let printing = RegisterPath([kind, 5])
    public static let keyline = RegisterPath([kind, 6])
    public static let highlight = RegisterPath([kind, 7])
    public static let mergedInto = RegisterPath([kind, 8])
}

/// One layer as read (layers.adoc, "Data model", with the read-time normalizations applied).
public struct LayerInfo: Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        case ordinary, guides
    }

    public var id: OpID
    public var name: String
    public var role: Role
    public var visible: Bool
    public var locked: Bool
    public var printing: Bool
    public var keyline: Bool
    /// The selection highlight colour, when one is set.
    public var highlight: Wiretuner_Doc_V1_Color?
    /// The layer a merge moved this layer's objects onto (set only on a deleted layer).
    public var mergedInto: OpID?
    /// Whether the layer node is deleted (a deleted layer can still be read as live: the Guides
    /// layer, or the default layer when every printing layer was deleted).
    public var isDeleted: Bool

    /// A background layer: never printed, drawn below every printing layer.
    public var isBackground: Bool { !printing }
}

/// The derived view of the layer list (layers.adoc, "Ordering rule", "Default layer", "Delete
/// layer versus add objects to it", "Guides layer invariants"): the layers in stacking order,
/// the default layer, the Guides layer, and where objects on a deleted layer are shown.
///
/// Stacking order, bottom first: background layers, then printing layers, each group in tree
/// order (position, then node id).  The panel lists it in reverse, frontmost at the top.
public struct LayerOrder: Hashable, Sendable {
    /// The layers read as live, bottom first.
    public let layers: [LayerInfo]
    /// Every layer node, deleted ones included, by id.
    public let all: [OpID: LayerInfo]
    /// The Guides layer: the one with `LAYER_ROLE_GUIDES` and the smallest id (read as live even
    /// when deleted).
    public let guides: OpID?
    /// The live, printing, non-Guides layer with the smallest node id; when there is none, the
    /// non-Guides layer with the smallest id (read as live and printing).
    public let defaultLayer: OpID?

    public init(_ state: EngineState) {
        let nodes = state.store.children(WellKnown.layers).filter { state.store.exists($0) && state.nodeKind($0) == .layer }
        var infos: [OpID: LayerInfo] = [:]
        let guideCandidates = nodes.filter { state.props($0).layer.role == .guides }
        let guides = guideCandidates.min()
        for node in nodes {
            let props = state.props(node).layer
            infos[node] = LayerInfo(
                id: node, name: props.common.name, role: node == guides ? .guides : .ordinary,
                visible: props.visible, locked: props.locked, printing: props.printing, keyline: props.keyline,
                highlight: props.hasHighlight ? props.highlight : nil,
                mergedInto: props.hasMergedInto ? OpID(props.mergedInto.id) : nil,
                isDeleted: !state.isLive(node)
            )
        }
        let ordinary = nodes.filter { $0 != guides }
        var defaultLayer = ordinary.filter { infos[$0]!.printing && !infos[$0]!.isDeleted }.min()
        if defaultLayer == nil, let fallback = ordinary.min() {
            defaultLayer = fallback
            infos[fallback]!.printing = true
        }
        let live = nodes.filter { !infos[$0]!.isDeleted || $0 == guides || $0 == defaultLayer }
        // `nodes` is already in tree order; a stable partition keeps it within each group.
        layers = live.filter { !infos[$0]!.printing }.map { infos[$0]! } + live.filter { infos[$0]!.printing }.map { infos[$0]! }
        all = infos
        self.guides = guides
        self.defaultLayer = defaultLayer
    }

    /// The layer `id`, as read.
    public func layer(_ id: OpID) -> LayerInfo? { all[id] }

    /// Whether `id` reads as a live layer.
    public func isLive(_ id: OpID) -> Bool { layers.contains { $0.id == id } }

    /// The index of `id` in `layers`.
    public func index(of id: OpID) -> Int? { layers.firstIndex { $0.id == id } }

    /// The layer objects on `layer` are shown on: itself when live; a deleted layer's
    /// `merged_into` target when that is live; otherwise the default layer.
    public func displayLayer(for layer: OpID) -> OpID? {
        if isLive(layer) { return layer }
        if let target = all[layer]?.mergedInto, isLive(target) { return target }
        return defaultLayer
    }

    /// The live objects shown on the live layer `layer`, bottom first: its own live children,
    /// then the live children of deleted layers routed to it (by the deleted layers' tree order).
    public func objects(on layer: OpID, in state: EngineState) -> [OpID] {
        var objects = state.liveChildren(layer)
        for node in state.store.children(WellKnown.layers) where all[node] != nil && !isLive(node) && displayLayer(for: node) == layer {
            objects += state.liveChildren(node)
        }
        return objects
    }

    /// The live printing, non-Guides layers.
    public var printingLayers: [LayerInfo] { layers.filter { $0.printing && $0.role == .ordinary } }

    /// The layer new objects go into by default: the top-most live, visible, unlocked, non-Guides
    /// layer.
    public var drawingLayer: OpID? {
        layers.reversed().first { $0.visible && !$0.locked && $0.role == .ordinary }?.id
    }

    /// The layer the object `node` (top-level or a group member) is shown on.
    public func layer(of node: OpID, in state: EngineState) -> OpID? {
        var current = node
        while let parent = state.store.placement(current)?.parent {
            if all[parent] != nil { return displayLayer(for: parent) }
            current = parent
        }
        return nil
    }
}
