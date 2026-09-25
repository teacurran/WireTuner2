import WTCRDT
import WTProto

/// The style-to-objects index kept up to date change by change (styles.adoc, "Client"; LIB-018's
/// `GraphicStyleResolver.index(in:)` read in full once): which live objects -- on the layers, in
/// groups and in symbols' artwork -- use each graphic style after the read-time rules.  The
/// Styles panel reads it for highlighting the selection's style, *Remove Unused* and the object
/// counts.
///
/// Invalidation: `refresh` re-reads every node a change touched together with its subtree (a
/// created, moved or deleted group moves its members in or out of the index), and, for each
/// touched style node, the objects whose reference names it (a style arriving after an object
/// that already names it, a style deleted and restored, a kind that stops reading as graphic).
public struct GraphicStyleIndex: Hashable, Sendable {
    /// Style → the objects using it.
    public private(set) var objects: [OpID: Set<OpID>] = [:]
    /// Object → the style it uses.
    private var styleOf: [OpID: OpID] = [:]
    /// Object → the node its reference names, valid or not (for re-reading when that node changes).
    private var named: [OpID: OpID] = [:]
    private var naming: [OpID: Set<OpID>] = [:]

    public init() {}

    /// The index of `state` read in full.
    public init(_ state: EngineState, styles: GraphicStyleResolver) {
        for (style, list) in styles.index(in: state) {
            objects[style] = Set(list)
            for object in list { styleOf[object] = style }
        }
        for object in Self.indexed(in: state) {
            if let target = Self.target(object, in: state) { name(object, target) }
        }
    }

    /// The objects using `style`, in id order.
    public func objects(using style: OpID) -> [OpID] {
        (objects[style] ?? []).sorted()
    }

    /// The style `object` uses, when it is indexed.
    public func style(of object: OpID) -> OpID? {
        styleOf[object]
    }

    /// Whether some object uses `style`.
    public func isUsed(_ style: OpID) -> Bool {
        objects[style]?.isEmpty == false
    }

    /// The nodes the ops of `change` write, create under, move or delete.
    public static func touched(by change: Wiretuner_Doc_V1_Change) -> Set<OpID> {
        var result: Set<OpID> = []
        for (op, id) in zip(change.ops, change.opIDs) {
            for (node, _) in DocumentDisplayListBuilder.targets(op) { result.insert(node) }
            if case .create = op.op { result.insert(id) }
        }
        return result
    }

    /// Brings the index up to `state` after changes that touched `nodes` (`touched(by:)`);
    /// `styles` must already be updated to `state`.
    public mutating func refresh(_ nodes: Set<OpID>, in state: EngineState, styles: GraphicStyleResolver) {
        var pending: [OpID] = []
        var seen: Set<OpID> = []
        func add(_ node: OpID) {
            if seen.insert(node).inserted { pending.append(node) }
        }
        for node in nodes.sorted() {
            if state.store.kind(node) == GraphicStyleResolver.styleKind {
                for object in naming[node] ?? [] { add(object) }
            }
            add(node)
        }
        var cursor = 0
        while cursor < pending.count {
            let node = pending[cursor]
            cursor += 1
            for child in state.store.children(node) { add(child) }
        }
        for node in pending {
            remove(node)
            guard Self.isIndexed(node, in: state) else { continue }
            if let target = Self.target(node, in: state) { name(node, target) }
            if let style = styles.style(of: node, in: state) {
                styleOf[node] = style
                objects[style, default: []].insert(node)
            }
        }
    }

    private mutating func remove(_ node: OpID) {
        if let style = styleOf.removeValue(forKey: node) {
            objects[style]?.remove(node)
            if objects[style]?.isEmpty == true { objects[style] = nil }
        }
        if let target = named.removeValue(forKey: node) {
            naming[target]?.remove(node)
            if naming[target]?.isEmpty == true { naming[target] = nil }
        }
    }

    private mutating func name(_ object: OpID, _ target: OpID) {
        named[object] = target
        naming[target, default: []].insert(object)
    }

    /// The node `object`'s style reference names, valid or not.
    static func target(_ object: OpID, in state: EngineState) -> OpID? {
        guard let bytes = state.register(object, RegisterPath([state.store.kind(object), 1, 7]))?.value,
              let record = WireReader.fields(bytes)?.first, let ref = try? Wiretuner_Doc_V1_NodeRef(serializedBytes: record.payload),
              ref.hasID else { return nil }
        return OpID(ref.id)
    }

    /// Whether the index covers `node`: it and every node up to a live top-level layer (or a live
    /// symbol in the symbols collection, through symbol folders) are live, and it is below that
    /// layer or symbol -- the nodes `GraphicStyleResolver.index(in:)` walks.
    static func isIndexed(_ node: OpID, in state: EngineState) -> Bool {
        var current = node
        while state.isLive(current), let parent = state.store.placement(current)?.parent {
            if parent == WellKnown.layers { return current != node }
            if state.nodeKind(current) == .symbol, isInSymbols(parent, state: state) { return current != node }
            current = parent
        }
        return false
    }

    /// Whether `node` is the symbols collection or a folder below it.
    private static func isInSymbols(_ node: OpID, state: EngineState) -> Bool {
        var current: OpID? = node
        while let id = current {
            if id == WellKnown.symbols { return true }
            guard case .symbolFolder? = state.props(id).kind else { return false }
            current = state.store.placement(id)?.parent
        }
        return false
    }

    /// Every node the index covers, in tree order.
    static func indexed(in state: EngineState) -> [OpID] {
        var pending = state.liveChildren(WellKnown.layers).flatMap(state.liveChildren) + Symbols.symbols(in: state).flatMap(state.liveChildren)
        var cursor = 0
        while cursor < pending.count {
            pending += state.liveChildren(pending[cursor])
            cursor += 1
        }
        return pending
    }
}
