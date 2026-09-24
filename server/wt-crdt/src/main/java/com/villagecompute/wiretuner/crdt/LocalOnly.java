package com.villagecompute.wiretuner.crdt;

import com.google.protobuf.InvalidProtocolBufferException;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.FieldPolicy;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Noop;
import com.villagecompute.wiretuner.doc.v1.Op;
import java.util.ArrayList;
import java.util.List;

/**
 * {@code local_only} fields (docs/spec/crdt-model.adoc, "Local-only fields"), mirroring
 * {@code WTCRDT.LocalOnly}: view state and per-Mac values that never leave the device. A register
 * is local-only when the walk to it crosses a field whose merge-table row says {@code local_only}.
 * This engine never writes one (every change is remote to it), and {@link #strip} takes them out
 * of a pushed change before the server logs it, byte for byte as WTCRDT does before a change
 * enters its outbox.
 */
public final class LocalOnly {

    private LocalOnly() {
    }

    /**
     * Whether the field rows {@code path} crosses include a {@code local_only} one, the field it
     * ends at included. The walk starts at {@code NodeProps}: STRUCT and VARIANT fields into their
     * message, SEQUENCE fields into the element message, TEXT fields into their characters; it
     * stops, answering false, at an unknown field or one nothing is beneath. Element segments are
     * skipped.
     */
    public static boolean enters(Schema schema, RegisterPath path) {
        String message = Schema.ROOT;
        for (RegisterPath.Segment segment : path.segments()) {
            if (segment.isElement()) {
                continue;
            }
            FieldPolicy row = message == null ? null : schema.field(message, segment.field());
            if (row == null) {
                return false;
            }
            if (row.localOnly()) {
                return true;
            }
            message = inner(schema, row);
        }
        return false;
    }

    /** {@link #enters(Schema, RegisterPath)} for a wire path; false for one that is malformed. */
    public static boolean enters(Schema schema, FieldPath path) {
        RegisterPath at = RegisterPath.of(path);
        return at != null && enters(schema, at);
    }

    private static String inner(Schema schema, FieldPolicy row) {
        if (row.typeName() == null) {
            return null;
        }
        return switch (row.policy()) {
            case STRUCT, VARIANT, SEQUENCE -> row.typeName();
            case TEXT -> {
                FieldPolicy chars = schema.field(row.typeName(), PathResolver.CHARS_FIELD);
                yield chars == null ? null : chars.typeName();
            }
            default -> null;
        };
    }

    /**
     * {@code change} without anything local-only: a {@code SetFields} loses the paths that enter a
     * {@code local_only} field (and becomes a {@code Noop}, keeping its counter, when none is left),
     * and the {@code NodeProps} of every op that carries one loses its local-only fields, however
     * deep. Every other op, and a change with nothing local-only, is returned as it came.
     */
    public static Change strip(Schema schema, Change change) {
        Change.Builder out = null;
        for (int index = 0; index < change.getOpsCount(); index++) {
            Op op = strip(schema, change.getOps(index));
            if (op != null) {
                if (out == null) {
                    out = change.toBuilder();
                }
                out.setOps(index, op);
            }
        }
        return out == null ? change : out.build();
    }

    /** Whether {@code change} carries anything {@link #strip} would take out. */
    public static boolean carries(Schema schema, Change change) {
        return change.getOpsList().stream().anyMatch(op -> strip(schema, op) != null);
    }

