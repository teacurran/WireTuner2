// Decoded, treated image levels held in memory under a byte budget (IMG-018): least recently
// used first out, so panning over twenty large images keeps the ones on screen.

import CoreGraphics
import Foundation

/// Identifies one decoded level of one blob under one treatment.
public struct ImageCacheKey: Hashable, Sendable {
    public var hash: String
    public var level: Int
    public var treatment: ImageTreatment

    public init(hash: String, level: Int, treatment: ImageTreatment) {
        self.hash = hash
        self.level = level
        self.treatment = treatment
    }
}

/// A thread-safe, byte-budgeted LRU of decoded images.
public final class ImageMemoryCache: @unchecked Sendable {
    private struct Entry {
        var image: CGImage
        var bytes: Int
        var tick: UInt64
    }

    /// The most bytes held after an insert (a single image larger than the budget is still
    /// held, alone).
    public let budget: Int
    private let lock = NSLock()
    private var entries: [ImageCacheKey: Entry] = [:]
    private var clock: UInt64 = 0
    private var total = 0

    public init(budget: Int = 512 << 20) {
        self.budget = max(budget, 0)
    }

    /// The decoded size of `image`.
    public static func cost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    public var bytesInUse: Int {
        lock.withLock { total }
    }

    public var count: Int {
        lock.withLock { entries.count }
    }

    /// The image for `key`, marking it most recently used.
    public func image(for key: ImageCacheKey) -> CGImage? {
        lock.withLock {
            guard var entry = entries[key] else {
                return nil
            }
            clock += 1
            entry.tick = clock
            entries[key] = entry
            return entry.image
        }
    }

    /// Any cached level of `hash` under `treatment`, finest first: what to draw while the
    /// wanted level decodes.
    public func anyLevel(hash: String, treatment: ImageTreatment) -> (level: Int, image: CGImage)? {
        lock.withLock {
            entries
                .filter { $0.key.hash == hash && $0.key.treatment == treatment }
                .min { $0.key.level < $1.key.level }
                .map { ($0.key.level, $0.value.image) }
        }
    }

    /// Holds `image` for `key` and evicts least recently used entries (never the new one)
    /// until the total fits the budget.
    public func insert(_ image: CGImage, for key: ImageCacheKey) {
        lock.withLock {
            clock += 1
            let bytes = ImageMemoryCache.cost(of: image)
            total -= entries[key]?.bytes ?? 0
            entries[key] = Entry(image: image, bytes: bytes, tick: clock)
            total += bytes
            while total > budget, let victim = entries.filter({ $0.key != key }).min(by: { $0.value.tick < $1.value.tick }) {
                total -= victim.value.bytes
                entries[victim.key] = nil
            }
        }
    }

    /// Drops every level of `hash` (the blob changed or was purged).
    public func removeAll(hash: String) {
        lock.withLock {
            for key in entries.keys where key.hash == hash {
                total -= entries[key]!.bytes
                entries[key] = nil
            }
        }
    }

    public func removeAll() {
        lock.withLock {
            entries.removeAll()
            total = 0
        }
    }
}
