package com.villagecompute.wiretuner.crdt;

import static com.villagecompute.wiretuner.crdt.Changes.createUnder;
import static com.villagecompute.wiretuner.crdt.Changes.group;
import static com.villagecompute.wiretuner.crdt.Changes.move;
import static org.assertj.core.api.Assertions.assertThat;

import com.villagecompute.wiretuner.doc.v1.Op;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Random;
import org.junit.jupiter.api.Test;

/**
 * CRDT-002's done-when: random moves delivered out of order match a sequential oracle that
 * applies every tree op in OpId order, and a late move on a 50,000-node tree is fast (the timing is
 * a {@link PerfTest}; the default build checks that late moves on a large tree land as in-order
 * delivery would). WTCRDTTests'
 * TreeFuzzTests is the Swift twin.
 */
class TreeFuzzTest {

    private static final OpId LAYERS = OpId.wellKnown(4);
    private static final int NODES = 60;

    /** One random move with its id. */
    private record Move(OpId id, OpId node, OpId parent, int position) {
    }

    private static Engine seeded() {
        Engine engine = new Engine();
        for (int i = 1; i <= NODES; i++) {
            engine.apply(createUnder(LAYERS, i, group()), new OpId(i, 1));
        }
        return engine;
    }

    private static OpId randomNode(Random random) {
        return new OpId(1 + random.nextInt(NODES), 1);
    }

    /** `count` moves by five replicas whose Lamport clocks drift apart and occasionally sync. */
    private static List<ArrayDeque<Move>> streams(Random random, int count) {
        long[] clocks = new long[5];
        Arrays.fill(clocks, NODES);
        List<ArrayDeque<Move>> streams = new ArrayList<>();
        for (int r = 0; r < 5; r++) {
            streams.add(new ArrayDeque<>());
        }
        long max = NODES;
        for (int i = 0; i < count; i++) {
            int r = random.nextInt(5);
            if (random.nextInt(10) == 0) {
                clocks[r] = max;
            }
            clocks[r]++;
            max = Math.max(max, clocks[r]);
            OpId parent = random.nextInt(8) == 0 ? LAYERS : randomNode(random);
            streams.get(r).add(new Move(new OpId(clocks[r], r + 2), randomNode(random), parent, random.nextInt(256)));
        }
        return streams;
    }

    /** Applies every move in OpId order with the skip rule: the oracle's parent map. */
    private static Map<OpId, Move> oracle(List<Move> moves) {
        List<Move> sorted = new ArrayList<>(moves);
        sorted.sort((a, b) -> a.id().compareTo(b.id()));
        Map<OpId, OpId> parents = new HashMap<>();
        Map<OpId, Move> placed = new HashMap<>();
        for (int i = 1; i <= NODES; i++) {
            parents.put(new OpId(i, 1), LAYERS);
        }
        for (Move move : sorted) {
            boolean cycle = false;
            for (OpId at = move.parent(); at != null; at = parents.get(at)) {
                cycle |= at.equals(move.node());
            }
            if (!cycle) {
                parents.put(move.node(), move.parent());
                placed.put(move.node(), move);
            }
        }
        return placed;
    }

    private static void assertMatches(Engine engine, Map<OpId, Move> oracle) {
        for (int i = 1; i <= NODES; i++) {
            OpId node = new OpId(i, 1);
            Placement placement = engine.store().placement(node);
            Move move = oracle.get(node);
            if (move == null) {
                assertThat(placement).isEqualTo(new Placement(LAYERS, new byte[] {(byte) i}, node));
            } else {
                assertThat(placement).isEqualTo(new Placement(move.parent(), new byte[] {(byte) move.position()}, move.id()));
            }
        }
    }

    private static void deliver(Engine engine, Move move) {
        engine.apply(move(move.node(), move.parent(), move.position()), move.id());
    }

