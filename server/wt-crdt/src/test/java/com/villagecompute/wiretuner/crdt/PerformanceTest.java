package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;

import com.villagecompute.wiretuner.doc.v1.SnapshotFrame;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import org.junit.jupiter.api.Test;

/**
 * The CRDT performance scenarios (crdt-model.adoc, "Performance budget") on the JVM: inserts into a
 * long text and loading the design-point document from a snapshot.  The default-run tests check
 * that the work is right at a smaller volume; the {@link PerfTest} methods run the design-point
 * volume under {@code -Pperf} and hold it to a loose JVM bound that only catches a pathological
 * regression (docs/spec/testing.adoc, Where budgets run).  The budgets themselves are the
 * client's, enforced by WTCRDTTests' PerformanceTests in release builds.
 */
class PerformanceTest {

    /** A text of {@code runs} x 1,000 'a's from replica 1, one insert op per run. */
    private static TextSequence text(int runs) {
        TextSequence text = new TextSequence();
        int[] scalars = new int[1_000];
        Arrays.fill(scalars, 0x61);
        long counter = 1;
        for (int i = 0; i < runs; i++) {
            text.insert(scalars, new OpId(counter, 1), counter == 1 ? OpId.ZERO : new OpId(counter - 1, 1), OpId.ZERO);
            counter += 1_000;
        }
        return text;
    }

    /** Types {@code count} 'b's one at a time after the character at {@code at}; returns their ids in order. */
    private static OpId[] type(TextSequence text, int at, int count) {
        OpId caret = text.charAt(at);
        OpId[] ids = new OpId[count];
        for (int index = 0; index < count; index++) {
            OpId id = new OpId(text.count() + 1_000_000L, 2);
            text.insert(new int[] {0x62}, id, caret, text.successor(caret));
            ids[index] = id;
            caret = id;
        }
        return ids;
    }

    @Test
    void typingIntoALongTextLandsInOrderAtTheCaret() {
        TextSequence text = text(20);
        assertThat(text.count()).isEqualTo(20_000);
        OpId[] typed = type(text, 10_000, 200);
        assertThat(text.count()).isEqualTo(20_200);
        for (int index = 0; index < typed.length; index++) {
            assertThat(text.charAt(10_001 + index)).isEqualTo(typed[index]);
            assertThat(text.codepoint(typed[index])).isEqualTo(0x62);
        }
        assertThat(text.codepoint(text.charAt(10_201))).isEqualTo(0x61);
    }

    @PerfTest
    void insertsIntoA200000CharacterText() {
        TextSequence text = text(200);
        int inserts = 2_000;
        long start = System.nanoTime();
        type(text, 100_000, inserts);
        double perInsert = (System.nanoTime() - start) / 1e3 / inserts;
        assertThat(text.count()).isEqualTo(202_000);
        boolean met = perInsert < 1_000;
        PerfReport.measured("TextSequence insert into 200,000 characters (JVM)",
                String.format(Locale.ROOT, "%.2f µs", perInsert), "< 1000 µs", met);
        assertThat(perInsert).isLessThan(1_000);
    }

    /** The design point: 50,000 nodes of 20+ registers each, and 200,000 characters of text. */
    static Engine designPoint() {
        return document(50_000, 200);
    }

    /** {@code nodes} nodes, each with a register override and five gradient stops, and {@code chunks} x 999 characters. */
    static Engine document(int nodes, int chunks) {
        Engine engine = new Engine(Scenario.SCHEMA);
        String common = "common { name: \"Object\" note: \"n\" locked: true url: \"https://example.com\" alt: \"a\" decorative: true"
                + " origin_layer: \"L\" transform { a: 1 d: 1 } text_wrap { enabled: true } }";
        long counter = 1;
        for (int index = 0; index < nodes; index++) {
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
        for (int i = 0; i < chunks; i++) {
            engine.apply(Scenario.change(7, nodes + 10_000 + counter, counter, Scenario.insert(chunk, left, null)));
            left = new OpId(counter + 998, 7);
            counter += 999;
        }
        return engine;
    }

    @Test
    void aDocumentRoundTripsThroughSnapshotFrames() throws Snapshot.SnapshotException {
        Engine engine = document(2_000, 20);
        List<SnapshotFrame> frames = SnapshotTransfer.frames(engine, 1);
        Engine loaded = SnapshotTransfer.state(frames, Scenario.SCHEMA);
        assertThat(loaded.stateHash()).isEqualTo(engine.stateHash());
        assertThat(loaded.store().nodes()).hasSameSizeAs(engine.store().nodes());
    }

    @PerfTest
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
        System.out.printf("Snapshot (JVM): design point %d registers, %d compressed bytes in %d chunks; encode %.2f s%n",
                registers, bytes, frames.size() - 1, encode);
        assertThat(loaded.stateHash()).isEqualTo(engine.stateHash());
        PerfReport.measured("Load the design point from a snapshot (JVM)", String.format(Locale.ROOT, "%.2f s", load), "< 60 s", load < 60);
        assertThat(load).isLessThan(60);
    }
}
