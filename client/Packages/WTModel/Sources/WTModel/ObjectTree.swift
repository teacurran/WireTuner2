import WTCRDT
import WTGeometry
import WTProto

/// The Layers panel's object tree (layers.adoc, "Objects in the Layers panel"; D-092): each layer's
/// objects frontmost first, and the members of every object that has them -- a group's or clip
/// group's members (the clip path last, at the bottom), a blend's key objects, the shape an
/// extrusion, envelope or perspective object wraps, a chart's pictograph -- read on demand, one
/// container at a time, so a panel over a document of many thousands of objects reads only what
/// its open rows show.  A value over one state: cheap to make, nothing cached.
public struct ObjectTree: Sendable {
    /// What a row stands for besides its kind.
    public enum Role: Hashable, Sendable {
        case object
        /// The clip path of the clip group it is in.
        case clipPath
    }

    public let state: EngineState
    public let order: LayerOrder

    public init(_ state: EngineState, order: LayerOrder? = nil) {
        self.state = state
        self.order = order ?? LayerOrder(state)
    }

    /// The kinds whose members the tree lists.  A symbol instance draws its symbol's artwork, which
    /// is not its own (the Library panel lists symbols), so it has none.
    public static let containerKinds: Set<NodeKind> = [.group, .blend, .extrude, .envelope, .perspective, .chart, .text]

    /// The rows under `node` -- a live layer's objects (with those routed to it from deleted
    /// layers), or an object's live member objects -- frontmost first.
    public func children(of node: OpID) -> [OpID] {
        if order.layer(node) != nil {
            guard order.isLive(node) else { return [] }
            return order.objects(on: node, in: state).filter(isRow).reversed()
        }
        guard let kind = state.nodeKind(node), Self.containerKinds.contains(kind) else { return [] }
        return state.liveChildren(node).filter(isRow).reversed()
    }

    /// Whether the live object `node` has a row: every object but a group with no live members,
    /// which renders nothing and is pruned from the panel (grouping.adoc, "Read-time normalizations").
    func isRow(_ node: OpID) -> Bool {
        guard Objects.isObject(node, in: state) else { return false }
        guard state.nodeKind(node) == .group else { return true }
        return state.store.children(node).contains { Objects.isObject($0, in: state) }
    }

    /// Whether `node` has rows under it, read without listing them: a disclosure triangle.
    public func hasChildren(_ node: OpID) -> Bool {
        if order.layer(node) != nil { return !children(of: node).isEmpty }
        guard let kind = state.nodeKind(node), Self.containerKinds.contains(kind) else { return false }
        return state.store.children(node).contains(where: isRow)
    }

    /// The row `node` sits under: its layer as displayed (a deleted layer's objects show on the
    /// layer they are routed to) or its container object.
    public func parent(of node: OpID) -> OpID? {
        guard let parent = state.store.placement(node)?.parent else { return nil }
        if order.layer(parent) != nil { return order.displayLayer(for: parent) }
        return parent
    }

    /// The rows from the layer down to the one directly above `node` -- what must be open for
    /// `node`'s row to show -- or nil when `node` is not an object in the tree.
    public func ancestors(of node: OpID) -> [OpID]? {
        guard Objects.isObject(node, in: state) else { return nil }
        var result: [OpID] = []
        var current = node
        while let parent = parent(of: current) {
            result.insert(parent, at: 0)
            if order.layer(parent) != nil { return order.isLive(parent) ? result : nil }
            guard let kind = state.nodeKind(parent), Self.containerKinds.contains(kind), state.isLive(parent) else { return nil }
            current = parent
        }
        return nil
    }

    // MARK: Labels

    /// The object's own name, nil when it has none.  Read from the one register, not the whole
    /// props: the panel reads it for every row it shows.
    public func name(of node: OpID) -> String? {
        guard let kind = state.nodeKind(node), let bytes = state.store.register(node, CommonFields.name(kind))?.value,
              let common = try? Wiretuner_Doc_V1_CommonProps(serializedBytes: bytes), !common.name.isEmpty else { return nil }
        return common.name
    }

