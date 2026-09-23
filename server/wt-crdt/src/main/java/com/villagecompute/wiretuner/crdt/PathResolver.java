package com.villagecompute.wiretuner.crdt;

import com.villagecompute.wiretuner.crdt.schema.MergeTable.FieldPolicy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.Policy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.VariantPolicy;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.function.Predicate;

/**
 * Walks a field path with the merge table (docs/spec/crdt-model.adoc, "Field paths and
 * registers"), mirroring {@code WTCRDT.PathResolver}:
 *
 * <ul>
 *   <li>a path ending at an ATOMIC field is one register; its value is that field's records in
 *       {@code values}, or unset when {@code values} holds none;</li>
 *   <li>a path ending at a STRUCT field, or at a sequence element, stands for every register
 *       beneath it, each written from {@code values} (absent leaves unset); an element's
 *       {@code id} (field 1) is never a register;</li>
 *   <li>beneath a MERGE_VARIANT message present in {@code values}, only the case messages present
 *       are written; a variant being cleared clears every case;</li>
 *   <li>a SEQUENCE field is entered only through an element segment naming an element that
 *       exists; its elements, a SET field's members and a TEXT field merge by their own ops;</li>
 *   <li>anything else makes the path a no-op.</li>
 * </ul>
 *
 * <p>Element segments are transparent in {@code values}: the sparse message holds, at a SEQUENCE
 * field, only the element the path names.
 */
final class PathResolver {

    /** One register write: where, and the value ({@code null} = unset). */
    record Assignment(RegisterPath path, byte[] value) {
    }

    /** Where a path ends: at a field ({@code row} set) or at an existing element ({@code message} set). */
    record Target(RegisterPath path, FieldPolicy row, String message, WireMessage value) {

        boolean isField() {
            return row != null;
        }
    }

    private final Schema schema;

    PathResolver(Schema schema) {
        this.schema = schema;
    }

    /**
     * Where {@code path} leads on a node of {@code kind}, or {@code null} when it is malformed.
     * At a field, {@code value} is the navigated message holding the field; at an element, the
     * element's message.
     */
    Target walk(int kind, FieldPath path, WireMessage values, Predicate<RegisterPath> elementExists) {
        RegisterPath full = RegisterPath.of(path);
        if (full == null || !full.segments().get(0).equals(RegisterPath.Segment.field(kind))) {
            return null;
        }
        List<RegisterPath.Segment> segments = full.segments();
        String message = Schema.ROOT;
        WireMessage current = values;
        boolean inElement = false;
        FieldPolicy sequence = null;
        Target target = null;
        for (int index = 0; index < segments.size() && target == null; index++) {
            RegisterPath at = RegisterPath.of(segments.subList(0, index + 1));
            boolean last = index == segments.size() - 1;
            RegisterPath.Segment segment = segments.get(index);
            if (segment.isElement()) {
                if (sequence == null || !elementExists.test(at)) {
                    return null;
                }
                message = sequence.typeName();
                sequence = null;
                inElement = true;
                if (last) {
                    target = new Target(at, null, message, current);
                }
                continue;
            }
            int number = segment.field();
            FieldPolicy row = sequence == null ? schema.field(message, number) : null;
            if (row == null || inElement && number == 1) {
                return null;
            }
            if (last) {
                target = new Target(at, row, null, current);
                continue;
            }
            if (row.typeName() == null || row.repeated() && row.policy() != Policy.SEQUENCE) {
                return null;
            }
            switch (row.policy()) {
                case STRUCT, VARIANT -> {
                    message = row.typeName();
                    inElement = false;
                }
                case SEQUENCE -> sequence = row;
                default -> {
                    return null;
                }
            }
            current = current == null ? null : current.message(number);
        }
        return target;
    }

    /**
     * The register writes of a {@code SetFields} path on a node of {@code kind}, or {@code null}
     * when the path does not name registers (a deterministic no-op, "Totality").
     */
    List<Assignment> resolve(int kind, FieldPath path, WireMessage values, Predicate<RegisterPath> elementExists) {
        Target target = walk(kind, path, values, elementExists);
        if (target == null) {
            return null;
        }
        List<Assignment> out = new ArrayList<>();
        if (!target.isField()) {
            expand(target.message(), target.path(), target.value(), true, true, new HashSet<>(), out);
            return out;
        }
        FieldPolicy row = target.row();
        WireMessage container = target.value();
        int number = row.fieldNumber();
        if (row.policy() == Policy.ATOMIC) {
            return List.of(new Assignment(target.path(), records(container, number)));
        }
        if (!isStruct(row)) {
            return null;
        }
        expand(row.typeName(), target.path(), container == null ? null : container.message(number), true, false,
                new HashSet<>(), out);
        return out;
    }

    /** The registers a {@code CreateNode}'s props set: every leaf present, nothing else. */
    List<Assignment> initial(int kind, WireMessage props) {
        FieldPolicy row = schema.field(Schema.ROOT, kind);
        List<Assignment> out = new ArrayList<>();
        expand(row.typeName(), RegisterPath.of(kind), props.message(kind), false, false, new HashSet<>(), out);
        return out;
    }

    /** The registers a new element's values set: every leaf present except its id. */
    List<Assignment> initialElement(String message, RegisterPath path, WireMessage values) {
        List<Assignment> out = new ArrayList<>();
        expand(message, path, values, false, true, new HashSet<>(), out);
        return out;
    }

    // Singular STRUCT/VARIANT message fields are walked through.
    private static boolean isStruct(FieldPolicy row) {
        return (row.policy() == Policy.STRUCT || row.policy() == Policy.VARIANT) && !row.repeated()
                && row.typeName() != null;
    }

    private static byte[] records(WireMessage message, int number) {
        return message == null ? null : message.records(number);
    }

    /**
     * Appends the registers beneath {@code message} at {@code prefix}. With {@code absentAsUnset}
     * every leaf is written; without it only leaves present in {@code value} are. A message
     * already on the current branch is not entered again.
     */
    private void expand(String message, RegisterPath prefix, WireMessage value, boolean absentAsUnset,
            boolean inElement, Set<String> branch, List<Assignment> out) {
        if (!absentAsUnset && value == null || !branch.add(message)) {
            return;
        }
        VariantPolicy variant = schema.variant(message);
        for (FieldPolicy row : schema.fields(message)) {
            int number = row.fieldNumber();
            boolean present = value != null && value.has(number);
            boolean skippedCase = variant != null && value != null && !present
                    && variant.caseFields().contains(number);
            boolean register = row.policy() == Policy.ATOMIC || isStruct(row);
            if (inElement && number == 1 || !register || skippedCase || !absentAsUnset && !present) {
                continue;
            }
            RegisterPath path = prefix.child(number);
            if (row.policy() == Policy.ATOMIC) {
                out.add(new Assignment(path, records(value, number)));
            } else {
                WireMessage sub = value == null ? null : value.message(number);
                expand(row.typeName(), path, sub, absentAsUnset, false, branch, out);
            }
        }
        branch.remove(message);
    }
}
