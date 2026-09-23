package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;

import com.villagecompute.wiretuner.crdt.schema.MergeTable.FieldPolicy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.Policy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.RefFallback;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * The edges of the text, mark, set and element ops through the engine, recorded and not: ops
 * that name the wrong kind of target, replays, losing writes and marks that cover nothing.
 */
class EngineTextTest {

    static final String N = Scenario.N;
    static final String T = Scenario.T;
    static final String STOP3 = InverseTest.STOP3;

    @Test
    void textOpsOnTheWrongTargetsChangeNothing() {
        Engine engine = InverseTest.base();
        byte[] before = engine.stateHash();
        String element = "text { segments { field: 1000 } segments { field: 9 } segments { element { counter: 7 replica: 7 } } }";
        Inverse inverse = engine.applyLocal(Scenario.change(9, 1, 13,
                "text_insert { " + N + " " + element + " chars: \"x\" }",
                "text_delete { " + N + " text { segments { field: 1000 } segments { field: 2 } } ranges { first { counter: 5 replica: 7 } count: 1 } }",
                "text_mark { " + N + " " + element + " start { } end { } value { bold: true } }",
                "set_add { " + N + " set { segments { field: 1000 } segments { field: 2 } } values { test { label: \"x\" } } }",
                "set_add { " + N + " set { " + STOP3 + " } values { test { tags: \"x\" } } }",
                "element_insert { " + N + " sequence { segments { field: 1000 } segments { field: 2 } } positions: \"\\x80\" }",
                "element_move { " + N + " element { segments { field: 1000 } segments { field: 9 } segments { element { counter: 7 replica: 7 } } } position: \"\\x80\" }",
                Scenario.insert("ab", new OpId(5, 7), null)));
        assertThat(inverse.steps()).hasSize(1);
        // Replaying the insert inserts nothing more.
        Inverse replay = engine.applyLocal(Scenario.change(9, 1, 20, Scenario.insert("ab", new OpId(5, 7), null)));
        assertThat(replay.isEmpty()).isTrue();
        assertThat(engine.stateHash()).isNotEqualTo(before);
        assertThat(engine.registerValue(com.villagecompute.wiretuner.doc.v1.NodeProps.getDefaultInstance(), 1000,
                RegisterPath.of(1000, 8).element(new OpId(3, 7)))).isNull();
    }

    @Test
    void remoteDeletesAndMarksAreAppliedWithoutRecording() {
        Engine engine = InverseTest.base();
        engine.apply(Scenario.change(5, 1, 30,
                "text_delete { " + N + " " + T + " ranges { first { counter: 5 replica: 7 } count: 2 } }",
                "text_delete { " + N + " " + T + " ranges { first { counter: 5 replica: 7 } count: 1 } }"));
        assertThat(engine.text(Scenario.NODE, Scenario.TEXT).string()).isEqualTo("\ncd");
        // Recording: a delete over a tombstone records only the live characters; a mark over a
        // range with a tombstone records only live ones; a mark that covers nothing records none.
        Inverse inverse = engine.applyLocal(Scenario.change(9, 1, 40,
                "text_delete { " + N + " " + T + " ranges { first { counter: 5 replica: 7 } count: 3 } }",
                Scenario.mark(new OpId(5, 7), true, new OpId(9, 7), false, "size: 3"),
                Scenario.mark(new OpId(9, 7), false, new OpId(5, 7), true, "size: 4")));
        assertThat(inverse.steps()).hasSize(3);
        assertThat(((Inverse.TextDeleted) inverse.steps().get(0)).chars()).hasSize(1);
        assertThat(((Inverse.TextMarked) inverse.steps().get(1)).prior()).hasSize(2);
        assertThat(((Inverse.TextMarked) inverse.steps().get(2)).prior()).isEmpty();
    }

    @Test
    void marksOnATextWithoutCharactersAndLosingWritesAreNotRecorded() {
        Engine engine = Scenario.engine();
        Inverse inverse = engine.applyLocal(Scenario.change(9, 1, 5,
                Scenario.mark(null, true, null, false, "bold: true"),
                "text_delete { " + N + " " + T + " ranges { first { counter: 1 replica: 7 } count: 1 } }"));
        assertThat(inverse.steps()).singleElement().isInstanceOf(Inverse.TextMarked.class);
        Engine withStop = InverseTest.base();
        withStop.apply(Scenario.change(5, 1, 50, "set_deleted { node { counter: 2 replica: 7 } deleted: true }",
                "element_delete { " + N + " elements { " + STOP3 + " } deleted: true }"));
        Inverse losing = withStop.applyLocal(Scenario.change(9, 1, 13, "set_deleted { node { counter: 2 replica: 7 } }",
                "element_delete { " + N + " elements { " + STOP3 + " } }"));
        assertThat(losing.isEmpty()).isTrue();
    }

