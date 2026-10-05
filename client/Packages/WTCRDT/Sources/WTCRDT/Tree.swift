/// Where a node sits: its parent, its position among the parent's children, and the tree op
/// (`CreateNode` or `MoveNode`) that put it there.
public struct Placement: Hashable, Sendable, CustomStringConvertible {
    public let parent: OpID
    public let position: [UInt8]
    public let op: OpID

    public init(parent: OpID, position: [UInt8], op: OpID) {
        self.parent = parent
        self.position = position
        self.op = op
    }

    public var description: String { "\(parent)/\(Bytes.hex(position))@\(op)" }
}

/// One tree op as the move log records it (`MoveLogEntry` in doc/v1/snapshot.proto): what the op
/// asked for, the node's placement before it, and whether it applied.
public struct MoveLogEntry: Hashable, Sendable {
    public let op: OpID
    public let node: OpID
    public let parent: OpID
    public let position: [UInt8]
    /// A `CreateNode` (the node comes into existence here) rather than a `MoveNode`.
    public let creates: Bool
    /// The node's placement before the op, when it applied (nil: it had none).
    public internal(set) var old: Placement?
    /// False when the op was skipped: an unknown node or parent, a well-known node, or a move
    /// that would make the node its own ancestor.
    public internal(set) var applied: Bool
}

/// The node tree (docs/spec/crdt-model.adoc, "Tree moves"; CRDT-002): Kleppmann et al.'s
/// highly-available move operation.  Every tree op is kept in the move log in OpId order; an op
/// that arrives late undoes the logged ops after it, applies, and redoes them, so every replica
/// reaches the placement of applying all tree ops in OpId order:
///
/// * a `CreateNode` makes its node exist and places it under its parent when the parent exists;
/// * a `MoveNode` applies when the node and the parent exist, the node is not well-known, and the
///   parent is neither the node nor one of its descendants; otherwise it is skipped.
///
/// The well-known nodes (replica 0, counters 0..15) always exist; 1..15 sit under the document
/// (0:0) with an empty position, so they sort by id.  wt-crdt's `Tree` is this type in Java.
///
/// Each parent's children are kept in sibling order as placements change (`SiblingList`), so
/// reading them costs no sort (crdt-model.adoc, "Tree moves", As built).
struct Tree: Sendable {
    /// The unstable move log, ascending by op: every tree op not yet pruned as stable (CRDT-010).
    private(set) var log: [MoveLogEntry] = []
    private var live: Set<OpID> = []
    private var placements: [OpID: Placement] = [:]
    private var children: [OpID: SiblingList] = [:]

    init() {}

    /// A tree as a snapshot holds it: the move log, every placed node's placement, and the nodes
    /// that exist (every created node).
    init(log: [MoveLogEntry], placements: [OpID: Placement], live: Set<OpID>) {
        self.log = log
        self.live = live
        self.placements = placements
        var unsorted: [OpID: [(position: [UInt8], id: OpID)]] = [:]
        for (node, placement) in placements {
            unsorted[placement.parent, default: []].append((placement.position, node))
        }
        children = unsorted.mapValues(SiblingList.init(sorting:))
    }

    static func isWellKnown(_ node: OpID) -> Bool {
        node.replica == 0 && node.counter < NodeStore.wellKnownLimit
    }

    /// Whether `node` exists in the tree: well-known, or created by an op applied so far.
    func exists(_ node: OpID) -> Bool {
        Self.isWellKnown(node) || live.contains(node)
    }

    /// The node's placement, or nil for the document root and for nodes without a parent.
    func placement(_ node: OpID) -> Placement? {
        if Self.isWellKnown(node) {
            return node == .zero ? nil : Placement(parent: .zero, position: [], op: .zero)
        }
        return placements[node]
    }

    /// The children of `parent`, deleted ones included, by position then id.
    func children(_ parent: OpID) -> [OpID] {
        guard parent == .zero else { return children[parent]?.ids ?? [] }
        var list = children[.zero] ?? SiblingList()
        for counter in 1..<NodeStore.wellKnownLimit {
            list.insert(.wellKnown(counter), at: [])
        }
        return list.ids
    }

    /// Applies one tree op in OpId order (undo, do, redo); a replay of a logged op is ignored.
    /// While ops are undone and redone only `placements` changes; the children index is updated
    /// once at the end for the nodes whose parent or position actually changed.
    mutating func apply(op: OpID, node: OpID, parent: OpID, position: [UInt8], creates: Bool) {
        var low = 0
        var high = log.count
        while low < high {
            let mid = (low + high) / 2
            if log[mid].op < op { low = mid + 1 } else { high = mid }
        }
        guard low == log.count || log[low].op != op else { return }
        var touched: [OpID: Placement?] = [:]
        var index = log.count
        while index > low {
            index -= 1
            undo(log[index], &touched)
        }
        let entry = MoveLogEntry(op: op, node: node, parent: parent, position: position, creates: creates,
                                 old: nil, applied: false)
        log.insert(entry, at: low)
        for redo in low..<log.count {
            log[redo] = perform(log[redo], &touched)
        }
        for (node, before) in touched {
            let after = placements[node]
            guard before?.parent != after?.parent || before?.position != after?.position else { continue }
            if let before {
                children[before.parent]?.remove(node, at: before.position)
            }
            if let after {
                children[after.parent, default: SiblingList()].insert(node, at: after.position)
            }
        }
    }

