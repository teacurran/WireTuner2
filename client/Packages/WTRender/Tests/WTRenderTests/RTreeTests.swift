import WTGeometry
import Testing
@testable import WTRender

/// A deterministic generator so failures reproduce.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct RTreeTests {
    static func randomRect(_ rng: inout SplitMix64, extent: Double = 1000, maxSize: Double = 30) -> Rect {
        Rect(
            x: Double.random(in: 0..<extent, using: &rng),
            y: Double.random(in: 0..<extent, using: &rng),
            width: Double.random(in: 0..<maxSize, using: &rng),
            height: Double.random(in: 0..<maxSize, using: &rng)
        )
    }

    /// Compares every query kind against a brute-force scan of `truth`.
    static func matchesBruteForce(_ tree: RTree<Int>, _ truth: [Int: Rect], rng: inout SplitMix64, queries: Int = 60) -> Bool {
        guard tree.count == truth.count, tree.validate() else {
            return false
        }
        for _ in 0..<queries {
            let probe = randomRect(&rng, maxSize: 200)
            let expected = Set(truth.filter { $0.value.intersects(probe) }.keys)
            guard Set(tree.query(probe)) == expected else { return false }
            let enclosed = Set(truth.filter { probe.contains($0.value) }.keys)
            guard Set(tree.query(containedIn: probe)) == enclosed else { return false }
            let point = Point(x: Double.random(in: 0..<1000, using: &rng), y: Double.random(in: 0..<1000, using: &rng))
            let nearest = tree.nearest(to: point, count: 5).map(\.distance)
            let bruteNearest = truth.values.map { RTree<Int>.distance(from: point, to: $0) }.sorted().prefix(5)
            guard nearest.count == bruteNearest.count, zip(nearest, bruteNearest).allSatisfy({ approx($0, $1) }) else { return false }
        }
        for (id, rect) in truth.prefix(20) where tree.bounds(of: id) != rect {
            return false
        }
        return true
    }

    @Test func emptyTree() {
        var tree = RTree<Int>()
        #expect(tree.isEmpty && tree.count == 0)
        #expect(tree.bounds == nil)
        #expect(tree.height == 0)
        #expect(tree.query(Rect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        #expect(tree.query(containedIn: Rect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        #expect(tree.nearest(to: .zero).isEmpty)
        let removedAbsent = tree.remove(1)
        #expect(!removedAbsent)
        #expect(tree.bounds(of: 1) == nil)
        #expect(!tree.contains(1))
        #expect(tree.validate())
        #expect(RTree<Int>(nodeCapacity: 1).nodeCapacity == 4, "capacity is at least four")
        #expect(RTree<Int>.defaultNodeCapacity == 16)
        #expect(RTree<Int>(bulkLoading: []).isEmpty)
    }

    @Test func bulkLoadMatchesBruteForce() {
        var rng = SplitMix64(seed: 1)
        var truth: [Int: Rect] = [:]
        for id in 0..<5000 {
            truth[id] = Self.randomRect(&rng)
        }
        let tree = RTree(bulkLoading: truth.map { ($0.key, $0.value) })
        #expect(tree.count == 5000)
        #expect(tree.height == 4, "5000 entries at 16 per node pack into four levels")
        #expect(tree.bounds == DisplayList.union(of: Array(truth.values)))
        #expect(Self.matchesBruteForce(tree, truth, rng: &rng))
    }

    @Test func bulkLoadSkipsNullBoundsAndKeepsTheLastDuplicate() {
        let tree = RTree(bulkLoading: [
            (1, Rect(x: 0, y: 0, width: 1, height: 1)),
            (2, Rect.null),
            (1, Rect(x: 5, y: 5, width: 1, height: 1)),
        ])
        #expect(tree.count == 1)
        #expect(tree.bounds(of: 1) == Rect(x: 5, y: 5, width: 1, height: 1))
        #expect(!tree.contains(2))
    }

    @Test func incrementalMaintenanceMatchesBruteForce() {
        var rng = SplitMix64(seed: 7)
        var tree = RTree<Int>(nodeCapacity: 8)
        var truth: [Int: Rect] = [:]
        for id in 0..<3000 {
            let rect = Self.randomRect(&rng)
            tree.insert(id, bounds: rect)
            truth[id] = rect
        }
        #expect(tree.height > 2)
        #expect(Self.matchesBruteForce(tree, truth, rng: &rng))

        // Small nudges stay in their leaf; large moves reinsert.
        for id in 0..<1000 {
            let old = truth[id]!
            let rect = id % 2 == 0
                ? Rect(x: old.minX + 0.01, y: old.minY, width: old.width * 0.5, height: old.height * 0.5)
                : Self.randomRect(&rng)
            tree.update(id, bounds: rect)
            truth[id] = rect
        }
        #expect(Self.matchesBruteForce(tree, truth, rng: &rng))

        for id in stride(from: 0, to: 3000, by: 2) {
            let removed = tree.remove(id)
            #expect(removed)
            truth[id] = nil
        }
        let removedTwice = tree.remove(0)
        #expect(!removedTwice, "already gone")
        #expect(Self.matchesBruteForce(tree, truth, rng: &rng))

        // Re-inserting after removals reuses freed nodes.
        for id in 3000..<3500 {
            let rect = Self.randomRect(&rng)
            tree.insert(id, bounds: rect)
            truth[id] = rect
        }
        #expect(Self.matchesBruteForce(tree, truth, rng: &rng))

        for id in Array(truth.keys) {
            tree.remove(id)
        }
        #expect(tree.isEmpty && tree.bounds == nil && tree.height == 0)
        #expect(tree.validate())
    }

    @Test func removalFromABulkLoadedTreeCollapsesTheRoot() {
        var rng = SplitMix64(seed: 3)
        var truth: [Int: Rect] = [:]
        for id in 0..<400 {
            truth[id] = Self.randomRect(&rng)
        }
        var tree = RTree(bulkLoading: truth.map { ($0.key, $0.value) }, nodeCapacity: 4)
        let tall = tree.height
        for id in 0..<399 {
            tree.remove(id)
            truth[id] = nil
        }
        #expect(tall > 1 && tree.height == 1, "one entry left: the root collapsed to its leaf")
        #expect(Self.matchesBruteForce(tree, truth, rng: &rng, queries: 10))
    }

    @Test func insertUpdateAndRemoveEdgeCases() {
        var tree = RTree<String>()
        tree.insert("a", bounds: Rect(x: 0, y: 0, width: 10, height: 10))
        #expect(tree.height == 1)
        tree.insert("a", bounds: Rect(x: 100, y: 100, width: 1, height: 1))
        #expect(tree.count == 1, "inserting an existing id moves it")
        #expect(tree.bounds(of: "a") == Rect(x: 100, y: 100, width: 1, height: 1))
        tree.insert("null", bounds: .null)
        #expect(!tree.contains("null"), "a null rectangle is never stored")
        tree.update("b", bounds: Rect(x: 1, y: 1, width: 1, height: 1))
        #expect(tree.contains("b"), "updating an absent id inserts it")
        tree.update("b", bounds: .null)
        #expect(!tree.contains("b"), "updating to a null rectangle removes it")
        #expect(tree.query(Rect(x: 101, y: 101, width: 0, height: 0)) == ["a"], "closed rectangles: touching counts")
        #expect(tree.validate())
    }

    @Test func nearestHonoursCountAndMaxDistance() {
        var tree = RTree<Int>()
        for index in 0..<10 {
            tree.insert(index, bounds: Rect(x: Double(index) * 10, y: 0, width: 1, height: 1))
        }
        let three = tree.nearest(to: Point(x: 0, y: 0), count: 3)
        #expect(three.map(\.id) == [0, 1, 2])
        #expect(three[0].distance == 0 && approx(three[1].distance, 10))
        #expect(tree.nearest(to: Point(x: 0, y: 0), count: 10, maxDistance: 25).map(\.id) == [0, 1, 2])
        #expect(tree.nearest(to: .zero, count: 0).isEmpty)
        #expect(RTree<Int>.distance(from: Point(x: 5, y: 5), to: Rect(x: 0, y: 0, width: 10, height: 10)) == 0)
        #expect(RTree<Int>.distance(from: Point(x: 13, y: 14), to: Rect(x: 0, y: 0, width: 10, height: 10)) == 5)
    }

    @Test func minHeapPopsInOrder() {
        var heap = MinHeap<Int> { $0 < $1 }
        #expect(heap.isEmpty)
        #expect(heap.pop() == nil)
        for value in [5, 3, 9, 1, 7, 1, 8] {
            heap.push(value)
        }
        var popped: [Int] = []
        while let value = heap.pop() {
            popped.append(value)
        }
        #expect(popped == [1, 1, 3, 5, 7, 8, 9])
    }
}
