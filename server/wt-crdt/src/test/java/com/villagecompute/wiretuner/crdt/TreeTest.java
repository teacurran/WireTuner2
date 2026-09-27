package com.villagecompute.wiretuner.crdt;

import static com.villagecompute.wiretuner.crdt.Changes.change;
import static com.villagecompute.wiretuner.crdt.Changes.createUnder;
import static com.villagecompute.wiretuner.crdt.Changes.group;
import static com.villagecompute.wiretuner.crdt.Changes.move;
import static com.villagecompute.wiretuner.crdt.Changes.setDeleted;
import static org.assertj.core.api.Assertions.assertThat;

import com.villagecompute.wiretuner.doc.v1.Op;
import java.util.Arrays;
import java.util.List;
import org.junit.jupiter.api.Test;

class TreeTest {

    private static final OpId LAYERS = OpId.wellKnown(4);
    private static final OpId A = new OpId(1, 1);
    private static final OpId B = new OpId(2, 1);
    private static final OpId C = new OpId(3, 1);

    /** Three groups A, B, C under the layers collection at 0x80, 0x40, 0x80. */
    private static Engine threeGroups() {
        Engine engine = new Engine();
        engine.apply(change(1, 1, createUnder(LAYERS, 0x80, group()), createUnder(LAYERS, 0x40, group()),
                createUnder(LAYERS, 0x80, group())));
        return engine;
    }

    @Test
    void createPlacesNodesAndChildrenSortByPositionThenId() {
        Engine engine = threeGroups();
        assertThat(engine.store().children(LAYERS)).containsExactly(B, A, C);
        assertThat(engine.store().placement(A)).isEqualTo(new Placement(LAYERS, new byte[] {(byte) 0x80}, A));
        assertThat(engine.store().placement(A).position()).containsExactly(0x80);
        assertThat(engine.store().placement(A).toString()).isEqualTo("4:0/80@1:1");
        Object word = "x";
        assertThat(engine.store().placement(A)).isNotEqualTo(new Placement(LAYERS, new byte[] {1}, A))
                .isNotEqualTo(new Placement(A, new byte[] {(byte) 0x80}, A))
                .isNotEqualTo(new Placement(LAYERS, new byte[] {(byte) 0x80}, B))
                .isNotEqualTo(word)
                .hasSameHashCodeAs(new Placement(LAYERS, new byte[] {(byte) 0x80}, A));
        assertThat(engine.store().moveLog()).extracting(MoveLogEntry::op).containsExactly(A, B, C);
    }

    @Test
    void wellKnownNodesSitUnderTheDocumentAndNeverMove() {
        Engine engine = threeGroups();
        assertThat(engine.store().placement(OpId.ZERO)).isNull();
        assertThat(engine.store().placement(LAYERS)).isEqualTo(new Placement(OpId.ZERO, new byte[0], OpId.ZERO));
        assertThat(engine.store().children(OpId.ZERO)).hasSize(15).startsWith(OpId.wellKnown(1));
        byte[] before = engine.stateHash();
        engine.apply(change(2, 10, move(LAYERS, A, 1), setDeleted(LAYERS, true)));
        assertThat(engine.store().placement(LAYERS).parent()).isEqualTo(OpId.ZERO);
        assertThat(engine.store().deleted(LAYERS)).isNull();
        assertThat(engine.stateHash()).isEqualTo(before);
    }

    @Test
    void concurrentMovesIntoTwoParentsResolveToTheGreaterOpId() {
        Op[] toA = {move(C, A, 0x80)};
        Op[] toB = {move(C, B, 0x80)};
        Engine one = threeGroups();
        one.apply(change(1, 10, toA));
        one.apply(change(2, 10, toB));
        Engine two = threeGroups();
        two.apply(change(2, 10, toB));
        two.apply(change(1, 10, toA));
        assertThat(one.store().placement(C).parent()).isEqualTo(B);
        assertThat(Arrays.equals(one.stateHash(), two.stateHash())).isTrue();
        assertThat(one.store().children(A)).isEmpty();
        assertThat(one.store().children(B)).containsExactly(C);
    }

