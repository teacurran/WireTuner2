package com.villagecompute.wiretuner.crdt;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.Arrays;
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

    /**
     * One record: field number, wire type, and where the record and its payload start and end
     * (for a VARINT record the payload start is its end; the value follows the tag).
     */
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
     * Each LEN record of {@code number} parsed on its own, in order; {@code null} for one that
     * does not parse. The elements an {@code ElementInsert} carries are the occurrences of the
     * SEQUENCE field.
     */
    List<WireMessage> occurrences(int number) {
        List<WireMessage> out = new ArrayList<>();
        for (Field field : fields) {
            if (field.number() == number && field.wireType() == LEN) {
                out.add(parse(Arrays.copyOfRange(bytes, field.payloadStart(), field.end())));
            }
        }
        return out;
    }

    /** The payload of each LEN record of {@code number}, in order. */
    List<byte[]> payloads(int number) {
        List<byte[]> out = new ArrayList<>();
        for (Field field : fields) {
            if (field.number() == number && field.wireType() == LEN) {
                out.add(Arrays.copyOfRange(bytes, field.payloadStart(), field.end()));
            }
        }
        return out;
    }

    /** The payload of the last LEN record of {@code number}, or {@code null} when there is none. */
    byte[] lastPayload(int number) {
        byte[] found = null;
        for (Field field : fields) {
            if (field.number() == number && field.wireType() == LEN) {
                found = Arrays.copyOfRange(bytes, field.payloadStart(), field.end());
            }
        }
        return found;
    }

    /** The field number of the last record, or {@code null} for an empty message. */
    Integer lastField() {
        return fields.isEmpty() ? null : fields.get(fields.size() - 1).number();
    }

    /** The wire type of the last record, or {@code null} for an empty message. */
    Integer lastWireType() {
        return fields.isEmpty() ? null : fields.get(fields.size() - 1).wireType();
    }

    /**
     * The value bytes of the last record as on the wire (a VARINT's varint, a fixed value's bytes,
     * a LEN record's payload), or {@code null} for an empty message.
     */
    byte[] lastRecordPayload() {
        if (fields.isEmpty()) {
            return null;
        }
        Field field = fields.get(fields.size() - 1);
        if (field.wireType() != VARINT) {
            return Arrays.copyOfRange(bytes, field.payloadStart(), field.end());
        }
        Cursor cursor = new Cursor(Arrays.copyOfRange(bytes, field.start(), field.end()));
        cursor.varint(); // the tag
        return Arrays.copyOfRange(cursor.bytes, cursor.pos, cursor.bytes.length);
    }

    private static final Set<String> VARINT_TYPES = Set.of("int32", "int64", "uint32", "uint64", "sint32", "sint64", "bool", "enum");
    private static final Set<String> FIXED64_TYPES = Set.of("fixed64", "sfixed64", "double");
    private static final Set<String> FIXED32_TYPES = Set.of("fixed32", "sfixed32", "float");

    /** Message types a SET may hold, compared as ids. */
    static final Set<String> ID_TYPES = Set.of("wiretuner.doc.v1.ElementId", "wiretuner.doc.v1.OpId");

    /**
     * The members of the SET field {@code number} of protobuf {@code type} ({@code typeName} for
     * messages), each in its canonical form (docs/spec/crdt-model.adoc, "Sets"): a string's or
     * bytes' payload; a varint scalar's value as a big-endian uint64; a fixed-width scalar's
     * little-endian wire bytes; an ElementId or OpId as its counter and replica, big-endian
     * uint64s. Packed and unpacked scalars are both read. A record of the wrong wire type, or a
     * packed record or id message that does not parse, holds no members. {@code null} for a type
     * a SET cannot hold.
     */
    List<byte[]> members(int number, String type, String typeName) {
        List<byte[]> out = new ArrayList<>();
        boolean text = type.equals("string") || type.equals("bytes");
        boolean id = type.equals("message") && typeName != null && ID_TYPES.contains(typeName);
        int width = FIXED64_TYPES.contains(type) ? 8 : FIXED32_TYPES.contains(type) ? 4 : 0;
        boolean varint = VARINT_TYPES.contains(type);
        if (!text && !id && width == 0 && !varint) {
            return null;
        }
        for (Field field : fields) {
            if (field.number() != number) {
                continue;
            }
            if (text || id) {
                if (field.wireType() == LEN) {
                    byte[] payload = Arrays.copyOfRange(bytes, field.payloadStart(), field.end());
                    byte[] member = text ? payload : idMember(payload);
                    if (member != null) {
                        out.add(member);
                    }
                }
            } else {
                out.addAll(scalars(field, varint ? VARINT : width == 8 ? FIXED64 : FIXED32, width));
            }
        }
        return out;
    }

    private static byte[] idMember(byte[] payload) {
        WireMessage id = parse(payload);
        if (id == null) {
            return null;
        }
        ByteArrayOutputStream member = new ByteArrayOutputStream();
        Bytes.writeU64(member, id.lastVarint(1));
        Bytes.writeU64(member, id.lastFixed64(2));
        return member.toByteArray();
    }

    // The values of one scalar record: the record itself when it has the unpacked wire type, the
    // packed values when it is LEN and parses completely, else none.  width 0 = varint.
    private List<byte[]> scalars(Field field, int unpacked, int width) {
        if (field.wireType() != unpacked && field.wireType() != LEN) {
            return List.of();
        }
        boolean single = field.wireType() == unpacked;
        Cursor cursor = new Cursor(Arrays.copyOfRange(bytes, single ? field.start() : field.payloadStart(), field.end()));
        if (single) {
            cursor.varint(); // the tag
            return List.of(readScalar(cursor, width));
        }
        List<byte[]> values = new ArrayList<>();
        while (!cursor.atEnd()) {
            byte[] value = readScalar(cursor, width);
            if (cursor.failed) {
                return List.of();
            }
            values.add(value);
        }
        return values;
    }

    private static byte[] readScalar(Cursor cursor, int width) {
        if (width == 0) {
            ByteArrayOutputStream member = new ByteArrayOutputStream();
            Bytes.writeU64(member, cursor.varint());
            return member.toByteArray();
        }
        return cursor.take(width);
    }

    /** The value of the last VARINT record of {@code number}, or 0. */
    long lastVarint(int number) {
        Field last = null;
        for (Field field : fields) {
            if (field.number() == number && field.wireType() == VARINT) {
                last = field;
            }
        }
        if (last == null) {
            return 0;
        }
        Cursor cursor = new Cursor(Arrays.copyOfRange(bytes, last.start(), last.end()));
        cursor.varint(); // the tag
        return cursor.varint();
    }

    /** The value of the last FIXED64 record of {@code number} (little-endian), or 0. */
    long lastFixed64(int number) {
        Field last = null;
        for (Field field : fields) {
            if (field.number() == number && field.wireType() == FIXED64) {
                last = field;
            }
        }
        long value = 0;
        if (last != null) {
            for (int i = last.end() - 1; i >= last.payloadStart(); i--) {
                value = value << 8 | (bytes[i] & 0xFF);
            }
        }
        return value;
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

        /** The next {@code count} bytes, or none (latching {@code failed}) when fewer remain. */
        byte[] take(int count) {
            if (bytes.length - pos < count) {
                failed = true;
                return new byte[0];
            }
            pos += count;
            return Arrays.copyOfRange(bytes, pos - count, pos);
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
