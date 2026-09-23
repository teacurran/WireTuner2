package com.villagecompute.wiretuner.crdt;

import static com.villagecompute.wiretuner.crdt.Changes.change;
import static com.villagecompute.wiretuner.crdt.Changes.clear;
import static com.villagecompute.wiretuner.crdt.Changes.set;
import static com.villagecompute.wiretuner.crdt.TestKinds.CONTOURS;
import static com.villagecompute.wiretuner.crdt.TestKinds.STOPS;
import static com.villagecompute.wiretuner.crdt.TestKinds.TAGS;
import static com.villagecompute.wiretuner.crdt.TestKinds.add;
import static com.villagecompute.wiretuner.crdt.TestKinds.deleteElements;
import static com.villagecompute.wiretuner.crdt.TestKinds.insert;
import static com.villagecompute.wiretuner.crdt.TestKinds.moveElement;
import static com.villagecompute.wiretuner.crdt.TestKinds.props;
import static org.assertj.core.api.Assertions.assertThat;

import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.TextInsert;
import java.util.Arrays;
import org.junit.jupiter.api.Test;

class SequenceTest {

    private static final OpId NODE = new OpId(1, 1);
    private static final OpId S2 = new OpId(2, 1);
    private static final OpId S3 = new OpId(3, 1);
    private static final OpId S4 = new OpId(4, 1);

    private static NodeProps stops(Wire... stops) {
        Wire inner = Wire.message();
        for (Wire stop : stops) {
            inner.message(8, stop);
        }
        return props(inner);
    }

    /** The node, then three stops 2:1, 3:1, 4:1 at 0x40, 0x80, 0xC0 (the first two with values). */
    private static Engine withStops() {
        Engine engine = new Engine(TestKinds.schema());
        engine.apply(change(1, 1, TestKinds.create(Wire.message()),
                insert(NODE, STOPS, stops(Wire.message().varint(1, 99).string(3, "red"), Wire.message().string(3, "blue")),
                        0x40, 0x80, 0xC0),
                Op.newBuilder().setNoop(com.villagecompute.wiretuner.doc.v1.Noop.getDefaultInstance()).build()));
        return engine;
    }

    @Test
    void anInsertOfManyTakesConsecutiveIdsAndCounters() {
        Engine engine = withStops();
        assertThat(engine.store().elementOrder(NODE, STOPS)).containsExactly(S2, S3, S4);
        assertThat(engine.register(NODE, STOPS.element(S2).child(3)))
                .isEqualTo(new Register(Wire.message().string(3, "red").build(), S2));
        assertThat(engine.register(NODE, STOPS.element(S3).child(3)).op()).isEqualTo(S3);
        assertThat(engine.store().registers(NODE)).hasSize(2);      // the id field is never a register
        assertThat(engine.clock().max()).as("the noop after the insert has counter 5").isEqualTo(5);
        Stamped<byte[]> position = engine.store().element(NODE, STOPS.element(S4)).position().current();
        assertThat(position.value()).containsExactly(0xC0);
        assertThat(position.op()).isEqualTo(S4);
        assertThat(engine.store().element(NODE, STOPS.element(new OpId(5, 1)))).isNull();
        assertThat(engine.store().element(new OpId(7, 7), STOPS.element(S4))).isNull();
        assertThat(engine.store().elements(NODE)).hasSize(3);
        byte[] before = engine.stateHash();
        engine.apply(change(1, 2, insert(NODE, STOPS, NodeProps.getDefaultInstance(), 0x01)));   // replay of 2:1
        assertThat(engine.stateHash()).isEqualTo(before);
    }

    @Test
    void aConcurrentReorderAndEditKeepBoth() {
        Op reorder = moveElement(NODE, STOPS.element(S4), 0x10);
        Op edit = set(NODE, stops(Wire.message().string(3, "green")), STOPS.element(S4).child(3));
        Op reorderToo = moveElement(NODE, STOPS.element(S4), 0x90);
        Engine one = withStops();
        one.apply(change(2, 10, reorder));
        one.apply(change(3, 10, edit));
        one.apply(change(1, 10, reorderToo));
        Engine two = withStops();
        two.apply(change(1, 10, reorderToo));
        two.apply(change(3, 10, edit));
        two.apply(change(2, 10, reorder));
        assertThat(one.store().elementOrder(NODE, STOPS)).containsExactly(S4, S2, S3);   // 0x10 by 10:2 wins
        assertThat(Arrays.equals(one.stateHash(), two.stateHash())).isTrue();
        Element stop = one.store().element(NODE, STOPS.element(S4));
        assertThat(stop.position().current().op()).isEqualTo(new OpId(10, 2));
        assertThat(stop.position().losing()).extracting(Stamped::op).containsExactly(S4, new OpId(10, 1));
        assertThat(one.register(NODE, STOPS.element(S4).child(3)).op()).isEqualTo(new OpId(10, 3));
    }

