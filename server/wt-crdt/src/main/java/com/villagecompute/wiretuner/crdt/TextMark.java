package com.villagecompute.wiretuner.crdt;

import java.util.Arrays;
import java.util.Objects;

/**
 * One formatting mark ({@code TextMark}, CRDT-006): a span between two anchors, its id (the op's)
 * and its {@code TextMarkValue} bytes exactly as the op carried them; {@code key} is what it
 * formats ({@code null}: the value sets no attribute). Mirrors {@code WTCRDT.TextMark}.
 */
public record TextMark(OpId id, Anchor start, Anchor end, byte[] value, MarkKey key) {

    /** A copy of the value. */
    @Override
    public byte[] value() {
        return value.clone();
    }

    byte[] valueBytes() {
        return value;
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof TextMark mark && id.equals(mark.id) && start.equals(mark.start) && end.equals(mark.end)
                && Arrays.equals(value, mark.value) && Objects.equals(key, mark.key);
    }

    @Override
    public int hashCode() {
        return Objects.hash(id, start, end, Arrays.hashCode(value), key);
    }
}
