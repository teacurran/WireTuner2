package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/** The Fugue sequence and Peritext marks below the engine; mirrors WTCRDTTests' TextTests. */
class TextSequenceTest {

    static OpId id(long counter) {
        return new OpId(counter, 1);
    }

    static OpId id(long counter, long replica) {
        return new OpId(counter, replica);
    }

    static int[] scalars(String text) {
        return text.codePoints().toArray();
    }

    @Test
    void readsOutTheLiveCharactersInOrder() {
        TextSequence text = new TextSequence();
        assertThat(text.isEmpty()).isTrue();
        assertThat(text.count()).isZero();
        assertThat(text.liveCount()).isZero();
        assertThat(text.string()).isEmpty();
        assertThat(text.insert(scalars("abc"), id(1), OpId.ZERO, OpId.ZERO)).containsExactly(id(1), id(2), id(3));
        assertThat(text.insert(scalars("X"), id(9), id(99), OpId.ZERO)).isEmpty();
        assertThat(text.insert(scalars("X"), id(9), OpId.ZERO, id(99))).isEmpty();
        assertThat(text.insert(scalars("ab"), id(1), OpId.ZERO, OpId.ZERO)).isEmpty();
        assertThat(text.delete(id(2), id(10, 2))).isTrue();
        assertThat(text.delete(id(2), id(10, 1))).isFalse();
        assertThat(text.deletedOp(id(2))).isEqualTo(id(10, 2));
        assertThat(text.delete(id(2), id(11, 1))).isFalse();
        assertThat(text.deletedOp(id(2))).isEqualTo(id(11, 1));
        assertThat(text.delete(id(42), id(12))).isFalse();
        assertThat(text.string()).isEqualTo("ac");
        assertThat(text.count()).isEqualTo(3);
        assertThat(text.liveCount()).isEqualTo(2);
        assertThat(text.isEmpty()).isFalse();
        assertThat(text.order()).containsExactly(id(1), id(2), id(3));
        assertThat(text.liveChars()).containsExactly(id(1), id(3));
        assertThat(text.contains(id(2))).isTrue();
        assertThat(text.contains(id(4))).isFalse();
        assertThat(text.codepoint(id(3))).isEqualTo(0x63);
        assertThat(text.codepoint(id(4))).isNull();
        assertThat(text.isDeleted(id(2))).isTrue();
        assertThat(text.isDeleted(id(1))).isFalse();
        assertThat(text.isDeleted(id(4))).isFalse();
        assertThat(text.deletedOp(id(1))).isNull();
        assertThat(text.deletedOp(id(4))).isNull();
        assertThat(text.origins(id(2))).isEqualTo(new TextSequence.Origins(id(1), OpId.ZERO));
        assertThat(text.origins(id(4))).isNull();
    }

    @Test
    void mapsCharacterIdsToOffsetsAndBack() {
        TextSequence text = new TextSequence();
        assertThat(text.insertionOrigins(0)).isEqualTo(new TextSequence.Origins(OpId.ZERO, OpId.ZERO));
        text.insert(scalars("abcd"), id(1), OpId.ZERO, OpId.ZERO);
        text.delete(id(2), id(9));
        assertThat(text.offset(id(1))).isZero();
        assertThat(text.offset(id(2))).isEqualTo(1);
        assertThat(text.offset(id(3))).isEqualTo(1);
        assertThat(text.offset(id(99))).isNull();
        assertThat(text.charAt(0)).isEqualTo(id(1));
        assertThat(text.charAt(1)).isEqualTo(id(3));
        assertThat(text.charAt(2)).isEqualTo(id(4));
        assertThat(text.charAt(3)).isNull();
        assertThat(text.charAt(-1)).isNull();
        assertThat(text.successor(id(1))).isEqualTo(id(2));
        assertThat(text.successor(id(4))).isEqualTo(OpId.ZERO);
        assertThat(text.successor(id(99))).isEqualTo(OpId.ZERO);
        assertThat(text.insertionOrigins(0)).isEqualTo(new TextSequence.Origins(OpId.ZERO, id(1)));
        assertThat(text.insertionOrigins(1)).isEqualTo(new TextSequence.Origins(id(1), id(2)));
        assertThat(text.insertionOrigins(3)).isEqualTo(new TextSequence.Origins(id(4), OpId.ZERO));
    }

