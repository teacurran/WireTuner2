/// Fractional positions (docs/spec/crdt-model.adoc, "Sibling order"; CRDT-003): byte strings
/// compared bytewise, generated between two neighbours with a random suffix so that two people
/// inserting into the same gap at once almost never produce equal keys.  Positions are never
/// rebalanced; ties are broken by id (`childOrder`).  wt-crdt's `FractionalIndex` is this type in
/// Java and generates the same key from the same random value.
///
/// A generated key is never empty and never ends in `0x00`, so there is always room below it and
/// between it and any longer key.  The key is built from the neighbours' digits (base 256):
///
/// * no neighbours: `[0x80]`;
/// * after the last key `lo`: `lo` up to its first byte below `0xFF`, that byte plus one (so a
///   run of appends grows by one byte per ~128 keys);
/// * before the first key `hi`: `hi`'s leading zeros, then its first other byte minus one (a
///   `0x01` there becomes `0x00 0xFF`);
/// * between `lo` and `hi`: their common prefix, then the midpoint digit when the next digits
///   differ by two or more, else `lo`'s digit followed by the "after" key of the rest of `lo`;
///
/// then two suffix bytes from one 64-bit random value `r`: `r & 0xFF` and `1 + (r >> 8) % 255`.
/// The body is never a prefix of `hi`, so the suffix keeps the key below `hi`.
public enum FractionalIndex {
    /// Bytewise order, shorter prefix first: the order siblings and sequence elements sort by.
    public static func less(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.lexicographicallyPrecedes(b)
    }

    /// Whether `a` sorts before `b` as siblings: by position, then by id.
    public static func childOrder(_ a: (position: [UInt8], id: OpID), _ b: (position: [UInt8], id: OpID)) -> Bool {
        a.position == b.position ? a.id < b.id : less(a.position, b.position)
    }

    /// Why a key cannot be generated between two neighbours.
    public struct OrderError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// A key strictly between `lo` and `hi` (nil: the start or end of the list), using one value
    /// from `random` for the suffix.
    public static func between(
        _ lo: [UInt8]?, _ hi: [UInt8]?, using random: inout some RandomNumberGenerator
    ) throws(OrderError) -> [UInt8] {
        try between(lo, hi, suffix: random.next())
    }

    /// A key strictly between `lo` and `hi` with the suffix taken from `suffix`.  Neighbours must
    /// be generated keys (non-empty, not ending in `0x00`) and `lo` must sort before `hi`.
    public static func between(_ lo: [UInt8]?, _ hi: [UInt8]?, suffix: UInt64) throws(OrderError) -> [UInt8] {
        for key in [lo, hi].compactMap({ $0 }) where key.isEmpty || key.last == 0 {
            throw OrderError(description: "\(Bytes.hex(key)) is not a generated position")
        }
        var key: [UInt8]
        switch (lo, hi) {
        case (nil, nil):
            key = [0x80]
        case (let lo?, nil):
            key = after(lo[...])
        case (nil, let hi?):
            key = before(hi)
        case (let lo?, let hi?):
            guard less(lo, hi) else {
                throw OrderError(description: "\(Bytes.hex(lo)) does not sort before \(Bytes.hex(hi))")
            }
            key = middle(lo, hi)
        }
        key.append(UInt8(truncatingIfNeeded: suffix))
        key.append(UInt8(1 + (suffix >> 8) % 255))
        return key
    }

    // `lo` up to its first byte below 0xFF, plus one; [0x01] for an empty `lo`.
    private static func after(_ lo: ArraySlice<UInt8>) -> [UInt8] {
        var key: [UInt8] = []
        for byte in lo {
            if byte < 0xFF {
                key.append(byte + 1)
                return key
            }
            key.append(byte)
        }
        key.append(1)
        return key
    }

    // `hi` up to its first byte above 0x00, minus one; a 0x01 there becomes 0x00 0xFF.  `hi`
    // does not end in 0x00, so it holds a byte above 0x00.
    private static func before(_ hi: [UInt8]) -> [UInt8] {
        let index = hi.firstIndex { $0 != 0 }!
        let zeros = [UInt8](repeating: 0, count: index)
        return hi[index] > 1 ? zeros + [hi[index] - 1] : zeros + [0, 0xFF]
    }

    private static func middle(_ lo: [UInt8], _ hi: [UInt8]) -> [UInt8] {
        func digit(_ index: Int) -> Int { index < lo.count ? Int(lo[index]) : 0 }
        var n = 0
        while digit(n) == Int(hi[n]) {
            n += 1
        }
        var key = Array(hi[..<n])
        let low = digit(n)
        let high = Int(hi[n])
        if high - low >= 2 {
            key.append(UInt8((low + high) / 2))
        } else {
            key.append(UInt8(low))
            key += after(n + 1 < lo.count ? lo[(n + 1)...] : [])
        }
        return key
    }
}

/// SplitMix64 (Steele, Lea and Flood): a tiny seeded generator that wt-crdt implements
/// identically, so tests and conformance vectors can pin generated positions byte for byte.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
