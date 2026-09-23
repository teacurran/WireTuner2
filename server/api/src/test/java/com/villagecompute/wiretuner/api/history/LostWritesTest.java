package com.villagecompute.wiretuner.api.history;

import static com.villagecompute.wiretuner.api.history.DocOps.LAYERS;
import static com.villagecompute.wiretuner.api.history.DocOps.wellKnown;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.CommonProps;
import com.villagecompute.wiretuner.doc.v1.ElementId;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.MoveNode;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.OpId;
import com.villagecompute.wiretuner.doc.v1.PathProps;
import com.villagecompute.wiretuner.doc.v1.PathSegment;
import com.villagecompute.wiretuner.doc.v1.SetFields;

/** COLLAB-023: a register write that lost to a concurrent, greater write is marked; nothing else is. */
class LostWritesTest {

    static final OpId NODE = DocOps.id(1, 7);

    /** A change of {@code replica} (its {@code seq}-th) whose first op takes {@code counter}, made knowing {@code base}. */
    static LostWrites.Logged at(long serverSeq, long replica, long seq, long counter, long base, Op... ops) {
        return new LostWrites.Logged(serverSeq, Change.newBuilder().setReplica(replica).setSeq(seq).setStartCounter(counter)
                .setBaseServerSeq(base).addAllOps(List.of(ops)).build());
    }

    static Map<Long, List<String>> lost(LostWrites.Logged... changes) {
        return LostWrites.of(List.of(changes), List.of());
    }

    static Op note(String note) {
        return Op.newBuilder().setSet(SetFields.newBuilder().setNode(NODE)
                .addPaths(DocOps.fields(NodeProps.PATH_FIELD_NUMBER, 1, CommonProps.NOTE_FIELD_NUMBER))
                .setValues(DocOps.path("", note))).build();
    }

    /** Writes the whole {@code common} struct: every register beneath it. */
    static Op common(String name) {
        return Op.newBuilder().setSet(SetFields.newBuilder().setNode(NODE)
                .addPaths(DocOps.fields(NodeProps.PATH_FIELD_NUMBER, 1)).setValues(DocOps.path(name, ""))).build();
    }

    static Op move() {
        return Op.newBuilder().setMove(MoveNode.newBuilder().setNode(NODE).setParent(wellKnown(LAYERS))).build();
    }

    @Test
    void theLesserOfTwoConcurrentWritesLosesWhicheverArrivedFirst() {
        LostWrites.Logged create = at(1, 7, 1, 1, 0, DocOps.create(wellKnown(LAYERS), DocOps.path("Logo", "")));
        // Both made knowing only the creation; 9:2 beats 5:3 on either arrival order.
        LostWrites.Logged lesser = at(2, 3, 1, 5, 1, DocOps.rename(NODE, "Mark"));
        LostWrites.Logged greater = at(3, 2, 1, 9, 1, DocOps.rename(NODE, "Badge"));
        assertThat(lost(create, lesser, greater)).containsOnly(Map.entry(2L, List.of("Name")));
        LostWrites.Logged greaterFirst = at(2, 2, 1, 9, 1, DocOps.rename(NODE, "Badge"));
        LostWrites.Logged lesserAfter = at(3, 3, 1, 5, 1, DocOps.rename(NODE, "Mark"));
        assertThat(lost(create, greaterFirst, lesserAfter)).containsOnly(Map.entry(3L, List.of("Name")));
        // Only the page's own changes are answered; the others are context.
        assertThat(LostWrites.of(List.of(greaterFirst), List.of(create, lesserAfter))).isEmpty();
        assertThat(LostWrites.of(List.of(lesserAfter), List.of(greaterFirst))).containsOnlyKeys(3L);
    }

    @Test
    void aLaterEditThatKnewTheWriteReplacesItWithoutALoss() {
        LostWrites.Logged first = at(1, 3, 1, 5, 0, DocOps.rename(NODE, "Mark"));
        // Made knowing seq 1 (its base), or the same replica's next change: both applied in turn.
        LostWrites.Logged knowing = at(2, 2, 1, 9, 1, DocOps.rename(NODE, "Badge"));
        LostWrites.Logged own = at(3, 3, 2, 12, 0, DocOps.rename(NODE, "Seal"));
        assertThat(lost(first, knowing, own)).containsOnlyKeys(2L);
        assertThat(LostWrites.knew(own.change(), first)).isTrue();
        assertThat(LostWrites.knew(first.change(), own)).isFalse();
    }

    @Test
    void writesToDifferentRegistersNeverConflict() {
        LostWrites.Logged name = at(1, 3, 1, 5, 0, DocOps.rename(NODE, "Mark"));
        LostWrites.Logged note = at(2, 2, 1, 9, 0, note("Hello"));
        assertThat(lost(name, note)).isEmpty();
        // Writes in one change never beat each other.
        assertThat(lost(at(1, 3, 1, 5, 0, DocOps.rename(NODE, "A"), DocOps.rename(NODE, "B")))).isEmpty();
    }

    @Test
    void aStructWriteLosesOnlyWhenEveryRegisterBeneathItLost() {
        // A greater concurrent Name covers one register of the lesser Common: Common partly applied.
        LostWrites.Logged whole = at(1, 3, 1, 5, 0, common("Mark"));
        LostWrites.Logged name = at(2, 2, 1, 9, 0, DocOps.rename(NODE, "Badge"));
        assertThat(lost(whole, name)).isEmpty();
        // A greater concurrent Common covers the lesser Name entirely.
        LostWrites.Logged lesserName = at(1, 3, 1, 5, 0, DocOps.rename(NODE, "Mark"));
        LostWrites.Logged greaterWhole = at(2, 2, 1, 9, 0, common("Badge"));
        assertThat(lost(lesserName, greaterWhole)).containsOnly(Map.entry(1L, List.of("Name")));
    }

    @Test
    void deletedAndOrderAreOneRegisterEach() {
        LostWrites.Logged delete = at(1, 3, 1, 5, 0, DocOps.delete(NODE), move());
        LostWrites.Logged undelete = at(2, 2, 1, 9, 0, DocOps.undelete(NODE), move());
        assertThat(lost(delete, undelete)).containsOnly(Map.entry(1L, List.of("Deleted", "Order")));
    }

    @Test
    void textSequenceAndSetOpsNeverLose() {
        FieldPath contours = DocOps.fields(NodeProps.PATH_FIELD_NUMBER, PathProps.CONTOURS_FIELD_NUMBER);
        FieldPath element = contours.toBuilder().addSegments(PathSegment.newBuilder()
                .setElement(ElementId.newBuilder().setCounter(4).setReplica(3))).addSegments(PathSegment.newBuilder().setField(2))
                .build();
        // A write through an element this scratch state does not hold resolves to no register.
        Op throughElement = Op.newBuilder().setSet(SetFields.newBuilder().setNode(NODE).addPaths(element)
                .setValues(NodeProps.newBuilder().setPath(PathProps.getDefaultInstance()))).build();
        // A path naming no known field has no attribute.
        Op unknown = Op.newBuilder().setSet(SetFields.newBuilder().setNode(NODE).addPaths(DocOps.fields(999, 1))).build();
        LostWrites.Logged lesser = at(1, 3, 1, 5, 0, DocOps.type(NODE, "ab"), DocOps.keyword("k"), throughElement, unknown);
        LostWrites.Logged greater = at(2, 2, 1, 9, 0, DocOps.type(NODE, "cd"), DocOps.keyword("k"), throughElement, unknown,
                DocOps.noop());
        assertThat(lost(lesser, greater)).isEmpty();
    }
}
