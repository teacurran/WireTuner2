package com.villagecompute.wiretuner.conformance;

import com.google.protobuf.TextFormat;
import com.villagecompute.wiretuner.conformance.v1.Delivery;
import com.villagecompute.wiretuner.conformance.v1.ExpectNode;
import com.villagecompute.wiretuner.conformance.v1.ExpectRegister;
import com.villagecompute.wiretuner.conformance.v1.Replica;
import com.villagecompute.wiretuner.conformance.v1.SchemaOverride;
import com.villagecompute.wiretuner.conformance.v1.Vector;
import com.villagecompute.wiretuner.crdt.Engine;
import com.villagecompute.wiretuner.crdt.OpId;
import com.villagecompute.wiretuner.crdt.Register;
import com.villagecompute.wiretuner.crdt.RegisterPath;
import com.villagecompute.wiretuner.crdt.Schema;
import com.villagecompute.wiretuner.crdt.StateHash;
import com.villagecompute.wiretuner.crdt.Write;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.Policy;
import com.villagecompute.wiretuner.doc.v1.Change;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;

/**
 * Replays the conformance vectors ({@code crdt-conformance/vectors/<area>/<name>.textproto},
 * schema {@code crdt-conformance/schema/vector.proto}) through {@code wt-crdt}, exactly as
 * {@code WTCRDTTests.ConformanceRunner} does through {@code WTCRDT} (docs/spec/testing.adoc,
 * CRDT-011). A vector passes when every delivery order reaches the same state and that state
 * has the expected hash and read-outs; a failure names the vector and the first differing node.
 */
public final class ConformanceRunner {

    /** The vector directory relative to the repository root. */
    public static final Path VECTORS_DIR = Path.of("crdt-conformance", "vectors");

    private static final String VECTOR_SUFFIX = ".textproto";

    private ConformanceRunner() {
    }

    /** What replaying one vector produced. {@code failures} is empty when it passed. */
    public record Outcome(String name, List<String> failures, String stateHash) {

        /** Whether the vector passed. */
        public boolean passed() {
            return failures.isEmpty();
        }

        /** The failures as one report, headed by the vector name. */
        public String report() {
            return name + ":\n  " + String.join("\n  ", failures);
        }
    }

    /**
     * Every vector file under {@code root}, sorted by path. A missing directory yields no
     * vectors rather than an error.
     *
     * @throws IOException if the directory cannot be walked
     */
    public static List<Path> vectors(Path root) throws IOException {
        if (!Files.isDirectory(root)) {
            return List.of();
        }
        try (Stream<Path> files = Files.walk(root)) {
            return files.filter(ConformanceRunner::isVector).sorted().toList();
        }
    }

    static boolean isVector(Path path) {
        return Files.isRegularFile(path) && path.getFileName().toString().endsWith(VECTOR_SUFFIX);
    }

    /**
     * The name a vector at {@code file} must declare: its path below {@code root} without the
     * suffix, with forward slashes.
     */
    public static String expectedName(Path root, Path file) {
        String relative = root.relativize(file).toString().replace(file.getFileSystem().getSeparator(), "/");
        return relative.substring(0, relative.length() - VECTOR_SUFFIX.length());
    }

    /**
     * Parses one vector file.
     *
     * @throws IOException if the file cannot be read or is not a {@code Vector} in text format
     */
    public static Vector load(Path file) throws IOException {
        Vector.Builder vector = Vector.newBuilder();
        TextFormat.merge(Files.readString(file, StandardCharsets.UTF_8), vector);
        return vector.build();
    }

    /** Loads and replays the vector at {@code file} below {@code root}. */
    public static Outcome run(Path root, Path file) throws IOException {
        return run(load(file), expectedName(root, file));
    }

    /** Turns the changes of one delivery order (setup first) into a merged state. */
    interface Replayer {
        Engine replay(Schema schema, List<Change> changes);
    }