    private mutating func perform(_ entry: MoveLogEntry, _ touched: inout [OpID: Placement?]) -> MoveLogEntry {
        var entry = entry
        if entry.creates {
            live.insert(entry.node)
        }
        let applies = !Self.isWellKnown(entry.node) && live.contains(entry.node) && exists(entry.parent)
            && !isAncestor(entry.node, of: entry.parent)
        entry.applied = applies
        entry.old = applies ? placements[entry.node] : nil
        if applies {
            place(entry.node, Placement(parent: entry.parent, position: entry.position, op: entry.op), &touched)
        }
        return entry
    }

    private mutating func undo(_ entry: MoveLogEntry, _ touched: inout [OpID: Placement?]) {
        if entry.applied {
            place(entry.node, entry.old, &touched)
        }
        if entry.creates {
            live.remove(entry.node)
        }
    }

    // MARK: Garbage collection

    /// Drops the entries whose op is stable; returns how many.  Every later tree op is causally
    /// after a stable one and so has a greater OpId: a stable entry is never undone again, and the
    /// entries left keep the placement each replaced (`old`), which is all undoing them needs.
    mutating func prune(_ stable: (OpID) -> Bool) -> Int {
        let before = log.count
        log.removeAll { stable($0.op) }
        return before - log.count
    }

    /// `node` and every node placed below it.
    func subtree(_ node: OpID) -> [OpID] {
        var out = [node]
        var index = 0
        while index < out.count {
            out += children[out[index]]?.ids ?? []
            index += 1
        }
        return out
    }

    /// Whether a logged entry names one of `nodes` as its node, its parent or its old parent.
    func names(_ nodes: [OpID]) -> Bool {
        let set = Set(nodes)
        return log.contains { set.contains($0.node) || set.contains($0.parent) || $0.old.map { set.contains($0.parent) } == true }
    }

    /// Forgets `nodes`: they no longer exist, sit anywhere or have children.
    mutating func remove(_ nodes: [OpID]) {
        for node in nodes {
            if let placement = placements.removeValue(forKey: node) {
                children[placement.parent]?.remove(node, at: placement.position)
            }
            children[node] = nil
            live.remove(node)
        }
    }

    // Whether `ancestor` is `node` or above it.
    private func isAncestor(_ ancestor: OpID, of node: OpID) -> Bool {
        var current = node
        while current != ancestor {
            guard let up = placement(current) else { return false }
            current = up.parent
        }
        return true
    }

    // Sets a placement, remembering the node's placement before the first change of this apply.
    private mutating func place(_ node: OpID, _ placement: Placement?, _ touched: inout [OpID: Placement?]) {
        if touched.index(forKey: node) == nil {
            touched[node] = .some(placements[node])
        }
        placements[node] = placement
    }
}

/// One parent's children in sibling order -- by position, then id (`FractionalIndex.childOrder`)
/// -- each with the position it is listed under.  The two arrays run in parallel, so the ids are
/// handed out without copying, and a node is found by binary search on the position it was
/// inserted with: an apply changes `placements` before it updates the lists, so a list must not
/// look positions up there.
struct SiblingList: Sendable {
    private(set) var ids: [OpID] = []
    private var positions: [[UInt8]] = []

    init() {}

    /// The entries in sibling order (one sort, when a snapshot is loaded).
    init(sorting entries: [(position: [UInt8], id: OpID)]) {
        let sorted = entries.sorted(by: FractionalIndex.childOrder)
        ids = sorted.map(\.id)
        positions = sorted.map(\.position)
    }

    /// The first index whose entry does not sort before (`position`, `id`).
    private func lowerBound(_ position: [UInt8], _ id: OpID) -> Int {
        var low = 0
        var high = ids.count
        while low < high {
            let mid = (low + high) / 2
            if FractionalIndex.childOrder((positions[mid], ids[mid]), (position, id)) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    mutating func insert(_ id: OpID, at position: [UInt8]) {
        let index = lowerBound(position, id)
        ids.insert(id, at: index)
        positions.insert(position, at: index)
    }

    /// Removes `id`, listed under `position`; a node not listed there is left alone.
    mutating func remove(_ id: OpID, at position: [UInt8]) {
        let index = lowerBound(position, id)
        guard index < ids.count, ids[index] == id else { return }
        ids.remove(at: index)
        positions.remove(at: index)
    }
}
