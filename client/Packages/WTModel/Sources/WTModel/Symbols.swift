import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Register paths of `SymbolProps` (kind `symbol` = 151) and `InstanceProps` (kind `instance` =
/// 153) (library.adoc, "Data model").
public enum SymbolFields {
    public static let name = RegisterPath([NodeKind.symbol.rawValue, 1, 1])
    public static let origin = RegisterPath([NodeKind.symbol.rawValue, 4])
    public static let instanceTransform = RegisterPath([NodeKind.instance.rawValue, 1, 4])
    public static let instanceSymbol = RegisterPath([NodeKind.instance.rawValue, 2])
    public static let overrides = RegisterPath([NodeKind.instance.rawValue, 3])

    public static func override(_ element: OpID) -> RegisterPath { overrides.element(element) }
    public static func overrideFill(_ element: OpID) -> RegisterPath { override(element).child(5) }
    public static func overrideStroke(_ element: OpID) -> RegisterPath { override(element).child(6) }
    public static func overrideHidden(_ element: OpID) -> RegisterPath { override(element).child(7) }
    public static func overrideImage(_ element: OpID) -> RegisterPath { override(element).child(8) }
}

/// Reading symbols, instances and overrides (library.adoc, "Merge semantics", read-time
/// normalizations): the live symbols, the instance index, and each instance's live overrides.
public enum Symbols {
    /// The live symbols, in tree order: children of the well-known `symbols` node and of live
    /// folders at any depth.  A symbol inside a deleted folder is listed at the top level (it is
    /// still read: the folder only affects the list).
    public static func symbols(in state: EngineState) -> [OpID] {
        var result: [OpID] = []
        var pending = [WellKnown.symbols]
        while !pending.isEmpty {
            let next = pending.removeFirst()
            for child in state.store.children(next) {
                switch state.props(child).kind {
                case .symbol?:
                    if state.isLive(child) { result.append(child) }
                case .symbolFolder?:
                    pending.append(child)
                default:
                    break
                }
            }
        }
        return result
    }

    /// The live nodes of `symbol`'s artwork at any depth of grouping (an instance's own artwork is
    /// its symbol's, so the walk never enters one).
    public static func artworkNodes(of symbol: OpID, in state: EngineState) -> Set<OpID> {
        var result: Set<OpID> = []
        var pending = state.liveChildren(symbol)
        while let next = pending.popLast() {
            result.insert(next)
            pending += state.liveChildren(next)
        }
        return result
    }

    /// Symbol → its live instances on the layers and inside symbols (the *Count* column; the
    /// instance index of LIB-009), each list in tree order.
    public static func instanceIndex(in state: EngineState) -> [OpID: [OpID]] {
        var result: [OpID: [OpID]] = [:]
        let order = LayerOrder(state)
        // The objects as the layers show them (a deleted layer's objects on their display layer),
        // then the symbols' artwork.
        var pending = order.layers.flatMap { order.objects(on: $0.id, in: state) } + symbols(in: state).flatMap(state.liveChildren)
        while !pending.isEmpty {
            let next = pending.removeFirst()
            if case .instance(let instance)? = state.props(next).kind, instance.hasSymbol {
                result[OpID(instance.symbol.id), default: []].append(next)
            }
            pending += state.liveChildren(next)
        }
        return result
    }

    /// The symbol `instance` draws, when that is a live symbol and the instance does not cut a
    /// nesting cycle.
    public static func symbol(of instance: OpID, in state: EngineState) -> OpID? {
        guard case .instance(let props)? = state.props(instance).kind, props.hasSymbol else { return nil }
        let symbol = OpID(props.symbol.id)
        guard state.isLive(symbol), state.nodeKind(symbol) == .symbol, !isCut(instance, in: state) else { return nil }
        return symbol
    }

    /// The overrides of `instance` that apply, after the read-time rules: `property` set; the
    /// master node a live node of the instance's current symbol whose kind fits the property
    /// (`TEXT` a text block, `IMAGE` an image); of several for one `(master_node, property)` the
    /// greatest element id.  Keyed by that pair.
    public static func liveOverrides(of instance: OpID, in state: EngineState) -> [OverrideKey: Wiretuner_Doc_V1_Override] {
        guard let symbol = symbol(of: instance, in: state) else { return [:] }
        let artwork = artworkNodes(of: symbol, in: state)
        var result: [OverrideKey: Wiretuner_Doc_V1_Override] = [:]
        for override in state.props(instance).instance.overrides {
            guard override.property != .unspecified, let element = OpID(element: override.id) else { continue }
            let master = OpID(override.masterNode)
            guard artwork.contains(master), fits(override.property, state.props(master)) else { continue }
            let key = OverrideKey(master: master, property: override.property)
            if let existing = result[key], let other = OpID(element: existing.id), other > element { continue }
            result[key] = override
        }
        return result
    }

    static func fits(_ property: Wiretuner_Doc_V1_OverrideProperty, _ props: Wiretuner_Doc_V1_NodeProps) -> Bool {
        switch property {
        case .text: if case .text? = props.kind { return true } else { return false }
        case .image: if case .image? = props.kind { return true } else { return false }
        default: return true
        }
    }

    /// The render-side overrides of `instance` (text overrides are not laid out yet: TXT-001 has
    /// no layout in WTModel, so a text override draws the master's text).
    static func renderOverrides(of instance: OpID, in state: EngineState) -> [InstanceOverride] {
        liveOverrides(of: instance, in: state).sorted { $0.key < $1.key }.compactMap { key, override in
            let node = NodeID(key.master)
            switch key.property {
            case .fill: return .fill(node, Appearances.color(override.fill) ?? .clear)
            case .stroke: return .stroke(node, Appearances.color(override.stroke) ?? .clear)
            case .hidden: return override.hidden ? .hidden(node) : nil
            case .image:
                guard override.hasImage, case .asset(let asset)? = state.props(OpID(override.image.id)).kind,
                      state.isLive(OpID(override.image.id)), !asset.sha256.isEmpty else { return nil }
                return .image(node, assetID: asset.sha256.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined())
            default: return nil
            }
        }
    }

    /// The instance as WTRender draws it (without the enclosing transforms): its symbol, own
    /// transform, overrides and appearance, and for a placeholder the name it shows -- the deleted
    /// symbol's name, or "not a symbol" when the reference names another kind of node.
    static func instanceSpec(_ node: OpID, transform: AffineTransform, in state: EngineState) -> SymbolInstance {
        let props = state.props(node).instance
        let appearance = Appearances.resolve(props.appearance, order: AppearanceEditing.stack(node, in: state))
        guard props.hasSymbol else {
            return SymbolInstance(symbol: nil, transform: transform, appearance: appearance)
        }
        let target = OpID(props.symbol.id)
        guard case .symbol(let symbol)? = state.props(target).kind else {
            return SymbolInstance(symbol: nil, transform: transform, appearance: appearance, placeholderName: state.store.exists(target) ? "not a symbol" : "")
        }
        let live = state.isLive(target) && !isCut(node, in: state)
        return SymbolInstance(symbol: live ? NodeID(target) : nil, transform: transform, overrides: live ? renderOverrides(of: node, in: state) : [],
                              appearance: appearance, placeholderName: symbol.common.name,
                              placeholderRect: live ? nil : lastKnownBounds(of: target, origin: symbol.origin, in: state))
    }

    // MARK: Read-time normalizations (LIB-009)

    /// The placeholder rectangle of an instance of the missing symbol `symbol` in instance space:
    /// the bounds of the artwork a deleted symbol still holds (deleted nodes keep their
    /// registers until compaction) about its origin; nil (72 × 72 pt) when there is none.
    static func lastKnownBounds(of symbol: OpID, origin: Wiretuner_Doc_V1_Point, in state: EngineState) -> Rect? {
        var bounds = Rect.null
        for child in state.store.children(symbol) {
            if let rect = Objects.bounds(of: child, in: state) { bounds = bounds.union(rect) }
        }
        return bounds.isNull ? nil : Rect(x: bounds.minX - origin.x, y: bounds.minY - origin.y, width: bounds.width, height: bounds.height)
    }

    /// The symbol whose artwork holds `node` (at any depth of grouping), when it is inside one.
    public static func enclosingSymbol(of node: OpID, in state: EngineState) -> OpID? {
        var current = state.store.placement(node)?.parent
        while let id = current {
            switch state.store.kind(id) {
            case NodeKind.symbol.rawValue: return id
            case NodeKind.layer.rawValue: return nil
            default: current = state.store.placement(id)?.parent
            }
        }
        return nil
    }

    /// Whether the nested instance `node` is where a nesting cycle is cut (library.adoc,
    /// "Read-time normalizations"): it draws the placeholder at the second level.  Only an
    /// instance inside a symbol's artwork can close a cycle, so instances on layers answer at
    /// once.
    public static func isCut(_ node: OpID, in state: EngineState) -> Bool {
        guard enclosingSymbol(of: node, in: state) != nil else { return false }
        return cutInstances(in: state).contains(node)
    }

    /// The nested instances that cut every nesting cycle: while the graph of symbols (an edge from
    /// the symbol an instance sits in to the symbol it draws) has a cycle, the instance with the
    /// smallest node id among those on a cycle is cut and its edge removed.  Deterministic on
    /// every replica; nothing is written.
    public static func cutInstances(in state: EngineState) -> Set<OpID> {
        var edges: [(instance: OpID, from: OpID, to: OpID)] = []
        for symbol in symbols(in: state) {
            var pending = state.liveChildren(symbol)
            while let next = pending.popLast() {
                if case .instance(let props)? = state.props(next).kind {
                    if props.hasSymbol, state.nodeKind(OpID(props.symbol.id)) == .symbol {
                        edges.append((next, symbol, OpID(props.symbol.id)))
                    }
                } else {
                    pending += state.liveChildren(next)
                }
            }
        }
        edges.sort { $0.instance < $1.instance }
        var cut: Set<OpID> = []
        func reaches(_ from: OpID, _ target: OpID) -> Bool {
            var seen: Set<OpID> = [from]
            var pending = [from]
            while let next = pending.popLast() {
                if next == target { return true }
                for edge in edges where edge.from == next && !cut.contains(edge.instance) && seen.insert(edge.to).inserted {
                    pending.append(edge.to)
                }
            }
            return false
        }
        while let edge = edges.first(where: { !cut.contains($0.instance) && reaches($0.to, $0.from) }) {
            cut.insert(edge.instance)
        }
        return cut
    }
}

/// An override's key: one property of one master node.
public struct OverrideKey: Hashable, Comparable, Sendable {
    public var master: OpID
    public var property: Wiretuner_Doc_V1_OverrideProperty

    public init(master: OpID, property: Wiretuner_Doc_V1_OverrideProperty) {
        self.master = master
        self.property = property
    }

    public static func < (lhs: OverrideKey, rhs: OverrideKey) -> Bool {
        (lhs.master, lhs.property.rawValue) < (rhs.master, rhs.property.rawValue)
    }
}
