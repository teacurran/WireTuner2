// The spatial index behind hit testing and marquee selection (REND-003; docs/spec/client.adoc,
// "Hit testing uses the same geometry as both renderers").  A value type: a hit tester holding
// one never sees a half-applied change.
//
// Built by Sort-Tile-Recursive packing (Leutenegger et al.): entries sorted into vertical slabs
// by centre x, each slab sorted by centre y and cut into full leaves, and the same again one
// level up until one root remains.  Maintained incrementally afterwards: insertion descends by
// least enlargement and splits an overfull node at the median of its longer axis; removal
// shrinks bounds upward and drops empty nodes, collapsing a single-child root.

import WTGeometry

/// An R-tree of axis-aligned rectangles keyed by `ID`.
public struct RTree<ID: Hashable & Sendable>: Sendable {
    /// The default maximum number of children per node.
    public static var defaultNodeCapacity: Int { 16 }

    struct Entry: Sendable {
        let id: ID
        var bounds: Rect
    }

    struct Node: Sendable {
        var bounds: Rect
        var parent: Int
        let isLeaf: Bool
        /// Child node indices (internal nodes).
        var children: [Int]
        /// Entries (leaves).
        var entries: [Entry]

        var count: Int { isLeaf ? entries.count : children.count }
    }

    /// Maximum children per node.
    public let nodeCapacity: Int

    private(set) var nodes: [Node] = []
    private var freeNodes: [Int] = []
    private(set) var root = -1
    private var leafOf: [ID: Int] = [:]

    /// An empty tree.
    public init(nodeCapacity: Int = RTree.defaultNodeCapacity) {
        self.nodeCapacity = max(nodeCapacity, 4)
    }

    /// A tree bulk-loaded from `items` by STR packing.  A repeated id keeps its last bounds.
    public init<S: Sequence>(bulkLoading items: S, nodeCapacity: Int = RTree.defaultNodeCapacity) where S.Element == (ID, Rect) {
        self.init(nodeCapacity: nodeCapacity)
        var unique: [ID: Int] = [:]
        var entries: [Entry] = []
        for (id, bounds) in items where !bounds.isNull {
            if let index = unique[id] {
                entries[index].bounds = bounds
            } else {
                unique[id] = entries.count
                entries.append(Entry(id: id, bounds: bounds))
            }
        }
        guard !entries.isEmpty else {
            return
        }
        var level = pack(entries)
        while level.count > 1 {
            level = pack(nodes: level)
        }
        root = level[0]
    }

    // MARK: Reading

    /// The number of entries.
    public var count: Int { leafOf.count }

    public var isEmpty: Bool { leafOf.isEmpty }

    /// The union of every entry's bounds; nil when empty.
    public var bounds: Rect? { root < 0 ? nil : nodes[root].bounds }

    /// Levels from the root to the leaves; 0 when empty.
    public var height: Int {
        var levels = 0
        var node = root
        while node >= 0 {
            levels += 1
            node = nodes[node].isLeaf ? -1 : nodes[node].children[0]
        }
        return levels
    }

    public func contains(_ id: ID) -> Bool {
        leafOf[id] != nil
    }

    /// The stored bounds of `id`.
    public func bounds(of id: ID) -> Rect? {
        guard let leaf = leafOf[id] else {
            return nil
        }
        return nodes[leaf].entries.first { $0.id == id }?.bounds
    }

    /// Every id whose bounds intersect `rect` (closed rectangles: touching counts), in no
    /// particular order.
    public func query(_ rect: Rect) -> [ID] {
        var result: [ID] = []
        visit(rect) { entry in
            result.append(entry.id)
        }
        return result
    }

    /// Every id whose bounds lie entirely inside `rect`.
    public func query(containedIn rect: Rect) -> [ID] {
        var result: [ID] = []
        visit(rect) { entry in
            if rect.contains(entry.bounds) {
                result.append(entry.id)
            }
        }
        return result
    }

