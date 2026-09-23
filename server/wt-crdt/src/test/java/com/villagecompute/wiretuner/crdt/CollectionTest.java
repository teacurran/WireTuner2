package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;

import com.google.protobuf.InvalidProtocolBufferException;
import com.google.protobuf.Message;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.DocumentSnapshot;
import com.villagecompute.wiretuner.doc.v1.NodeState;
import com.villagecompute.wiretuner.doc.v1.SetMemberState;
import com.villagecompute.wiretuner.doc.v1.SetState;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.junit.jupiter.api.Test;

/**
 * Garbage collection (CRDT-010): the stable point, what a collection drops and keeps, replays and
 * late ops after it, and that the state a collection reaches does not depend on when it ran.
 * Mirrors WTCRDTTests' CollectionTests; the vectors under crdt-conformance/vectors/gc check both
 * engines agree.
 */
class CollectionTest {

    static final String N = Scenario.N;
    static final String T = Scenario.T;
    static final String STOPS = "sequence { segments { field: 1000 } segments { field: 8 } }";
    static final String TAGS = "set { segments { field: 1000 } segments { field: 3 } }";
    static final RegisterPath TAG_PATH = RegisterPath.of(1000, 3);
    static final long RETENTION = Engine.DELETED_NODE_RETENTION_MS;

    static OpId id(long counter) {
        return new OpId(counter, 7);
    }

    static OpId id(long counter, long replica) {
        return new OpId(counter, replica);
    }

    static String stop(OpId element) {
        return "segments { field: 1000 } segments { field: 8 } segments { element { counter: " + element.counter()
                + " replica: " + element.replica() + " } }";
    }

    static String tag(String value) {
        return "values { test { tags: \"" + value + "\" } }";
    }

    static Clock at(long millis) {
        return Clock.fixed(Instant.ofEpochMilli(millis), ZoneOffset.UTC);
    }

    // ---- The stable point

    @Test
    void theStablePointIsTheSmallestAckOfTheReplicasNotRetired() {
        Engine engine = Scenario.engine();
        assertThat(new Engine().stablePoint(Set.of())).isZero();
        engine.apply(Scenario.change(1, 1, 2, 5, List.of("noop { }")), 6L);
        engine.apply(Scenario.change(2, 1, 3, 3, List.of("noop { }")), 7L);
        assertThat(engine.stablePoint(Set.of())).isZero();
        assertThat(engine.stablePoint(Set.of(7L))).isEqualTo(3);
        assertThat(engine.stablePoint(Set.of(7L, 2L))).isEqualTo(5);
        assertThat(engine.stablePoint(Set.of(1L, 2L, 7L))).isZero();
    }

    @Test
    void anOpIsStableOnceItsChangeIsSequencedAtOrBeforeTheStablePoint() {
        Engine engine = Scenario.engine();
        engine.apply(Scenario.change(1, 1, 2, 1, List.of("noop { }", "noop { }")), 2L);
        engine.apply(Scenario.change(1, 2, 4, 1, List.of("noop { }")));
        assertThat(engine.isStable(id(1), 1)).isTrue();
        assertThat(engine.isStable(id(2), 1)).isFalse();
        assertThat(engine.isStable(id(2, 1), 1)).isFalse();
        assertThat(engine.isStable(id(3, 1), 2)).isTrue();
        assertThat(engine.isStable(id(4, 1), 9)).isFalse();
        assertThat(engine.store().stableCounters(2)).isEqualTo(Map.of(7L, 2L, 1L, 4L));
        engine.collect(1, at(0));
        assertThat(engine.isStable(id(1), 0)).isTrue();
        assertThat(engine.isStable(id(1, 9), 5)).isFalse();
        assertThat(engine.store().replicaState(7).stableCounter()).isEqualTo(2);
        assertThat(engine.store().stableSeq()).isEqualTo(1);
    }

    // ---- Text