    /** The replayer vectors run with: a fresh {@link Engine} applying every change in order. */
    static final Replayer ENGINE = (schema, changes) -> {
        Engine engine = new Engine(schema);
        changes.forEach(engine::apply);
        return engine;
    };

    /** Replays {@code vector}, which must be named {@code expectedName}. */
    public static Outcome run(Vector vector, String expectedName) {
        return run(vector, expectedName, ENGINE);
    }

    /** {@link #run(Vector, String)} with another replayer (tests use a faulty one). */
    static Outcome run(Vector vector, String expectedName, Replayer replayer) {
        List<String> failures = new ArrayList<>();
        if (!vector.getName().equals(expectedName)) {
            failures.add("name is \"" + vector.getName() + "\" but the file says \"" + expectedName + "\"");
        }
        Schema schema = schema(vector, failures);
        List<List<Change>> orders = deliveryOrders(vector, failures);
        if (!failures.isEmpty()) {
            return new Outcome(expectedName, failures, "");
        }
        Engine reference = null;
        String referenceOrder = "";
        for (int i = 0; i < orders.size(); i++) {
            List<Change> changes = new ArrayList<>(vector.getSetup().getChangeList());
            changes.addAll(orders.get(i));
            Engine engine = replayer.replay(schema, changes);
            String order = describe(vector, i);
            if (reference == null) {
                reference = engine;
                referenceOrder = order;
            } else if (!Arrays.equals(engine.stateHash(), reference.stateHash())) {
                failures.add("delivery " + order + " diverges from " + referenceOrder
                        + " at node " + firstDifference(reference, engine));
            }
        }
        checkExpectations(vector, reference, failures);
        return new Outcome(expectedName, failures, StateHash.hex(reference.stateHash()));
    }

    /** The generated merge table with the vector's overrides applied. */
    static Schema schema(Vector vector, List<String> failures) {
        Schema schema = Schema.generated();
        for (SchemaOverride override : vector.getSchemaOverrideList()) {
            try {
                schema = switch (override.getChangeCase()) {
                    case POLICY -> schema.withPolicy(override.getPolicy().getMessage(),
                            override.getPolicy().getField(), Policy.valueOf(override.getPolicy().getPolicy()));
                    case VARIANT -> schema.withVariant(override.getVariant().getMessage(),
                            override.getVariant().getKindField(), override.getVariant().getCaseFieldsList());
                    case CHANGE_NOT_SET -> throw new IllegalArgumentException("empty schema_override");
                };
            } catch (IllegalArgumentException e) {
                failures.add("schema_override: " + e.getMessage());
            }
        }
        return schema;
    }

    /** The changes of each delivery order, validated against the replicas. */
    static List<List<Change>> deliveryOrders(Vector vector, List<String> failures) {
        Map<Long, ArrayDeque<Change>> byReplica = new LinkedHashMap<>();
        vector.getReplicaList().stream()
                .sorted((a, b) -> Long.compareUnsigned(a.getId(), b.getId()))
                .forEach(replica -> {
                    checkReplica(replica, failures);
                    byReplica.put(replica.getId(), new ArrayDeque<>(replica.getChangeList()));
                });
        List<Delivery> deliveries = new ArrayList<>(vector.getDeliveriesList());
        if (deliveries.isEmpty()) {
            Delivery.Builder all = Delivery.newBuilder();
            byReplica.forEach((id, changes) -> changes.forEach(change -> all.addOrder(id)));
            deliveries.add(all.build());
        }
        List<List<Change>> orders = new ArrayList<>();
        for (Delivery delivery : deliveries) {
            Map<Long, ArrayDeque<Change>> pending = new LinkedHashMap<>();
            byReplica.forEach((id, changes) -> pending.put(id, new ArrayDeque<>(changes)));
            List<Change> order = new ArrayList<>();
            for (long id : delivery.getOrderList()) {
                ArrayDeque<Change> changes = pending.get(id);
                if (changes == null || changes.isEmpty()) {
                    failures.add("delivery " + delivery.getOrderList() + " names replica "
                            + Long.toUnsignedString(id) + " more often than it has changes");
                } else {
                    order.add(changes.removeFirst());
                }
            }
            if (pending.values().stream().anyMatch(changes -> !changes.isEmpty())) {
                failures.add("delivery " + delivery.getOrderList() + " leaves changes undelivered");
            }
            orders.add(order);
        }
        return orders;
    }

