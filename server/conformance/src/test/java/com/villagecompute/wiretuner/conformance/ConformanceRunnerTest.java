package com.villagecompute.wiretuner.conformance;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.google.protobuf.TextFormat;
import com.villagecompute.wiretuner.conformance.v1.Vector;
import com.villagecompute.wiretuner.crdt.Engine;
import com.villagecompute.wiretuner.crdt.FractionalIndex;
import com.villagecompute.wiretuner.crdt.SplitMix64;
import com.villagecompute.wiretuner.crdt.OpId;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.CreateNode;
import com.villagecompute.wiretuner.doc.v1.GroupProps;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Op;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class ConformanceRunnerTest {

    private static final String CREATE = """
            setup { change { replica: 7 seq: 1 start_counter: 1
              ops { create { parent { counter: 4 } position: "\\x80"
                props { layer { common { name: "L" } } } } } } }
            """;

    private static String rename(long replica, long counter, String name) {
        return "change { replica: " + Long.toUnsignedString(replica) + " seq: 1 start_counter: " + counter
                + " ops { set { node { counter: 1 replica: 7 }"
                + " paths { segments { field: 150 } segments { field: 1 } segments { field: 1 } }"
                + " values { layer { common { name: \"" + name + "\" } } } } } }";
    }

    private static Vector vector(String text) throws TextFormat.ParseException {
        Vector.Builder vector = Vector.newBuilder();
        TextFormat.merge(text, vector);
        return vector.build();
    }

    private static ConformanceRunner.Outcome run(String text) throws TextFormat.ParseException {
        return withoutSnapshot(ConformanceRunner.run(vector("name: \"t/v\"\n" + text), "t/v"));
    }

    /** The outcome without its snapshot_hash failure: these vectors leave the hash out. */
    private static ConformanceRunner.Outcome withoutSnapshot(ConformanceRunner.Outcome outcome) {
        return new ConformanceRunner.Outcome(outcome.name(),
                outcome.failures().stream().filter(failure -> !failure.startsWith("snapshot_hash: expected \"\"")).toList(),
                outcome.stateHash());
    }

    @Test
    void missingDirectoryYieldsNoVectors() throws IOException {
        assertThat(ConformanceRunner.vectors(Path.of("does", "not", "exist"))).isEmpty();
    }

    @Test
    void listsTextprotoFilesRecursivelyInPathOrderAndNamesThem(@TempDir Path root) throws IOException {
        Path nested = Files.createDirectories(root.resolve("text"));
        Path b = Files.writeString(nested.resolve("b_insert.textproto"), "");
        Path a = Files.writeString(root.resolve("a_move.textproto"), "");
        Files.writeString(root.resolve("README.adoc"), "not a vector");
        Files.createDirectories(root.resolve("folder.textproto"));

        assertThat(ConformanceRunner.vectors(root)).containsExactly(a, b);
        assertThat(ConformanceRunner.expectedName(root, b)).isEqualTo("text/b_insert");
        assertThat(ConformanceRunner.VECTORS_DIR).hasFileName("vectors");
    }

    @Test
    void loadsAndRunsAFile(@TempDir Path root) throws IOException {
        Path file = Files.writeString(Files.createDirectories(root.resolve("t")).resolve("v.textproto"),
                "name: \"t/v\"\n" + CREATE);
        ConformanceRunner.Outcome outcome = withoutSnapshot(ConformanceRunner.run(root, file));

        assertThat(outcome.failures()).singleElement().asString().startsWith("state_hash: expected \"\", got");
        assertThat(outcome.stateHash()).hasSize(64);
        assertThat(outcome.report()).startsWith("t/v:\n  state_hash");

        Path broken = Files.writeString(root.resolve("t").resolve("broken.textproto"), "nme: 1");
        assertThatThrownBy(() -> ConformanceRunner.run(root, broken)).isInstanceOf(TextFormat.ParseException.class);
    }

    @Test
    void aPassingVectorHasNoFailures() throws IOException {
        String text = CREATE + "replica { id: 1 " + rename(1, 2, "A") + " }\n";
        String hash = run(text).stateHash();
        String nodeHash = run(text + "expect { node { id { counter: 1 replica: 7 } node_hash: \"x\" } }")
                .failures().get(1).replaceAll(".*got \"([0-9a-f]+)\"$", "$1");

        ConformanceRunner.Outcome outcome = run(text + "expect { state_hash: \"" + hash + "\" node {"
                + " id { counter: 1 replica: 7 } node_hash: \"" + nodeHash + "\""
                + " register { path { segments { field: 150 } segments { field: 1 } segments { field: 1 } }"
                + "   value { layer { common { name: \"A\" } } } op { counter: 2 replica: 1 } losing { counter: 1 replica: 7 } }"
                + " register { path { segments { field: 150 } segments { field: 1 } segments { field: 3 } } } } }");
        assertThat(outcome.failures()).containsExactly(
                "node 1:7 register 150.1.3: expected unset@0:0, got null");
    }

    @Test
    void reportsNameReplicaAndDeliveryMistakes() throws IOException {
        ConformanceRunner.Outcome outcome = ConformanceRunner.run(vector("name: \"x\"\n" + CREATE
                + "replica { id: 1 " + rename(2, 2, "A") + " }\n"
                + "replica { id: 3 " + rename(3, 2, "B") + " }\n"
                + "deliveries { order: [1, 1, 3] }\n"
                + "deliveries { order: [4] }\n"), "t/v");

        assertThat(outcome.passed()).isFalse();
        assertThat(outcome.failures()).containsExactly(
                "name is \"x\" but the file says \"t/v\"",
                "replica 1 holds a change of replica 2",
                "delivery [1, 1, 3] names replica 1 more often than it has changes",
                "delivery [4] names replica 4 more often than it has changes",
                "delivery [4] leaves changes undelivered");
        assertThat(outcome.stateHash()).isEmpty();
    }

    @Test
    void reportsBadSchemaOverrides() throws IOException {
        ConformanceRunner.Outcome outcome = run(CREATE
                + "schema_override { policy { message: \"wiretuner.doc.v1.CommonProps\" field: 999 policy: \"ATOMIC\" } }\n"
                + "schema_override { policy { message: \"wiretuner.doc.v1.CommonProps\" field: 1 policy: \"BOGUS\" } }\n"
                + "schema_override { }\n"
                + "schema_override { variant { message: \"wiretuner.doc.v1.NavigationProps\" kind_field: 2 case_fields: [3] } }\n");

        assertThat(outcome.failures()).hasSize(3).allMatch(failure -> failure.startsWith("schema_override: "));
    }

    @Test
    void namesTheFirstNodeWhereDeliveryOrdersDiverge() throws IOException {
        // A correct engine never diverges, so a replayer that drops the last change of every order
        // after the first stands in for a broken one.
        int[] calls = {0};
        ConformanceRunner.Replayer faulty = (schema, changes) -> ConformanceRunner.ENGINE.replay(schema,
                calls[0]++ == 0 ? changes : changes.subList(0, changes.size() - 1));
        Vector vector = vector("name: \"t/v\"\n" + CREATE
                + "replica { id: 1 " + rename(1, 2, "A") + " }\n"
                + "replica { id: 2 " + rename(2, 3, "B") + " }\n"
                + "deliveries { order: [2, 1] }\n"
                + "deliveries { order: [1, 2] }\n"
                + "expect { node { id { counter: 1 replica: 7 } } }\n");

        ConformanceRunner.Outcome outcome = ConformanceRunner.run(vector, "t/v", faulty);
        assertThat(outcome.failures().get(0)).isEqualTo("delivery [1, 2] diverges from [2, 1] at node 1:7");
        assertThat(outcome.failures().get(1)).contains("no expected node_hash differs; actual node hashes: 1:7=");
    }

    @Test
    void withoutDeliveriesTheReplicasAreDeliveredInIdOrder() throws IOException {
        ConformanceRunner.Outcome outcome = run(CREATE
                + "replica { id: 2 " + rename(2, 2, "B") + " }\n"
                + "replica { id: 1 " + rename(1, 2, "A") + " }\n"
                + "expect { node { id { counter: 1 replica: 7 }"
                + " register { path { segments { field: 150 } segments { field: 1 } segments { field: 1 } }"
                + "   value { layer { common { name: \"B\" } } } op { counter: 2 replica: 2 } } } }");

        assertThat(outcome.failures()).hasSize(2)
                .anyMatch(failure -> failure.endsWith("losing writes expected [], got [1:7, 2:1]"));
    }

    @Test
    void aReplayerSeesSetupBeforeTheOrder() throws IOException {
        ConformanceRunner.Replayer checking = (schema, changes) -> {
            assertThat(changes.get(0).change().getReplica()).isEqualTo(7);
            assertThat(changes.get(0).serverSeq()).isEqualTo(1L);
            return ConformanceRunner.ENGINE.replay(schema, changes);
        };
        assertThat(withoutSnapshot(ConformanceRunner.run(vector("name: \"t/v\"\n" + CREATE), "t/v", checking)).failures()).hasSize(1);
    }

    @Test
    void aHashMismatchNamesTheFirstNodeWhoseExpectedHashDiffers() throws IOException {
        String text = CREATE + "replica { id: 1 " + rename(1, 2, "A") + " }\n";
        String nodeHash = run(text + "expect { node { id { counter: 1 replica: 7 } node_hash: \"x\" } }")
                .failures().get(1).replaceAll(".*got \"([0-9a-f]+)\"$", "$1");

        ConformanceRunner.Outcome outcome = run(text + "expect { state_hash: \"wrong\""
                + " node { id { counter: 1 replica: 7 } node_hash: \"" + nodeHash + "\""
                + "   register { } }"
                + " node { id { counter: 9 replica: 9 } node_hash: \"00\" } }");

        assertThat(outcome.failures().get(0)).endsWith("; first differing node 9:9");
        assertThat(outcome.failures()).contains("node 1:7: expected register has an empty path");
    }

    @Test
    void firstDifferenceSkipsEqualNodes() {
        Engine a = new Engine();
        Engine b = new Engine();
        for (var engine : List.of(a, b)) {
            engine.apply(Change.newBuilder().setReplica(1).setStartCounter(1)
                    .addOps(Op.newBuilder().setCreate(
                            CreateNode.newBuilder().setProps(
                                    NodeProps.newBuilder().setGroup(
                                            GroupProps.getDefaultInstance()))))
                    .build());
        }
        b.apply(Change.newBuilder().setReplica(2).setStartCounter(1)
                .addOps(Op.newBuilder().setCreate(
                        CreateNode.newBuilder().setProps(
                                NodeProps.newBuilder().setGroup(
                                        GroupProps.getDefaultInstance()))))
                .build());

        assertThat(ConformanceRunner.firstDifference(a, b))
                .isEqualTo(new OpId(1, 2));
    }

    @Test
    void firstDifferenceIsNullForEqualStates() {
        assertThat(ConformanceRunner.firstDifference(new Engine(),
                new Engine())).isNull();
    }

    private static final String TEST_NODE = """
            setup { change { replica: 1 seq: 1 start_counter: 1
              ops { create { parent { counter: 4 } position: "\\x80" props { test { label: "t" } } } }
              ops { element_insert { node { counter: 1 replica: 1 }
                sequence { segments { field: 1000 } segments { field: 8 } }
                positions: "\\x40" positions: "\\x80"
                values { test { stops { color: "red" } } } } }
              ops { set_add { node { counter: 1 replica: 1 } set { segments { field: 1000 } segments { field: 3 } }
                values { test { tags: "a" } } } } } }
            """;

    @Test
    void testKindsSequencesSetsAndTheTreeReadOut() throws IOException {
        String expect = "expect { node { id { counter: 1 replica: 1 }"
                + " tree { parent { counter: 4 } position: \"\\x80\" }"
                + " sequence { path { segments { field: 1000 } segments { field: 8 } }"
                + "   elements { counter: 2 replica: 1 } elements { counter: 3 replica: 1 } }"
                + " set { path { segments { field: 1000 } segments { field: 3 } } members { test { tags: \"a\" } } }"
                + " register { path { segments { field: 1000 } segments { field: 8 } segments { element { counter: 2 replica: 1 } }"
                + "   segments { field: 3 } } value { test { stops { color: \"red\" } } } op { counter: 2 replica: 1 } } }"
                + " node { id { counter: 4 } tree { parent { } children { counter: 1 replica: 1 } } } }";
        ConformanceRunner.Outcome outcome = run(TEST_NODE + expect);
        assertThat(outcome.failures()).singleElement().asString().startsWith("state_hash:");

        ConformanceRunner.Outcome wrong = run(TEST_NODE + "expect { state_hash: \"" + outcome.stateHash() + "\""
                + " node { id { counter: 1 replica: 1 } tree { deleted: true children { counter: 9 } }"
                + " sequence { path { segments { field: 1000 } segments { field: 8 } } deleted { counter: 2 replica: 1 } }"
                + " sequence { }"
                + " set { path { segments { field: 1000 } segments { field: 3 } } }"
                + " set { path { segments { field: 1000 } segments { field: 2 } } }"
                + " set { } } }");
        assertThat(wrong.failures()).containsExactly(
                "node 1:1: expected parent none position , got 4:0/80@1:1",
                "node 1:1: expected deleted true, got false",
                "node 1:1: expected children [9:0], got []",
                "node 1:1 sequence 1000.8: expected [] deleted [2:1], got [2:1, 3:1] deleted []",
                "node 1:1: expected sequence has an empty path",
                "node 1:1 set 1000.3: expected [], got [61]",
                "node 1:1 set 1000.2: expected [], got []",
                "node 1:1: expected set has an empty path");
    }

    @Test
    void theTreeReadOutComparesPositions() throws IOException {
        String hash = run(TEST_NODE).stateHash();
        assertThat(run(TEST_NODE + "expect { state_hash: \"" + hash + "\" node { id { counter: 1 replica: 1 }"
                + " tree { parent { counter: 4 } position: \"\\x81\" } } }").failures())
                .containsExactly("node 1:1: expected parent 4:0 position 81, got 4:0/80@1:1");
        assertThat(run(TEST_NODE + "expect { state_hash: \"" + hash + "\" node { id { counter: 1 replica: 1 }"
                + " tree { parent { counter: 5 } position: \"\\x80\" } } }").failures()).hasSize(1);
        assertThat(run(TEST_NODE + "expect { state_hash: \"" + hash + "\" node { id { counter: 9 replica: 9 }"
                + " tree { parent { counter: 4 } } } }").failures())
                .containsExactly("node 9:9: expected parent 4:0 position , got none");
    }

    @Test
    void positionsAndAppendRunsAreGeneratedAndCompared() throws IOException {
        byte[] key = FractionalIndex.between(null, null, new SplitMix64(5));
        String escaped = escape(key);
        byte[] last = null;
        SplitMix64 random = new SplitMix64(1);
        for (int i = 0; i < 10; i++) {
            last = FractionalIndex.between(last, null, random);
        }
        String hash = run("").stateHash();
        String ok = "expect { state_hash: \"" + hash + "\" }"
                + " position { seed: 5 expect: \"" + escaped + "\" }"
                + " append_run { seed: 1 count: 10 max_length: 40 last: \"" + escape(last) + "\" }";
        assertThat(run(ok).failures()).isEmpty();

        ConformanceRunner.Outcome bad = run("expect { state_hash: \"" + hash + "\" }"
                + " position { lo: \"\\x80\" hi: \"\\x10\" seed: 5 expect: \"\\x01\" }"
                + " position { seed: 5 expect: \"\\x01\" }"
                + " append_run { seed: 1 count: 10 max_length: 2 last: \"" + escape(last) + "\" }"
                + " append_run { seed: 1 count: 10 max_length: 40 }"
                + " append_run { seed: 1 max_length: 40 last: \"\\x01\" }");
        assertThat(bad.failures()).hasSize(5);
        assertThat(bad.failures().get(0)).isEqualTo("position between 80 and 10 seed 5: expected 01, got an error");
        assertThat(bad.failures().get(1)).startsWith("position between  and  seed 5: expected 01, got 80");
        assertThat(bad.failures().get(4)).isEqualTo("append run seed 1: longest key 0 bytes (limit 40), last , expected 01");
    }

    private static String escape(byte[] bytes) {
        StringBuilder text = new StringBuilder();
        for (byte b : bytes) {
            text.append(String.format("\\x%02x", b & 0xFF));
        }
        return text.toString();
    }

    @Test
    void fieldRowOverridesDeclareMessagesAndReportBadPolicies() throws IOException {
        ConformanceRunner.Outcome outcome = run(CREATE
                + "schema_override { field { message: \"t.X\" field: 1 name: \"x\" policy: \"BOGUS\" type: \"string\" } }\n"
                + "schema_override { field { message: \"t.X\" field: 2 name: \"y\" policy: \"SEQUENCE\" type: \"message\""
                + " repeated: true type_name: \"t.X\" } }\n");
        assertThat(outcome.failures()).singleElement().asString().startsWith("schema_override: ");
    }

    @Test
    void theTestKindsAreLoadedFromTheClasspath() {
        assertThat(ConformanceRunner.TEST_KINDS).isNotEmpty();
        assertThatThrownBy(() -> ConformanceRunner.loadTestKinds("/no-such-file.textproto"))
                .isInstanceOf(IllegalStateException.class);
        assertThatThrownBy(() -> ConformanceRunner.loadTestKinds("/test-kinds-broken.textproto"))
                .isInstanceOf(java.io.UncheckedIOException.class);
    }

    @Test
    void serverSeqsTravelBesideTheChange() throws IOException {
        List<Long> seen = new java.util.ArrayList<>();
        ConformanceRunner.Replayer recording = (schema, changes) -> {
            changes.forEach(delivered -> seen.add(delivered.serverSeq()));
            return ConformanceRunner.ENGINE.replay(schema, changes);
        };
        ConformanceRunner.run(vector("name: \"t/v\"\n" + CREATE
                + "setup { change { replica: 7 seq: 2 start_counter: 2 server_seq: 9 ops { noop { } } } }\n"
                + "replica { id: 1 change { replica: 1 seq: 1 start_counter: 5 server_seq: 12 ops { noop { } } }"
                + " change { replica: 1 seq: 2 start_counter: 6 ops { noop { } } } }"), "t/v", recording);
        assertThat(seen).containsExactly(1L, 9L, 12L, null);
        assertThat(ConformanceRunner.docChange(com.villagecompute.wiretuner.conformance.v1.Change.newBuilder()
                .setReplica(3).setServerSeq(4).build())).isEqualTo(Change.newBuilder().setReplica(3).build());
    }

    @Test
    void theVectorNodePropsMirrorsEveryDocKind() {
        var doc = NodeProps.getDescriptor();
        var mirror = com.villagecompute.wiretuner.conformance.v1.NodeProps.getDescriptor();
        for (var field : doc.getFields()) {
            var twin = mirror.findFieldByNumber(field.getNumber());
            assertThat(twin).as("conformance NodeProps lacks %s", field.getName()).isNotNull();
            assertThat(twin.getName()).isEqualTo(field.getName());
            assertThat(twin.getMessageType().getFullName()).isEqualTo(field.getMessageType().getFullName());
            assertThat(twin.getContainingOneof().getName()).isEqualTo(field.getContainingOneof().getName());
        }
    }

    @Test
    void picksDeliverChangesInAnyOrderAndReportMistakes() throws IOException {
        String replicas = "replica { id: 1 " + rename(1, 2, "A") + " }\n";
        ConformanceRunner.Outcome good = run(CREATE + replicas
                + "deliveries { picks { replica: 1 seq: 1 } picks { replica: 1 seq: 1 } }\n");
        assertThat(good.failures()).singleElement().asString().startsWith("state_hash:");
        ConformanceRunner.Outcome bad = run(CREATE + replicas
                + "deliveries { order: [1] picks { replica: 1 seq: 7 } }\n");
        assertThat(bad.failures()).containsExactly("a delivery has both order and picks", "pick 1/7 names no change",
                "picks leave [1/1] undelivered");
    }

    @Test
    void theSnapshotIsHashedAndComparedAcrossDeliveries() throws IOException {
        String text = CREATE + "replica { id: 1 " + rename(1, 2, "A") + " }\n";
        ConformanceRunner.Outcome outcome = ConformanceRunner.run(vector("name: \"t/v\"\n" + text
                + "expect { snapshot_hash: \"00\" }"), "t/v");
        assertThat(outcome.failures()).last().asString().startsWith("snapshot_hash: expected \"00\", got \"");
        // A replayer that acknowledges an extra change on its second order changes the snapshot
        // (the server-seq map) but not the state hash.
        int[] calls = {0};
        ConformanceRunner.Replayer faulty = (schema, changes) -> {
            com.villagecompute.wiretuner.crdt.Engine engine = ConformanceRunner.ENGINE.replay(schema, changes);
            if (calls[0]++ > 0) {
                engine.acknowledge(9, 9, 9);
            }
            return engine;
        };
        ConformanceRunner.Outcome diverging = ConformanceRunner.run(vector("name: \"t/v\"\n" + text
                + "deliveries { order: [1] }\ndeliveries { order: [1] }\n"), "t/v", faulty);
        assertThat(diverging.failures()).contains("delivery [1] writes a different snapshot from [1]");
    }

    @Test
    void textReadOutsAreCompared() throws IOException {
        String node = "setup { change { replica: 7 seq: 1 start_counter: 1 ops { create { parent { counter: 4 } position: \"\\x80\""
                + " props { test { } } } } ops { text_insert { node { counter: 1 replica: 7 }"
                + " text { segments { field: 1000 } segments { field: 9 } } chars: \"ab\" } }"
                + " ops { text_mark { node { counter: 1 replica: 7 } text { segments { field: 1000 } segments { field: 9 } }"
                + " start { before: true } end { } value { bold: true } } } } }\n";
        String path = "path { segments { field: 1000 } segments { field: 9 } }";
        assertThat(run(node + "expect { node { id { counter: 1 replica: 7 } text { " + path + " text: \"ab\""
                + " chars { counter: 2 replica: 7 } chars { counter: 3 replica: 7 }"
                + " runs { start: 0 length: 2 attributes { value { bold: true } mark { counter: 4 replica: 7 } } } } } }")
                .failures()).singleElement().asString().startsWith("state_hash:");
        assertThat(run(node + "expect { node { id { counter: 1 replica: 7 } text { " + path + " text: \"x\" } } }").failures())
                .hasSize(4).anyMatch(failure -> failure.contains("expected \"x\", got \"ab\""))
                .anyMatch(failure -> failure.contains("expected chars [] deleted [], got [2:7, 3:7] deleted []"))
                .anyMatch(failure -> failure.contains("expected runs [], got [0+2 f00101@4:7]"));
        assertThat(run(node + "expect { node { id { counter: 1 replica: 7 } text { path { } } } }").failures())
                .contains("node 1:7: expected text has an empty path");
        assertThat(run(node + "expect { node { id { counter: 1 replica: 7 } text { path { segments { field: 1000 } segments { field: 2 } } } } }")
                .failures()).hasSize(1);
    }
}