    /** "abc\nd" typed as one run, a paragraph register on the newline, a mark on a; c, the newline, d and a deleted. */
    static Engine typed() {
        Engine engine = Scenario.engine();
        engine.apply(Scenario.change(7, 2, 2, 1, List.of(Scenario.insert("abc\\nd", null, null))), 2L);
        engine.apply(Scenario.change(7, 3, 7, 2, List.of(
                "set { " + N + " paths { segments { field: 1000 } segments { field: 9 } segments { element { counter: 5 replica: 7 } }"
                        + " segments { field: 6 } segments { field: 1 } } values { test { text { chars { paragraph { alignment: 1 } } } } } }",
                Scenario.mark(id(2), true, id(2), false, "bold: true"))), 3L);
        engine.apply(Scenario.change(7, 4, 9, 3, List.of(
                "text_delete { " + N + " " + T + " ranges { first { counter: 4 replica: 7 } count: 3 } }",
                "text_delete { " + N + " " + T + " ranges { first { counter: 2 replica: 7 } count: 1 } }")), 4L);
        return engine;
    }

    static final RegisterPath PARAGRAPH = RegisterPath.of(List.of(RegisterPath.Segment.field(1000), RegisterPath.Segment.field(9),
            RegisterPath.Segment.element(id(5)), RegisterPath.Segment.field(6), RegisterPath.Segment.field(1)));

    @Test
    void tombstonesNothingHangsFromAndNoMarkAnchorsAreDropped() {
        Engine engine = typed();
        assertThat(engine.register(Scenario.NODE, PARAGRAPH)).isNotNull();
        Collected early = engine.collect(3, at(0));
        assertThat(early.characters()).isZero();
        assertThat(early.moveLogEntries()).isEqualTo(1);
        assertThat(engine.store().moveLog()).isEmpty();
        assertThat(engine.collect(4, at(0)).characters()).isEqualTo(3);
        TextSequence text = engine.text(Scenario.NODE, Scenario.TEXT);
        assertThat(text.order()).containsExactly(id(2), id(3));
        assertThat(text.string()).isEqualTo("b");
        assertThat(engine.register(Scenario.NODE, PARAGRAPH)).isNull();
        assertThat(engine.collect(4, at(0))).isEqualTo(Collected.NONE);
        assertThat(engine.collect(2, at(0))).isEqualTo(Collected.NONE);
    }

    @Test
    void lateOpsNamingCollectedCharactersAreNoOps() {
        Engine engine = typed();
        engine.collect(4, at(0));
        byte[] before = engine.stateHash();
        engine.apply(Scenario.change(1, 1, 11, 0, List.of(
                Scenario.insert("X", id(3), id(4)),
                Scenario.insert("Y", id(6), null),
                "text_delete { " + N + " " + T + " ranges { first { counter: 4 replica: 7 } count: 3 } }",
                Scenario.mark(id(5), true, null, false, "bold: true"),
                "set { " + N + " paths { segments { field: 1000 } segments { field: 9 } segments { element { counter: 5 replica: 7 } }"
                        + " segments { field: 6 } segments { field: 1 } } values { test { text { chars { paragraph { alignment: 2 } } } } } }")),
                5L);
        assertThat(engine.text(Scenario.NODE, Scenario.TEXT).string()).isEqualTo("b");
        assertThat(engine.stateHash()).isEqualTo(before);
    }

