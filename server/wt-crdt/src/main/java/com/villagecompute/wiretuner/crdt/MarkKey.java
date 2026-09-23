package com.villagecompute.wiretuner.crdt;

import java.util.Arrays;

/**
 * The identity of a formatting attribute: the {@code TextMarkValue} case (its field number) and,
 * for the {@code feature} case, the feature's {@code tag} records, so marks of different tags
 * stack while marks of one attribute supersede by OpId. Mirrors {@code WTCRDT.MarkKey}.
 */
public record MarkKey(int field, byte[] tag) implements Comparable<MarkKey> {

    /** A key without a tag. */
    public MarkKey(int field) {
        this(field, new byte[0]);
    }

    /** A copy of the tag records. */
    @Override
    public byte[] tag() {
        return tag.clone();
    }

    @Override
    public int compareTo(MarkKey other) {
        return field != other.field ? Integer.compareUnsigned(field, other.field) : Arrays.compareUnsigned(tag, other.tag);
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof MarkKey key && field == key.field && Arrays.equals(tag, key.tag);
    }

    @Override
    public int hashCode() {
        return field * 31 + Arrays.hashCode(tag);
    }

    @Override
    public String toString() {
        return tag.length == 0 ? Integer.toUnsignedString(field) : Integer.toUnsignedString(field) + "/" + Bytes.hex(tag);
    }
}