    @Test
    void tenThousandInterleavedMovesMatchTheSequentialOracle() {
        Random random = new Random(42);
        List<ArrayDeque<Move>> streams = streams(random, 10_000);
        List<Move> all = new ArrayList<>();
        streams.forEach(all::addAll);
        Engine engine = seeded();
        List<ArrayDeque<Move>> pending = new ArrayList<>(streams);
        while (!pending.isEmpty()) {
            int r = random.nextInt(pending.size());
            deliver(engine, pending.get(r).removeFirst());
            if (pending.get(r).isEmpty()) {
                pending.remove(r);
            }
        }
        assertMatches(engine, oracle(all));
        assertThat(engine.store().moveLog()).hasSize(NODES + 10_000);
    }

    @Test
    void aThousandFullyShuffledMovesMatchTheSequentialOracle() {
        Random random = new Random(7);
        List<Move> all = new ArrayList<>();
        streams(random, 1_000).forEach(all::addAll);
        Collections.shuffle(all, random);
        Engine engine = seeded();
        all.forEach(move -> deliver(engine, move));
        all.forEach(move -> deliver(engine, move));     // replays change nothing
        assertMatches(engine, oracle(all));
    }

    /** A random tree of {@code nodes} groups (the first 100 under Layers) and 1,000 moves by replica 2 after the creates. */
    private static Engine grownTree(Random random, int nodes, List<Map.Entry<OpId, Op>> log) {
        Engine engine = new Engine();
        for (int i = 1; i <= nodes; i++) {
            OpId parent = i <= 100 ? LAYERS : new OpId(1 + random.nextInt(i - 1), 1);
            record(engine, log, createUnder(parent, 0x80, group()), new OpId(i, 1));
        }
        for (int k = 1; k <= 1_000; k++) {
            OpId node = new OpId(101 + random.nextInt(nodes - 100), 1);
            record(engine, log, move(node, new OpId(1 + random.nextInt(nodes), 1), 0x40), new OpId(nodes + 2L * k, 2));
        }
        return engine;
    }

    /** A move that sorts before every one of the 1,000 moves: it arrives late and undoes and redoes them. */
    private static Op lateMove(Random random, int nodes) {
        return move(new OpId(101 + random.nextInt(nodes - 100), 1), new OpId(1 + random.nextInt(nodes), 1), 0x20);
    }

    private static void record(Engine engine, List<Map.Entry<OpId, Op>> log, Op op, OpId id) {
        engine.apply(op, id);
        log.add(Map.entry(id, op));
    }

    @Test
    void lateMovesOnALargeTreeMatchInOrderDelivery() {
        Random random = new Random(3);
        int nodes = 5_000;
        List<Map.Entry<OpId, Op>> log = new ArrayList<>();
        Engine engine = grownTree(random, nodes, log);
        for (int j = 0; j < 31; j++) {
            record(engine, log, lateMove(random, nodes), new OpId(nodes + 1L, 100 + j));
        }
        log.sort(Map.Entry.comparingByKey());
        Engine inOrder = new Engine();
        log.forEach(entry -> inOrder.apply(entry.getValue(), entry.getKey()));
        assertThat(engine.stateHash()).isEqualTo(inOrder.stateHash());
        assertThat(engine.store().moveLog()).hasSize(nodes + 1_031);
    }

    @PerfTest
    void aLateMoveOnAFiftyThousandNodeTreeIsFast() {
        Random random = new Random(3);
        int nodes = 50_000;
        Engine engine = grownTree(random, nodes, new ArrayList<>());
        long[] times = new long[31];
        for (int j = 0; j < times.length; j++) {
            Op late = lateMove(random, nodes);
            long start = System.nanoTime();
            engine.apply(late, new OpId(nodes + 1L, 100 + j));
            times[j] = System.nanoTime() - start;
        }
        Arrays.sort(times);
        long median = times[times.length / 2];
        PerfReport.measured("Late move (before 1,000 tree ops) on a 50,000-node tree, median (JVM)",
                String.format(Locale.ROOT, "%.3f ms", median / 1e6), "< 20 ms", median < 20_000_000L);
        assertThat(median).isLessThan(20_000_000L);
    }
}
