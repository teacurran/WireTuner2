import WTGeometry
import CoreGraphics
import Testing
@testable import WTRender

@Suite struct LRUStoreTests {
    @Test func evictsLeastRecentlyUsed() {
        var store = LRUStore<String, Int>(capacity: 3)
        #expect(store.isEmpty)
        #expect(store.insert(1, for: "a") == nil)
        #expect(store.insert(2, for: "b") == nil)
        #expect(store.insert(3, for: "c") == nil)
        #expect(store.keysByRecency == ["a", "b", "c"])
        #expect(store.value(for: "a") == 1, "a lookup refreshes the entry")
        #expect(store.keysByRecency == ["b", "c", "a"])
        #expect(store.peek("b") == 2)
        #expect(store.keysByRecency == ["b", "c", "a"], "peeking does not")
        #expect(store.insert(4, for: "d") == "b")
        #expect(store.count == 3)
        #expect(!store.contains("b"))
        #expect(store.value(for: "b") == nil)
        #expect(store.insert(30, for: "c") == nil, "replacing an existing key does not evict")
        #expect(store.peek("c") == 30)
        #expect(Set(store.keys) == ["a", "c", "d"])
    }

    @Test func removal() {
        var store = LRUStore<Int, String>(capacity: 0)
        #expect(store.capacity == 1, "capacity is at least one")
        store.insert("x", for: 1)
        #expect(store.insert("y", for: 2) == 1)
        #expect(store.remove(2) == "y")
        #expect(store.remove(2) == nil)
        store.insert("a", for: 3)
        #expect(store.removeAll { $0 == 3 } == 1)
        #expect(store.isEmpty)
        store.insert("b", for: 4)
        store.removeAll()
        #expect(store.isEmpty && store.keysByRecency.isEmpty)
    }
}

@Suite struct TileCacheTests {
    private let geometry = TileGeometry(zoomStep: ZoomStep(index: 0), rotationDegrees: 0)

    private func key(_ column: Int, _ row: Int, canvas: CanvasID = Corpus.canvas, rotation: Double = 0) -> TileKey {
        TileKey(canvas: canvas, zoomStep: ZoomStep(index: 0), rotationDegrees: rotation, column: column, row: row)
    }

    @Test func rendersOnceThenServesFromCache() async throws {
        let cache = TileCache(renderer: CoreGraphicsRenderer(), capacity: 8)
        #expect(await cache.capacity == 8)
        #expect(await cache.tileSize == 256)
        let first = try #require(await cache.tile(for: key(0, 0), in: Corpus.solidRect, geometry: geometry))
        #expect(first.width == 256)
        let second = try #require(await cache.tile(for: key(0, 0), in: Corpus.solidRect, geometry: geometry))
        #expect(first === second)
        #expect(await cache.renders == 1)
        #expect(await cache.count == 1)
        #expect(await cache.cachedTile(for: key(0, 0)) === first)
        #expect(await cache.cachedTile(for: key(5, 5)) == nil)
        #expect(await cache.renders == 1, "a cache lookup never renders")
    }

    @Test func evictsByRecency() async {
        let cache = TileCache(renderer: CoreGraphicsRenderer(), capacity: 2)
        _ = await cache.tile(for: key(0, 0), in: Corpus.empty, geometry: geometry)
        _ = await cache.tile(for: key(1, 0), in: Corpus.empty, geometry: geometry)
        _ = await cache.tile(for: key(0, 0), in: Corpus.empty, geometry: geometry)  // refresh (0, 0)
        _ = await cache.tile(for: key(2, 0), in: Corpus.empty, geometry: geometry)  // evicts (1, 0)
        #expect(await cache.count == 2)
        #expect(await cache.keysByRecency == [key(0, 0), key(2, 0)])
        #expect(await cache.cachedTile(for: key(1, 0)) == nil)
        #expect(await cache.renders == 3)
    }

    @Test func invalidationByPasteboardRect() async throws {
        let cache = TileCache(renderer: CoreGraphicsRenderer(), capacity: 16)
        let rotated = TileGeometry(zoomStep: ZoomStep(index: 0), rotationDegrees: 45)
        for column in 0..<3 {
            _ = await cache.tile(for: key(column, 0), in: Corpus.empty, geometry: geometry)
        }
        _ = await cache.tile(for: key(0, 0, canvas: "other"), in: DisplayList(canvas: "other", items: []), geometry: geometry)
        _ = await cache.tile(for: key(0, 0, rotation: 45), in: Corpus.empty, geometry: rotated)
        #expect(await cache.count == 5)

        // A rect inside the second unrotated tile (x 256...512) misses the rotated tile, whose
        // pasteboard bounding box spans x -181...181, so exactly one tile is dropped.
        let dropped = await cache.invalidate(pasteboardRect: Rect(x: 300, y: 10, width: 10, height: 10), canvas: Corpus.canvas)
        #expect(dropped == [key(1, 0)])
        #expect(await cache.count == 4)

        // A rect around the origin touches tile (0, 0) at 0° and the rotated (0, 0) tile.
        let droppedAtOrigin = await cache.invalidate(pasteboardRect: Rect(x: -5, y: -5, width: 10, height: 10), canvas: Corpus.canvas)
        #expect(Set(droppedAtOrigin) == [key(0, 0), key(0, 0, rotation: 45)])
        #expect(await cache.cachedTile(for: key(0, 0, canvas: "other")) != nil, "other canvases are untouched")

        #expect(await cache.invalidateAll(canvas: Corpus.canvas) == 1)
        #expect(await cache.count == 1)
        await cache.removeAll()
        #expect(await cache.count == 0)
    }

    @Test func insertingAForeignTile() async throws {
        let cache = TileCache(renderer: CoreGraphicsRenderer(), capacity: 4)
        let image = try #require(CoreGraphicsRenderer().renderTile(Corpus.solidRect, key: key(0, 0), geometry: geometry))
        await cache.insert(image, for: key(7, 7))
        #expect(await cache.cachedTile(for: key(7, 7)) === image)
        #expect(await cache.renders == 0)
    }

    @Test func failedRendersAreNotCached() async {
        let cache = TileCache(renderer: FailingRenderer(), capacity: 4)
        #expect(await cache.tile(for: key(0, 0), in: Corpus.solidRect, geometry: geometry) == nil)
        #expect(await cache.count == 0)
        #expect(await cache.renders == 1)
    }

    @Test func cancelledRequestsNeitherRenderNorStore() async {
        let cache = TileCache(renderer: CoreGraphicsRenderer(), capacity: 4)
        let geometry = geometry
        let key = key(0, 0)
        let task = Task { () -> CGImage? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.tile(for: key, in: Corpus.solidRect, geometry: geometry)
        }
        #expect(await task.value == nil)
        #expect(await cache.count == 0)
        #expect(await cache.renders == 0)
    }
}
