package com.villagecompute.wiretuner.crdt;

import com.google.protobuf.InvalidProtocolBufferException;
import com.google.protobuf.TextFormat;
import com.villagecompute.wiretuner.conformance.v1.FieldRow;
import com.villagecompute.wiretuner.conformance.v1.SchemaOverride;
import com.villagecompute.wiretuner.conformance.v1.SchemaOverrides;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.FieldPolicy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.Policy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.RefFallback;
import com.villagecompute.wiretuner.doc.v1.Change;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;

/**
 * Scenarios on the conformance test kind ({@code TestProps}, NodeProps field 1000, with its TEXT
 * field at 9), written as the vectors write changes; mirrors WTCRDTTests' {@code Scenario}.
 */
final class Scenario {

    static final OpId NODE = new OpId(1, 7);
    static final RegisterPath TEXT = RegisterPath.of(1000, 9);
    static final RegisterPath LABEL = RegisterPath.of(1000, 2);
    static final String N = "node { counter: 1 replica: 7 }";
    static final String T = "text { segments { field: 1000 } segments { field: 9 } }";

    /** The generated merge table plus crdt-conformance/schema/test-kinds.textproto. */
    static final Schema SCHEMA = schema();

    private Scenario() {
    }

    private static Schema schema() {
        try {
            SchemaOverrides.Builder overrides = SchemaOverrides.newBuilder();
            TextFormat.merge(Files.readString(Path.of("..", "..", "crdt-conformance", "schema", "test-kinds.textproto")), overrides);
            Schema schema = Schema.generated();
            for (SchemaOverride override : overrides.getOverrideList()) {
                FieldRow row = override.getField();
                Policy policy = Policy.valueOf(row.getPolicy());
                String typeName = row.getTypeName().isEmpty() ? null : row.getTypeName();
                schema = schema.withField(row.getMessage(), new FieldPolicy(row.getField(), row.getName(), policy,
                        RefFallback.UNSET, false, row.getType(), row.getRepeated(), typeName,
                        policy == Policy.SEQUENCE ? typeName : null, row.getOneof().isEmpty() ? null : row.getOneof()));
            }
            return schema;
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    /** A change parsed from the vectors' text format and converted to doc.v1. */
    static Change change(String text) {
        try {
            com.villagecompute.wiretuner.conformance.v1.Change.Builder change = com.villagecompute.wiretuner.conformance.v1.Change.newBuilder();
            TextFormat.merge(text, change);
            return Change.parseFrom(change.build().toByteArray());
        } catch (TextFormat.ParseException | InvalidProtocolBufferException e) {
            throw new IllegalArgumentException(e);
        }
    }

    /** A change of {@code ops} whose causal past is the server log up to {@code base}. */
    static Change change(long replica, long seq, long counter, long base, List<String> ops) {
        StringBuilder text = new StringBuilder("replica: " + replica + " seq: " + seq + " start_counter: " + counter
                + " base_server_seq: " + base);
        for (String op : ops) {
            text.append(" ops { ").append(op).append(" }");
        }
        return change(text.toString());
    }

    static Change change(long replica, long seq, long counter, String... ops) {
        return change(replica, seq, counter, 0, Arrays.asList(ops));
    }

    /** An engine over {@link #SCHEMA} with the test node 1:7 created (label "T") and {@code extra} applied. */
    static Engine engine(Change... extra) {
        Engine engine = new Engine(SCHEMA);
        engine.apply(change(7, 1, 1, "create { parent { counter: 4 } position: \"\\x80\" props { test { label: \"T\" } } }"), 1L);
        for (Change change : extra) {
            engine.apply(change);
        }
        return engine;
    }

    static String insert(String chars, OpId left, OpId right) {
        StringBuilder op = new StringBuilder("text_insert { " + N + " " + T);
        if (left != null) {
            op.append(" left_origin { counter: ").append(left.counter()).append(" replica: ").append(left.replica()).append(" }");
        }
        if (right != null) {
            op.append(" right_origin { counter: ").append(right.counter()).append(" replica: ").append(right.replica()).append(" }");
        }
        return op.append(" chars: \"").append(chars).append("\" }").toString();
    }

    static String anchor(OpId id, boolean before) {
        return (id == null ? "" : "char { counter: " + id.counter() + " replica: " + id.replica() + " } ") + (before ? "before: true" : "");
    }

    static String mark(OpId start, boolean startBefore, OpId end, boolean endBefore, String value) {
        return "text_mark { " + N + " " + T + " start { " + anchor(start, startBefore) + " } end { " + anchor(end, endBefore)
                + " } value { " + value + " } }";
    }
}