    @Test
    void undoRestoresAFlagRestoredBeforeAndMergesDeleteRanges() {
        Engine engine = InverseTest.base();
        engine.apply(Scenario.change(7, 3, 20, "set_deleted { node { counter: 2 replica: 7 } deleted: true }",
                "element_delete { " + N + " elements { " + STOP3 + " } deleted: true }"));
        engine.apply(Scenario.change(7, 4, 22, "set_deleted { node { counter: 2 replica: 7 } }",
                "element_delete { " + N + " elements { " + STOP3 + " } }"));
        Inverse inverse = engine.applyLocal(Scenario.change(9, 1, 30, "set_deleted { node { counter: 2 replica: 7 } deleted: true }",
                "element_delete { " + N + " elements { " + STOP3 + " } deleted: true }",
                Scenario.insert("xyz", new OpId(9, 7), null), Scenario.insert("w", new OpId(9, 7), null)));
        var undo = engine.undoChange(inverse, 9, 2, engine.clock().peek(), 0, "");
        assertThat(undo.getOps(0).getTextDelete().getRangesCount()).isEqualTo(1);
        assertThat(undo.getOps(1).getTextDelete().getRangesList()).extracting(r -> r.getCount()).containsExactly(3L);
        assertThat(undo.getOps(2).getElementDelete().getDeleted()).isFalse();
        assertThat(undo.getOps(3).getSetDeleted().getDeleted()).isFalse();
    }

    @Test
    void theFeatureFieldIsFoundThroughTheTable() {
        Schema schema = Scenario.SCHEMA;
        FieldPolicy text = schema.field("wiretuner.conformance.v1.TestProps", 9);
        assertThat(schema.featureField(text)).isEqualTo(21);
        FieldPolicy untyped = row(9, Policy.TEXT, null);
        assertThat(schema.featureField(untyped)).isNull();
        assertThat(schema.featureField(row(9, Policy.TEXT, "no.Such"))).isNull();
        Schema marksUntyped = schema.withField("t.Rich", row(2, Policy.ATOMIC, null));
        assertThat(marksUntyped.featureField(row(9, Policy.TEXT, "t.Rich"))).isNull();
        Schema noValue = schema.withField("t.Rich", row(2, Policy.ATOMIC, "t.Mark"));
        assertThat(noValue.featureField(row(9, Policy.TEXT, "t.Rich"))).isNull();
        Schema valueUntyped = noValue.withField("t.Mark", row(4, Policy.ATOMIC, null));
        assertThat(valueUntyped.featureField(row(9, Policy.TEXT, "t.Rich"))).isNull();
        Schema noFeature = noValue.withField("t.Mark", row(4, Policy.ATOMIC, "t.Value")).withField("t.Value", row(1, Policy.ATOMIC, null));
        assertThat(noFeature.featureField(row(9, Policy.TEXT, "t.Rich"))).isNull();
    }

    private static FieldPolicy row(int number, Policy policy, String typeName) {
        return new FieldPolicy(number, "f" + number, policy, RefFallback.UNSET, false, "message", false, typeName, null, null);
    }

    @Test
    void valueRecordsCompareByEveryField() {
        byte[] bold = {(byte) 0xF0, 0x01, 0x01};
        TextMark mark = new TextMark(new OpId(1, 1), Anchor.START, Anchor.END, bold, new MarkKey(30));
        assertThat(mark).isNotEqualTo(new TextMark(new OpId(2, 1), Anchor.START, Anchor.END, bold, new MarkKey(30)))
                .isNotEqualTo(new TextMark(new OpId(1, 1), Anchor.END, Anchor.END, bold, new MarkKey(30)))
                .isNotEqualTo(new TextMark(new OpId(1, 1), Anchor.START, Anchor.START, bold, new MarkKey(30)))
                .isNotEqualTo(new TextMark(new OpId(1, 1), Anchor.START, Anchor.END, new byte[0], new MarkKey(30)))
                .isNotEqualTo(new TextMark(new OpId(1, 1), Anchor.START, Anchor.END, bold, null));
        TextAttribute attribute = new TextAttribute(new MarkKey(30), bold, new OpId(1, 1));
        assertThat(attribute).isNotEqualTo(new TextAttribute(new MarkKey(3), bold, new OpId(1, 1)))
                .isNotEqualTo(new TextAttribute(new MarkKey(30), new byte[0], new OpId(1, 1)))
                .isNotEqualTo(new TextAttribute(new MarkKey(30), bold, new OpId(2, 1)));
        assertThat(new MarkKey(30)).isNotEqualTo(new MarkKey(31));
    }

    @Test
    void storeTextHelpersToleratePathsThatNameNoCharacter() {
        NodeStore store = new NodeStore();
        assertThat(store.isNewline(Scenario.NODE, RegisterPath.of(1000))).isFalse();
        assertThat(store.isNewline(Scenario.NODE, RegisterPath.of(1000, 9))).isFalse();
        assertThat(store.isNewline(Scenario.NODE, Scenario.TEXT.element(new OpId(1, 1)))).isFalse();
        List<OpId> none = store.editText(Scenario.NODE, Scenario.TEXT, text -> text.insert(new int[] {0x61}, new OpId(2, 1), new OpId(9, 9), OpId.ZERO));
        assertThat(none).isEmpty();
        assertThat(store.nodes()).isEmpty();
        store.editText(Scenario.NODE, Scenario.TEXT, text -> text.insert(new int[] {0x61}, new OpId(2, 1), OpId.ZERO, OpId.ZERO));
        store.editText(Scenario.NODE, RegisterPath.of(1000, 10), text -> text.insert(new int[] {0x61}, new OpId(3, 1), new OpId(9, 9), OpId.ZERO));
        assertThat(store.textPaths(Scenario.NODE)).containsExactly(Scenario.TEXT);
        store.moveElement(Scenario.NODE, RegisterPath.of(1000, 8).element(new OpId(1, 1)), new byte[] {1}, new OpId(4, 1));
        store.deleteElement(Scenario.NODE, RegisterPath.of(1000, 8).element(new OpId(1, 1)), true, new OpId(4, 1));
        assertThat(store.elements(Scenario.NODE)).isEmpty();
    }
}
