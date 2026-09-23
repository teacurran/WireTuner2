package com.villagecompute.wiretuner.crdt;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;
import java.util.random.RandomGenerator;

/**
 * Fractional positions (docs/spec/crdt-model.adoc, "Sibling order"; CRDT-003): byte strings
 * compared bytewise, generated between two neighbours with a random suffix. Mirrors
 * {@code WTCRDT.FractionalIndex} and generates the same key from the same random value.
 *
 * <p>A generated key is never empty and never ends in {@code 0x00}. The body is built from the
 * neighbours' digits (base 256): no neighbours {@code [0x80]}; after {@code lo}, {@code lo} up to
 * its first byte below {@code 0xFF}, plus one; before {@code hi}, {@code hi}'s leading zeros then
 * its first other byte minus one (a {@code 0x01} there becomes {@code 0x00 0xFF}); between both,
 * their common prefix then the midpoint digit when the next digits differ by two or more, else
 * {@code lo}'s digit followed by the "after" key of the rest of {@code lo}. Then two suffix bytes
 * from one random value {@code r}: {@code r & 0xFF} and {@code 1 + (r >>> 8) % 255} (unsigned).
 */
public final class FractionalIndex {

    private FractionalIndex() {
    }

    /** Bytewise unsigned order, shorter prefix first. */
    public static boolean less(byte[] a, byte[] b) {
        return Arrays.compareUnsigned(a, b) < 0;
    }

    /** Sibling order: by position (bytewise unsigned), then by id. */
    public static int childOrder(byte[] positionA, OpId idA, byte[] positionB, OpId idB) {
        int byPosition = Arrays.compareUnsigned(positionA, positionB);
        return byPosition != 0 ? byPosition : idA.compareTo(idB);
    }

    /**
     * A key strictly between {@code lo} and {@code hi} ({@code null}: the start or end of the
     * list), using one value from {@code random} for the suffix.
     *
     * @throws IllegalArgumentException if a neighbour is not a generated key or they are out of order
     */
    public static byte[] between(byte[] lo, byte[] hi, RandomGenerator random) {
        return between(lo, hi, random.nextLong());
    }

    /**
     * A key strictly between {@code lo} and {@code hi} with the suffix taken from {@code suffix}.
     *
     * @throws IllegalArgumentException if a neighbour is not a generated key or they are out of order
     */
    public static byte[] between(byte[] lo, byte[] hi, long suffix) {
        check(lo);
        check(hi);
        byte[] body;
        if (lo == null) {
            body = hi == null ? new byte[] {(byte) 0x80} : before(hi);
        } else if (hi == null) {
            body = after(lo, 0);
        } else {
            if (!less(lo, hi)) {
                throw new IllegalArgumentException(Bytes.hex(lo) + " does not sort before " + Bytes.hex(hi));
            }
            body = middle(lo, hi);
        }
        byte[] key = Arrays.copyOf(body, body.length + 2);
        key[body.length] = (byte) suffix;
        key[body.length + 1] = (byte) (1 + Long.remainderUnsigned(suffix >>> 8, 255));
        return key;
    }

    private static void check(byte[] key) {
        if (key != null && (key.length == 0 || key[key.length - 1] == 0)) {
            throw new IllegalArgumentException(Bytes.hex(key) + " is not a generated position");
        }
    }

    // lo[from...] up to its first byte below 0xFF, plus one; [0x01] when that rest is empty.
    private static byte[] after(byte[] lo, int from) {
        ByteArrayOutputStream key = new ByteArrayOutputStream();
        for (int i = from; i < lo.length; i++) {
            int b = lo[i] & 0xFF;
            if (b < 0xFF) {
                key.write(b + 1);
                return key.toByteArray();
            }
            key.write(b);
        }
        key.write(1);
        return key.toByteArray();
    }

    // hi's leading zeros, then its first other byte minus one (0x01 becomes 0x00 0xFF).
    private static byte[] before(byte[] hi) {
        int index = 0;
        while (hi[index] == 0) {
            index++;
        }
        int b = hi[index] & 0xFF;
        byte[] key = new byte[b > 1 ? index + 1 : index + 2];
        if (b > 1) {
            key[index] = (byte) (b - 1);
        } else {
            key[index + 1] = (byte) 0xFF;
        }
        return key;
    }

    private static byte[] middle(byte[] lo, byte[] hi) {
        int n = 0;
        while (digit(lo, n) == (hi[n] & 0xFF)) {
            n++;
        }
        ByteArrayOutputStream key = new ByteArrayOutputStream();
        key.write(hi, 0, n);
        int low = digit(lo, n);
        int high = hi[n] & 0xFF;
        if (high - low >= 2) {
            key.write((low + high) / 2);
        } else {
            key.write(low);
            key.writeBytes(after(lo, n + 1));
        }
        return key.toByteArray();
    }

    private static int digit(byte[] key, int index) {
        return index < key.length ? key[index] & 0xFF : 0;
    }
}