    @Test
    void splitsBlocksAndKeepsTheOrderAcrossThem() {
        TextSequence text = new TextSequence();
        int count = TextSequence.BLOCK_LIMIT * 3;
        int[] as = new int[count];
        java.util.Arrays.fill(as, 0x61);
        text.insert(as, id(1), OpId.ZERO, OpId.ZERO);
        text.insert(new int[] {0x41}, id(10_001, 2), OpId.ZERO, id(1));
        text.insert(new int[] {0x42}, id(10_002, 2), id(700), id(701));
        text.insert(new int[] {0x43}, id(10_003, 2), id(count), OpId.ZERO);
        for (int index = 1; index <= count; index += 2) {
            text.delete(id(index), id(20_000));
        }
        assertThat(text.count()).isEqualTo(count + 3);
        assertThat(text.charAt(0)).isEqualTo(id(10_001, 2));
        assertThat(text.offset(id(10_002, 2))).isEqualTo(1 + 350);
        assertThat(text.charAt(text.liveCount() - 1)).isEqualTo(id(10_003, 2));
        assertThat(text.successor(id(512))).isEqualTo(id(513));
        assertThat(text.string().codePointCount(0, text.string().length())).isEqualTo(text.liveCount());
    }

    @Test
    void concurrentSiblingsGoAfterEarlierSiblingsSubtrees() {
        TextSequence text = new TextSequence();
        text.insert(scalars("XY"), id(1, 7), OpId.ZERO, OpId.ZERO);
        text.insert(scalars("bb"), id(5, 2), id(1, 7), OpId.ZERO);
        text.insert(scalars("aa"), id(5, 1), id(1, 7), OpId.ZERO);
        text.insert(scalars("c"), id(9, 3), id(1, 7), OpId.ZERO);
        assertThat(text.string()).isEqualTo("XYaabbc");
        text.insert(scalars("p"), id(20, 1), id(1, 7), id(2, 7));
        text.insert(scalars("q"), id(21, 1), id(1, 7), id(2, 7));
        text.insert(scalars("o"), id(3, 9), id(1, 7), id(2, 7));
        assertThat(text.string()).isEqualTo("XopqYaabbc");
    }

    @Test
    void rangesLongerThanTheTextAreMatchedAgainstIt() {
        TextSequence text = new TextSequence();
        text.insert(scalars("abc"), id(5), OpId.ZERO, OpId.ZERO);
        assertThat(text.ids(id(4), 3)).containsExactly(id(5), id(6));
        assertThat(text.ids(id(6), 100)).containsExactly(id(6), id(7));
        assertThat(text.ids(id(6, 2), 100)).isEmpty();
        assertThat(text.ids(new OpId(-2L, 1), -1L)).isEmpty();
    }

    @Test
    void restoresFromCharactersInAnyOrderAndDropsOrphans() {
        TextSequence original = new TextSequence();
        original.insert(scalars("ab"), id(1), OpId.ZERO, OpId.ZERO);
        original.insert(scalars("x"), id(5, 2), id(1), id(2));
        original.delete(id(2), id(9));
        List<TextSequence.RestoredChar> chars = new ArrayList<>();
        for (OpId c : original.order()) {
            chars.add(new TextSequence.RestoredChar(c, original.codepoint(c), original.origins(c).left(),
                    original.origins(c).right(), original.deletedOp(c)));
        }
        Collections.reverse(chars);
        chars.add(chars.get(0));
        chars.add(new TextSequence.RestoredChar(id(30), 0x7A, id(29), OpId.ZERO, null));
        chars.add(new TextSequence.RestoredChar(id(31), 0xD800_0000, id(2), OpId.ZERO, null));
        TextSequence restored = TextSequence.restore(chars, List.of());
        List<OpId> expected = new ArrayList<>(original.order());
        expected.add(id(31));
        assertThat(restored.order()).isEqualTo(expected);
        assertThat(restored.string()).isEqualTo("ax�");
        assertThat(restored.contains(id(30))).isFalse();
    }

    // ---- Marks

    static final MarkKey BOLD = new MarkKey(30);

    static TextSequence abcdef() {
        TextSequence text = new TextSequence();
        text.insert(scalars("abcdef"), id(1), OpId.ZERO, OpId.ZERO);
        return text;
    }

    static TextMark mark(long counter, Anchor start, Anchor end, byte[] value) {
        return new TextMark(id(counter, 2), start, end, value, MarkValue.key(value, 21));
    }

