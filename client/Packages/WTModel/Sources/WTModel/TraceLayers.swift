import WTCRDT
import WTGeometry
import WTRender

/// The Trace tool's *Trace layers* option (tracing.adoc, "Setting the Trace tool options";
/// IMG-023): which layers' objects the tool looks at inside its selection -- *All*,
/// *Foreground* (the printing layers) or *Background* (the non-printing ones).  The Guides layer
/// is never traced.
public enum TraceLayers: String, CaseIterable, Codable, Sendable {
    case all, foreground, background

    public var title: String {
        switch self {
        case .all: "All"
        case .foreground: "Foreground"
        case .background: "Background"
        }
    }

    /// Whether objects on `layer` are traced.
    public func includes(_ layer: LayerInfo) -> Bool {
        guard layer.role == .ordinary else { return false }
        switch self {
        case .all: return true
        case .foreground: return !layer.isBackground
        case .background: return layer.isBackground
        }
    }

    /// Whether the object `node` of `state` is on a traced layer (an object on no layer -- a
    /// master's or a glyph's canvas content -- is traced with *All* only).
    public func includes(node: OpID, in state: EngineState, order: LayerOrder? = nil) -> Bool {
        let order = order ?? LayerOrder(state)
        guard let layer = order.layer(of: node, in: state).flatMap(order.layer) else { return self == .all }
        return includes(layer)
    }

    /// `list` with only the top-level items of objects on traced layers (items of no node --
    /// furniture -- are dropped unless *All*); *All* is `list` itself.
    public func filter(_ list: DisplayList, in state: EngineState) -> DisplayList {
        guard self != .all else { return list }
        let order = LayerOrder(state)
        var items: [DisplayItem] = []
        var bounds: [Rect?] = []
        var ids: [NodeID?] = []
        for (index, item) in list.items.enumerated() {
            guard index < list.nodeIDs.count, let id = list.nodeIDs[index], includes(node: OpID(id), in: state, order: order) else { continue }
            items.append(item)
            bounds.append(list.itemBounds[index])
            ids.append(id)
        }
        return DisplayList(canvas: list.canvas, items: items, itemBounds: bounds, nodeIDs: ids)
    }
}
