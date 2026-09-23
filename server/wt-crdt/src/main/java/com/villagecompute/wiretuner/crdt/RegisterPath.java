package com.villagecompute.wiretuner.crdt;

import com.villagecompute.wiretuner.doc.v1.ElementId;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.PathSegment;
import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * The address of one register, element or set inside a node: segments from {@code NodeProps}
 * down, each a field number or, directly after a SEQUENCE field, an element id
 * (docs/spec/crdt-model.adoc, "Field paths and registers"). Mirrors {@code WTCRDT.RegisterPath}.
 *
 * <p>Paths order by their {@link #canonical() canonical encoding}, compared bytewise unsigned,
 * which is the same as comparing segments in order with a prefix first.
 */
public final class RegisterPath implements Comparable<RegisterPath> {

    /** Canonical tag of a field-number segment (then the number as a big-endian uint32). */
    static final int FIELD_TAG = 0x01;

    /** Canonical tag of an element segment (then the element id as two big-endian uint64s). */
    static final int ELEMENT_TAG = 0x02;

    /** One step of a path: a field number, or an element id when {@code element} is non-null. */
    public record Segment(int field, OpId element) {

        /** A field-number segment. */
        public static Segment field(int number) {
            return new Segment(number, null);
        }

        /** An element segment. */
        public static Segment element(OpId id) {
            return new Segment(0, id);
        }

        /** Whether this is an element segment. */
        public boolean isElement() {
            return element != null;
        }

        @Override
        public String toString() {
            return isElement() ? "<" + element + ">" : Integer.toUnsignedString(field);
        }
    }

    private final Segment[] segments;
    private final byte[] canonical;

    private RegisterPath(Segment[] segments) {
        this.segments = segments;
        ByteArrayOutputStream out = new ByteArrayOutputStream(segments.length * 5);
        for (Segment segment : segments) {
            if (segment.isElement()) {
                out.write(ELEMENT_TAG);
                Bytes.writeId(out, segment.element());
            } else {
                out.write(FIELD_TAG);
                Bytes.writeU32(out, segment.field());
            }
        }
        this.canonical = out.toByteArray();
    }

    /**
     * A path of segments, outermost first.
     *
     * @throws IllegalArgumentException if {@code segments} is empty
     */
    public static RegisterPath of(List<Segment> segments) {
        if (segments.isEmpty()) {
            throw new IllegalArgumentException("a register path has at least one segment");
        }
        return new RegisterPath(segments.toArray(Segment[]::new));
    }

    /**
     * A path of field numbers, outermost first.
     *
     * @throws IllegalArgumentException if {@code fields} is empty
     */
    public static RegisterPath of(int... fields) {
        List<Segment> segments = new ArrayList<>();
        for (int field : fields) {
            segments.add(Segment.field(field));
        }
        return of(segments);
    }

    /** The path a wire {@code FieldPath} names, or {@code null} when it is empty or has an unset segment. */
    public static RegisterPath of(FieldPath path) {
        List<Segment> segments = new ArrayList<>();
        for (PathSegment segment : path.getSegmentsList()) {
            switch (segment.getSegmentCase()) {
                case FIELD -> segments.add(Segment.field(segment.getField()));
                case ELEMENT -> segments.add(Segment.element(
                        new OpId(segment.getElement().getCounter(), segment.getElement().getReplica())));
                default -> {
                    return null;
                }
            }
        }
        return segments.isEmpty() ? null : of(segments);
    }

    /** The wire {@code FieldPath} for this path. */
    public FieldPath toProto() {
        FieldPath.Builder path = FieldPath.newBuilder();
        for (Segment segment : segments) {
            if (segment.isElement()) {
                path.addSegments(PathSegment.newBuilder().setElement(ElementId.newBuilder()
                        .setCounter(segment.element().counter()).setReplica(segment.element().replica())));
            } else {
                path.addSegments(PathSegment.newBuilder().setField(segment.field()));
            }
        }
        return path.build();
    }

    /** The segments, outermost first. */
    public List<Segment> segments() {
        return List.of(segments);
    }

    /** The field numbers of the path, element segments left out. */
    public int[] fields() {
        return Arrays.stream(segments).filter(segment -> !segment.isElement()).mapToInt(Segment::field).toArray();
    }

    /** This path with {@code field} appended. */
    public RegisterPath child(int field) {
        return append(Segment.field(field));
    }

    /** This path with the element segment {@code id} appended. */
    public RegisterPath element(OpId id) {
        return append(Segment.element(id));
    }

    private RegisterPath append(Segment segment) {
        Segment[] longer = Arrays.copyOf(segments, segments.length + 1);
        longer[segments.length] = segment;
        return new RegisterPath(longer);
    }

    /** The path without its last segment, or {@code null} for a one-segment path. */
    public RegisterPath parent() {
        return segments.length > 1 ? new RegisterPath(Arrays.copyOf(segments, segments.length - 1)) : null;
    }

    /** The last segment. */
    public Segment last() {
        return segments[segments.length - 1];
    }

    /**
     * The value this path addresses inside an encoded message of the root type (a sparse
     * {@code NodeProps}): the records of the last field, reached through the embedded messages
     * of the others (element segments are transparent), or {@code null} when absent -- the same
     * bytes a {@code SetFields} carrying {@code message} writes into this register.
     */
    public byte[] valueIn(byte[] message) {
        int[] fields = fields();
        if (fields.length == 0) {
            return null;
        }
        WireMessage current = WireMessage.parse(message);
        for (int i = 0; i < fields.length - 1 && current != null; i++) {
            current = current.message(fields[i]);
        }
        return current == null ? null : current.records(fields[fields.length - 1]);
    }

    /** The canonical encoding the state hash uses (crdt-model.adoc, "Canonical encoding"). */
    public byte[] canonical() {
        return canonical.clone();
    }

    byte[] canonicalBytes() {
        return canonical;
    }

    @Override
    public int compareTo(RegisterPath other) {
        return Arrays.compareUnsigned(canonical, other.canonical);
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof RegisterPath path && Arrays.equals(canonical, path.canonical);
    }

    @Override
    public int hashCode() {
        return Arrays.hashCode(canonical);
    }

    /** The segments joined by dots, e.g. {@code 150.1.6} or {@code 1000.7.<3:1>.2}. */
    @Override
    public String toString() {
        StringBuilder text = new StringBuilder();
        for (Segment segment : segments) {
            if (!text.isEmpty()) {
                text.append('.');
            }
            text.append(segment);
        }
        return text.toString();
    }
}