    @Test
    void theCollectedStateDoesNotDependOnWhenTheCollectionRan() throws Snapshot.SnapshotException {
        TextSequence.Origins origins = typed().insertionOrigins(Scenario.NODE, Scenario.TEXT, 1, 4);
        assertThat(origins).isEqualTo(new TextSequence.Origins(id(3), OpId.ZERO));
        assertThat(typed().insertionOrigins(Scenario.NODE, Scenario.TEXT, 1, 3)).isEqualTo(new TextSequence.Origins(id(3), id(4)));
        assertThat(typed().insertionOrigins(Scenario.NODE, Scenario.TEXT, 1, 0)).isEqualTo(new TextSequence.Origins(id(3), id(4)));
        assertThat(typed().insertionOrigins(Scenario.NODE, RegisterPath.of(1000, 7), 0, 4))
                .isEqualTo(new TextSequence.Origins(OpId.ZERO, OpId.ZERO));
        Change typing = Scenario.change(2, 1, 11, 4, List.of(Scenario.insert("Z", origins.left(), null)));
        Engine first = typed();
        first.collect(4, at(0));
        first.apply(typing, 5L);
        Engine last = typed();
        last.apply(typing, 5L);
        last.collect(4, at(0));
        assertThat(first.stateHash()).isEqualTo(last.stateHash());
        assertThat(Snapshot.encode(first, 5)).isEqualTo(Snapshot.encode(last, 5));
        assertThat(first.text(Scenario.NODE, Scenario.TEXT).string()).isEqualTo("bZ");
        Engine decoded = Snapshot.decode(Snapshot.encode(first, 5), Scenario.SCHEMA);
        assertThat(decoded.stateHash()).isEqualTo(first.stateHash());
        assertThat(decoded.store().stableSeq()).isEqualTo(4);
        assertThat(decoded.store().replicaState(7).stableCounter()).isEqualTo(11);
    }

    @Test
    void aCharacterWhoseRightOriginWasCollectedKeepsItsPlace() {
        TextSequence text = new TextSequence();
        OpId l = id(1, 1);
        OpId r = id(2, 2);
        OpId tee = id(3, 1);
        OpId x = id(5, 1);
        text.insert(new int[] {'L'}, l, OpId.ZERO, OpId.ZERO);
        text.insert(new int[] {'R'}, r, OpId.ZERO, OpId.ZERO);
        text.insert(new int[] {'T'}, tee, l, r);
        text.delete(tee, id(4, 1));
        assertThat(text.insertionOrigins(1, op -> op.equals(id(4, 1)))).isEqualTo(new TextSequence.Origins(l, r));
        text.insert(new int[] {'X'}, x, l, r);
        text.delete(r, id(6, 2));
        assertThat(text.order()).containsExactly(l, tee, x, r);
        Set<OpId> gone = text.collectable(op -> true);
        assertThat(gone).containsExactlyInAnyOrder(tee, r);
        TextSequence collected = text.removing(gone);
        assertThat(collected.order()).containsExactly(l, x);
        assertThat(collected.string()).isEqualTo("LX");
        assertThat(collected.origins(x)).isEqualTo(new TextSequence.Origins(l, r));
        text.insert(new int[] {'Y'}, id(7, 1), x, OpId.ZERO);
        collected.insert(new int[] {'Y'}, id(7, 1), x, OpId.ZERO);
        assertThat(collected.liveChars()).isEqualTo(text.liveChars());
        TextSequence orphan = TextSequence.restore(List.of(new TextSequence.RestoredChar(x, 'X', l, r, null)), List.of());
        assertThat(orphan.isEmpty()).isTrue();
    }

    @Test
    void aTextLeftWithNothingIsDropped() {
        Engine engine = Scenario.engine();
        engine.apply(Scenario.change(7, 2, 2, 1, List.of(Scenario.insert("ab", null, null))), 2L);
        engine.apply(Scenario.change(7, 3, 4, 2, List.of("text_delete { " + N + " " + T + " ranges { first { counter: 2 replica: 7 } count: 2 } }")), 3L);
        engine.collect(3, at(0));
        assertThat(engine.text(Scenario.NODE, Scenario.TEXT)).isNull();
        assertThat(engine.store().textPaths(Scenario.NODE)).isEmpty();
    }

    // ---- Sequences

