package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;

import com.villagecompute.wiretuner.doc.v1.Change;
import java.util.List;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

/**
 * Inverses (CRDT-008): applying a local change, then the change its inverse builds, leaves the
 * document as it was wherever nobody else touched the same things. WTCRDTTests' InverseTests runs
 * the same cases.
 */
class InverseTest {

    static final String N = Scenario.N;
    static final String T = Scenario.T;
    static final String STOP3 = "segments { field: 1000 } segments { field: 8 } segments { element { counter: 3 replica: 7 } }";
    static final String LABEL = "paths { segments { field: 1000 } segments { field: 2 } }";
    static final String TAGS = "set { segments { field: 1000 } segments { field: 3 } }";
    static final String OTHER = "node { counter: 2 replica: 7 }";

    /** Node 1:7 with node 2:7, stops 3:7 and 4:7, the text "ab\ncd" (5:7..9:7) with an aligned newline and a bold b, tag "t". */
    static Engine base() {
        Engine engine = Scenario.engine();
        engine.apply(Scenario.change(7, 2, 2,
                "create { parent { counter: 4 } position: \"\\x81\" props { test { label: \"U\" } } }",
                "element_insert { " + N + " sequence { segments { field: 1000 } segments { field: 8 } } positions: [\"\\x80\", \"\\x81\"]"
                        + " values { test { stops { offset: 1 } stops { offset: 2 } } } }",
                Scenario.insert("ab\\ncd", null, null),
                "set { " + N + " paths { segments { field: 1000 } segments { field: 9 } segments { element { counter: 7 replica: 7 } }"
                        + " segments { field: 6 } segments { field: 1 } } values { test { text { chars { paragraph { alignment: 1 } } } } } }",
                Scenario.mark(new OpId(6, 7), true, new OpId(6, 7), false, "bold: true"),
                "set_add { " + N + " " + TAGS + " values { test { tags: \"t\" } } }"), 2L);
        return engine;
    }