    /// Whether `node` is its parent's clip path.
    public func role(of node: OpID) -> Role {
        guard let parent = state.store.placement(node)?.parent, Arranging.clipPath(of: parent, in: state) == node else { return .object }
        return .clipPath
    }

    /// What the row says when the object has no name: the kind's name, refined where the panel can
    /// tell more -- "Clip Group", "Clip Path", "Compound Path", a symbol instance's symbol name, the
    /// start of a text block's text.
    public func defaultLabel(of node: OpID) -> String {
        guard let kind = state.nodeKind(node) else { return "Object" }
        if role(of: node) == .clipPath { return "Clip Path" }
        switch kind {
        case .group:
            return state.props(node).group.kind == .clip ? "Clip Group" : kind.title
        case .path:
            return state.props(node).path.contours.count > 1 ? "Compound Path" : kind.title
        case .instance:
            guard let symbol = Symbols.symbol(of: node, in: state) else { return kind.title }
            return name(of: symbol) ?? kind.title
        case .text:
            let text = state.textNode(node)?.string ?? ""
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty else { return kind.title }
            return line.count > Self.textLabelLength ? String(line.prefix(Self.textLabelLength)) + "…" : line
        default:
            return kind.title
        }
    }

    /// How much of a text block's first line labels it.
    public static let textLabelLength = 40

    /// The row's label: the name, else the default label.
    public func label(of node: OpID) -> String {
        name(of: node) ?? defaultLabel(of: node)
    }

    /// Whether the object itself holds `locked`.
    public func isLocked(_ node: OpID) -> Bool {
        guard let kind = state.nodeKind(node), let bytes = state.store.register(node, CommonFields.locked(kind))?.value else { return false }
        return (try? Wiretuner_Doc_V1_CommonProps(serializedBytes: bytes))?.locked ?? false
    }

    // MARK: Filtering

    /// The rows a search for `query` shows (layers.adoc, "Finding objects by name"): every object
    /// whose label contains it (case- and diacritic-insensitive), and the rows above each, so each
    /// match shows in place.  Layers are not matched themselves.
    public func matching(_ query: String) -> Set<OpID> {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var shown: Set<OpID> = []
        func visit(_ node: OpID, path: [OpID]) {
            let below = children(of: node)
            if order.layer(node) == nil, label(of: node).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                shown.insert(node)
                shown.formUnion(path)
            }
            for child in below { visit(child, path: path + [node]) }
        }
        for layer in order.layers { visit(layer.id, path: []) }
        return shown
    }

    // MARK: Dragging

    /// Whether objects can be dropped into `node`: a live layer, or a group or clip group.  Other
    /// containers' members are their structure (a blend's keys, an envelope's contents) and move
    /// only with them.
    public func accepts(_ node: OpID) -> Bool {
        if order.layer(node) != nil { return order.isLive(node) }
        return state.isLive(node) && state.nodeKind(node) == .group
    }

    /// Whether the row `node` can be dragged: an object directly on a layer or in a group, other
    /// than a clip path (which stays at the bottom of its clip group).
    public func isMovable(_ node: OpID) -> Bool {
        guard Objects.isObject(node, in: state), let parent = state.store.placement(node)?.parent else { return false }
        guard order.layer(parent) != nil || state.nodeKind(parent) == .group else { return false }
        return role(of: node) != .clipPath
    }

    /// Whether `node` is `ancestor` or lies under it.
    public func isWithin(_ node: OpID, _ ancestor: OpID) -> Bool {
        var current: OpID? = node
        while let id = current {
            if id == ancestor { return true }
            current = state.store.placement(id)?.parent
        }
        return false
    }
}

