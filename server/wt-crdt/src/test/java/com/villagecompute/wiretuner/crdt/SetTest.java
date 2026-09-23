package com.villagecompute.wiretuner.crdt;

import static com.villagecompute.wiretuner.crdt.TestKinds.CODES;
import static com.villagecompute.wiretuner.crdt.TestKinds.NODES;
import static com.villagecompute.wiretuner.crdt.TestKinds.POINTS;
import static com.villagecompute.wiretuner.crdt.TestKinds.TAGS;
import static com.villagecompute.wiretuner.crdt.TestKinds.add;
import static com.villagecompute.wiretuner.crdt.TestKinds.props;
import static com.villagecompute.wiretuner.crdt.TestKinds.remove;
import static org.assertj.core.api.Assertions.assertThat;

import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Op;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.List;
import org.junit.jupiter.api.Test;

class SetTest {

    private static final OpId NODE = new OpId(1, 1);

    private static Change change(long replica, long seq, long start, long base, Op... ops) {
        return Change.newBuilder().setReplica(replica).setSeq(seq).setStartCounter(start).setBaseServerSeq(base)
                .addAllOps(List.of(ops)).build();
    }

    private static NodeProps tag(String value) {
        return props(Wire.message().string(3, value));
    }

    private static byte[] utf8(String value) {
        return value.getBytes(StandardCharsets.UTF_8);
    }

    /** The node (server_seq 1) and "a" added by replica 1 (server_seq 2). */
    private static Engine withA() {
        Engine engine = new Engine(TestKinds.schema());
        engine.apply(change(1, 1, 1, 0, TestKinds.create(Wire.message().string(2, "n"))), 1L);
        engine.apply(change(1, 2, 2, 1, add(NODE, TAGS, tag("a"))), 2L);
        return engine;
    }

    @Test
    void aConcurrentAddAndRemoveKeepTheMember() {
        Change removeA = change(2, 1, 3, 2, remove(NODE, TAGS, tag("a")));   // saw the add
        Change addA = change(3, 1, 3, 2, add(NODE, TAGS, tag("a")));         // concurrent re-add
        Engine one = withA();
        one.apply(removeA, 3L);
        assertThat(one.store().members(NODE, TAGS)).isEmpty();
        one.apply(addA, 4L);
        Engine two = withA();
        two.apply(addA);
        two.apply(removeA);
        assertThat(one.store().members(NODE, TAGS)).containsExactly(utf8("a"));
        assertThat(one.store().liveTags(NODE, TAGS, utf8("a"))).containsExactly(new OpId(3, 3));
        assertThat(Arrays.equals(one.stateHash(), two.stateHash())).isTrue();
    }

    @Test
    void aRemoveOnlyRemovesTheAddsInItsCausalPast() {
        Engine engine = withA();
        engine.apply(change(2, 1, 3, 1, remove(NODE, TAGS, tag("a"))));      // base 1: never saw the add
        assertThat(engine.store().members(NODE, TAGS)).containsExactly(utf8("a"));
        engine.apply(change(2, 1, 3, 1, remove(NODE, TAGS, tag("a"))));      // replay
        engine.apply(change(4, 1, 9, 5, remove(NODE, TAGS, tag("b"))));      // a member never added
        assertThat(engine.store().members(NODE, TAGS)).containsExactly(utf8("a"));
        assertThat(engine.store().liveTags(NODE, TAGS, utf8("zzz"))).isEmpty();
        assertThat(engine.store().liveTags(new OpId(9, 9), TAGS, utf8("a"))).isEmpty();
    }

    @Test
    void theSameReplicaRemovesItsEarlierAddsAndReAddsAfter() {
        Engine engine = new Engine(TestKinds.schema());
        engine.apply(change(1, 1, 1, 0, TestKinds.create(Wire.message()), add(NODE, TAGS, tag("x")),
                remove(NODE, TAGS, tag("x"))));
        assertThat(engine.store().members(NODE, TAGS)).isEmpty();
        assertThat(engine.store().setPaths(NODE)).isEmpty();
        engine.apply(change(1, 2, 4, 0, add(NODE, TAGS, tag("x")), add(NODE, TAGS, tag("x"))));
        assertThat(engine.store().members(NODE, TAGS)).containsExactly(utf8("x"));
        assertThat(engine.store().setPaths(NODE)).containsExactly(TAGS);
    }