    @Test
    void elementTombstonesGoWithEverythingBeneathThem() {
        Engine engine = Scenario.engine();
        String contours = "sequence { segments { field: 1000 } segments { field: 7 } }";
        String contour = "segments { field: 1000 } segments { field: 7 } segments { element { counter: 2 replica: 7 } }";
        engine.apply(Scenario.change(7, 2, 2, 1, List.of(
                "element_insert { " + N + " " + contours + " positions: \"\\x80\" values { test { contours { name: \"c\" } } } }",
                "element_insert { " + N + " sequence { " + contour + " segments { field: 3 } } positions: \"\\x80\" values { test { contours { anchors { weight: 1 } } } } }",
                "set_add { " + N + " set { " + contour + " segments { field: 5 } } values { test { contours { tags: \"t\" } } } }",
                "element_insert { " + N + " " + STOPS + " positions: \"\\x80\" }")), 2L);
        engine.apply(Scenario.change(7, 3, 6, 2, List.of(
                "element_delete { " + N + " elements { " + contour + " } deleted: true }",
                "element_delete { " + N + " elements { " + stop(id(5)) + " } deleted: true }",
                "element_delete { " + N + " elements { " + stop(id(5)) + " } }")), 3L);
        assertThat(engine.collect(3, at(0)).elements()).isEqualTo(2);
        assertThat(engine.store().elements(Scenario.NODE).keySet()).containsExactly(RegisterPath.of(1000, 8).element(id(5)));
        assertThat(engine.store().registers(Scenario.NODE).keySet()).noneMatch(path -> path.toString().contains("<2:7>"));
        assertThat(engine.store().setPaths(Scenario.NODE)).isEmpty();
        byte[] before = engine.stateHash();
        engine.apply(Scenario.change(1, 1, 9, 0, List.of(
                "element_delete { " + N + " elements { " + contour + " } }",
                "element_move { " + N + " element { " + contour + " } position: \"\\x70\" }",
                "set { " + N + " paths { " + contour + " segments { field: 4 } } values { test { contours { name: \"x\" } } } }",
                "element_insert { " + N + " sequence { " + contour + " segments { field: 3 } } positions: \"\\x90\" }")), 4L);
        assertThat(engine.stateHash()).isEqualTo(before);
    }

    // ---- Sets

    @Test
    void setHistoryThatCanNoLongerChangeAMemberIsDropped() {
        Engine engine = sets();
        Engine uncollected = sets();
        Collected collected = engine.collect(3, at(0));
        assertThat(collected.setTags()).isEqualTo(2);
        assertThat(collected.changes()).isEqualTo(3);
        List<NodeStore.SetEntry> histories = engine.store().setHistories(Scenario.NODE);
        assertThat(histories).hasSize(1);
        assertThat(histories.get(0).members()).hasSize(1);
        assertThat(histories.get(0).members().get(0).adds()).extracting(NodeStore.SetAddition::op).containsExactly(id(3));
        assertThat(histories.get(0).members().get(0).removes()).extracting(NodeStore.SetRemoval::op).containsExactly(id(4, 2));
        assertThat(engine.store().members(Scenario.NODE, TAG_PATH)).containsExactly("b".getBytes());
        Change remove = Scenario.change(3, 1, 5, 4, List.of("set_remove { " + N + " " + TAGS + " " + tag("b") + " }"));
        engine.apply(remove, 5L);
        uncollected.apply(remove, 5L);
        assertThat(engine.store().members(Scenario.NODE, TAG_PATH)).isEmpty();
        assertThat(uncollected.store().members(Scenario.NODE, TAG_PATH)).isEmpty();
        engine.collect(5, at(0));
        assertThat(engine.store().setHistories(Scenario.NODE)).isEmpty();
    }

    private static Engine sets() {
        Engine engine = Scenario.engine();
        engine.apply(Scenario.change(7, 2, 2, 1, List.of(
                "set_add { " + N + " " + TAGS + " " + tag("a") + " }",
                "set_add { " + N + " " + TAGS + " " + tag("b") + " }")), 2L);
        engine.apply(Scenario.change(1, 1, 4, 2, List.of("set_remove { " + N + " " + TAGS + " " + tag("a") + " }")), 3L);
        engine.apply(Scenario.change(2, 1, 4, 1, List.of("set_remove { " + N + " " + TAGS + " " + tag("b") + " }")), 4L);
        return engine;
    }