/// A drag in the Layers panel's object tree (layers.adoc, "Reordering and regrouping objects";
/// D-092): moves `nodes` into `parent` -- a layer or a group -- at `index` among its rows as the
/// panel lists them (frontmost first, 0 = the top), as one change.  Each moved object keeps its
/// place on the page: one leaving or entering a group has the groups' transforms folded into its
/// own.  The moved objects keep their stacking order among themselves.  Locked objects, objects
/// under a locked group or on a locked layer, clip paths, members of blends and other wrappers,
/// and anything the destination lies within are left where they are; a locked destination takes
/// nothing.  In a clip group nothing goes below the clip path.  One undo step.
public struct RestackObjects: Command {
    public var nodes: [OpID]
    public var parent: OpID
    public var index: Int

    public init(_ nodes: [OpID], into parent: OpID, at index: Int) {
        self.nodes = nodes
        self.parent = parent
        self.index = index
    }

    public var label: String { Objects.label("Move", count: nodes.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let tree = ObjectTree(state)
        guard tree.accepts(parent) else { throw ObjectEditError.invalidValue("parent") }
        let isLayer = tree.order.layer(parent) != nil
        if isLayer ? tree.order.layer(parent)?.locked == true : Objects.isEffectivelyLocked(parent, in: state, layers: tree.order) { return }
        let candidates = Objects.editable(nodes, in: state, order: tree.order).filter { tree.isMovable($0) && !tree.isWithin(parent, $0) }
        // An object whose container moves too goes with it.
        let chosen = Set(candidates)
        let movers = Objects.stackingOrder(candidates.filter { node in
            // Read up the tree, not across the selection: thousands may be chosen.
            var above = state.store.placement(node)?.parent
            while let id = above {
                if chosen.contains(id) { return false }
                above = state.store.placement(id)?.parent
            }
            return true
        }, in: state, order: tree.order)
        guard !movers.isEmpty else { return }
        let moving = Set(movers)

        // Where the block goes: between the rows that stay, at `index` counted in the rows shown.
        let shown = tree.children(of: parent)
        let clip = Arranging.clipPath(of: parent, in: state)
        var cut = min(max(index, 0), shown.count)
        // In a clip group the clip path is the bottom row: nothing goes below it.
        if let clip, let floor = shown.firstIndex(of: clip) { cut = min(cut, floor) }
        let above = shown[..<cut].filter { !moving.contains($0) }
        let below = shown[cut...].filter { !moving.contains($0) }
        // Positions are siblings' only: an object routed here from a deleted layer is not one.
        func own(_ node: OpID) -> Bool { state.store.placement(node)?.parent == parent }
        func position(_ node: OpID) -> [UInt8]? { state.store.placement(node)?.position }
        let lo = below.first(where: own).flatMap(position)
        var hi = above.last(where: own).flatMap(position)
        if let low = lo, let high = hi, !FractionalIndex.less(low, high) { hi = nil }
        let keys = try PathEditing.keys(between: lo, and: hi, count: movers.count)

        guard let space = Objects.pasteboardTransform(ofSpace: parent, in: state).inverted() else { throw ObjectEditError.degenerateTransform }
        for (node, key) in zip(movers, keys) {
            let from = state.store.placement(node)?.parent
            if from != parent, let kind = state.nodeKind(node) {
                let world = Objects.transform(of: node, in: state).concatenating(Objects.parentTransform(of: node, in: state))
                let local = world.concatenating(space)
                if !Self.nearlyEqual(local, Objects.transform(of: node, in: state)) {
                    builder.append(Objects.setTransform(node, kind: kind, local))
                }
            }
            builder.append(Ops.move(node, parent: parent, position: key))
        }
    }

    static func nearlyEqual(_ a: AffineTransform, _ b: AffineTransform) -> Bool {
        let tolerance = 1e-9
        return abs(a.a - b.a) < tolerance && abs(a.b - b.b) < tolerance && abs(a.c - b.c) < tolerance && abs(a.d - b.d) < tolerance
            && abs(a.tx - b.tx) < tolerance && abs(a.ty - b.ty) < tolerance
    }
}