    // The op without its local-only content, or null when it has none.
    private static Op strip(Schema schema, Op op) {
        switch (op.getOpCase()) {
            case CREATE -> {
                NodeProps props = strip(schema, op.getCreate().getProps());
                return props == null ? null : op.toBuilder().setCreate(op.getCreate().toBuilder().setProps(props)).build();
            }
            case SET -> {
                List<FieldPath> kept = new ArrayList<>();
                for (FieldPath path : op.getSet().getPathsList()) {
                    if (!enters(schema, path)) {
                        kept.add(path);
                    }
                }
                NodeProps props = strip(schema, op.getSet().getValues());
                if (kept.size() == op.getSet().getPathsCount() && props == null) {
                    return null;
                }
                if (kept.isEmpty()) {
                    return Op.newBuilder().setNoop(Noop.getDefaultInstance()).build();
                }
                var set = op.getSet().toBuilder().clearPaths().addAllPaths(kept);
                if (props != null) {
                    set.setValues(props);
                }
                return op.toBuilder().setSet(set).build();
            }
            case ELEMENT_INSERT -> {
                NodeProps props = strip(schema, op.getElementInsert().getValues());
                return props == null ? null
                        : op.toBuilder().setElementInsert(op.getElementInsert().toBuilder().setValues(props)).build();
            }
            case SET_ADD -> {
                NodeProps props = strip(schema, op.getSetAdd().getValues());
                return props == null ? null : op.toBuilder().setSetAdd(op.getSetAdd().toBuilder().setValues(props)).build();
            }
            case SET_REMOVE -> {
                NodeProps props = strip(schema, op.getSetRemove().getValues());
                return props == null ? null
                        : op.toBuilder().setSetRemove(op.getSetRemove().toBuilder().setValues(props)).build();
            }
            default -> {
                return null;
            }
        }
    }

    // `props` without its local-only fields, or null when it has none (or does not parse).
    private static NodeProps strip(Schema schema, NodeProps props) {
        byte[] stripped = strip(schema, props.toByteArray());
        if (stripped == null) {
            return null;
        }
        try {
            return NodeProps.parseFrom(stripped);
        } catch (InvalidProtocolBufferException e) {
            return null;
        }
    }

    /**
     * An encoded {@code NodeProps} without its local-only fields, or {@code null} when it has none
     * or is not well-formed. A record whose row is {@code local_only} is dropped; a LEN record of a
     * STRUCT, VARIANT or SEQUENCE field is stripped in its message (an element's {@code id}
     * untouched), and of a TEXT field in each of its characters (fields 1-5 untouched); every other
     * record is kept byte for byte. A record that changed is written again as tag, length and
     * payload; the rest are copied as they came.
     */
    public static byte[] strip(Schema schema, byte[] props) {
        return strip(schema, Schema.ROOT, props, 0);
    }

    private static byte[] strip(Schema schema, String message, byte[] bytes, int reserved) {
        WireMessage parsed = WireMessage.parse(bytes);
        if (parsed == null) {
            return null;
        }
        WireWriter out = new WireWriter();
        boolean changed = false;
        for (WireMessage.Field record : parsed.fields()) {
            FieldPolicy row = record.number() > reserved ? schema.field(message, record.number()) : null;
            if (row == null) {
                out.raw(parsed.record(record));
                continue;
            }
            if (row.localOnly()) {
                changed = true;
                continue;
            }
            byte[] inner = null;
            if (record.wireType() == WireMessage.LEN && row.typeName() != null) {
                inner = switch (row.policy()) {
                    case STRUCT, VARIANT -> strip(schema, row.typeName(), parsed.payload(record), 0);
                    case SEQUENCE -> strip(schema, row.typeName(), parsed.payload(record), PathResolver.ELEMENT_RESERVED);
                    case TEXT -> stripText(schema, row.typeName(), parsed.payload(record));
                    default -> null;
                };
            }
            if (inner != null) {
                out.lenField(record.number(), inner);
                changed = true;
            } else {
                out.raw(parsed.record(record));
            }
        }
        return changed ? out.bytes() : null;
    }

    // A TEXT field's message: each character (field 1) stripped beyond the engine's fields.
    private static byte[] stripText(Schema schema, String message, byte[] bytes) {
        FieldPolicy chars = schema.field(message, PathResolver.CHARS_FIELD);
        WireMessage parsed = WireMessage.parse(bytes);
        if (chars == null || chars.typeName() == null || parsed == null) {
            return null;
        }
        WireWriter out = new WireWriter();
        boolean changed = false;
        for (WireMessage.Field record : parsed.fields()) {
            byte[] inner = record.number() == PathResolver.CHARS_FIELD && record.wireType() == WireMessage.LEN
                    ? strip(schema, chars.typeName(), parsed.payload(record), PathResolver.CHAR_RESERVED)
                    : null;
            if (inner != null) {
                out.lenField(record.number(), inner);
                changed = true;
            } else {
                out.raw(parsed.record(record));
            }
        }
        return changed ? out.bytes() : null;
    }
}
