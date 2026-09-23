package com.villagecompute.wiretuner.crdt;

import com.villagecompute.wiretuner.crdt.schema.MergeTable.FieldPolicy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.MessagePolicy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.Policy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.RefFallback;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.VariantPolicy;
import java.util.List;
import java.util.Map;

/**
 * A hand-written merge table exercising every shape the resolver meets, rooted at NodeProps under
 * kind 1000, a field number the generated NodeProps does not know, so test values survive as
 * unknown fields byte for byte:
 *
 * <pre>
 * NodeProps  1000 kind -> t.K (STRUCT, oneof kind)
 * t.K        1 a     ATOMIC string
 *            2 self  STRUCT t.K        (recursive)
 *            3 seq   SEQUENCE t.K      (not a register)
 *            4 many  STRUCT repeated   (not walkable)
 *            5 bare  STRUCT, no type   (not walkable)
 *            6 v     VARIANT t.V
 *            7 ref   ATOMIC NodeRef    (as protoc-gen-wtcrdt emits it)
 *            8 refs  STRUCT NodeRef repeated (not walkable)
 * t.V        1 kind  ATOMIC enum; 2 c1 STRUCT t.C; 3 c2 STRUCT t.C; 4 note ATOMIC
 * t.C        1 x     ATOMIC
 * </pre>
 */
final class Tables {

    /** The kind (NodeProps field number) of the test table. */
    static final int K = 1000;

    static final String NODE_REF = "wiretuner.doc.v1.NodeRef";

    private Tables() {
    }

    static FieldPolicy row(int number, Policy policy, String type, boolean repeated, String typeName, String oneof) {
        return new FieldPolicy(number, "f" + number, policy, RefFallback.UNSET, false, type, repeated, typeName, null, oneof);
    }

    static Schema shapes() {
        Map<String, MessagePolicy> messages = Map.of(
                Schema.ROOT, new MessagePolicy(Schema.ROOT, Map.of(
                        K, row(K, Policy.STRUCT, "message", false, "t.K", "kind"))),
                "t.K", new MessagePolicy("t.K", Map.of(
                        1, row(1, Policy.ATOMIC, "string", false, null, null),
                        2, row(2, Policy.STRUCT, "message", false, "t.K", null),
                        3, row(3, Policy.SEQUENCE, "message", true, "t.K", null),
                        4, row(4, Policy.STRUCT, "message", true, "t.C", null),
                        5, row(5, Policy.STRUCT, "message", false, null, null),
                        6, row(6, Policy.VARIANT, "message", false, "t.V", null),
                        7, row(7, Policy.ATOMIC, "message", false, NODE_REF, null),
                        8, row(8, Policy.STRUCT, "message", true, NODE_REF, null))),
                "t.V", new MessagePolicy("t.V", Map.of(
                        1, row(1, Policy.ATOMIC, "enum", false, "t.Kind", null),
                        2, row(2, Policy.STRUCT, "message", false, "t.C", null),
                        3, row(3, Policy.STRUCT, "message", false, "t.C", null),
                        4, row(4, Policy.ATOMIC, "string", false, null, null))),
                "t.C", new MessagePolicy("t.C", Map.of(
                        1, row(1, Policy.ATOMIC, "double", false, null, null))));
        return Schema.of(messages, Map.of("t.V", new VariantPolicy(1, List.of(2, 3))));
    }
}