    @Test
    void anAddAppliedOnItsOwnIsNeverSequenced() {
        Engine engine = Scenario.engine();
        engine.apply(Scenario.change(7, 2, 2, 1, List.of("noop { }")), 2L);
        engine.apply(Scenario.change(9, 1, 1, "set_add { " + N + " " + TAGS + " " + tag("s") + " }").getOps(0), id(3, 9));
        engine.apply(Scenario.change(9, 1, 3, 1, List.of("noop { }")), 3L);
        engine.collect(3, at(0));
        assertThat(engine.store().isStable(id(3, 9))).isTrue();
        engine.apply(Scenario.change(1, 1, 5, 9, List.of("set_remove { " + N + " " + TAGS + " " + tag("s") + " }")), 4L);
        assertThat(engine.store().members(Scenario.NODE, TAG_PATH)).containsExactly("s".getBytes());
    }

    // ---- The tree

    /** Node 2:7 under 1:7 with a child 3:7 holding text; 2:7 deleted at wall time {@code deletedAt}. */
    static Engine tree(long deletedAt) {
        Engine engine = Scenario.engine();
        engine.apply(Scenario.change(7, 2, 2, 1, List.of(
                "create { parent { counter: 1 replica: 7 } position: \"\\x80\" props { test { label: \"G\" } } }",
                "create { parent { counter: 2 replica: 7 } position: \"\\x80\" props { test { label: \"C\" } } }",
                Scenario.insert("x", null, null).replace(N, "node { counter: 3 replica: 7 }"))), 2L);
        engine.apply(Scenario.change("replica: 7 seq: 3 start_counter: 5 base_server_seq: 2 wall_time_ms: " + deletedAt
                + " ops { set_deleted { node { counter: 2 replica: 7 } deleted: true } }"), 3L);
        return engine;
    }

    @Test
    void deletedNodesCompactThirtyDaysAfterTheirDeletionIsStable() throws Snapshot.SnapshotException {
        Engine engine = tree(1_000);
        assertThat(engine.store().deletedTime(id(2))).isEqualTo(1_000);
        assertThat(RETENTION).isEqualTo(30L * 24 * 60 * 60 * 1000);
        Collected collected = engine.collect(3, at(1_000 + RETENTION - 1));
        assertThat(collected.nodes()).isZero();
        assertThat(collected.moveLogEntries()).isEqualTo(3);
        assertThat(engine.store().moveLog()).isEmpty();
        Engine decoded = Snapshot.decode(Snapshot.encode(engine, 3), Scenario.SCHEMA);
        assertThat(decoded.store().deletedTime(id(2))).isEqualTo(1_000);
        assertThat(engine.collect(3, at(1_000 + RETENTION)).nodes()).isEqualTo(2);
        assertThat(engine.store().exists(id(2))).isFalse();
        assertThat(engine.store().exists(id(3))).isFalse();
        assertThat(engine.store().children(Scenario.NODE)).isEmpty();
        assertThat(engine.store().nodes()).containsExactly(Scenario.NODE);
        engine.apply(Scenario.change(1, 1, 9, 0, List.of(
                "set { node { counter: 2 replica: 7 } paths { segments { field: 1000 } segments { field: 2 } } values { test { label: \"late\" } } }",
                "set_deleted { node { counter: 2 replica: 7 } }",
                "move { node { counter: 3 replica: 7 } parent { counter: 1 replica: 7 } position: \"\\x80\" }",
                "create { parent { counter: 2 replica: 7 } position: \"\\x80\" props { test { } } }")), 4L);
        assertThat(engine.store().exists(id(2))).isFalse();
        assertThat(engine.store().exists(id(12, 1))).isTrue();
        assertThat(engine.store().placement(id(12, 1))).isNull();
    }