    static Stream<Arguments> cases() {
        String create = "create { parent { counter: 1 replica: 7 } position: \"\\x80\" props { test { label: \"N\" } } }";
        String insertStop = "element_insert { " + N + " sequence { segments { field: 1000 } segments { field: 8 } } positions: \"\\x82\"";
        return Stream.of(
                Arguments.of("create", List.of(create)),
                Arguments.of("create then delete", List.of(create, "set_deleted { node { counter: 13 replica: 9 } deleted: true }")),
                Arguments.of("set a register", List.of("set { " + N + " " + LABEL + " values { test { label: \"L\" } } }")),
                Arguments.of("set a register twice", List.of("set { " + N + " " + LABEL + " values { test { label: \"L1\" } } }",
                        "set { " + N + " " + LABEL + " values { test { label: \"L2\" } } }")),
                Arguments.of("write a struct", List.of("set { " + N + " paths { segments { field: 1000 } segments { field: 1 } }"
                        + " values { test { common { name: \"n\" locked: true } } } }")),
                Arguments.of("clear a register", List.of("set { " + N + " " + LABEL + " }")),
                Arguments.of("move a node", List.of("move { " + OTHER + " parent { counter: 1 replica: 7 } position: \"\\x80\" }")),
                Arguments.of("move a node twice", List.of("move { " + OTHER + " parent { counter: 1 replica: 7 } position: \"\\x80\" }",
                        "move { " + OTHER + " parent { counter: 4 } position: \"\\x90\" }")),
                Arguments.of("delete a node", List.of("set_deleted { " + OTHER + " deleted: true }")),
                Arguments.of("delete and restore a node", List.of("set_deleted { " + OTHER + " deleted: true }", "set_deleted { " + OTHER + " }")),
                Arguments.of("insert an element", List.of(insertStop + " values { test { stops { offset: 3 } } } }")),
                Arguments.of("insert and delete an element", List.of(insertStop + " }", "element_delete { " + N
                        + " elements { segments { field: 1000 } segments { field: 8 } segments { element { counter: 13 replica: 9 } } } deleted: true }")),
                Arguments.of("move an element", List.of("element_move { " + N + " element { " + STOP3 + " } position: \"\\x83\" }")),
                Arguments.of("delete an element", List.of("element_delete { " + N + " elements { " + STOP3 + " } deleted: true }")),
                Arguments.of("add a member", List.of("set_add { " + N + " " + TAGS + " values { test { tags: \"u\" } } }")),
                Arguments.of("add a member again", List.of("set_add { " + N + " " + TAGS + " values { test { tags: \"t\" } } }")),
                Arguments.of("remove a member", List.of("set_remove { " + N + " " + TAGS + " values { test { tags: \"t\" } } }")),
                Arguments.of("add and remove a member", List.of("set_add { " + N + " " + TAGS + " values { test { tags: \"u\" } } }",
                        "set_remove { " + N + " " + TAGS + " values { test { tags: \"u\" } } }")),
                Arguments.of("remove and add a member", List.of("set_remove { " + N + " " + TAGS + " values { test { tags: \"t\" } } }",
                        "set_add { " + N + " " + TAGS + " values { test { tags: \"t\" } } }")),
                Arguments.of("add id and scalar members", List.of(
                        "set_add { " + N + " set { segments { field: 1000 } segments { field: 5 } } values { test { points { counter: 3 replica: 7 } } } }",
                        "set_add { " + N + " set { segments { field: 1000 } segments { field: 4 } } values { test { codes: [7] } } }")),
                Arguments.of("insert text", List.of(Scenario.insert("X", new OpId(6, 7), new OpId(7, 7)))),
                Arguments.of("delete formatted text and a newline", List.of("text_delete { " + N + " " + T
                        + " ranges { first { counter: 6 replica: 7 } count: 2 } }")),
                Arguments.of("delete separated characters", List.of("text_delete { " + N + " " + T
                        + " ranges { first { counter: 5 replica: 7 } count: 1 } ranges { first { counter: 9 replica: 7 } count: 1 } }")),
                Arguments.of("insert and delete text", List.of(Scenario.insert("XY", new OpId(9, 7), null),
                        "text_delete { " + N + " " + T + " ranges { first { counter: 13 replica: 9 } count: 1 } }")),
                Arguments.of("mark text", List.of(Scenario.mark(new OpId(5, 7), true, new OpId(7, 7), true, "bold: true"),
                        Scenario.mark(null, true, null, false, "font_family: \"F\""),
                        Scenario.mark(new OpId(8, 7), true, null, false, "feature { tag: \"liga\" state: 1 }"))));
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("cases")
    void applyThenInvertIsIdentity(String name, List<String> ops) {
        Engine engine = base();
        List<String> before = View.of(engine);
        Inverse inverse = engine.applyLocal(Scenario.change(9, 1, 13, 2, ops));
        List<String> after = View.of(engine);
        assertThat(inverse.isEmpty()).isFalse();
        Change undo = engine.undoChange(inverse, 9, 2, engine.clock().peek(), 2, "Undo");
        if (undo == null) {
            assertThat(after).as(name + " has nothing to undo").isEqualTo(before);
            return;
        }
        assertThat(undo.getLabel()).isEqualTo("Undo");
        Inverse redo = engine.applyLocal(undo);
        assertThat(View.of(engine)).as("undo of " + name).isEqualTo(before);
        if (after.equals(before)) {
            return;
        }
        engine.applyLocal(engine.undoChange(redo, 9, 3, engine.clock().peek(), 2, ""));
        assertThat(View.of(engine)).as("redo of " + name).isEqualTo(after);
    }

    static Stream<Arguments> contested() {
        return Stream.of(
                Arguments.of("register", List.of("set { " + N + " " + LABEL + " values { test { label: \"L\" } } }"),
                        List.of("set { " + N + " " + LABEL + " values { test { label: \"R\" } } }")),
                Arguments.of("creation", List.of("create { parent { counter: 1 replica: 7 } position: \"\\x80\" props { test { label: \"N\" } } }"),
                        List.of("set_deleted { node { counter: 13 replica: 9 } }")),
                Arguments.of("placement", List.of("move { " + OTHER + " parent { counter: 1 replica: 7 } position: \"\\x80\" }"),
                        List.of("move { " + OTHER + " parent { counter: 4 } position: \"\\x99\" }")),
                Arguments.of("deleted flag", List.of("set_deleted { " + OTHER + " deleted: true }"), List.of("set_deleted { " + OTHER + " }")),
                Arguments.of("element insert", List.of("element_insert { " + N + " sequence { segments { field: 1000 } segments { field: 8 } } positions: \"\\x82\" }"),
                        List.of("element_delete { " + N + " elements { segments { field: 1000 } segments { field: 8 } segments { element { counter: 13 replica: 9 } } } }")),
                Arguments.of("element position", List.of("element_move { " + N + " element { " + STOP3 + " } position: \"\\x83\" }"),
                        List.of("element_move { " + N + " element { " + STOP3 + " } position: \"\\x84\" }")),
                Arguments.of("element deleted flag", List.of("element_delete { " + N + " elements { " + STOP3 + " } deleted: true }"),
                        List.of("element_delete { " + N + " elements { " + STOP3 + " } }")),
                Arguments.of("member add", List.of("set_add { " + N + " " + TAGS + " values { test { tags: \"u\" } } }"),
                        List.of("set_add { " + N + " " + TAGS + " values { test { tags: \"u\" } } }")),
                Arguments.of("member remove", List.of("set_remove { " + N + " " + TAGS + " values { test { tags: \"t\" } } }"),
                        List.of("set_add { " + N + " " + TAGS + " values { test { tags: \"t\" } } }")),
                Arguments.of("text insert", List.of(Scenario.insert("X", new OpId(9, 7), null)),
                        List.of("text_delete { " + N + " " + T + " ranges { first { counter: 13 replica: 9 } count: 1 } }")),
                Arguments.of("text mark", List.of(Scenario.mark(null, true, null, false, "size: 12")),
                        List.of(Scenario.mark(null, true, null, false, "size: 14"))));
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("contested")
    void undoNeverRevertsOtherPeoplesWork(String name, List<String> local, List<String> remote) {
        Engine engine = base();
        Inverse inverse = engine.applyLocal(Scenario.change(9, 1, 13, 2, local));
        engine.apply(Scenario.change(5, 1, 50, 2, remote));
        assertThat(engine.undoChange(inverse, 9, 2, engine.clock().peek(), 2, "")).as(name).isNull();
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("contested")
    void thisReplicasOwnLaterWritesDoNotBlockAnUndo(String name, List<String> local, List<String> later) {
        Engine engine = base();
        List<String> before = View.of(engine);
        Inverse inverse = engine.applyLocal(Scenario.change(9, 1, 13, 2, local));
        engine.applyLocal(Scenario.change(9, 2, 50, 2, later));
        Change undo = engine.undoChange(inverse, 9, 3, engine.clock().peek(), 2, "");
        if (undo != null) {
            engine.applyLocal(undo);
        }
        assertThat(View.of(engine)).as(name).isEqualTo(before);
    }

    @Test
    void undoSkipsWhatACollectionDropped() {
        Engine engine = base();
        Inverse inverse = engine.applyLocal(Scenario.change(9, 1, 13, 2, List.of(
                "create { parent { counter: 4 } position: \"\\x90\" props { test { label: \"N\" } } }",
                "element_insert { " + N + " sequence { segments { field: 1000 } segments { field: 8 } } positions: \"\\x82\""
                        + " values { test { stops { offset: 5 } } } }",
                Scenario.insert("X", new OpId(9, 7), null),
                "set { " + N + " " + LABEL + " values { test { label: \"L\" } } }",
                "set { " + N + " paths { segments { field: 1000 } segments { field: 8 } segments { element { counter: 14 replica: 9 } }"
                        + " segments { field: 2 } } values { test { stops { offset: 6 } } } }",
                "move { " + OTHER + " parent { counter: 4 } position: \"\\xA0\" }",
                "set_deleted { " + OTHER + " deleted: false }",
                "element_move { " + N + " element { " + STOP3 + " } position: \"\\x83\" }",
                "element_delete { " + N + " elements { " + STOP3 + " } deleted: false }")));
        engine.acknowledge(9, 1, 3);
        engine.apply(Scenario.change(5, 1, 30, 3, List.of(
                "set_deleted { " + OTHER + " deleted: true }",
                "element_delete { " + N + " elements { " + STOP3 + " } deleted: true }",
                "set_deleted { node { counter: 13 replica: 9 } deleted: true }",
                "element_delete { " + N + " elements { segments { field: 1000 } segments { field: 8 } segments { element { counter: 14 replica: 9 } } }"
                        + " deleted: true }",
                "text_delete { " + N + " " + T + " ranges { first { counter: 15 replica: 9 } count: 1 } }")), 4L);
        Collected collected = engine.collect(4, java.time.Clock.fixed(java.time.Instant.ofEpochMilli(Engine.DELETED_NODE_RETENTION_MS),
                java.time.ZoneOffset.UTC));
        assertThat(collected.nodes()).isEqualTo(2);
        assertThat(collected.elements()).isEqualTo(2);
        assertThat(collected.characters()).isEqualTo(1);
        Change undo = engine.undoChange(inverse, 9, 2, engine.clock().peek(), 0, "");
        assertThat(undo.getOpsList()).hasSize(1);
        assertThat(undo.getOps(0).getSet().getPathsList()).containsExactly(Scenario.LABEL.toProto());
        // The text itself dropped (every character collected, or its node compacted): nothing of a
        // text step is left either.
        Engine emptied = Scenario.engine();
        Inverse typed = emptied.applyLocal(Scenario.change(9, 1, 2, 1, List.of(Scenario.insert("ab", null, null))));
        Inverse deleted = emptied.applyLocal(Scenario.change(9, 2, 4, 1, List.of(
                "text_delete { " + N + " " + T + " ranges { first { counter: 2 replica: 9 } count: 2 } }")));
        emptied.acknowledge(9, 1, 2);
        emptied.acknowledge(9, 2, 3);
        assertThat(emptied.collect(3, java.time.Clock.systemUTC()).characters()).isEqualTo(2);
        assertThat(emptied.text(Scenario.NODE, Scenario.TEXT)).isNull();
        assertThat(emptied.undoChange(typed, 9, 3, emptied.clock().peek(), 3, "")).isNull();
        assertThat(emptied.undoChange(deleted, 9, 3, emptied.clock().peek(), 3, "")).isNull();
        Engine compacted = Scenario.engine();
        Inverse marked = compacted.applyLocal(Scenario.change(9, 1, 2, 1, List.of(Scenario.insert("ab", null, null),
                Scenario.mark(null, true, null, false, "size: 3"))));
        compacted.acknowledge(9, 1, 2);
        compacted.apply(Scenario.change(5, 1, 10, 2, List.of("set_deleted { " + N + " deleted: true }")), 3L);
        assertThat(compacted.collect(3, java.time.Clock.fixed(java.time.Instant.ofEpochMilli(Engine.DELETED_NODE_RETENTION_MS),
                java.time.ZoneOffset.UTC)).nodes()).isEqualTo(1);
        assertThat(compacted.undoChange(marked, 9, 2, compacted.clock().peek(), 3, "")).isNull();
    }

    @Test
    void joinedInversesUndoAsOne() {
        Engine engine = base();
        Inverse first = engine.applyLocal(Scenario.change(9, 1, 13, 2, List.of(
                "text_delete { " + N + " " + T + " ranges { first { counter: 6 replica: 7 } count: 2 } }")));
        Inverse second = engine.applyLocal(Scenario.change(9, 2, 14, 2, List.of(
                "set_remove { " + N + " " + TAGS + " values { test { tags: \"t\" } } }", Scenario.mark(null, true, null, false, "size: 12"))));
        Inverse joined = first.followed(second);
        assertThat(joined.steps()).hasSize(first.steps().size() + second.steps().size());
        engine.applyLocal(engine.undoChange(joined, 9, 3, engine.clock().peek(), 2, ""));
        assertThat(View.of(engine)).isEqualTo(View.of(base()));
    }

    @Test
    void aMoveOfAnUnplacedNodeHasNothingToMoveBackTo() {
        Engine engine = base();
        engine.apply(Scenario.change(7, 3, 20, "create { parent { counter: 99 replica: 9 } position: \"\\x80\" props { test { } } }"));
        Inverse inverse = engine.applyLocal(Scenario.change(9, 2, 22,
                "move { node { counter: 20 replica: 7 } parent { counter: 1 replica: 7 } position: \"\\x80\" }"));
        assertThat(inverse.steps()).hasSize(1);
        assertThat(engine.undoChange(inverse, 9, 3, engine.clock().peek(), 0, "")).isNull();
    }

    @Test
    void opsThatChangeNothingRecordNothing() {
        Engine engine = base();
        Inverse inverse = engine.applyLocal(Scenario.change(9, 1, 13, "noop { }", "set_deleted { node { counter: 1 replica: 0 } deleted: true }",
                "move { node { counter: 1 replica: 7 } parent { counter: 1 replica: 7 } position: \"\\x80\" }",
                "move { node { counter: 16 replica: 9 } parent { counter: 1 replica: 7 } position: \"\\x80\" }",
                "set_remove { " + N + " " + TAGS + " values { test { tags: \"zz\" } } }",
                "text_delete { " + N + " " + T + " ranges { first { counter: 90 replica: 7 } count: 1 } }",
                Scenario.mark(new OpId(90, 7), true, null, false, "bold: true"),
                "text_mark { " + N + " " + T + " start { } end { } }"));
        assertThat(inverse.isEmpty()).isTrue();
        assertThat(inverse).isEqualTo(new Inverse(List.of())).hasSameHashCodeAs(new Inverse(List.of()));
        assertThat(engine.undoChange(inverse, 9, 2, engine.clock().peek(), 0, "")).isNull();
    }

    @Test
    void undoAppliesTheUndoChangeAndReturnsTheRedo() {
        Engine engine = new Engine(Scenario.SCHEMA);
        Inverse inverse = engine.applyLocal(Scenario.change(7, 1, 1,
                "create { parent { counter: 4 } position: \"\\x80\" props { test { label: \"T\" } } }"));
        Engine.Undone undone = engine.undo(inverse, 7, 2, 0, "Undo");
        assertThat(undone.change().getStartCounter()).isEqualTo(2);
        assertThat(undone.redo().isEmpty()).isFalse();
        assertThat(engine.store().deleted(new OpId(1, 7)).current().value()).isTrue();
        assertThat(engine.undo(new Inverse(List.of()), 7, 3, 0, "")).isNull();
    }

    @Test
    void membersEncodeByTheirFieldType() {
        assertThat(new Inverse.MemberField(4, "fixed64", null).record(new byte[] {1, 0, 0, 0, 0, 0, 0, 0}))
                .containsExactly(0x21, 1, 0, 0, 0, 0, 0, 0, 0);
        assertThat(new Inverse.MemberField(4, "float", null).record(new byte[] {1, 2, 3, 4})).containsExactly(0x25, 1, 2, 3, 4);
        assertThat(new Inverse.MemberField(4, "uint32", null).record(new byte[] {0, 0, 0, 0, 0, 0, 0, 5})).containsExactly(0x20, 5);
        assertThat(new Inverse.MemberField(4, "bytes", null).record(new byte[] {9})).containsExactly(0x22, 1, 9);
        assertThat(new Inverse.MemberField(4, "message", "wiretuner.doc.v1.OpId")
                .record(new byte[] {0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2}))
                .containsExactly(0x22, 11, 0x08, 1, 0x11, 2, 0, 0, 0, 0, 0, 0, 0);
    }
}
