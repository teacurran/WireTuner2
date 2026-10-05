import Testing
import WTGeometry
@testable import WTRender

/// D-094: a list patched in place (`DisplayList.replaceItems`) is the list built from scratch over
/// the same items, ids and spans -- bounds, node index, lens indices included.
@Suite struct DisplayListSpliceTests {
    /// SplitMix64.
    struct Random: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func item(_ random: inout Random, lens: Bool = false) -> DisplayItem {
        let rect = Rect(x: Double(Int.random(in: -100...100, using: &random)), y: Double(Int.random(in: -100...100, using: &random)),
                        width: Double(Int.random(in: 1...50, using: &random)), height: Double(Int.random(in: 1...50, using: &random)))
        let paint: Paint = lens ? .lens(LensFill(type: .invert)) : .solid(Color(red: 1, green: 0, blue: 0))
        return .fill(FillItem(path: DisplayPath(rect: rect), paint: paint))
    }

    /// `list` equals the list built from its own items, ids and spans, field by field.
    static func expectFresh(_ list: DisplayList, _ label: String) {
        let fresh = DisplayList(canvas: list.canvas, items: list.items, nodeIDs: list.nodeIDs, layers: list.layers)
        #expect(list == fresh, "\(label)")
        #expect(list.itemBounds == fresh.itemBounds, "item bounds \(label)")
        #expect(list.bounds == fresh.bounds, "bounds \(label)")
        #expect(list.lensIndices == fresh.lensIndices, "lens indices \(label)")
        #expect(list.nodeIDs.isEmpty == !list.nodeIDs.contains { $0 != nil }, "ids are empty exactly when none is set \(label)")
        for (index, id) in fresh.nodeIDs.enumerated() {
            if let id { #expect(list.index(of: id) == index, "index of \(id) \(label)") }
        }
    }

    @Test(arguments: [UInt64(1), 2, 3])
    func randomSplicesEqualAFreshList(seed: UInt64) {
        var random = Random(state: seed)
        var next: UInt64 = 1
        var items: [DisplayItem] = []
        var ids: [NodeID?] = []
        for _ in 0..<40 {
            items.append(Self.item(&random, lens: Int.random(in: 0..<10, using: &random) == 0))
            ids.append(Bool.random(using: &random) ? NodeID(counter: next, replica: 1) : nil)
            next += 1
        }
        var list = DisplayList(canvas: "c", items: items, nodeIDs: ids, layers: [LayerSpan(layer: LayerRendering(id: NodeID(counter: 0, replica: 9)), range: 0..<40)])
        for step in 0..<300 {
            let low = Int.random(in: 0...list.count, using: &random)
            let high = Int.random(in: low...min(list.count, low + 3), using: &random)
            let count = Int.random(in: 0...(Bool.random(using: &random) ? high - low : 3), using: &random)
            var newItems: [DisplayItem] = []
            var newIDs: [NodeID?] = []
            for _ in 0..<count {
                newItems.append(Self.item(&random, lens: Int.random(in: 0..<8, using: &random) == 0))
                newIDs.append(Int.random(in: 0..<3, using: &random) == 0 ? nil : NodeID(counter: next, replica: 1))
                next += 1
            }
            let total = list.count - (high - low) + count
            list.replaceItems(low..<high, with: newItems, bounds: newItems.map(\.bounds), nodeIDs: newIDs,
                              layers: [LayerSpan(layer: LayerRendering(id: NodeID(counter: 0, replica: 9)), range: 0..<total)])
            Self.expectFresh(list, "after step \(step)")
        }
    }

    @Test func idsAppearAndVanishAndTheIndexFlattens() {
        var random = Random(state: 9)
        let items = (0..<3).map { _ in Self.item(&random) }
        var list = DisplayList(canvas: "c", items: items)
        #expect(list.nodeIDs.isEmpty)
        let node = NodeID(counter: 5, replica: 1)
        // The first id makes the list name nodes; replacing it with nothing makes it empty again.
        list.replaceItems(1..<2, with: [items[1]], bounds: [items[1].bounds], nodeIDs: [node])
        #expect(list.nodeIDs == [nil, node, nil] && list.index(of: node) == 1)
        list.replaceItems(1..<2, with: [items[1]], bounds: [items[1].bounds], nodeIDs: [nil])
        #expect(list.nodeIDs.isEmpty && list.index(of: node) == nil)
        Self.expectFresh(list, "ids gone")
        // Many replacements in place: the edits over the shared table are folded into a new one.
        var tagged = DisplayList(canvas: "c", items: items, nodeIDs: [NodeID(counter: 1, replica: 1), nil, nil])
        for counter in 0..<1100 {
            let id = NodeID(counter: UInt64(100 + counter), replica: 1)
            tagged.replaceItems(2..<3, with: [items[2]], bounds: [items[2].bounds], nodeIDs: [id])
            #expect(tagged.index(of: id) == 2)
        }
        #expect(tagged.index(of: NodeID(counter: 100, replica: 1)) == nil)
        Self.expectFresh(tagged, "after the edits")
        // Two items swapped in place, one replacement at a time: each keeps its new index.
        let first = NodeID(counter: 1, replica: 2), second = NodeID(counter: 2, replica: 2)
        var swapped = DisplayList(canvas: "c", items: items, nodeIDs: [first, nil, second])
        swapped.replaceItems(0..<1, with: [items[2]], bounds: [items[2].bounds], nodeIDs: [second])
        swapped.replaceItems(2..<3, with: [items[0]], bounds: [items[0].bounds], nodeIDs: [first])
        #expect(swapped.index(of: first) == 2 && swapped.index(of: second) == 0)
        Self.expectFresh(swapped, "after a swap")
        // An item at the edge of the union leaves it: the bounds are summed again.
        let edge = DisplayItem.fill(FillItem(path: DisplayPath(rect: Rect(x: 1000, y: 1000, width: 10, height: 10)), paint: .solid(.black)))
        var wide = DisplayList(canvas: "c", items: items + [edge])
        wide.replaceItems(3..<4, with: [], bounds: [], nodeIDs: [])
        #expect(wide.bounds == DisplayList(canvas: "c", items: items).bounds)
        // An empty list gains its first item.
        var empty = DisplayList(canvas: "c", items: [])
        empty.replaceItems(0..<0, with: [edge], bounds: [edge.bounds], nodeIDs: [nil])
        #expect(empty.bounds == edge.bounds)
        empty.setLayers([LayerSpan(layer: LayerRendering(id: node), range: 0..<1)])
        #expect(empty.layers.count == 1)
    }

    @Test func screenRenderingTintsOnlyTheGuidesLayer() {
        let guides = LayerRendering(id: NodeID(counter: 1, replica: 1), isGuides: true)
        let cyan = Color(red: 0, green: 1, blue: 1)
        #expect(LayerScene.screenRendering(guides, guideColor: cyan).highlight == cyan)
        var keyline = guides
        keyline.keyline = true
        #expect(LayerScene.screenRendering(keyline, guideColor: cyan).highlight == .black)
        let plain = LayerRendering(id: NodeID(counter: 2, replica: 1), highlight: .white)
        #expect(LayerScene.screenRendering(plain, guideColor: cyan) == plain)
    }

    @Test func dependenciesAreRemovedPerSourceAndJoined() {
        let a = NodeID(counter: 1, replica: 1), b = NodeID(counter: 2, replica: 1), c = NodeID(counter: 3, replica: 1)
        var index = DependencyIndex()
        index.add(c, dependsOn: a)
        index.add(c, dependsOn: b)
        index.remove(c, from: [a])
        #expect(index.directDependents(of: a).isEmpty && index.directDependents(of: b) == [c])
        index.remove(c, from: [b, a])
        #expect(index.isEmpty)
        var other = DependencyIndex()
        other.add(b, dependsOn: a)
        index.add(c, dependsOn: a)
        index.formUnion(other)
        #expect(index.directDependents(of: a) == [b, c])
    }
}