    @Test
    void aDeletedNodeAnUnstableMoveStillNamesIsKept() {
        Engine engine = tree(0);
        engine.apply(Scenario.change(1, 1, 9, 3, List.of(
                "move { node { counter: 3 replica: 7 } parent { counter: 1 replica: 7 } position: \"\\x90\" }")), 4L);
        assertThat(engine.collect(3, at(RETENTION)).nodes()).isZero();
        assertThat(engine.store().exists(id(2))).isTrue();
        assertThat(engine.store().moveLog()).extracting(MoveLogEntry::op).containsExactly(id(9, 1));
        assertThat(engine.collect(4, at(RETENTION)).nodes()).isEqualTo(1);
        assertThat(engine.store().exists(id(2))).isFalse();
        assertThat(engine.store().placement(id(3)).parent()).isEqualTo(Scenario.NODE);
        assertThat(tree(0).collect(3, at(Long.MIN_VALUE + 1)).nodes()).isZero();
    }

    @Test
    void aNodeIsCompactableWhenItOrAnAncestorWouldCompact() {
        Engine engine = tree(1_000);
        assertThat(engine.isCompactable(id(3), 3, 1_000 + RETENTION)).isTrue();
        assertThat(engine.isCompactable(id(2), 3, 1_000 + RETENTION)).isTrue();
        assertThat(engine.isCompactable(id(3), 3, 999 + RETENTION)).isFalse();
        assertThat(engine.isCompactable(id(3), 2, 1_000 + RETENTION)).isFalse();
        assertThat(engine.isCompactable(Scenario.NODE, 3, 1_000 + RETENTION)).isFalse();
        assertThat(engine.isCompactable(id(3), 3, Long.MIN_VALUE)).isFalse();
        engine.collect(3, at(0));
        assertThat(engine.isCompactable(id(3), 0, 1_000 + RETENTION)).isTrue();
        engine.apply(Scenario.change(1, 1, 9, 3, List.of("set_deleted { node { counter: 2 replica: 7 } }")), 4L);
        assertThat(engine.isCompactable(id(3), 4, 1_000 + RETENTION)).isFalse();
    }

    @Test
    void anUnstableEntryNamingTheNodeOrAChildOfItKeepsIt() {
        Engine moved = tree(0);
        moved.apply(Scenario.change(1, 1, 9, 3, List.of(
                "move { node { counter: 2 replica: 7 } parent { counter: 4 } position: \"\\x90\" }")), 4L);
        assertThat(moved.collect(3, at(RETENTION)).nodes()).isZero();
        Engine parent = tree(0);
        parent.apply(Scenario.change(1, 1, 9, 3, List.of(
                "create { parent { counter: 2 replica: 7 } position: \"\\x90\" props { test { } } }")), 4L);
        assertThat(parent.collect(3, at(RETENTION)).nodes()).isZero();
        // A change applied with server_seq 0 is not taken for a replay.
        parent.apply(Scenario.change(3, 1, 20, 3, List.of("noop { }")), 0L);
        assertThat(parent.store().replicaState(3)).isNotNull();
    }

    @Test
    void aDeletionWithoutAWallTimeCountsFromTheEpoch() throws Snapshot.SnapshotException {
        Engine decoded = Snapshot.decode(Snapshot.encode(tree(0), 3), Scenario.SCHEMA);
        assertThat(decoded.store().deletedTime(id(2))).isZero();
        assertThat(decoded.collect(3, at(RETENTION - 1)).nodes()).isZero();
        assertThat(decoded.collect(3, at(RETENTION)).nodes()).isEqualTo(2);
    }

    @Test
    void aLateMoveStillUndoesAndRedoesTheUnstableEntries() {
        Engine engine = twoNodes();
        Engine uncollected = twoNodes();
        engine.collect(2, at(0));
        assertThat(engine.store().moveLog()).extracting(MoveLogEntry::op).containsExactly(id(10, 1));
        Change late = Scenario.change(2, 1, 5, 2, List.of("move { node { counter: 3 replica: 7 } parent { counter: 2 replica: 7 } position: \"\\x80\" }"));
        engine.apply(late, 4L);
        uncollected.apply(late, 4L);
        uncollected.collect(2, at(0));
        assertThat(engine.stateHash()).isEqualTo(uncollected.stateHash());
        assertThat(engine.store().placement(id(3)).parent()).isEqualTo(id(2));
        assertThat(engine.store().placement(id(2)).parent()).isEqualTo(OpId.wellKnown(4));
    }

