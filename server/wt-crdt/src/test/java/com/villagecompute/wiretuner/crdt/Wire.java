package com.villagecompute.wiretuner.crdt;

import java.io.ByteArrayOutputStream;

/** A tiny protobuf wire writer for tests that need bytes no generated message produces. */
final class Wire {

    private final ByteArrayOutputStream out = new ByteArrayOutputStream();

    static Wire message() {
        return new Wire();
    }

    Wire varint(int field, long value) {
        tag(field, 0);
        raw(value);
        return this;
    }

    Wire bytes(int field, byte[] payload) {
        tag(field, 2);
        raw(payload.length);
        out.writeBytes(payload);
        return this;
    }

    Wire string(int field, String value) {
        return bytes(field, value.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }

    Wire message(int field, Wire inner) {
        return bytes(field, inner.build());
    }

    Wire fixed64(int field, long value) {
        tag(field, 1);
        for (int i = 0; i < 8; i++) {
            out.write((int) (value >>> (8 * i)));
        }
        return this;
    }

    Wire fixed32(int field, int value) {
        tag(field, 5);
        for (int i = 0; i < 4; i++) {
            out.write(value >>> (8 * i));
        }
        return this;
    }

    Wire tag(int field, int wireType) {
        raw(((long) field << 3) | wireType);
        return this;
    }

    Wire raw(long value) {
        while ((value & ~0x7FL) != 0) {
            out.write((int) ((value & 0x7F) | 0x80));
            value >>>= 7;
        }
        out.write((int) value);
        return this;
    }

    Wire rawBytes(int... bytes) {
        for (int b : bytes) {
            out.write(b);
        }
        return this;
    }

    byte[] build() {
        return out.toByteArray();
    }
}
