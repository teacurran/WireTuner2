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
 *       exists, and a TEXT field only through one naming a newline character (its paragraph
 *       registers, CRDT-006); elements, characters, marks and a SET field's members merge by
 *       their own ops;</li>
 *   <li>anything else makes the path a no-op.</li>
 * </ul>
 *
 * <p>Element segments are transparent in {@code values}: the sparse message holds, at a SEQUENCE
 * field, only the element the path names, and at a TEXT field a {@code RichText} whose
 * {@code chars} hold only the character the path names.
 */
final class PathResolver {

    /** One register write: where, and the value ({@code null} = unset). */
    record Assignment(RegisterPath path, byte[] value) {
    }

    /**
     * Where a path ends: at a field ({@code row} set) or at an existing element ({@code message}
     * set, with {@code reserved} the highest field number the engine owns in it: 1 for a sequence
     * element, 5 for a character).
     */
    record Target(RegisterPath path, FieldPolicy row, String message, WireMessage value, int reserved) {

        boolean isField() {
            return row != null;
        }
    }

    /** Engine-owned fields of a sequence element: its {@code id}. */
    static final int ELEMENT_RESERVED = 1;

    /** Engine-owned fields of a character: id, codepoint, deleted, left and right origin. */
    static final int CHAR_RESERVED = 5;

    /** {@code RichText.chars}: the field of a TEXT field's message holding its characters. */
    static final int CHARS_FIELD = 1;

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
        int reserved = 0;
        FieldPolicy container = null;
        for (int index = 0; index < segments.size(); index++) {
            RegisterPath at = RegisterPath.of(segments.subList(0, index + 1));
            boolean last = index == segments.size() - 1;
            RegisterPath.Segment segment = segments.get(index);
            if (segment.isElement()) {
                if (container == null || !elementExists.test(at)) {
                    return null;
                }
                if (container.policy() == Policy.TEXT) {
                    FieldPolicy chars = schema.field(container.typeName(), CHARS_FIELD);
                    if (chars == null || chars.typeName() == null) {
                        return null;
                    }
                    message = chars.typeName();
                    reserved = CHAR_RESERVED;
                    current = current == null ? null : current.message(CHARS_FIELD);
                } else {
                    message = container.typeName();
                    reserved = ELEMENT_RESERVED;
                }
                container = null;
                if (last) {
                    return new Target(at, null, message, current, reserved);
                }
                continue;
            }
            int number = segment.field();
            FieldPolicy row = container == null ? schema.field(message, number) : null;
            if (row == null || Integer.compareUnsigned(number, reserved) <= 0) {
                return null;
            }
            if (last) {
                return new Target(at, row, null, current, 0);
            }
            if (row.typeName() == null || row.repeated() && row.policy() != Policy.SEQUENCE) {
                return null;
            }
            switch (row.policy()) {
                case STRUCT, VARIANT -> {
                    message = row.typeName();
                    reserved = 0;
                }
                case SEQUENCE, TEXT -> container = row;
                default -> {
                    return null;
                }
            }
            current = current == null ? null : current.message(number);
        }
        return null;
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
            expand(target.message(), target.path(), target.value(), true, target.reserved(), new HashSet<>(), out);
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
        expand(row.typeName(), target.path(), container == null ? null : container.message(number), true, 0,
                new HashSet<>(), out);
        return out;
    }

    /** The registers a {@code CreateNode}'s props set: every leaf present, nothing else. */
    List<Assignment> initial(int kind, WireMessage props) {
        FieldPolicy row = schema.field(Schema.ROOT, kind);
        List<Assignment> out = new ArrayList<>();
        expand(row.typeName(), RegisterPath.of(kind), props.message(kind), false, 0, new HashSet<>(), out);
        return out;
    }

    /** The registers a new element's values set: every leaf present except its id. */
    List<Assignment> initialElement(String message, RegisterPath path, WireMessage values) {
        List<Assignment> out = new ArrayList<>();
        expand(message, path, values, false, ELEMENT_RESERVED, new HashSet<>(), out);
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
            int reserved, Set<String> branch, List<Assignment> out) {
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
            if (Integer.compareUnsigned(number, reserved) <= 0 || !register || skippedCase || !absentAsUnset && !present) {
                continue;
            }
            RegisterPath path = prefix.child(number);
            if (row.policy() == Policy.ATOMIC) {
                out.add(new Assignment(path, records(value, number)));
            } else {
                WireMessage sub = value == null ? null : value.message(number);
                expand(row.typeName(), path, sub, absentAsUnset, 0, branch, out);
            }
        }
        branch.remove(message);
    }
}
