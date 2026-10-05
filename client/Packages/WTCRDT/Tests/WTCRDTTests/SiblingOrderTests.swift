import Testing
@testable import WTCRDT

/// The maintained sibling order (crdt-model.adoc, "Tree moves", As built): under random tree ops
/// -- arriving out of OpId order (undo, do, redo), moving nodes into their own subtrees (skipped
/// cycles), between parents and within one, onto tied positions, naming unknown or well-known
/// nodes -- with snapshot reloads and garbage collection in between, every parent's children
/// always equal a fresh sort of the placements under it.
@Suite struct SiblingOrderTests {
    static let layers = OpID.wellKnown(4)

    /// Every parent's children, compared with a fresh sort of every known node's placement.
    static func expectFreshOrder(_ tree: Tree, _ nodes: [OpID], _ context: String) {
        var expected: [OpID: [(position: [UInt8], id: OpID)]] = [:]
        for node in nodes {
            if let placement = tree.placement(node) { expected[placement.parent, default: []].append((placement.position, node)) }
        }
        expected[.zero, default: []] += (1..<NodeStore.wellKnownLimit).map { ([], OpID.wellKnown($0)) }
        for parent in Set([.zero, layers] + nodes + expected.keys) {
            let fresh = (expected[parent] ?? []).sorted(by: FractionalIndex.childOrder).map(\.id)
            #expect(tree.children(parent) == fresh, "\(context): children of \(parent)")
        }
    }

    /// The tree as a snapshot holds it, loaded back.
    static func reloaded(_ tree: Tree, _ nodes: [OpID]) -> Tree {
        var placements: [OpID: Placement] = [:]
        for node in nodes { placements[node] = tree.placement(node) }
        return Tree(log: tree.log, placements: placements, live: Set(nodes.filter(tree.exists)))
    }

    @Test(arguments: 0..<24 as Range<UInt64>)
    func theMaintainedOrderAlwaysEqualsAFreshSort(seed: UInt64) {
        var random = SplitMix64(seed: seed &* 0x9E37_79B9 &+ 1)
        func pick(_ n: Int) -> Int { Int(random.next() % UInt64(n)) }
        var tree = Tree()
        var nodes: [OpID] = []
        var counter: UInt64 = 1_000
        // Few position bytes and few values, so ties are common.
        func position() -> [UInt8] { (0..<(1 + pick(2))).map { _ in UInt8(1 + pick(4)) } }
        func parent() -> OpID {
            switch pick(12) {
            case 0: .zero
            case 1: Self.layers
            case 2: OpID(counter: 999_999, replica: 9)  // never created: the op is skipped
            default: nodes.isEmpty ? Self.layers : nodes[pick(nodes.count)]
            }
        }
        for step in 0..<400 {
            counter += 1
            // Some ops arrive late: an OpId below ops already applied.
            let op = OpID(counter: pick(5) == 0 ? counter - UInt64(1 + pick(200)) : counter, replica: UInt64(1 + pick(4)))
            switch pick(10) {
            case 0...2:
                tree.apply(op: op, node: op, parent: parent(), position: position(), creates: true)
                if tree.exists(op), !nodes.contains(op) { nodes.append(op) }
            case 3:
                tree.apply(op: op, node: .wellKnown(UInt64(1 + pick(15))), parent: parent(), position: position(), creates: false)
            case 4:
                // Within the same parent: only the position changes.
                guard let node = nodes.randomElement(using: &random), let placement = tree.placement(node) else { continue }
                tree.apply(op: op, node: node, parent: placement.parent, position: position(), creates: false)
            default:
                guard let node = nodes.randomElement(using: &random) else { continue }
                tree.apply(op: op, node: node, parent: parent(), position: position(), creates: false)
            }
            if step % 50 == 49 {
                Self.expectFreshOrder(tree, nodes, "seed \(seed) step \(step)")
                tree = Self.reloaded(tree, nodes)
                Self.expectFreshOrder(tree, nodes, "seed \(seed) step \(step), reloaded")
            }
            if step % 100 == 99 {
                // Garbage collection: everything so far is stable; compact a few subtrees.
                _ = tree.prune { _ in true }
                for _ in 0..<3 {
                    guard let node = nodes.randomElement(using: &random) else { break }
                    let subtree = tree.subtree(node)
                    guard !tree.names(subtree) else { continue }
                    tree.remove(subtree)
                    nodes.removeAll(where: Set(subtree).contains)
                }
                Self.expectFreshOrder(tree, nodes, "seed \(seed) step \(step), collected")
            }
        }
        Self.expectFreshOrder(tree, nodes, "seed \(seed) end")
    }

    @Test func aNodeNotListedUnderThePositionIsLeftAlone() {
        var list = SiblingList(sorting: [([0x80], OpID(counter: 2, replica: 1)), ([0x40], OpID(counter: 3, replica: 1))])
        #expect(list.ids == [OpID(counter: 3, replica: 1), OpID(counter: 2, replica: 1)])
        list.remove(OpID(counter: 4, replica: 1), at: [0x80])
        list.remove(OpID(counter: 2, replica: 1), at: [0x90])
        #expect(list.ids == [OpID(counter: 3, replica: 1), OpID(counter: 2, replica: 1)])
        list.remove(OpID(counter: 2, replica: 1), at: [0x80])
        #expect(list.ids == [OpID(counter: 3, replica: 1)])
    }
}
