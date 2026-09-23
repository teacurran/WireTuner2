package com.villagecompute.wiretuner.crdt;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;

/**
 * One protobuf message read at the wire level: its records (tag plus payload) in order, without a
 * schema. The engine walks {@code SetFields.values} with the merge table this way rather than
 * through generated classes, so a field newer than this replica merges and survives unchanged
 * (docs/spec/crdt-model.adoc, "Schema evolution").
 */
final class WireMessage {

    static final int VARINT = 0;
    static final int FIXED64 = 1;
    static final int LEN = 2;
    static final int FIXED32 = 5;

    private static final long MAX_FIELD_NUMBER = 0x1FFF_FFFFL;

    /** One record: field number, wire type, and where the record and its payload start and end. */
    record Field(int number, int wireType, int start, int payloadStart, int end) {
    }

    private final byte[] bytes;
    private final List<Field> fields;

    private WireMessage(byte[] bytes, List<Field> fields) {
        this.bytes = bytes;
        this.fields = fields;
    }

    /**
     * Parses {@code bytes}, or returns {@code null} when they are not a well-formed message
     * (truncated, an over-long varint, field number 0 or above 2^29-1, a group, an unknown wire
     * type).
     */
    static WireMessage parse(byte[] bytes) {
        List<Field> fields = new ArrayList<>();
        Cursor cursor = new Cursor(bytes);
        while (!cursor.atEnd()) {
            int start = cursor.pos;
            long tag = cursor.varint();
            long number = tag >>> 3;
            if (cursor.failed || number < 1 || number > MAX_FIELD_NUMBER) {
                return null;
            }
            int wireType = (int) (tag & 7);
            int payloadStart = cursor.skipHeader(wireType);
            if (cursor.failed) {
                return null;
            }
            fields.add(new Field((int) number, wireType, start, payloadStart, cursor.pos));
        }
        return new WireMessage(bytes, fields);
    }

    /** Whether any record has field number {@code number}. */
    boolean has(int number) {
        for (Field field : fields) {
            if (field.number() == number) {
                return true;
            }
        }
        return false;
    }

    /** Every record of {@code number}, concatenated in order, or {@code null} when there is none. */
    byte[] records(int number) {
        ByteArrayOutputStream out = null;
        for (Field field : fields) {
            if (field.number() == number) {
                out = out == null ? new ByteArrayOutputStream() : out;
                out.write(bytes, field.start(), field.end() - field.start());
            }
        }
        return out == null ? null : out.toByteArray();
    }

    /**
     * The embedded message in field {@code number}: the payloads of its LEN records concatenated
     * (protobuf merges repeated occurrences of a message field), or {@code null} when there is
     * none or it does not parse.
     */
    WireMessage message(int number) {
        ByteArrayOutputStream out = null;
        for (Field field : fields) {
            if (field.number() == number && field.wireType() == LEN) {
                out = out == null ? new ByteArrayOutputStream() : out;
                out.write(bytes, field.payloadStart(), field.end() - field.payloadStart());
            }
        }
        return out == null ? null : parse(out.toByteArray());
    }

    /**
     * The field number of the last LEN record whose number is in {@code candidates}, or 0 if none:
     * the set case of a oneof of messages, as a protobuf parser reads it.
     */
    int lastMessageOf(Set<Integer> candidates) {
        int found = 0;
        for (Field field : fields) {
            if (field.wireType() == LEN && candidates.contains(field.number())) {
                found = field.number();
            }
        }
        return found;
    }

    /** A read position that latches {@code failed} instead of throwing. */
    private static final class Cursor {
        private final byte[] bytes;
        private int pos;
        private boolean failed;

        Cursor(byte[] bytes) {
            this.bytes = bytes;
        }

        boolean atEnd() {
            return pos >= bytes.length;
        }

        long varint() {
            long value = 0;
            for (int shift = 0; shift < 70; shift += 7) {
                if (atEnd()) {
                    break;
                }
                byte b = bytes[pos++];
                value |= (long) (b & 0x7F) << shift;
                if (b >= 0) {
                    return value;
                }
            }
            failed = true;
            return 0;
        }

        // Moves past the record's payload; returns where the payload starts (after a LEN's length).
        int skipHeader(int wireType) {
            long length;
            switch (wireType) {
                case VARINT -> {
                    varint();
                    return pos;
                }
                case FIXED64 -> length = 8;
                case LEN -> length = varint();
                case FIXED32 -> length = 4;
                default -> {
                    failed = true;
                    return pos;
                }
            }
            int payloadStart = pos;
            if (failed || length < 0 || length > bytes.length - pos) {
                failed = true;
            } else {
                pos += (int) length;
            }
            return payloadStart;
        }
    }
}
