package com.villagecompute.wiretuner.crdt;

import com.villagecompute.wiretuner.crdt.schema.MergeTable;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.FieldPolicy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.MessagePolicy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.Policy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.VariantPolicy;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

/**
 * The merge table as the engine reads it: the generated {@link MergeTable} (or another table of
 * the same shape). It is the only feature-specific input the engine has
 * (docs/spec/crdt-model.adoc, "Merge policies"); the engine uses its policies as given (a
 * singular {@code NodeRef} is ATOMIC because protoc-gen-wtcrdt emits it so).
 */
public final class Schema {

    /** The message every field path starts from. */
    public static final String ROOT = "wiretuner.doc.v1.NodeProps";

    /** The oneof of {@link #ROOT} whose set case is a node's kind. */
    public static final String KIND_ONEOF = "kind";

    private final Map<String, Map<Integer, FieldPolicy>> messages;
    private final Map<String, VariantPolicy> variants;
    private final Set<Integer> kinds;

    private Schema(Map<String, Map<Integer, FieldPolicy>> messages, Map<String, VariantPolicy> variants) {
        this.messages = messages;
        this.variants = variants;
        Map<Integer, FieldPolicy> root = messages.getOrDefault(ROOT, Map.of());
        this.kinds = Set.copyOf(root.values().stream()
                .filter(row -> KIND_ONEOF.equals(row.oneof()))
                .map(FieldPolicy::fieldNumber)
                .toList());
    }

    /** The generated table (protoc-gen-wtcrdt over proto/). */
    public static Schema generated() {
        return of(MergeTable.MESSAGES, MergeTable.VARIANTS);
    }

    /** A table of the generated shape. */
    public static Schema of(Map<String, MessagePolicy> messages, Map<String, VariantPolicy> variants) {
        Map<String, Map<Integer, FieldPolicy>> rows = new HashMap<>();
        messages.forEach((name, message) -> {
            Map<Integer, FieldPolicy> fields = new TreeMap<>();
            message.fields().forEach((number, row) -> fields.put(number, row));
            rows.put(name, fields);
        });
        return new Schema(rows, new HashMap<>(variants));
    }

    private static FieldPolicy withPolicy(FieldPolicy row, Policy policy) {
        return new FieldPolicy(row.fieldNumber(), row.name(), policy, row.onDangling(), row.localOnly(),
                row.type(), row.repeated(), row.typeName(), row.elementMessage(), row.oneof());
    }

    /**
     * This table with one field's policy replaced. For tests and conformance vectors that
     * exercise a merge rule before any schema field uses it; the result is not re-checked the
     * way protoc-gen-wtcrdt checks the schema.
     *
     * @throws IllegalArgumentException if the table has no such field
     */
    public Schema withPolicy(String message, int field, Policy policy) {
        FieldPolicy row = field(message, field);
        if (row == null) {
            throw new IllegalArgumentException("no field " + message + "." + field + " in the merge table");
        }
        Map<String, Map<Integer, FieldPolicy>> rows = new HashMap<>(messages);
        Map<Integer, FieldPolicy> fields = new TreeMap<>(rows.get(message));
        fields.put(field, withPolicy(row, policy));
        rows.put(message, fields);
        return new Schema(rows, variants);
    }

    /**
     * This table with {@code row} added to {@code message} (or replacing its field of the same
     * number); the message is created when the table has none. For conformance vectors that
     * declare test messages (see {@link #withPolicy}).
     */
    public Schema withField(String message, FieldPolicy row) {
        Map<String, Map<Integer, FieldPolicy>> rows = new HashMap<>(messages);
        Map<Integer, FieldPolicy> fields = new TreeMap<>(rows.getOrDefault(message, Map.of()));
        fields.put(row.fieldNumber(), row);
        rows.put(message, fields);
        return new Schema(rows, variants);
    }

    /** This table with {@code message} declared a MERGE_VARIANT message (see {@link #withPolicy}). */
    public Schema withVariant(String message, int kindField, List<Integer> caseFields) {
        Map<String, VariantPolicy> declared = new HashMap<>(variants);
        declared.put(message, new VariantPolicy(kindField, List.copyOf(caseFields)));
        return new Schema(messages, declared);
    }

    /** The row for one field, or {@code null} when the message or the field is unknown. */
    public FieldPolicy field(String message, int number) {
        Map<Integer, FieldPolicy> fields = messages.get(message);
        return fields == null ? null : fields.get(number);
    }

    /** The rows of one message in field-number order (empty for an unknown message). */
    public Iterable<FieldPolicy> fields(String message) {
        return messages.getOrDefault(message, Map.of()).values();
    }

    /**
     * The field of the {@code TextMarkValue} a TEXT field's marks carry that is keyed by its
     * {@code tag} as well as its case (the {@code feature} case, CRDT-006), or {@code null}: found
     * through the table as {@code RichText.marks} (2) -> {@code TextMark.value} (4) -> the row
     * named {@code feature}.
     */
    public Integer featureField(FieldPolicy text) {
        FieldPolicy marks = text.typeName() == null ? null : field(text.typeName(), 2);
        FieldPolicy value = marks == null || marks.typeName() == null ? null : field(marks.typeName(), 4);
        if (value == null || value.typeName() == null) {
            return null;
        }
        for (FieldPolicy row : fields(value.typeName())) {
            if ("feature".equals(row.name())) {
                return row.fieldNumber();
            }
        }
        return null;
    }

    /** The variant declaration of {@code message}, or {@code null} when it is not a variant. */
    public VariantPolicy variant(String message) {
        return variants.get(message);
    }

    /** The field numbers of {@code NodeProps.kind}: the node kinds this table knows. */
    public Set<Integer> kinds() {
        return kinds;
    }
}
