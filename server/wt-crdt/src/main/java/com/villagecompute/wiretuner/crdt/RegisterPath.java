package com.villagecompute.wiretuner.crdt;

import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.PathSegment;
import java.io.ByteArrayOutputStream;
import java.util.Arrays;

/**
 * The address of one register inside a node: the field numbers from {@code NodeProps} down to an
 * ATOMIC field (docs/spec/crdt-model.adoc, "Merge policies"). Element segments (inside a
 * SEQUENCE) arrive with CRDT-004; the canonical encoding already reserves their tag.
 *
 * <p>Paths order by their {@link #canonical() canonical encoding}, compared bytewise unsigned,
 * which is the same as comparing field numbers segment by segment with a prefix first.
 */
public final class RegisterPath implements Comparable<RegisterPath> {

    /** Canonical tag of a field-number segment (then the number as a big-endian uint32). */
    static final int FIELD_TAG = 0x01;

    private final int[] fields;
    private final byte[] canonical;

    private RegisterPath(int[] fields) {
        this.fields = fields;
        ByteArrayOutputStream out = new ByteArrayOutputStream(fields.length * 5);
        for (int field : fields) {
            out.write(FIELD_TAG);
            Bytes.writeU32(out, field);
        }
        this.canonical = out.toByteArray();
    }

    /**
     * A path of field numbers, outermost first.
     *
     * @throws IllegalArgumentException if {@code fields} is empty
     */
    public static RegisterPath of(int... fields) {
        if (fields.length == 0) {
            throw new IllegalArgumentException("a register path has at least one field");
        }
        return new RegisterPath(fields.clone());
    }

    /**
     * The register path a wire {@code FieldPath} names, or {@code null} when it is empty or has a
     * segment that is not a field number (element segments arrive with CRDT-004).
     */
    public static RegisterPath of(FieldPath path) {
        int[] fields = new int[path.getSegmentsCount()];
        for (int i = 0; i < fields.length; i++) {
            PathSegment segment = path.getSegments(i);
            if (!segment.hasField()) {
                return null;
            }
            fields[i] = segment.getField();
        }
        return fields.length == 0 ? null : new RegisterPath(fields);
    }

    /** The wire {@code FieldPath} for this path. */
    public FieldPath toProto() {
        FieldPath.Builder path = FieldPath.newBuilder();
        for (int field : fields) {
            path.addSegments(PathSegment.newBuilder().setField(field));
        }
        return path.build();
    }

    /**
     * The value this path addresses inside an encoded message of the root type (a sparse
     * {@code NodeProps}): the records of the last field, reached through the embedded messages
     * of the others, or {@code null} when absent -- the same bytes a {@code SetFields} carrying
     * {@code message} writes into this register.
     */
    public byte[] valueIn(byte[] message) {
        WireMessage current = WireMessage.parse(message);
        for (int i = 0; i < fields.length - 1 && current != null; i++) {
            current = current.message(fields[i]);
        }
        return current == null ? null : current.records(fields[fields.length - 1]);
    }

    /** This path with {@code field} appended. */
    public RegisterPath child(int field) {
        int[] longer = Arrays.copyOf(fields, fields.length + 1);
        longer[fields.length] = field;
        return new RegisterPath(longer);
    }

    /** The field numbers, outermost first. */
    public int[] fields() {
        return fields.clone();
    }

    /** The canonical encoding the state hash uses (crdt-model.adoc, "Snapshots"). */
    public byte[] canonical() {
        return canonical.clone();
    }

    @Override
    public int compareTo(RegisterPath other) {
        return Arrays.compareUnsigned(canonical, other.canonical);
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof RegisterPath path && Arrays.equals(fields, path.fields);
    }

    @Override
    public int hashCode() {
        return Arrays.hashCode(fields);
    }

    /** The field numbers joined by dots, e.g. {@code 150.1.6}. */
    @Override
    public String toString() {
        StringBuilder text = new StringBuilder();
        for (int field : fields) {
            if (!text.isEmpty()) {
                text.append('.');
            }
            text.append(Integer.toUnsignedString(field));
        }
        return text.toString();
    }
}
