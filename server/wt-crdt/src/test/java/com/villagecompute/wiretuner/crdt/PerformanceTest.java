package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;

import com.villagecompute.wiretuner.doc.v1.SnapshotFrame;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * The CRDT performance budget (crdt-model.adoc, "Performance budget") on the JVM: inserts into a
 * 200,000-character text and loading the design-point document from a snapshot. The figures are
 * printed (the budgets are the client's, enforced by WTCRDTTests' PerformanceTests in release
 * builds); the assertions only guard against a pathological regression under JaCoCo.
 */
class PerformanceTest {

    @Test
    void insertsIntoA200000CharacterText() {
        TextSequence text = new TextSequence();
        int[] scalars = new int[1_000];
        java.util.Arrays.fill(scalars, 0x61);
        long counter = 1;
        for (int i = 0; i < 200; i++) {
            text.insert(scalars, new OpId(counter, 1), counter == 1 ? OpId.ZERO : new OpId(counter - 1, 1), OpId.ZERO);
            counter += 1_000;
        }
        assertThat(text.count()).isEqualTo(200_000);
        OpId caret = text.charAt(100_000);
        int inserts = 2_000;
        long start = System.nanoTime();
        for (int index = 0; index < inserts; index++) {
            OpId id = new OpId(counter + index, 2);
            text.insert(new int[] {0x62}, id, caret, text.successor(caret));
            caret = id;
        }
        double perInsert = (System.nanoTime() - start) / 1e3 / inserts;
        System.out.printf("TextSequence (JVM): %.2f µs per insert into 200,000 characters%n", perInsert);
        assertThat(text.count()).isEqualTo(202_000);
        assertThat(perInsert).isLessThan(1_000);
    }

    static Engine designPoint() {
        Engine engine = new Engine(Scenario.SCHEMA);
        String common = "common { name: \"Object\" note: \"n\" locked: true url: \"https://example.com\" alt: \"a\" decorative: true"
                + " origin_layer: \"L\" transform { a: 1 d: 1 } text_wrap { enabled: true } }";
        long counter = 1;
        for (int index = 0; index < 50_000; index++) {
            long node = counter;
            engine.apply(Scenario.change(7, index + 1, counter,
                    "create { parent { counter: 4 } position: \"\\x80\" props { test { label: \"Node\" " + common + " } } }",
                    "set { node { counter: " + node + " replica: 7 } paths { segments { field: 1000 } segments { field: 1 } segments { field: 9 } }"
                            + " values { test { common { alt: \"b\" } } } }",
                    "element_insert { node { counter: " + node + " replica: 7 } sequence { segments { field: 1000 } segments { field: 8 } }"
                            + " positions: [\"\\x80\", \"\\x81\", \"\\x82\", \"\\x83\", \"\\x84\"] values { test { stops { offset: 1 color: \"red\" }"
                            + " stops { offset: 2 color: \"red\" } stops { offset: 3 color: \"red\" } stops { offset: 4 color: \"red\" }"
                            + " stops { offset: 5 color: \"red\" } } } }"));
            counter += 7;
        }
        String chunk = "lorem ipsum dolor sit amet ".repeat(37);
        OpId left = null;
        for (int i = 0; i < 200; i++) {
            engine.apply(Scenario.change(7, 60_000 + counter, counter, Scenario.insert(chunk, left, null)));
            left = new OpId(counter + 998, 7);
            counter += 999;
        }
        return engine;
    }

    @Test
    void loadsTheDesignPointFromASnapshot() throws Snapshot.SnapshotException {
        Engine engine = designPoint();
        int registers = engine.store().nodes().stream().mapToInt(node -> engine.store().registers(node).size()).sum();
        assertThat(registers).isGreaterThanOrEqualTo(1_000_000);
        long start = System.nanoTime();
        List<SnapshotFrame> frames = SnapshotTransfer.frames(engine, 1);
        double encode = (System.nanoTime() - start) / 1e9;
        start = System.nanoTime();
        Engine loaded = SnapshotTransfer.state(frames, Scenario.SCHEMA);
        double load = (System.nanoTime() - start) / 1e9;
        long bytes = frames.stream().skip(1).mapToLong(frame -> frame.getChunk().size()).sum();
        System.out.printf("Snapshot (JVM): design point %d registers, %d compressed bytes in %d chunks; encode %.2f s, load %.2f s%n",
                registers, bytes, frames.size() - 1, encode, load);
        assertThat(loaded.stateHash()).isEqualTo(engine.stateHash());
        assertThat(load).isLessThan(60);
    }
}
