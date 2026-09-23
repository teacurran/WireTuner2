// The raster effect cache (FX-009; raster-effects.adoc, "Cache"): results keyed by the raster
// node's value (its content in pasteboard space, which carries the node's geometry, appearance
// and transform, and its operations and settings) and the resolution, least recently used first
// out under a byte cap (256 MiB by default).  An edit to an object changes its node's value, so
// its old entry is never hit again and ages out; `removeAll()` drops everything at once, for a
// change of the document resolution or the preview preference.
//
// Progressive mode renders misses on a background queue: the caller draws the vector content with
// a "rendering" badge meanwhile and is told the pasteboard rectangle to repaint when the bitmap is
// ready.

import Foundation
import WTGeometry

final class RasterEffectCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let node: RasterNode
        let resolution: Double
    }

    static let defaultCapacity = 256 * 1024 * 1024
    static let shared = RasterEffectCache(capacity: defaultCapacity)

    private let lock = NSLock()
    private var entries: [Key: (result: RasterResult?, stamp: UInt64)] = [:]
    private var pending: Set<Key> = []
    private var clock: UInt64 = 0
    private(set) var byteCount = 0
    /// Results rendered (not served from the cache), for tests.
    private(set) var renderCount = 0
    /// Entries evicted for space, for tests.
    private(set) var evictionCount = 0
    let capacity: Int
    private let queue = DispatchQueue(label: "com.villagecompute.wiretuner.raster-effects", qos: .userInitiated, attributes: .concurrent)

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        byteCount = 0
        lock.unlock()
    }

    /// The cached result, rendering it now on a miss.
    func result(for key: Key, render: () -> RasterResult?) -> RasterResult? {
        if let hit = lookup(key) {
            return hit.result
        }
        let result = render()
        store(result, for: key)
        return result
    }

    /// The cached result, or nil after starting a background render that calls `ready` with
    /// the rectangle to repaint when it finishes.
    func progressiveResult(for key: Key, area: Rect, ready: @escaping @Sendable (Rect) -> Void, render: @escaping @Sendable () -> RasterResult?) -> RasterResult? {
        if let hit = lookup(key) {
            return hit.result
        }
        lock.lock()
        let started = pending.insert(key).inserted
        lock.unlock()
        if started {
            queue.async { [self] in
                let result = render()
                store(result, for: key)
                lock.lock()
                pending.remove(key)
                lock.unlock()
                ready(area)
            }
        }
        return nil
    }

    private func lookup(_ key: Key) -> (result: RasterResult?, stamp: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else {
            return nil
        }
        clock += 1
        entries[key] = (entry.result, clock)
        return entry
    }

    private func store(_ result: RasterResult?, for key: Key) {
        let cost = result?.byteCount ?? 0
        lock.lock()
        defer { lock.unlock() }
        renderCount += 1
        clock += 1
        if let old = entries[key] {
            byteCount -= old.result?.byteCount ?? 0
        }
        entries[key] = (result, clock)
        byteCount += cost
        // Evict least recently used entries other than the one just stored.
        while byteCount > capacity, let victim = entries.filter({ $0.key != key }).min(by: { $0.value.stamp < $1.value.stamp }) {
            byteCount -= victim.value.result?.byteCount ?? 0
            entries[victim.key] = nil
            evictionCount += 1
        }
    }
}
