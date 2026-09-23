package com.villagecompute.wiretuner.conformance;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.google.protobuf.TextFormat;
import com.villagecompute.wiretuner.conformance.v1.Vector;
import com.villagecompute.wiretuner.crdt.Engine;
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
        return ConformanceRunner.run(vector("name: \"t/v\"\n" + text), "t/v");
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
        ConformanceRunner.Outcome outcome = ConformanceRunner.run(root, file);

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
            assertThat(changes.get(0).getReplica()).isEqualTo(7);
            return ConformanceRunner.ENGINE.replay(schema, changes);
        };
        assertThat(ConformanceRunner.run(vector("name: \"t/v\"\n" + CREATE), "t/v", checking).failures()).hasSize(1);
    }

    @Test
    void aHashMismatchNamesTheFirstNodeWhoseExpectedHashDiffers() throws IOException {
        String text = CREATE + "replica { id: 1 " + rename(1, 2, "A") + " }\n";
        String nodeHash = run(text + "expect { node { id { counter: 1 replica: 7 } node_hash: \"x\" } }")
                .failures().get(1).replaceAll(".*got \"([0-9a-f]+)\"$", "$1");

        ConformanceRunner.Outcome outcome = run(text + "expect { state_hash: \"wrong\""
                + " node { id { counter: 1 replica: 7 } node_hash: \"" + nodeHash + "\""
                + "   register { path { segments { field: 150 } segments { element { counter: 1 } } } } }"
                + " node { id { counter: 9 replica: 9 } node_hash: \"00\" } }");

        assertThat(outcome.failures().get(0)).endsWith("; first differing node 9:9");
        assertThat(outcome.failures()).contains("node 1:7: expected register path must be field numbers only");
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
}
