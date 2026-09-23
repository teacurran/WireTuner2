package com.villagecompute.wiretuner.crdt;

import java.util.random.RandomGenerator;

/**
 * SplitMix64 (Steele, Lea and Flood): a tiny seeded generator that {@code WTCRDT.SplitMix64}
 * implements identically, so tests and conformance vectors can pin generated positions byte for
 * byte. Not thread-safe.
 */
public final class SplitMix64 implements RandomGenerator {

    private long state;

    /** A generator starting from {@code seed}. */
    public SplitMix64(long seed) {
        this.state = seed;
    }

    @Override
    public long nextLong() {
        state += 0x9E3779B97F4A7C15L;
        long z = state;
        z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9L;
        z = (z ^ (z >>> 27)) * 0x94D049BB133111EBL;
        return z ^ (z >>> 31);
    }
}