    static TextMark bold(long counter, Anchor start, Anchor end) {
        return mark(counter, start, end, new byte[] {(byte) 0xF0, 0x01, 0x01});
    }

    @Test
    void coverageFollowsTheAnchors() {
        Map<OpId, Integer> index = abcdef().orderIndex();
        assertThat(TextSequence.covered(bold(9, Anchor.START, Anchor.END), index, 6)).containsExactly(0, 5);
        assertThat(TextSequence.covered(bold(9, new Anchor(id(2), true), new Anchor(id(4), true)), index, 6)).containsExactly(1, 2);
        assertThat(TextSequence.covered(bold(9, new Anchor(id(2), false), new Anchor(id(4), false)), index, 6)).containsExactly(2, 3);
        assertThat(TextSequence.covered(bold(9, new Anchor(OpId.ZERO, false), Anchor.END), index, 6)).isNull();
        assertThat(TextSequence.covered(bold(9, Anchor.START, new Anchor(OpId.ZERO, true)), index, 6)).isNull();
        assertThat(TextSequence.covered(bold(9, new Anchor(id(5), true), new Anchor(id(2), true)), index, 6)).isNull();
    }

    @Test
    void marksRecordOnceWithKnownAnchors() {
        TextSequence text = abcdef();
        assertThat(text.mark(bold(9, Anchor.START, Anchor.END))).isTrue();
        assertThat(text.mark(bold(9, Anchor.START, Anchor.END))).isFalse();
        assertThat(text.mark(bold(10, new Anchor(id(99), true), Anchor.END))).isFalse();
        assertThat(text.mark(bold(11, Anchor.START, new Anchor(id(99), true)))).isFalse();
        assertThat(text.sortedMarks()).extracting(TextMark::id).containsExactly(id(9, 2));
        assertThat(Anchor.START).hasToString("before 0:0");
        assertThat(Anchor.END).hasToString("after 0:0");
        TextMark mark = text.sortedMarks().get(0);
        assertThat(mark).isEqualTo(bold(9, Anchor.START, Anchor.END)).hasSameHashCodeAs(bold(9, Anchor.START, Anchor.END));
        assertThat(mark).isNotEqualTo("mark");
        assertThat(mark.value()).containsExactly(0xF0, 0x01, 0x01);
    }

    @Test
    void theGreatestMarkOfAnAttributeWinsAndClearedValuesAreLeftOut() {
        TextSequence text = abcdef();
        text.mark(bold(9, Anchor.START, Anchor.END));
        text.mark(mark(10, new Anchor(id(3), true), new Anchor(id(4), false), new byte[] {(byte) 0xF0, 0x01, 0x00}));
        text.mark(mark(11, new Anchor(id(6), true), Anchor.END, new byte[] {0x08}));
        text.mark(new TextMark(id(12, 2), Anchor.START, Anchor.END, new byte[0], null));
        text.delete(id(1), id(20));
        List<TextRun> runs = text.runs();
        assertThat(runs).extracting(TextRun::start).containsExactly(0, 1, 3);
        assertThat(runs).extracting(TextRun::length).containsExactly(1, 2, 2);
        assertThat(runs.get(0).attributes()).extracting(TextAttribute::mark).containsExactly(id(9, 2));
        assertThat(runs.get(0).attributes().get(0).value()).containsExactly(0xF0, 0x01, 0x01);
        assertThat(runs.get(0).attributes().get(0)).isEqualTo(runs.get(2).attributes().get(0))
                .hasSameHashCodeAs(runs.get(2).attributes().get(0)).isNotEqualTo("attribute");
        assertThat(runs.get(1).attributes()).isEmpty();
        Map<OpId, TextMark> winners = text.winners(BOLD, List.of(id(2), id(3), id(99)));
        assertThat(winners.get(id(2)).id()).isEqualTo(id(9, 2));
        assertThat(winners.get(id(3)).id()).isEqualTo(id(10, 2));
        assertThat(winners).doesNotContainKey(id(99));
        Map<OpId, List<TextAttribute>> attributes = text.attributes(List.of(id(3), id(99)));
        assertThat(attributes.get(id(3))).isEmpty();
        assertThat(attributes).doesNotContainKey(id(99));
        assertThat(new TextSequence().runs()).isEmpty();
    }

