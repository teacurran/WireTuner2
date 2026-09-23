package com.villagecompute.wiretuner.conformance;

import com.google.protobuf.TextFormat;
import com.google.protobuf.InvalidProtocolBufferException;
import com.villagecompute.wiretuner.conformance.v1.AppendRun;
import com.villagecompute.wiretuner.conformance.v1.Change;
import com.villagecompute.wiretuner.conformance.v1.Collect;
import com.villagecompute.wiretuner.conformance.v1.Delivery;
import com.villagecompute.wiretuner.conformance.v1.ExpectNode;
import com.villagecompute.wiretuner.conformance.v1.ExpectRegister;
import com.villagecompute.wiretuner.conformance.v1.ExpectSequence;
import com.villagecompute.wiretuner.conformance.v1.ExpectSet;
import com.villagecompute.wiretuner.conformance.v1.ExpectText;
import com.villagecompute.wiretuner.conformance.v1.Pick;
import com.villagecompute.wiretuner.conformance.v1.ExpectTree;
import com.villagecompute.wiretuner.conformance.v1.FieldRow;
import com.villagecompute.wiretuner.conformance.v1.PositionCase;
import com.villagecompute.wiretuner.conformance.v1.Replica;
import com.villagecompute.wiretuner.conformance.v1.SchemaOverride;
import com.villagecompute.wiretuner.conformance.v1.SchemaOverrides;
import com.villagecompute.wiretuner.conformance.v1.Vector;
import com.villagecompute.wiretuner.crdt.Engine;
import com.villagecompute.wiretuner.crdt.FractionalIndex;
import com.villagecompute.wiretuner.crdt.OpId;
import com.villagecompute.wiretuner.crdt.Placement;
import com.villagecompute.wiretuner.crdt.Register;
import com.villagecompute.wiretuner.crdt.RegisterPath;
import com.villagecompute.wiretuner.crdt.Schema;
import com.villagecompute.wiretuner.crdt.Snapshot;
import com.villagecompute.wiretuner.crdt.TextSequence;
import com.villagecompute.wiretuner.crdt.TextRun;
import com.villagecompute.wiretuner.crdt.SplitMix64;
import com.villagecompute.wiretuner.crdt.StateHash;
import com.villagecompute.wiretuner.crdt.Write;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.FieldPolicy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.Policy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.RefFallback;
import com.villagecompute.wiretuner.doc.v1.ElementId;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.HexFormat;
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

    /**
     * The test kinds' merge table every vector runs with: crdt-conformance/schema/test-kinds.textproto,
     * copied onto the classpath by the build.
     */
    static final List<SchemaOverride> TEST_KINDS = loadTestKinds("/test-kinds.textproto");

    static List<SchemaOverride> loadTestKinds(String resource) {
        try (InputStream in = ConformanceRunner.class.getResourceAsStream(resource)) {
            if (in == null) {
                throw new IllegalStateException(resource + " is not on the classpath");
            }
            SchemaOverrides.Builder overrides = SchemaOverrides.newBuilder();
            TextFormat.merge(new String(in.readAllBytes(), StandardCharsets.UTF_8), overrides);
            return overrides.build().getOverrideList();
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

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

    /**
     * One step of a delivery: a change to apply, with the server_seq it was sequenced at
     * ({@code null}: not sequenced), or else ({@code change} null) a garbage collection.
     */
    record Delivered(com.villagecompute.wiretuner.doc.v1.Change change, Long serverSeq, Collect collect) {

        Delivered(com.villagecompute.wiretuner.doc.v1.Change change, Long serverSeq) {
            this(change, serverSeq, null);
        }
    }

    /** Turns the changes of one delivery order (setup first) into a merged state. */
    interface Replayer {
        Engine replay(Schema schema, List<Delivered> changes);
    }

    /** The replayer vectors run with: a fresh {@link Engine} applying every change in order. */
    static final Replayer ENGINE = (schema, changes) -> {
        Engine engine = new Engine(schema);
        for (Delivered delivered : changes) {
            if (delivered.collect() != null) {
                engine.collect(delivered.collect().getStableSeq(),
                        Clock.fixed(Instant.ofEpochMilli(delivered.collect().getNowMs()), ZoneOffset.UTC));
            } else {
                engine.apply(delivered.change(), delivered.serverSeq());
            }
        }
        return engine;
    };

    /** The doc.v1 Change a vector change encodes (the test kind becomes an unknown field). */
    static com.villagecompute.wiretuner.doc.v1.Change docChange(Change change) {
        try {
            return com.villagecompute.wiretuner.doc.v1.Change.parseFrom(change.toBuilder().clearServerSeq().build().toByteArray());
        } catch (InvalidProtocolBufferException e) {
            // Both messages are proto3 with the same field numbers and types.
            throw new IllegalStateException(e);
        }
    }

    private static NodeProps docProps(com.villagecompute.wiretuner.conformance.v1.NodeProps props) {
        try {
            return NodeProps.parseFrom(props.toByteArray());
        } catch (InvalidProtocolBufferException e) {
            throw new IllegalStateException(e);
        }
    }

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
        checkPositions(vector, failures);
        for (int i = 0; i < orders.size() && i < vector.getDeliveriesCount(); i++) {
            for (Collect collect : vector.getDeliveries(i).getCollectList()) {
                if (collect.getAfter() > orders.get(i).size()) {
                    failures.add("delivery " + describe(vector, i) + " collects after change " + collect.getAfter()
                            + " of " + orders.get(i).size());
                }
            }
        }
        if (!failures.isEmpty()) {
            return new Outcome(expectedName, failures, "");
        }
        Engine reference = null;
        byte[] referenceSnapshot = null;
        String referenceOrder = "";
        long serverSeq = greatestServerSeq(vector);
        for (int i = 0; i < orders.size(); i++) {
            List<Delivered> changes = new ArrayList<>();
            List<Change> setup = vector.getSetup().getChangeList();
            for (int s = 0; s < setup.size(); s++) {
                Change change = setup.get(s);
                changes.add(new Delivered(docChange(change), change.getServerSeq() == 0 ? s + 1 : change.getServerSeq()));
            }
            List<Collect> collects = i < vector.getDeliveriesCount() ? vector.getDeliveries(i).getCollectList() : List.of();
            collectAfter(collects, 0, changes);
            List<Change> order = orders.get(i);
            for (int c = 0; c < order.size(); c++) {
                Change change = order.get(c);
                changes.add(new Delivered(docChange(change), change.getServerSeq() == 0 ? null : change.getServerSeq()));
                collectAfter(collects, c + 1, changes);
            }
            Engine engine = replayer.replay(schema, changes);
            byte[] snapshot = Snapshot.encode(engine, serverSeq);
            String described = describe(vector, i);
            if (reference == null) {
                reference = engine;
                referenceSnapshot = snapshot;
                referenceOrder = described;
            } else if (!Arrays.equals(engine.stateHash(), reference.stateHash())) {
                failures.add("delivery " + described + " diverges from " + referenceOrder
                        + " at node " + firstDifference(reference, engine));
            } else if (!Arrays.equals(snapshot, referenceSnapshot)) {
                failures.add("delivery " + described + " writes a different snapshot from " + referenceOrder);
            }
        }
        checkExpectations(vector, reference, failures);
        checkSnapshot(vector, schema, referenceSnapshot, failures);
        return new Outcome(expectedName, failures, StateHash.hex(reference.stateHash()));
    }

    // The collections of a delivery that come after `applied` of its changes.
    private static void collectAfter(List<Collect> collects, int applied, List<Delivered> steps) {
        for (Collect collect : collects) {
            if (collect.getAfter() == applied) {
                steps.add(new Delivered(null, null, collect));
            }
        }
    }

    /** The greatest server_seq the vector gives a change (setup changes default to index + 1). */
    static long greatestServerSeq(Vector vector) {
        long greatest = 0;
        List<Change> setup = vector.getSetup().getChangeList();
        for (int i = 0; i < setup.size(); i++) {
            long serverSeq = setup.get(i).getServerSeq() == 0 ? i + 1 : setup.get(i).getServerSeq();
            greatest = Long.compareUnsigned(serverSeq, greatest) > 0 ? serverSeq : greatest;
        }
        for (Replica replica : vector.getReplicaList()) {
            for (Change change : replica.getChangeList()) {
                greatest = Long.compareUnsigned(change.getServerSeq(), greatest) > 0 ? change.getServerSeq() : greatest;
            }
        }
        return greatest;
    }

    /**
     * The snapshot of the merged state: its hash, and a lossless round trip (decoding it gives the
     * same state hash and encodes to the same bytes).
     */
    static void checkSnapshot(Vector vector, Schema schema, byte[] snapshot, List<String> failures) {
        String hash = hex(sha256(snapshot));
        if (!hash.equals(vector.getExpect().getSnapshotHash())) {
            failures.add("snapshot_hash: expected \"" + vector.getExpect().getSnapshotHash() + "\", got \"" + hash + "\"");
        }
        try {
            Engine decoded = Snapshot.decode(snapshot, schema);
            if (!Arrays.equals(Snapshot.encode(decoded, greatestServerSeq(vector)), snapshot)) {
                failures.add("snapshot round trip: the decoded state encodes differently");
            }
        } catch (Snapshot.SnapshotException e) {
            failures.add("snapshot round trip: " + e.getMessage());
        }
    }

    static byte[] sha256(byte[] data) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(data);
        } catch (NoSuchAlgorithmException e) {
            // Every Java platform is required to provide SHA-256.
            throw new IllegalStateException(e);
        }
    }

    /** The generated merge table with the test kinds and the vector's overrides applied. */
    static Schema schema(Vector vector, List<String> failures) {
        Schema schema = Schema.generated();
        List<SchemaOverride> overrides = new ArrayList<>(TEST_KINDS);
        overrides.addAll(vector.getSchemaOverrideList());
        for (SchemaOverride override : overrides) {
            try {
                schema = switch (override.getChangeCase()) {
                    case POLICY -> schema.withPolicy(override.getPolicy().getMessage(),
                            override.getPolicy().getField(), Policy.valueOf(override.getPolicy().getPolicy()));
                    case VARIANT -> schema.withVariant(override.getVariant().getMessage(),
                            override.getVariant().getKindField(), override.getVariant().getCaseFieldsList());
                    case FIELD -> schema.withField(override.getField().getMessage(), row(override.getField()));
                    case CHANGE_NOT_SET -> throw new IllegalArgumentException("empty schema_override");
                };
            } catch (IllegalArgumentException e) {
                failures.add("schema_override: " + e.getMessage());
            }
        }
        return schema;
    }

    private static FieldPolicy row(FieldRow row) {
        Policy policy = Policy.valueOf(row.getPolicy());
        String typeName = row.getTypeName().isEmpty() ? null : row.getTypeName();
        return new FieldPolicy(row.getField(), row.getName(), policy, RefFallback.UNSET, false, row.getType(),
                row.getRepeated(), typeName, policy == Policy.SEQUENCE ? typeName : null,
                row.getOneof().isEmpty() ? null : row.getOneof());
    }

    private static String hex(byte[] bytes) {
        return HexFormat.of().formatHex(bytes);
    }

    /** Generates every {@code position} and {@code append_run} of the vector and compares. */
    static void checkPositions(Vector vector, List<String> failures) {
        for (PositionCase check : vector.getPositionList()) {
            byte[] lo = check.getLo().isEmpty() ? null : check.getLo().toByteArray();
            byte[] hi = check.getHi().isEmpty() ? null : check.getHi().toByteArray();
            String key;
            try {
                key = hex(FractionalIndex.between(lo, hi, new SplitMix64(check.getSeed())));
            } catch (IllegalArgumentException e) {
                key = null;
            }
            String expected = hex(check.getExpect().toByteArray());
            if (!expected.equals(key)) {
                failures.add("position between " + hex(check.getLo().toByteArray()) + " and " + hex(check.getHi().toByteArray())
                        + " seed " + Long.toUnsignedString(check.getSeed()) + ": expected " + expected + ", got "
                        + (key == null ? "an error" : key));
            }
        }
        for (AppendRun run : vector.getAppendRunList()) {
            SplitMix64 random = new SplitMix64(run.getSeed());
            byte[] last = null;
            int longest = 0;
            for (int i = 0; i < run.getCount(); i++) {
                last = FractionalIndex.between(last, null, random);
                longest = Math.max(longest, last.length);
            }
            String lastHex = last == null ? "" : hex(last);
            if (longest >= run.getMaxLength() || !lastHex.equals(hex(run.getLast().toByteArray()))) {
                failures.add("append run seed " + Long.toUnsignedString(run.getSeed()) + ": longest key " + longest
                        + " bytes (limit " + run.getMaxLength() + "), last " + lastHex + ", expected "
                        + hex(run.getLast().toByteArray()));
            }
        }
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
            if (delivery.getPicksCount() > 0) {
                orders.add(picked(vector, delivery, failures));
                continue;
            }
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

    // The changes `picks` name, in that order; every change must be picked at least once.
    private static List<Change> picked(Vector vector, Delivery delivery, List<String> failures) {
        if (delivery.getOrderCount() > 0) {
            failures.add("a delivery has both order and picks");
        }
        java.util.Set<String> unpicked = new java.util.TreeSet<>();
        for (Replica replica : vector.getReplicaList()) {
            for (Change change : replica.getChangeList()) {
                unpicked.add(Long.toUnsignedString(replica.getId()) + "/" + Long.toUnsignedString(change.getSeq()));
            }
        }
        List<Change> changes = new ArrayList<>();
        for (Pick pick : delivery.getPicksList()) {
            Change found = vector.getReplicaList().stream().filter(replica -> replica.getId() == pick.getReplica())
                    .flatMap(replica -> replica.getChangeList().stream())
                    .filter(change -> change.getSeq() == pick.getSeq()).findFirst().orElse(null);
            String key = Long.toUnsignedString(pick.getReplica()) + "/" + Long.toUnsignedString(pick.getSeq());
            if (found == null) {
                failures.add("pick " + key + " names no change");
            } else {
                changes.add(found);
                unpicked.remove(key);
            }
        }
        if (!unpicked.isEmpty()) {
            failures.add("picks leave " + unpicked + " undelivered");
        }
        return changes;
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
            if (node.hasTree()) {
                checkTree(engine, id, node.getTree(), failures);
            }
            for (ExpectSequence sequence : node.getSequenceList()) {
                checkSequence(engine, id, sequence, failures);
            }
            for (ExpectSet set : node.getSetList()) {
                checkSet(engine, id, set, failures);
            }
            for (ExpectText text : node.getTextList()) {
                checkText(engine, id, text, failures);
            }
        }
    }

    private static void checkTree(Engine engine, OpId node, ExpectTree expected, List<String> failures) {
        Placement placement = engine.store().placement(node);
        OpId parent = expected.hasParent() ? OpId.of(expected.getParent()) : null;
        byte[] position = placement == null ? new byte[0] : placement.position();
        if (!java.util.Objects.equals(placement == null ? null : placement.parent(), parent)
                || !Arrays.equals(position, expected.getPosition().toByteArray())) {
            failures.add("node " + node + ": expected parent " + (parent == null ? "none" : parent) + " position "
                    + hex(expected.getPosition().toByteArray()) + ", got " + (placement == null ? "none" : placement));
        }
        boolean deleted = engine.store().deleted(node) != null && engine.store().deleted(node).current().value();
        if (deleted != expected.getDeleted()) {
            failures.add("node " + node + ": expected deleted " + expected.getDeleted() + ", got " + deleted);
        }
        List<OpId> children = engine.store().children(node);
        List<OpId> want = expected.getChildrenList().stream().map(OpId::of).toList();
        if (!children.equals(want)) {
            failures.add("node " + node + ": expected children " + want + ", got " + children);
        }
    }

    private static OpId id(ElementId id) {
        return new OpId(id.getCounter(), id.getReplica());
    }

    private static void checkSequence(Engine engine, OpId node, ExpectSequence expected, List<String> failures) {
        RegisterPath path = RegisterPath.of(expected.getPath());
        if (path == null) {
            failures.add("node " + node + ": expected sequence has an empty path");
            return;
        }
        List<OpId> order = engine.store().elementOrder(node, path);
        List<OpId> deleted = order.stream().filter(e -> engine.store().element(node, path.element(e)).isDeleted()).toList();
        List<OpId> live = order.stream().filter(e -> !deleted.contains(e)).toList();
        List<OpId> want = expected.getElementsList().stream().map(ConformanceRunner::id).toList();
        List<OpId> wantDeleted = expected.getDeletedList().stream().map(ConformanceRunner::id).toList();
        if (!live.equals(want) || !deleted.equals(wantDeleted)) {
            failures.add("node " + node + " sequence " + path + ": expected " + want + " deleted " + wantDeleted
                    + ", got " + live + " deleted " + deleted);
        }
    }

    private static void checkSet(Engine engine, OpId node, ExpectSet expected, List<String> failures) {
        RegisterPath path = RegisterPath.of(expected.getPath());
        if (path == null) {
            failures.add("node " + node + ": expected set has an empty path");
            return;
        }
        List<byte[]> want = engine.members(docProps(expected.getMembers()), engine.store().kind(node), expected.getPath());
        List<String> wantHex = want == null ? null : want.stream().sorted(Arrays::compareUnsigned).map(ConformanceRunner::hex).toList();
        List<String> actual = engine.store().members(node, path).stream().map(ConformanceRunner::hex).toList();
        if (!actual.equals(wantHex)) {
            failures.add("node " + node + " set " + path + ": expected " + (wantHex == null ? List.of() : wantHex)
                    + ", got " + actual);
        }
    }

    private static void checkText(Engine engine, OpId node, ExpectText expected, List<String> failures) {
        RegisterPath path = RegisterPath.of(expected.getPath());
        if (path == null) {
            failures.add("node " + node + ": expected text has an empty path");
            return;
        }
        TextSequence text = engine.text(node, path);
        TextSequence actual = text == null ? new TextSequence() : text;
        if (!actual.string().equals(expected.getText())) {
            failures.add("node " + node + " text " + path + ": expected \"" + expected.getText() + "\", got \""
                    + actual.string() + "\"");
        }
        List<OpId> want = expected.getCharsList().stream().map(ConformanceRunner::id).toList();
        List<OpId> wantDeleted = expected.getDeletedList().stream().map(ConformanceRunner::id).toList();
        List<OpId> deleted = actual.order().stream().filter(actual::isDeleted).toList();
        if (!actual.liveChars().equals(want) || !deleted.equals(wantDeleted)) {
            failures.add("node " + node + " text " + path + ": expected chars " + want + " deleted " + wantDeleted
                    + ", got " + actual.liveChars() + " deleted " + deleted);
        }
        List<String> wantRuns = expected.getRunsList().stream().map(run -> {
            StringBuilder out = new StringBuilder(run.getStart() + "+" + run.getLength());
            run.getAttributesList().forEach(attribute -> out.append(' ').append(hex(attribute.getValue().toByteArray()))
                    .append('@').append(OpId.of(attribute.getMark())));
            return out.toString();
        }).toList();
        List<String> runs = new ArrayList<>();
        for (TextRun run : actual.runs()) {
            StringBuilder out = new StringBuilder(run.start() + "+" + run.length());
            run.attributes().forEach(attribute -> out.append(' ').append(hex(attribute.value())).append('@').append(attribute.mark()));
            runs.add(out.toString());
        }
        if (!runs.equals(wantRuns)) {
            failures.add("node " + node + " text " + path + ": expected runs " + wantRuns + ", got " + runs);
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
            failures.add("node " + node + ": expected register has an empty path");
            return;
        }
        Register actual = engine.register(node, path);
        byte[] value = expected.hasValue()
                ? engine.registerValue(docProps(expected.getValue()), engine.store().kind(node), path) : null;
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
