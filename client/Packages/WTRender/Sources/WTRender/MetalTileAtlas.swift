// The tile atlas (REND-006; docs/spec/client.adoc, "Metal tile renderer", *Tile atlas*):
// rasterized tiles live in slots of one array texture, a tile key maps to a slot, and slots are
// reused least recently used first.  A tile is drawable once the command buffer that rendered
// it has completed.
//
// The atlas is a `texture2DArray` of 256 × 256 slices rather than 4096² sheets: a multisample
// resolve can target a slice but not a sub-rectangle, so slices let a tile be resolved straight
// into its slot (NOTE on REND-006 in client.adoc).  256 slices hold what one 4096² sheet does.

import Metal

/// Slot bookkeeping for the atlas, separate from the texture so eviction is testable as plain
/// values.
struct TileSlots {
    let capacity: Int
    private var slots = LRUStore<TileKey, Int>(capacity: Int.max)
    private var free: [Int]
    /// Keys whose tile has finished rendering.
    private(set) var ready: Set<TileKey> = []

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        free = Array((0..<self.capacity).reversed())
    }

    var count: Int { slots.count }

    /// The slot of `key` if its tile is drawable, marking it recently used.
    mutating func readySlot(for key: TileKey) -> Int? {
        guard ready.contains(key) else {
            return nil
        }
        return slots.value(for: key)
    }

    func contains(_ key: TileKey) -> Bool {
        slots.contains(key)
    }

    /// A slot for `key`, taking a free one or evicting the least recently used key that is not
    /// in `protected`; nil when every slot holds a protected key.  The tile is not ready until
    /// `markReady`.
    mutating func allocate(_ key: TileKey, protecting protected: Set<TileKey>) -> Int? {
        if let existing = slots.peek(key) {
            return existing
        }
        if free.isEmpty {
            guard let victim = slots.keysByRecency.first(where: { !protected.contains($0) }) else {
                return nil
            }
            remove(victim)
        }
        let slot = free.removeLast()
        slots.insert(slot, for: key)
        return slot
    }

    /// Marks `key`'s tile drawable, if it still holds a slot.
    mutating func markReady(_ key: TileKey) {
        if slots.contains(key) {
            ready.insert(key)
        }
    }

    /// Frees `key`'s slot.
    mutating func remove(_ key: TileKey) {
        if let slot = slots.remove(key) {
            free.append(slot)
        }
        ready.remove(key)
    }

    /// Frees every slot whose key satisfies `predicate`; returns the removed keys.
    @discardableResult
    mutating func removeAll(where predicate: (TileKey) -> Bool) -> [TileKey] {
        let victims = slots.keys.filter(predicate)
        for key in victims {
            remove(key)
        }
        return victims
    }
}

/// The atlas texture and its slots.
final class MetalTileAtlas {
    /// The longest array texture every Metal device supports.
    static let maximumCapacity = 2048

    let texture: any MTLTexture
    let tileSize: Int
    var slots: TileSlots

    init?(device: any MTLDevice, capacity: Int, tileSize: Int = TileGeometry.standardTileSize) {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = MetalContext.colorFormat
        descriptor.width = tileSize
        descriptor.height = tileSize
        descriptor.arrayLength = min(max(capacity, 1), MetalTileAtlas.maximumCapacity)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        texture.label = "WTRender.atlas"
        self.texture = texture
        self.tileSize = tileSize
        slots = TileSlots(capacity: descriptor.arrayLength)
    }
}
