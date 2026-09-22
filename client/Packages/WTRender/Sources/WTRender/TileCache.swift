// The tile store behind the Core Graphics fallback canvas: rasterized tiles by key, evicted
// least-recently used, invalidated by pasteboard rectangle.  Rendering happens inside the
// actor, off the main actor (docs/spec/client.adoc, "Concurrency": rendering runs on a render
// executor).

import WTGeometry
import CoreGraphics

/// A fixed-capacity least-recently-used map.  Plain value type so the eviction and
/// invalidation logic is testable without an actor hop.
public struct LRUStore<Key: Hashable, Value> {
    public let capacity: Int
    private var values: [Key: Value] = [:]
    private var lastUse: [Key: UInt64] = [:]
    private var clock: UInt64 = 0

    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }
    public var keys: [Key] { Array(values.keys) }

    /// Keys from least to most recently used.
    public var keysByRecency: [Key] {
        lastUse.sorted { $0.value < $1.value }.map(\.key)
    }

    /// The value for `key`, marking it most recently used.
    public mutating func value(for key: Key) -> Value? {
        guard let value = values[key] else {
            return nil
        }
        clock += 1
        lastUse[key] = clock
        return value
    }

    /// The value for `key` without touching its recency.
    public func peek(_ key: Key) -> Value? {
        values[key]
    }

    public func contains(_ key: Key) -> Bool {
        values[key] != nil
    }

    /// Stores `value` as most recently used, evicting the least recently used entry when
    /// the store is over capacity.  Returns the evicted key, if any.
    @discardableResult
    public mutating func insert(_ value: Value, for key: Key) -> Key? {
        clock += 1
        values[key] = value
        lastUse[key] = clock
        guard values.count > capacity else {
            return nil
        }
        let victim = lastUse.min { $0.value < $1.value }!.key
        remove(victim)
        return victim
    }

    @discardableResult
    public mutating func remove(_ key: Key) -> Value? {
        lastUse[key] = nil
        return values.removeValue(forKey: key)
    }

    /// Removes every entry whose key satisfies `predicate`; returns how many were removed.
    @discardableResult
    public mutating func removeAll(where predicate: (Key) -> Bool) -> Int {
        let victims = values.keys.filter(predicate)
        for key in victims {
            remove(key)
        }
        return victims.count
    }

    public mutating func removeAll() {
        values.removeAll()
        lastUse.removeAll()
    }
}

extension LRUStore: Sendable where Key: Sendable, Value: Sendable {}

/// Rasterized tiles by key.  `tile(for:in:geometry:)` renders on a miss, so callers on the
/// main actor never rasterize; `invalidate(pasteboardRect:canvas:)` drops every tile whose
/// pasteboard bounds touch the rectangle at any zoom step or rotation.
public actor TileCache {
    public let capacity: Int
    public let tileSize: Int
    private let renderer: any WTRender
    private var store: LRUStore<TileKey, CGImage>
    private(set) var renderCount = 0

    public init(renderer: any WTRender, capacity: Int = 512, tileSize: Int = TileGeometry.standardTileSize) {
        self.renderer = renderer
        self.capacity = max(capacity, 1)
        self.tileSize = tileSize
        store = LRUStore(capacity: capacity)
    }

    public var count: Int { store.count }

    /// Keys from least to most recently used.
    public var keysByRecency: [TileKey] { store.keysByRecency }

    /// How many tiles have been rasterized so far (a cache-miss counter for tests).
    public var renders: Int { renderCount }

    /// The tile, rendered and stored on a miss.  Returns nil without rendering when the
    /// calling task was cancelled (the canvas cancels requests it no longer needs, and a
    /// cancelled request must not store a tile of a stale display list after an
    /// invalidation), or when no bitmap could be allocated.
    public func tile(for key: TileKey, in displayList: DisplayList, geometry: TileGeometry) -> CGImage? {
        if Task.isCancelled {
            return nil
        }
        if let cached = store.value(for: key) {
            return cached
        }
        renderCount += 1
        guard let image = renderer.renderTile(displayList, key: key, geometry: geometry) else {
            return nil
        }
        store.insert(image, for: key)
        return image
    }

    /// The tile if cached (marking it recently used); never renders.
    public func cachedTile(for key: TileKey) -> CGImage? {
        store.value(for: key)
    }

    /// Stores a tile rendered elsewhere.
    public func insert(_ image: CGImage, for key: TileKey) {
        store.insert(image, for: key)
    }

    /// Drops every tile of `canvas` whose pasteboard bounds intersect `rect`, whatever its
    /// zoom step or rotation.  Returns the dropped keys.
    @discardableResult
    public func invalidate(pasteboardRect rect: Rect, canvas: CanvasID) -> [TileKey] {
        let victims = store.keys.filter { key in
            key.canvas == canvas && TileGeometry(key: key, tileSize: tileSize).pasteboardBounds(of: key).intersects(rect)
        }
        for key in victims {
            store.remove(key)
        }
        return victims
    }

    /// Drops every tile of `canvas`.
    @discardableResult
    public func invalidateAll(canvas: CanvasID) -> Int {
        store.removeAll { $0.canvas == canvas }
    }

    /// Drops every tile.
    public func removeAll() {
        store.removeAll()
    }
}