    private static Engine twoNodes() {
        Engine engine = Scenario.engine();
        engine.apply(Scenario.change(7, 2, 2, 1, List.of(
                "create { parent { counter: 4 } position: \"\\x81\" props { test { label: \"A\" } } }",
                "create { parent { counter: 4 } position: \"\\x82\" props { test { label: \"B\" } } }")), 2L);
        engine.apply(Scenario.change(1, 1, 10, 2, List.of(
                "move { node { counter: 2 replica: 7 } parent { counter: 3 replica: 7 } position: \"\\x80\" }")), 3L);
        return engine;
    }

    // ---- Replays

    @Test
    void changesAndOpsTheCollectionFoldedInAreReplays() {
        Engine engine = typed();
        engine.collect(4, at(0));
        byte[] hash = engine.stateHash();
        byte[] snapshot = Snapshot.encode(engine, 4);
        Change typing = Scenario.change(7, 2, 2, 1, List.of(Scenario.insert("abc\\nd", null, null)));
        engine.apply(typing, 2L);
        engine.apply(typing);
        engine.apply(typing.getOps(0), id(2));
        engine.acknowledge(7, 2, 2);
        assertThat(engine.stateHash()).isEqualTo(hash);
        assertThat(Snapshot.encode(engine, 4)).isEqualTo(snapshot);
        assertThat(engine.text(Scenario.NODE, Scenario.TEXT).string()).isEqualTo("b");
    }

    @Test
    void collectsByTheSystemClockUnlessGivenOne() {
        Engine engine = new Engine(Scenario.SCHEMA);
        engine.apply(Scenario.change(7, 1, 1, "create { parent { counter: 4 } position: \"\\x80\" props { test { label: \"T\" } } }"), 1L);
        assertThat(engine.collect(1).moveLogEntries()).isEqualTo(1);
        assertThat(engine.collect(1, at(0))).isEqualTo(Collected.NONE);
        assertThat(engine.store().stableSeq()).isEqualTo(1);
    }

    // ---- Snapshots

