package com.villagecompute.wiretuner.crdt;

import java.io.ByteArrayOutputStream;
import java.util.HexFormat;

/** Big-endian fixed-width writers for the canonical encodings, and hex. */
final class Bytes {

    private Bytes() {
    }

    static void writeU32(ByteArrayOutputStream out, int value) {
        out.write(value >>> 24);
        out.write(value >>> 16);
        out.write(value >>> 8);
        out.write(value);
    }

    static void writeU64(ByteArrayOutputStream out, long value) {
        writeU32(out, (int) (value >>> 32));
        writeU32(out, (int) value);
    }

    static void writeId(ByteArrayOutputStream out, OpId id) {
        writeU64(out, id.counter());
        writeU64(out, id.replica());
    }

    static void writeBlock(ByteArrayOutputStream out, byte[] block) {
        writeU32(out, block.length);
        out.writeBytes(block);
    }

    static String hex(byte[] bytes) {
        return HexFormat.of().formatHex(bytes);
    }

    /** {@code bytes} as hex for a record's {@code toString}, or {@code null}. */
    static String show(byte[] bytes) {
        return bytes == null ? "null" : hex(bytes);
    }
}