    /// Up to `count` ids nearest to `point` by distance to their bounds (0 inside), nearest
    /// first, none farther than `maxDistance`.  Best-first search over node bounds.
    public func nearest(to point: Point, count: Int = 1, maxDistance: Double = .infinity) -> [(id: ID, distance: Double)] {
        guard root >= 0, count > 0 else {
            return []
        }
        // Heap elements: (distance, node index, or -1 with an entry).
        var heap = MinHeap<(distance: Double, node: Int, entry: Entry?)> { $0.distance < $1.distance }
        heap.push((RTree.distance(from: point, to: nodes[root].bounds), root, nil))
        var result: [(id: ID, distance: Double)] = []
        while let top = heap.pop(), result.count < count {
            if top.distance > maxDistance {
                break
            }
            if let entry = top.entry {
                result.append((entry.id, top.distance))
                continue
            }
            let node = nodes[top.node]
            if node.isLeaf {
                for entry in node.entries {
                    heap.push((RTree.distance(from: point, to: entry.bounds), -1, entry))
                }
            } else {
                for child in node.children {
                    heap.push((RTree.distance(from: point, to: nodes[child].bounds), child, nil))
                }
            }
        }
        return result
    }

    /// Euclidean distance from `point` to the closed rectangle.
    static func distance(from point: Point, to rect: Rect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    private func visit(_ rect: Rect, _ body: (Entry) -> Void) {
        guard root >= 0 else {
            return
        }
        var stack = [root]
        while let index = stack.popLast() {
            let node = nodes[index]
            guard node.bounds.intersects(rect) else {
                continue
            }
            if node.isLeaf {
                for entry in node.entries where entry.bounds.intersects(rect) {
                    body(entry)
                }
            } else {
                stack.append(contentsOf: node.children)
            }
        }
    }

    // MARK: Writing

    /// Adds `id` with `bounds`, or moves it there if present.  A null rectangle removes it.
    public mutating func insert(_ id: ID, bounds: Rect) {
        if leafOf[id] != nil {
            update(id, bounds: bounds)
            return
        }
        guard !bounds.isNull else {
            return
        }
        let entry = Entry(id: id, bounds: bounds)
        guard root >= 0 else {
            root = makeNode(bounds: bounds, parent: -1, isLeaf: true, entries: [entry])
            leafOf[id] = root
            return
        }
        var node = root
        while !nodes[node].isLeaf {
            node = chooseChild(of: node, for: bounds)
        }
        nodes[node].entries.append(entry)
        leafOf[id] = node
        adjustUpward(from: node)
    }

    /// Removes `id`; returns whether it was present.
    @discardableResult
    public mutating func remove(_ id: ID) -> Bool {
        guard let leaf = leafOf.removeValue(forKey: id),
              let position = nodes[leaf].entries.firstIndex(where: { $0.id == id })
        else {
            return false
        }
        nodes[leaf].entries.remove(at: position)
        condense(from: leaf)
        return true
    }

    /// Moves `id` to `bounds` (inserting it if absent; a null rectangle removes it).  A move
    /// that stays inside the entry's leaf is done in place.
    public mutating func update(_ id: ID, bounds: Rect) {
        guard let leaf = leafOf[id] else {
            insert(id, bounds: bounds)
            return
        }
        guard !bounds.isNull else {
            remove(id)
            return
        }
        if nodes[leaf].bounds.contains(bounds),
           let position = nodes[leaf].entries.firstIndex(where: { $0.id == id }) {
            nodes[leaf].entries[position].bounds = bounds
            adjustUpward(from: leaf)
            return
        }
        remove(id)
        insert(id, bounds: bounds)
    }

    // MARK: Structure

    private mutating func makeNode(bounds: Rect, parent: Int, isLeaf: Bool, children: [Int] = [], entries: [Entry] = []) -> Int {
        let node = Node(bounds: bounds, parent: parent, isLeaf: isLeaf, children: children, entries: entries)
        if let index = freeNodes.popLast() {
            nodes[index] = node
            return index
        }
        nodes.append(node)
        return nodes.count - 1
    }

    private mutating func freeNode(_ index: Int) {
        nodes[index].children = []
        nodes[index].entries = []
        nodes[index].parent = -1
        freeNodes.append(index)
    }

    private func computedBounds(of index: Int) -> Rect {
        let node = nodes[index]
        var result = Rect.null
        if node.isLeaf {
            for entry in node.entries {
                result.formUnion(entry.bounds)
            }
        } else {
            for child in node.children {
                result.formUnion(nodes[child].bounds)
            }
        }
        return result
    }

    /// The child whose bounds grow least to take `bounds`; ties go to the smaller child.
    private func chooseChild(of index: Int, for bounds: Rect) -> Int {
        var best = nodes[index].children[0]
        var bestGrowth = Double.infinity
        var bestArea = Double.infinity
        for child in nodes[index].children {
            let current = nodes[child].bounds
            let area = current.width * current.height
            let merged = current.union(bounds)
            let growth = merged.width * merged.height - area
            if growth < bestGrowth || (growth == bestGrowth && area < bestArea) {
                best = child
                bestGrowth = growth
                bestArea = area
            }
        }
        return best
    }

    /// Refits bounds from `index` to the root, splitting any node over capacity.
    private mutating func adjustUpward(from index: Int) {
        var node = index
        while node >= 0 {
            nodes[node].bounds = computedBounds(of: node)
            if nodes[node].count > nodeCapacity {
                let sibling = split(node)
                let parent = nodes[node].parent
                if parent < 0 {
                    let newRoot = makeNode(bounds: .null, parent: -1, isLeaf: false, children: [node, sibling])
                    nodes[node].parent = newRoot
                    nodes[sibling].parent = newRoot
                    root = newRoot
                } else {
                    nodes[parent].children.append(sibling)
                    nodes[sibling].parent = parent
                }
            }
            node = nodes[node].parent
        }
    }

    /// Moves the upper half of `index`'s children, sorted by centre along the node's longer
    /// axis, into a new sibling; returns the sibling.
    private mutating func split(_ index: Int) -> Int {
        let horizontal = nodes[index].bounds.width >= nodes[index].bounds.height
        func key(_ rect: Rect) -> Double { horizontal ? rect.midX : rect.midY }
        let sibling: Int
        if nodes[index].isLeaf {
            let sorted = nodes[index].entries.sorted { key($0.bounds) < key($1.bounds) }
            let half = sorted.count / 2
            nodes[index].entries = Array(sorted[..<half])
            sibling = makeNode(bounds: .null, parent: nodes[index].parent, isLeaf: true, entries: Array(sorted[half...]))
            for entry in nodes[sibling].entries {
                leafOf[entry.id] = sibling
            }
        } else {
            let sorted = nodes[index].children.sorted { key(nodes[$0].bounds) < key(nodes[$1].bounds) }
            let half = sorted.count / 2
            nodes[index].children = Array(sorted[..<half])
            sibling = makeNode(bounds: .null, parent: nodes[index].parent, isLeaf: false, children: Array(sorted[half...]))
            for child in nodes[sibling].children {
                nodes[child].parent = sibling
            }
        }
        nodes[index].bounds = computedBounds(of: index)
        nodes[sibling].bounds = computedBounds(of: sibling)
        return sibling
    }

    /// After a removal from `leaf`: drops emptied nodes, refits bounds to the root, and
    /// collapses a root left with one child.
    private mutating func condense(from leaf: Int) {
        var node = leaf
        while node >= 0 {
            let parent = nodes[node].parent
            if nodes[node].count == 0 && node != root {
                nodes[parent].children.removeAll { $0 == node }
                freeNode(node)
            } else {
                nodes[node].bounds = computedBounds(of: node)
            }
            node = parent
        }
        while root >= 0, !nodes[root].isLeaf, nodes[root].children.count == 1 {
            let child = nodes[root].children[0]
            freeNode(root)
            nodes[child].parent = -1
            root = child
        }
        if root >= 0, nodes[root].count == 0 {
            freeNode(root)
            root = -1
        }
    }

    // MARK: STR packing

    /// Slabs of `slabSize` items by `x`, each sorted by `y` and cut into groups of capacity.
    private func strGroups<T>(_ items: [T], center: (T) -> Point) -> [[T]] {
        let capacity = nodeCapacity
        let leafCount = (items.count + capacity - 1) / capacity
        let slabCount = max(Int(Double(leafCount).squareRoot().rounded(.up)), 1)
        let slabSize = slabCount * capacity
        let byX = items.sorted { center($0).x < center($1).x }
        var groups: [[T]] = []
        var start = 0
        while start < byX.count {
            let slab = byX[start..<min(start + slabSize, byX.count)].sorted { center($0).y < center($1).y }
            var index = 0
            while index < slab.count {
                groups.append(Array(slab[index..<min(index + capacity, slab.count)]))
                index += capacity
            }
            start += slabSize
        }
        return groups
    }

    private mutating func pack(_ entries: [Entry]) -> [Int] {
        strGroups(entries) { $0.bounds.center }.map { group in
            let leaf = makeNode(bounds: .null, parent: -1, isLeaf: true, entries: group)
            nodes[leaf].bounds = computedBounds(of: leaf)
            for entry in group {
                leafOf[entry.id] = leaf
            }
            return leaf
        }
    }

    private mutating func pack(nodes level: [Int]) -> [Int] {
        let centers = Dictionary(uniqueKeysWithValues: level.map { ($0, nodes[$0].bounds.center) })
        return strGroups(level) { centers[$0]! }.map { group in
            let parent = makeNode(bounds: .null, parent: -1, isLeaf: false, children: group)
            for child in group {
                nodes[child].parent = parent
            }
            nodes[parent].bounds = computedBounds(of: parent)
            return parent
        }
    }

    // MARK: Invariants

    /// Checks the structure (for tests): every node's bounds are exactly the union of its
    /// children's, parents and leaf back-references agree, leaves sit at one depth, no node
    /// exceeds capacity, and the entry count matches.
    func validate() -> Bool {
        guard root >= 0 else {
            return leafOf.isEmpty
        }
        var seen = 0
        var leafDepth: Int?
        var stack: [(node: Int, depth: Int)] = [(root, 0)]
        while let (index, depth) = stack.popLast() {
            let node = nodes[index]
            if node.count == 0 || node.count > nodeCapacity || node.bounds != computedBounds(of: index) {
                return false
            }
            if node.isLeaf {
                if leafDepth == nil { leafDepth = depth }
                if leafDepth != depth { return false }
                for entry in node.entries where leafOf[entry.id] != index {
                    return false
                }
                seen += node.entries.count
            } else {
                for child in node.children {
                    if nodes[child].parent != index { return false }
                    stack.append((child, depth + 1))
                }
            }
        }
        return seen == leafOf.count && nodes[root].parent == -1
    }
}

/// A binary min-heap ordered by `less`.
struct MinHeap<Element> {
    private var storage: [Element] = []
    private let less: (Element, Element) -> Bool

    init(less: @escaping (Element, Element) -> Bool) {
        self.less = less
    }

    var isEmpty: Bool { storage.isEmpty }

    mutating func push(_ element: Element) {
        storage.append(element)
        var child = storage.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard less(storage[child], storage[parent]) else { break }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Element? {
        guard !storage.isEmpty else {
            return nil
        }
        storage.swapAt(0, storage.count - 1)
        let top = storage.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < storage.count && less(storage[left], storage[smallest]) { smallest = left }
            if right < storage.count && less(storage[right], storage[smallest]) { smallest = right }
            if smallest == parent { break }
            storage.swapAt(parent, smallest)
            parent = smallest
        }
        return top
    }
}