    /**
     * The engine writes a {@code DocumentSnapshot} by hand; the generated classes read every field
     * of it (none lands in unknown fields) with the values the engine holds.
     */
    @Test
    void theGeneratedClassesReadTheSnapshotTheEngineWrites() throws InvalidProtocolBufferException {
        Engine engine = SnapshotTest.rich();
        engine.apply(Scenario.change("replica: 9 seq: 2 start_counter: 30 base_server_seq: 3 wall_time_ms: 77"
                + " ops { set_deleted { node { counter: 2 replica: 7 } deleted: true } }"
                + " ops { set_add { " + N + " " + TAGS + " " + tag("v") + " } }"
                + " ops { move { node { counter: 2 replica: 7 } parent { counter: 4 } position: \"\\x85\" } }"), 5L);
        engine.apply(Scenario.change(9, 3, 40, 5, List.of("noop { }")));
        engine.collect(3, at(0));
        DocumentSnapshot snapshot = DocumentSnapshot.parseFrom(Snapshot.encode(engine, 5));
        List<Message> messages = new ArrayList<>(List.of(snapshot));
        messages.addAll(snapshot.getReplicasList());
        messages.addAll(snapshot.getSequencedList());
        messages.addAll(snapshot.getMoveLogList());
        assertThat(snapshot.getServerSeq()).isEqualTo(5);
        assertThat(snapshot.getStableSeq()).isEqualTo(3);
        assertThat(snapshot.getMaxCounter()).isEqualTo(engine.clock().max());
        assertThat(snapshot.getStateHash().toByteArray()).isEqualTo(engine.stateHash());
        assertThat(snapshot.getReplicasList()).extracting(r -> r.getReplica())
                .containsExactlyElementsOf(engine.store().replicas().keySet());
        assertThat(snapshot.getReplicasList()).extracting(r -> r.getStableCounter())
                .containsExactlyElementsOf(engine.store().replicas().values().stream().map(ReplicaState::stableCounter).toList());
        assertThat(snapshot.getReplicasList()).anyMatch(r -> r.getStableCounter() > 0);
        assertThat(snapshot.getSequencedList()).extracting(c -> c.getReplica() + "/" + c.getSeq() + "/" + c.getServerSeq() + "/" + c.getEndCounter())
                .containsExactlyElementsOf(engine.store().sequencedChanges().stream()
                        .map(c -> c.replica() + "/" + c.seq() + "/" + c.serverSeq() + "/" + c.endCounter()).toList());
        assertThat(snapshot.getSequencedList()).anyMatch(c -> c.getServerSeq() == 0 && c.getEndCounter() == 41);
        assertThat(snapshot.getMoveLogList()).extracting(e -> OpId.of(e.getOp()))
                .containsExactlyElementsOf(engine.store().moveLog().stream().map(MoveLogEntry::op).toList());
        assertThat(snapshot.getMoveLogList()).extracting(e -> e.hasOldOp() ? OpId.of(e.getOldOp()) : null)
                .containsExactlyElementsOf(engine.store().moveLog().stream().map(e -> e.old() == null ? null : e.old().op()).toList());
        assertThat(snapshot.getMoveLogList()).anyMatch(e -> e.hasOldOp());
        assertThat(snapshot.getNodesList()).extracting(state -> OpId.of(state.getNode().getId()))
                .containsExactlyElementsOf(engine.store().nodes());
        for (NodeState state : snapshot.getNodesList()) {
            OpId node = OpId.of(state.getNode().getId());
            messages.add(state);
            messages.add(state.getNode());
            messages.addAll(state.getElementsList());
            messages.addAll(state.getRegistersList());
            assertThat(state.getDeletedWallTimeMs()).isEqualTo(engine.store().deletedTime(node));
            assertThat(state.getTextsList()).extracting(RegisterPath::of).containsExactlyElementsOf(engine.store().textPaths(node));
            assertThat(state.getRegistersList()).extracting(stamp -> RegisterPath.of(stamp.getPath()))
                    .containsExactlyElementsOf(engine.store().registers(node).keySet());
            List<NodeStore.SetEntry> histories = engine.store().setHistories(node);
            assertThat(state.getSetsList()).extracting(set -> RegisterPath.of(set.getSet()))
                    .containsExactlyElementsOf(histories.stream().map(NodeStore.SetEntry::path).toList());
            for (int i = 0; i < state.getSetsCount(); i++) {
                SetState set = state.getSets(i);
                messages.add(set);
                for (int m = 0; m < set.getMembersCount(); m++) {
                    SetMemberState member = set.getMembers(m);
                    NodeStore.MemberEntry entry = histories.get(i).members().get(m);
                    messages.add(member);
                    messages.addAll(member.getAddsList());
                    messages.addAll(member.getRemovesList());
                    assertThat(member.getValue().toByteArray()).isEqualTo(entry.member());
                    assertThat(member.getAddsList()).extracting(add -> OpId.of(add.getOp()))
                            .containsExactlyElementsOf(entry.adds().stream().map(NodeStore.SetAddition::op).toList());
                    assertThat(member.getRemovesList()).extracting(removal -> removal.getBaseServerSeq())
                            .containsExactlyElementsOf(entry.removes().stream().map(NodeStore.SetRemoval::base).toList());
                }
            }
        }
        assertThat(messages).allMatch(message -> message.getUnknownFields().asMap().isEmpty());
        assertThat(snapshot.getNodesList()).anyMatch(state -> state.getDeletedWallTimeMs() == 77);
        assertThat(snapshot.getNodesList()).anyMatch(state -> state.getSetsCount() > 0);
        assertThat(snapshot.getNodesList()).anyMatch(state -> state.getTextsCount() > 0);
    }
}
