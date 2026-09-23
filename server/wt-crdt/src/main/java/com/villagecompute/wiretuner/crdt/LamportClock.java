package com.villagecompute.wiretuner.crdt;

/**
 * A replica's Lamport clock (docs/spec/crdt-model.adoc, "Identifiers"): the next counter is one
 * more than the largest counter this replica has created <em>or seen</em>. Counters are unsigned
 * 64-bit values. Not thread-safe; the owning {@link Engine} serialises access.
 */
public final class LamportClock {

    private long max;

    /** A clock that has created and seen nothing: its next counter is 1. */
    public LamportClock() {
        this(0);
    }

    /** A clock resumed at {@code max}, the largest counter created or seen so far. */
    public LamportClock(long max) {
        this.max = max;
    }

    /** The largest counter created or seen (unsigned). */
    public long max() {
        return max;
    }

    /** The counter the next created operation takes, without taking it. */
    public long peek() {
        return max + 1;
    }

    /** Records a counter seen in an operation, created here or elsewhere. */
    public void observe(long counter) {
        if (Long.compareUnsigned(counter, max) > 0) {
            max = counter;
        }
    }

    /**
     * Takes {@code count} consecutive counters for a change of {@code count} operations and
     * returns the first; the change's op {@code i} has counter {@code first + i}.
     *
     * @throws IllegalArgumentException if {@code count} is not positive
     */
    public long allocate(int count) {
        if (count < 1) {
            throw new IllegalArgumentException("a change has at least one operation: " + count);
        }
        long first = max + 1;
        max += count;
        return first;
    }
}