    private static void checkReplica(Replica replica, List<String> failures) {
        for (Change change : replica.getChangeList()) {
            if (change.getReplica() != replica.getId()) {
                failures.add("replica " + Long.toUnsignedString(replica.getId()) + " holds a change of replica "
                        + Long.toUnsignedString(change.getReplica()));
            }
        }
    }

    private static String describe(Vector vector, int index) {
        return index < vector.getDeliveriesCount()
                ? vector.getDeliveries(index).getOrderList().toString()
                : "(replica order)";
    }

    /** The first node, in OpId order, whose encoding differs between two states. */
    static OpId firstDifference(Engine a, Engine b) {
        List<OpId> nodes = new ArrayList<>(a.store().nodes());
        nodes.addAll(b.store().nodes());
        return nodes.stream()
                .sorted()
                .filter(node -> !Arrays.equals(StateHash.ofNode(a.store(), node), StateHash.ofNode(b.store(), node)))
                .findFirst()
                .orElse(null);
    }

    private static void checkExpectations(Vector vector, Engine engine, List<String> failures) {
        String actual = StateHash.hex(engine.stateHash());
        String expected = vector.getExpect().getStateHash();
        if (!actual.equals(expected)) {
            failures.add("state_hash: expected \"" + expected + "\", got \"" + actual + "\""
                    + firstNamedDifference(vector, engine));
        }
        for (ExpectNode node : vector.getExpect().getNodeList()) {
            OpId id = OpId.of(node.getId());
            String nodeHash = StateHash.hex(StateHash.ofNode(engine.store(), id));
            if (!node.getNodeHash().isEmpty() && !node.getNodeHash().equals(nodeHash)) {
                failures.add("node " + id + ": node_hash expected \"" + node.getNodeHash() + "\", got \"" + nodeHash + "\"");
            }
            for (ExpectRegister register : node.getRegisterList()) {
                checkRegister(engine, id, register, failures);
            }
        }
    }

    private static String firstNamedDifference(Vector vector, Engine engine) {
        for (ExpectNode node : vector.getExpect().getNodeList()) {
            OpId id = OpId.of(node.getId());
            String nodeHash = StateHash.hex(StateHash.ofNode(engine.store(), id));
            if (!node.getNodeHash().isEmpty() && !node.getNodeHash().equals(nodeHash)) {
                return "; first differing node " + id;
            }
        }
        StringBuilder actual = new StringBuilder("; no expected node_hash differs; actual node hashes:");
        for (OpId node : engine.store().nodes()) {
            actual.append(' ').append(node).append('=').append(StateHash.hex(StateHash.ofNode(engine.store(), node)));
        }
        return actual.toString();
    }

    private static void checkRegister(Engine engine, OpId node, ExpectRegister expected, List<String> failures) {
        RegisterPath path = RegisterPath.of(expected.getPath());
        if (path == null) {
            failures.add("node " + node + ": expected register path must be field numbers only");
            return;
        }
        Register actual = engine.register(node, path);
        byte[] value = expected.hasValue() ? path.valueIn(expected.getValue().toByteArray()) : null;
        Register want = new Register(value, OpId.of(expected.getOp()));
        if (!want.equals(actual)) {
            failures.add("node " + node + " register " + path + ": expected " + want + ", got " + actual);
        }
        List<OpId> losing = engine.losingWrites(node, path).stream().map(Write::op).toList();
        List<OpId> wantLosing = expected.getLosingList().stream().map(OpId::of).toList();
        if (!losing.equals(wantLosing)) {
            failures.add("node " + node + " register " + path + ": losing writes expected " + wantLosing + ", got " + losing);
        }
    }
}