    @Test
    void aLateAcknowledgementMakesTheAddObserved() {
        Engine engine = new Engine(TestKinds.schema());
        engine.apply(change(1, 1, 1, 0, TestKinds.create(Wire.message())), 1L);
        engine.apply(change(1, 2, 2, 1, add(NODE, TAGS, tag("y"))));           // local, not yet acked
        engine.apply(change(2, 1, 3, 2, remove(NODE, TAGS, tag("y"))), 3L);    // saw server_seq 2
        assertThat(engine.store().members(NODE, TAGS)).containsExactly(utf8("y"));
        engine.acknowledge(1, 2, 2);
        assertThat(engine.store().members(NODE, TAGS)).isEmpty();
    }

    @Test
    void scalarMembersArePackedOrUnpackedValues() {
        Engine engine = withA();
        byte[] packed = Wire.message().raw(1).raw(300).build();
        engine.apply(change(1, 3, 3, 2, add(NODE, CODES, props(Wire.message().bytes(4, packed).varint(4, 7)))));
        engine.apply(change(1, 4, 4, 2, add(NODE, CODES, props(Wire.message().bytes(4, new byte[] {(byte) 0x80}).string(3, "ignored")))));
        assertThat(engine.store().members(NODE, CODES)).containsExactly(
                new byte[] {0, 0, 0, 0, 0, 0, 0, 1}, new byte[] {0, 0, 0, 0, 0, 0, 0, 7},
                new byte[] {0, 0, 0, 0, 0, 0, 1, 44});
        engine.apply(change(1, 5, 5, 2, add(NODE, RegisterPath.of(TestKinds.K, 9),
                props(Wire.message().fixed64(9, 5).bytes(9, new byte[16]).bytes(9, new byte[3]).fixed32(9, 1)))));
        assertThat(engine.store().members(NODE, RegisterPath.of(TestKinds.K, 9))).containsExactly(
                new byte[8], new byte[] {5, 0, 0, 0, 0, 0, 0, 0});
        engine.apply(change(1, 6, 6, 2, add(NODE, RegisterPath.of(TestKinds.K, 10),
                props(Wire.message().fixed32(10, 2).bytes(10, new byte[] {9, 0, 0, 0})))));
        assertThat(engine.store().members(NODE, RegisterPath.of(TestKinds.K, 10))).containsExactly(
                new byte[] {2, 0, 0, 0}, new byte[] {9, 0, 0, 0});
    }

    @Test
    void idMembersAreCounterAndReplica() {
        Engine engine = withA();
        Wire id = Wire.message().varint(1, 3).fixed64(2, 1).varint(1, 4).fixed32(2, 9);
        engine.apply(change(1, 3, 3, 2, add(NODE, POINTS, props(Wire.message().message(5, id)
                .bytes(5, new byte[] {0x08}).varint(5, 1)))));
        engine.apply(change(1, 4, 4, 2, add(NODE, NODES, props(Wire.message().message(6, Wire.message())))));
        assertThat(engine.store().members(NODE, POINTS)).containsExactly(
                new byte[] {0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 1});
        assertThat(engine.store().members(NODE, NODES)).containsExactly(new byte[16]);
    }

    @Test
    void pathsThatDoNotNameASetAreNoOps() {
        Engine engine = withA();
        byte[] before = engine.stateHash();
        engine.apply(change(1, 3, 3, 2,
                add(NODE, RegisterPath.of(TestKinds.K, 2), tag("x")),                         // ATOMIC
                add(NODE, RegisterPath.of(TestKinds.K, 11), props(Wire.message().message(11, Wire.message()))),   // not an id type
                add(new OpId(8, 8), TAGS, tag("x")),                                          // unknown node
                add(NODE, TAGS, Changes.raw(Wire.message().build()).toBuilder()
                        .setUnknownFields(com.google.protobuf.UnknownFieldSet.newBuilder().addField(9,
                                com.google.protobuf.UnknownFieldSet.Field.newBuilder()
                                        .addGroup(com.google.protobuf.UnknownFieldSet.getDefaultInstance()).build())
                                .build()).build())));                                          // malformed values
        engine.apply(change(1, 4, 7, 2, add(NODE, TAGS, NodeProps.getDefaultInstance())));    // no members
        assertThat(engine.stateHash()).isEqualTo(before);
        assertThat(engine.members(tag("q"), TestKinds.K, TAGS.toProto())).containsExactly(utf8("q"));
        assertThat(engine.members(tag("q"), TestKinds.K, RegisterPath.of(TestKinds.K, 2).toProto())).isNull();
        assertThat(engine.members(NodeProps.getDefaultInstance(), TestKinds.K, TAGS.toProto())).isEmpty();
    }
}