    @Test
    void movingAUnderBWhileBMovesUnderASkipsTheLaterMove() {
        Op aUnderB = move(A, B, 0x80);
        Op bUnderA = move(B, A, 0x80);
        Engine one = threeGroups();
        one.apply(change(1, 10, aUnderB));
        one.apply(change(2, 10, bUnderA));
        Engine two = threeGroups();
        two.apply(change(2, 10, bUnderA));
        two.apply(change(1, 10, aUnderB));
        for (Engine engine : List.of(one, two)) {
            assertThat(engine.store().placement(A).parent()).isEqualTo(B);
            assertThat(engine.store().placement(B).parent()).isEqualTo(LAYERS);
            assertThat(engine.store().moveLog().get(4).applied()).isFalse();
        }
        assertThat(Arrays.equals(one.stateHash(), two.stateHash())).isTrue();
    }

    @Test
    void aNodeCannotMoveUnderItself() {
        Engine engine = threeGroups();
        engine.apply(change(1, 10, move(A, A, 1)));
        assertThat(engine.store().placement(A).parent()).isEqualTo(LAYERS);
    }

    @Test
    void movesOfUnknownNodesOrToUnknownParentsAreSkippedUntilTheCreateArrives() {
        OpId late = new OpId(5, 2);
        Engine engine = threeGroups();
        engine.apply(change(1, 10, move(late, A, 0x10), move(B, late, 0x10)));
        assertThat(engine.store().placement(B).parent()).isEqualTo(LAYERS);
        assertThat(engine.store().placement(late)).isNull();
        // The create of 5:2 arrives late: the logged moves after it are redone.
        engine.apply(change(2, 5, createUnder(LAYERS, 0x90, group())));
        assertThat(engine.store().placement(late).parent()).isEqualTo(A);
        assertThat(engine.store().placement(B).parent()).isEqualTo(late);
        assertThat(engine.store().children(A)).containsExactly(late);
    }

    @Test
    void aCreateUnderAMissingParentLeavesTheNodeUnplacedButMovable() {
        Engine engine = new Engine();
        engine.apply(change(1, 1, createUnder(new OpId(99, 9), 0x80, group())));
        assertThat(engine.store().kind(A)).isEqualTo(50);
        assertThat(engine.store().placement(A)).isNull();
        engine.apply(change(1, 2, move(A, LAYERS, 0x20)));
        assertThat(engine.store().placement(A).parent()).isEqualTo(LAYERS);
        engine.apply(change(1, 2, move(A, LAYERS, 0x20)));        // replay: ignored
        assertThat(engine.store().moveLog()).hasSize(2);
    }

    @Test
    void reparentAcrossLayersKeepsTheSubtree() {
        Engine engine = threeGroups();
        engine.apply(change(1, 4, createUnder(A, 0x80, group())));   // 4:1 under A
        OpId child = new OpId(4, 1);
        engine.apply(change(1, 5, move(A, C, 0x80)));
        assertThat(engine.store().placement(child).parent()).isEqualTo(A);
        assertThat(engine.store().children(C)).containsExactly(A);
        // A late move of C under the child (a cycle once A is under C) is skipped only after it.
        engine.apply(change(2, 4, move(C, child, 0x80)));
        assertThat(engine.store().placement(C).parent()).isEqualTo(child);
        assertThat(engine.store().placement(A).parent()).as("A under C would now be a cycle").isEqualTo(LAYERS);
    }

    @Test
    void deleteIsARegisterAndEditsToDeletedNodesStillApply() {
        Engine engine = threeGroups();
        engine.apply(change(1, 10, setDeleted(A, true)));
        engine.apply(change(2, 10, setDeleted(A, false)));
        engine.apply(change(2, 10, setDeleted(A, false)));          // replay
        engine.apply(change(1, 11, setDeleted(new OpId(77, 7), true)));
        Cell<Boolean> deleted = engine.store().deleted(A);
        assertThat(deleted.current()).isEqualTo(new Stamped<>(false, new OpId(10, 2)));
        assertThat(deleted.losing()).extracting(Stamped::op).containsExactly(new OpId(10, 1));
        assertThat(deleted.writes()).hasSize(2);
        assertThat(engine.store().deleted(new OpId(77, 7))).isNull();
    }
}
