// A small thread-safe memo for the geometry both renderers derive from display-list values:
// stroke outlines, brush layouts, custom-stroke tiles, calligraphic sweeps, contour distance
// fields.  Display lists are values rebuilt on every change, so results are keyed by value;
// renders on any executor share one cache.

import Foundation

final class RenderCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Key: Value] = [:]
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    /// The cached value for `key`, computing and storing it on a miss.  When full, the cache
    /// starts over: simple, and a working set larger than the capacity recomputes either way.
    func value(for key: Key, compute: () -> Value) -> Value {
        lock.lock()
        if let hit = entries[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let value = compute()
        lock.lock()
        if entries.count >= capacity {
            entries.removeAll(keepingCapacity: true)
        }
        entries[key] = value
        lock.unlock()
        return value
    }
}
