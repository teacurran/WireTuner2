package com.villagecompute.wiretuner.crdt;

import java.io.ByteArrayOutputStream;

/**
 * A protobuf wire writer for the encodings the engine produces itself -- snapshots, inverse ops'
 * values, cleared mark values -- field by field in the order written, so both engines emit the
 * same bytes. Mirrors {@code WTCRDT.WireWriter}. Proto3 defaults are left out unless asked for.
 */
final class WireWriter {

    private final ByteArrayOutputStream out = new ByteArrayOutputStream();

    byte[] bytes() {
        return out.toByteArray();
    }

    void raw(byte[] data) {
        out.writeBytes(data);
    }

    void varint(long value) {
        long rest = value;
        while (Long.compareUnsigned(rest, 0x80) >= 0) {
            out.write((int) (rest & 0x7F) | 0x80);
            rest >>>= 7;
        }
        out.write((int) rest);
    }

    void tag(int field, int wireType) {
        varint(((long) field << 3) | wireType);
    }

    /** A VARINT field; zero is left out unless {@code always}. */
    void varintField(int field, long value, boolean always) {
        if (value != 0 || always) {
            tag(field, WireMessage.VARINT);
            varint(value);
        }
    }

    void varintField(int field, long value) {
        varintField(field, value, false);
    }

    /** A FIXED64 field (little-endian); zero is left out. */
    void fixed64Field(int field, long value) {
        if (value != 0) {
            tag(field, WireMessage.FIXED64);
            for (int shift = 0; shift < 64; shift += 8) {
                out.write((int) (value >>> shift));
            }
        }
    }

    /** A LEN field holding {@code payload}, written even when empty (message presence). */
    void lenField(int field, byte[] payload) {
        tag(field, WireMessage.LEN);
        varint(payload.length);
        out.writeBytes(payload);
    }

    /** A LEN field holding {@code payload}, left out when empty (a proto3 string or bytes default). */
    void bytesField(int field, byte[] payload) {
        if (payload.length > 0) {
            lenField(field, payload);
        }
    }

    /** An {@code OpId}/{@code ElementId} message field, written even for the zero id. */
    void idField(int field, OpId id) {
        lenField(field, id(id));
    }

    /** An {@code OpId}/{@code ElementId} message field, left out for the zero id. */
    void optionalIdField(int field, OpId id) {
        if (!id.equals(OpId.ZERO)) {
            idField(field, id);
        }
    }

    /** The encoding of an {@code OpId}/{@code ElementId}: counter (1, varint) and replica (2, fixed64). */
    static byte[] id(OpId id) {
        WireWriter out = new WireWriter();
        out.varintField(1, id.counter());
        out.fixed64Field(2, id.replica());
        return out.bytes();
    }

    /** A {@code FieldPath} message: one {@code PathSegment} per segment (field = 1, element = 2). */
    static byte[] path(RegisterPath path) {
        WireWriter out = new WireWriter();
        for (RegisterPath.Segment segment : path.segments()) {
            WireWriter inner = new WireWriter();
            if (segment.isElement()) {
                inner.idField(2, segment.element());
            } else {
                inner.varintField(1, Integer.toUnsignedLong(segment.field()), true);
            }
            out.lenField(1, inner.bytes());
        }
        return out.bytes();
    }
}
