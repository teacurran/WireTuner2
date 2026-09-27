package com.villagecompute.wiretuner.crdt;

import java.util.Arrays;
import java.util.Objects;

/** One resolved attribute of a run: the winning mark's value. Mirrors {@code WTCRDT.TextAttribute}. */
public record TextAttribute(MarkKey key, byte[] value, OpId mark) {

    /** A copy of the winning mark's {@code TextMarkValue} bytes. */
    @Override
    public byte[] value() {
        return value.clone();
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof TextAttribute attribute && key.equals(attribute.key)
                && Arrays.equals(value, attribute.value) && mark.equals(attribute.mark);
    }

    @Override
    public int hashCode() {
        return Objects.hash(key, Arrays.hashCode(value), mark);
    }

    /** {@inheritDoc} The value shows as hex. */
    @Override
    public String toString() {
        return "TextAttribute[key=" + key + ", value=" + Bytes.show(value) + ", mark=" + mark + "]";
    }
}