    @Test
    void deleteVersusEditAndRestore() {
        Engine engine = withStops();
        engine.apply(change(1, 10, deleteElements(NODE, true, STOPS.element(S2), STOPS.element(new OpId(50, 5)))));
        engine.apply(change(2, 10, set(NODE, stops(Wire.message().varint(2, 1)), STOPS.element(S2))));
        Element stop = engine.store().element(NODE, STOPS.element(S2));
        assertThat(stop.isDeleted()).isTrue();
        assertThat(engine.register(NODE, STOPS.element(S2).child(3))).as("a whole-element write clears absent leaves")
                .isEqualTo(new Register(null, new OpId(10, 2)));
        engine.apply(change(1, 11, deleteElements(NODE, false, STOPS.element(S2))));
        engine.apply(change(1, 11, deleteElements(NODE, false, STOPS.element(S2))));
        assertThat(engine.store().element(NODE, STOPS.element(S2)).isDeleted()).isFalse();
        assertThat(engine.store().element(NODE, STOPS.element(S3)).isDeleted()).isFalse();
        assertThat(engine.store().element(NODE, STOPS.element(S2)).deleted().writes()).hasSize(2);
    }

    @Test
    void nestedSequencesGoThroughTheirParentElement() {
        Engine engine = new Engine(TestKinds.schema());
        engine.apply(change(1, 1, TestKinds.create(Wire.message()),
                insert(NODE, CONTOURS, props(Wire.message().message(7, Wire.message().varint(2, 1).message(3,
                        Wire.message().fixed64(3, 5)))), 0x80)));
        RegisterPath anchors = CONTOURS.element(S2).child(3);
        engine.apply(change(1, 3, insert(NODE, anchors,
                props(Wire.message().message(7, Wire.message().message(3, Wire.message().fixed64(3, 7)))), 0x80, 0x90)));
        assertThat(engine.store().elementOrder(NODE, anchors)).containsExactly(S3, S4);
        assertThat(engine.register(NODE, CONTOURS.element(S2).child(2)).isSet()).isTrue();
        assertThat(engine.store().elementOrder(NODE, anchors.parent().child(9))).isEmpty();
        assertThat(engine.register(NODE, anchors.element(S3).child(3)).value())
                .isEqualTo(Wire.message().fixed64(3, 7).build());
        engine.apply(change(2, 5, set(NODE, props(Wire.message().message(7, Wire.message().message(3,
                Wire.message().fixed64(3, 9)))), anchors.element(S4).child(3))));
        assertThat(engine.register(NODE, anchors.element(S4).child(3)).op()).isEqualTo(new OpId(5, 2));
        engine.apply(change(2, 6, add(NODE, CONTOURS.element(S2).child(5),
                props(Wire.message().message(7, Wire.message().string(5, "t"))))));
        assertThat(engine.store().members(NODE, CONTOURS.element(S2).child(5))).hasSize(1);
    }

    @Test
    void opsOnMissingElementsOrNonSequencesAreNoOps() {
        Engine engine = withStops();
        byte[] before = engine.stateHash();
        OpId missing = new OpId(40, 4);
        engine.apply(change(1, 20,
                moveElement(NODE, STOPS.element(missing), 1),
                moveElement(NODE, STOPS, 1),                                          // not an element
                deleteElements(NODE, true, STOPS.child(3)),                           // field after a sequence
                insert(NODE, CONTOURS.element(missing).child(3), NodeProps.getDefaultInstance(), 1),
                insert(NODE, TAGS, NodeProps.getDefaultInstance(), 1),                // a SET, not a SEQUENCE
                insert(NODE, RegisterPath.of(TestKinds.K, 1, 1), NodeProps.getDefaultInstance(), 1),   // ATOMIC name
                insert(new OpId(9, 9), STOPS, NodeProps.getDefaultInstance(), 1),
                insert(NODE, STOPS, Changes.raw(Wire.message().build()).toBuilder()
                        .setUnknownFields(com.google.protobuf.UnknownFieldSet.newBuilder().addField(9,
                                com.google.protobuf.UnknownFieldSet.Field.newBuilder()
                                        .addGroup(com.google.protobuf.UnknownFieldSet.getDefaultInstance()).build())
                                .build()).build(), 1),
                clear(NODE, STOPS),                                                   // a whole sequence
                clear(NODE, STOPS.element(missing).child(2)),
                clear(NODE, STOPS.element(S2).child(1)),                              // the element id
                clear(NODE, RegisterPath.of(TestKinds.K, 2).element(S2)),             // element after ATOMIC
                clear(NODE, RegisterPath.of(TestKinds.K, 3, 1)),                      // past a SET
                clear(NODE, RegisterPath.of(TestKinds.K, 1).element(S2))));           // element after STRUCT
        assertThat(engine.stateHash()).isEqualTo(before);
    }

    @Test
    void insertsWithoutPositionsAndTextInsertsTakeCounters() {
        Op text = Op.newBuilder().setTextInsert(TextInsert.newBuilder().setChars("a😀b")).build();
        Op empty = Op.newBuilder().setTextInsert(TextInsert.getDefaultInstance()).build();
        assertThat(Engine.counters(text)).isEqualTo(3);
        assertThat(Engine.counters(empty)).isEqualTo(1);
        assertThat(Engine.counters(insert(NODE, STOPS, NodeProps.getDefaultInstance()))).isEqualTo(1);
        Engine engine = new Engine(TestKinds.schema());
        engine.apply(change(1, 1, text, insert(NODE, STOPS, NodeProps.getDefaultInstance())));
        assertThat(engine.clock().max()).isEqualTo(4);
    }
}
