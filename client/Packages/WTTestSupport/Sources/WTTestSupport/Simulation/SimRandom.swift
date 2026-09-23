import Foundation

/// The simulator's generator (docs/spec/testing.adoc, "Multi-client simulation"): SplitMix64, the
/// generator the fuzzer uses, so one seed names one run of the script.
///
/// Scheduling between the clients' actors is the operating system's, so a seed fixes what the
/// script does -- the edits, when faults start and stop -- not the exact interleaving.  Faults the
/// network applies to individual calls are therefore not drawn from a shared stream, whose order
/// would depend on which call happened to come first, but from `SimRandom.mix` of the seed and
/// the call's own key (link, kind, replica, seq, attempt): a given push meets the same fate
/// whatever else was in flight.
public struct SimRandom: Sendable, Hashable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    /// The next 64 bits.
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return Self.finalize(state)
    }

    /// A value in `0..<bound` (`bound` > 0).
    public mutating func below(_ bound: Int) -> Int {
        precondition(bound > 0)
        return Int(next() % UInt64(bound))
    }

    /// A value in `range`.
    public mutating func within(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + below(range.count)
    }

    /// A double in `0..<1`.
    public mutating func unit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }

    /// True with probability `probability` (0...1).
    public mutating func chance(_ probability: Double) -> Bool {
        unit() < probability
    }

    /// An element of a non-empty collection.
    public mutating func pick<C: RandomAccessCollection>(_ collection: C) -> C.Element where C.Index == Int {
        collection[collection.startIndex + below(collection.count)]
    }

    /// A generator for one part of the run, independent of how much the parent drew.
    public func fork(_ label: UInt64) -> SimRandom {
        SimRandom(seed: Self.mix(state, label))
    }

    /// A stateless hash of `seed` and `keys`: the same inputs give the same 64 bits.
    public static func mix(_ seed: UInt64, _ keys: UInt64...) -> UInt64 {
        mix(seed, keys)
    }

    public static func mix(_ seed: UInt64, _ keys: [UInt64]) -> UInt64 {
        var value = finalize(seed &+ 0x9E37_79B9_7F4A_7C15)
        for key in keys {
            value = finalize(value ^ (key &* 0xD6E8_FEB8_6659_FD93) &+ 0x9E37_79B9_7F4A_7C15)
        }
        return value
    }

    /// `mix` as a double in `0..<1`.
    public static func unit(_ seed: UInt64, _ keys: UInt64...) -> Double {
        Double(mix(seed, keys) >> 11) / Double(UInt64(1) << 53)
    }

    private static func finalize(_ input: UInt64) -> UInt64 {
        var value = input
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