    @Test
    void markValuesNameTheirAttribute() {
        assertThat(MarkValue.key(new byte[] {(byte) 0xF0, 0x01, 0x01}, 21)).isEqualTo(new MarkKey(30));
        assertThat(MarkValue.key(new byte[0], 21)).isNull();
        assertThat(MarkValue.key(new byte[] {0x08}, 21)).isNull();
        byte[] liga = {(byte) 0xAA, 0x01, 0x08, 0x0A, 0x04, 0x6C, 0x69, 0x67, 0x61, 0x10, 0x01};
        MarkKey key = MarkValue.key(liga, 21);
        assertThat(key).isEqualTo(new MarkKey(21, new byte[] {0x0A, 0x04, 0x6C, 0x69, 0x67, 0x61}));
        assertThat(key.tag()).hasSize(6);
        assertThat(key).hasSameHashCodeAs(new MarkKey(21, new byte[] {0x0A, 0x04, 0x6C, 0x69, 0x67, 0x61})).isNotEqualTo("key");
        assertThat(MarkValue.key(new byte[] {(byte) 0xAA, 0x01, 0x00}, 21)).isEqualTo(new MarkKey(21));
        assertThat(MarkValue.key(liga, null)).isEqualTo(new MarkKey(21));
        assertThat(key).hasToString("21/0a046c696761");
        assertThat(new MarkKey(3)).hasToString("3");
        assertThat(new MarkKey(3)).isLessThan(new MarkKey(21));
        assertThat(new MarkKey(21, new byte[] {1})).isLessThan(new MarkKey(21, new byte[] {2}));
        assertThat(MarkValue.isCleared(liga, key)).isFalse();
        assertThat(MarkValue.isCleared(MarkValue.cleared(liga, key), key)).isTrue();
        assertThat(MarkValue.isCleared(new byte[] {0x08}, key)).isFalse();
        assertThat(MarkValue.isCleared(new byte[] {0x1A, 0x01, 0x00}, key)).isTrue();
        assertThat(MarkValue.cleared(new byte[] {0x19, 1, 2, 3, 4, 5, 6, 7, 8}, new MarkKey(3))).containsExactly(0x19, 0, 0, 0, 0, 0, 0, 0, 0);
        assertThat(MarkValue.cleared(new byte[] {0x1D, 1, 2, 3, 4}, new MarkKey(3))).containsExactly(0x1D, 0, 0, 0, 0);
        assertThat(MarkValue.cleared(new byte[] {(byte) 0xF0, 0x01, 0x01}, BOLD)).containsExactly(0xF0, 0x01, 0x00);
        assertThat(MarkValue.cleared(new byte[] {0x08}, BOLD)).isEmpty();
    }

    // ---- Through the engine

    @Test
    void textOpsInsertDeleteAndMarkThroughTheEngine() {
        Engine engine = Scenario.engine(Scenario.change(7, 2, 2, Scenario.insert("h\\u00e9llo", null, null)));
        engine.apply(Scenario.change(7, 3, 7,
                "text_delete { " + Scenario.N + " " + Scenario.T + " ranges { first { counter: 3 replica: 7 } count: 1 } }",
                Scenario.mark(new OpId(2, 7), true, null, false, "bold: true")));
        TextSequence text = engine.text(Scenario.NODE, Scenario.TEXT);
        assertThat(text.string()).isEqualTo("hllo");
        assertThat(text.runs()).hasSize(1);
        assertThat(text.runs().get(0).attributes()).hasSize(1);
        assertThat(engine.text(Scenario.NODE, RegisterPath.of(1000, 2))).isNull();
        assertThat(engine.clock().max()).isEqualTo(8);
        assertThat(engine.store().replicaState(7)).isEqualTo(new ReplicaState(3, 0));
        assertThat(engine.store().replicaState(8)).isNull();
        assertThat(engine.store().replicas().keySet()).containsExactly(7L);
    }

    @Test
    void registerValuesAreReadThroughTheTable() {
        Engine engine = Scenario.engine();
        com.villagecompute.wiretuner.doc.v1.NodeProps values = Scenario.change("ops { set { values { test { label: \"x\" } } } }")
                .getOps(0).getSet().getValues();
        assertThat(engine.registerValue(values, 1000, Scenario.LABEL)).containsExactly(0x12, 0x01, 0x78);
        assertThat(engine.registerValue(values, 1000, RegisterPath.of(1000, 99))).isNull();
        assertThat(engine.registerValue(com.villagecompute.wiretuner.doc.v1.NodeProps.getDefaultInstance(), 1000, Scenario.LABEL)).isNull();
    }
}
