package com.villagecompute.wiretuner.crdt;

import com.villagecompute.wiretuner.crdt.schema.MergeTable.FieldPolicy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.Policy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.VariantPolicy;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.PathSegment;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Turns a {@code SetFields} path into register writes with the merge table
 * (docs/spec/crdt-model.adoc, "Field paths and registers"):
 *
 * <ul>
 *   <li>a path ending at an ATOMIC field is one register; its value is that field's records in
 *       {@code values}, or unset when {@code values} holds none;</li>
 *   <li>a path ending at a STRUCT field stands for every register beneath it in the table, each
 *       written from {@code values} (absent leaves written unset);</li>
 *   <li>beneath a MERGE_VARIANT message present in {@code values}, only the case messages present
 *       are written, so a kind switch never clears another case; a variant being cleared clears
 *       every case;</li>
 *   <li>anything else -- an unknown field, a path running past an ATOMIC field, an element
 *       segment, a SEQUENCE, TEXT or SET field (later tasks) -- makes the path a no-op.</li>
 * </ul>
 */
final class PathResolver {

    /** One register write: where, and the value ({@code null} = unset). */
    record Assignment(RegisterPath path, byte[] value) {
    }

    private final Schema schema;

    PathResolver(Schema schema) {
        this.schema = schema;
    }

    /**
     * The writes {@code path} stands for on a node of {@code kind}, or {@code null} when the path
     * is malformed for it (a deterministic no-op, "Totality").
     */
    List<Assignment> resolve(int kind, FieldPath path, WireMessage values) {
        List<PathSegment> segments = path.getSegmentsList();
        if (segments.isEmpty() || !isField(segments.get(0), kind)) {
            return null;
        }
        String message = Schema.ROOT;
        WireMessage current = values;
        RegisterPath at = null;
        for (int i = 0; ; i++) {
            PathSegment segment = segments.get(i);
            FieldPolicy row = segment.hasField() ? schema.field(message, segment.getField()) : null;
            if (row == null || !isRegisterWalkable(row)) {
                return null;
            }
            int number = row.fieldNumber();
            at = at == null ? RegisterPath.of(number) : at.child(number);
            boolean last = i == segments.size() - 1;
            if (row.policy() == Policy.ATOMIC) {
                return last ? List.of(new Assignment(at, records(current, number))) : null;
            }
            WireMessage sub = current == null ? null : current.message(number);
            if (last) {
                List<Assignment> out = new ArrayList<>();
                expand(row.typeName(), at, sub, true, new HashSet<>(), out);
                return out;
            }
            message = row.typeName();
            current = sub;
        }
    }

    /** The registers a {@code CreateNode}'s props set: every leaf present, nothing else. */
    List<Assignment> initial(int kind, WireMessage props) {
        FieldPolicy row = schema.field(Schema.ROOT, kind);
        List<Assignment> out = new ArrayList<>();
        expand(row.typeName(), RegisterPath.of(kind), props.message(kind), false, new HashSet<>(), out);
        return out;
    }

    private static boolean isField(PathSegment segment, int number) {
        return segment.hasField() && segment.getField() == number;
    }

    // ATOMIC fields are registers; singular STRUCT/VARIANT message fields are walked through.
    private static boolean isRegisterWalkable(FieldPolicy row) {
        return switch (row.policy()) {
            case ATOMIC -> true;
            case STRUCT, VARIANT -> !row.repeated() && row.typeName() != null;
            default -> false;
        };
    }

    private static byte[] records(WireMessage message, int number) {
        return message == null ? null : message.records(number);
    }

    /**
     * Appends the registers beneath {@code message} at {@code prefix}. With {@code absentAsUnset}
     * every leaf is written (a STRUCT write or clear); without it only leaves present in
     * {@code value} are (a CreateNode). A message already on the current branch is not entered
     * again, so a recursive schema expands finitely and identically in both engines.
     */
    private void expand(String message, RegisterPath prefix, WireMessage value, boolean absentAsUnset,
            Set<String> branch, List<Assignment> out) {
        if (!absentAsUnset && value == null || !branch.add(message)) {
            return;
        }
        VariantPolicy variant = schema.variant(message);
        for (FieldPolicy row : schema.fields(message)) {
            int number = row.fieldNumber();
            boolean present = value != null && value.has(number);
            boolean skippedCase = variant != null && value != null && !present
                    && variant.caseFields().contains(number);
            if (!isRegisterWalkable(row) || skippedCase || !absentAsUnset && !present) {
                continue;
            }
            RegisterPath path = prefix.child(number);
            if (row.policy() == Policy.ATOMIC) {
                out.add(new Assignment(path, records(value, number)));
            } else {
                WireMessage sub = value == null ? null : value.message(number);
                expand(row.typeName(), path, sub, absentAsUnset, branch, out);
            }
        }
        branch.remove(message);
    }
}
