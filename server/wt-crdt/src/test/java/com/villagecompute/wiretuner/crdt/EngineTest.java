package com.villagecompute.wiretuner.crdt;

import static com.villagecompute.wiretuner.crdt.Changes.LOCKED;
import static com.villagecompute.wiretuner.crdt.Changes.NAME;
import static com.villagecompute.wiretuner.crdt.Changes.TRANSFORM;
import static com.villagecompute.wiretuner.crdt.Changes.URL;
import static com.villagecompute.wiretuner.crdt.Changes.WRAP;
import static com.villagecompute.wiretuner.crdt.Changes.change;
import static com.villagecompute.wiretuner.crdt.Changes.clear;
import static com.villagecompute.wiretuner.crdt.Changes.create;
import static com.villagecompute.wiretuner.crdt.Changes.layer;
import static com.villagecompute.wiretuner.crdt.Changes.raw;
import static com.villagecompute.wiretuner.crdt.Changes.set;
import static org.assertj.core.api.Assertions.assertThat;


import com.google.protobuf.UnknownFieldSet;
import com.villagecompute.wiretuner.doc.v1.CommonProps;
import com.villagecompute.wiretuner.doc.v1.ElementId;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.MoveNode;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Noop;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.PathSegment;
import com.villagecompute.wiretuner.doc.v1.SetFields;
import com.villagecompute.wiretuner.doc.v1.TextWrap;
import com.villagecompute.wiretuner.doc.v1.Transform;
import java.util.Arrays;
import org.junit.jupiter.api.Test;

class EngineTest {

    private static final OpId LAYER = new OpId(1, 7);

    private static Engine withLayer() {
        Engine engine = new Engine();
        engine.apply(change(7, 1, create(layer(CommonProps.newBuilder().setName("Layer 1")))));
        return engine;
    }

    private static byte[] value(NodeProps props, RegisterPath path) {
        return path.valueIn(props.toByteArray());
    }

    @Test
    void versionIsTheDeclaredConstant() {
        assertThat(Engine.version()).isEqualTo(Engine.ENGINE_VERSION).matches("\\d+\\.\\d+\\.\\d+");
        assertThat(new Engine().schema().kinds()).isEqualTo(Schema.generated().kinds());
    }

    @Test
    void createNodeSetsItsKindAndThePresentLeavesOnly() {
        NodeProps props = layer(CommonProps.newBuilder().setName("L").setTransform(Transform.newBuilder().setA(1)));
        Engine engine = new Engine();
        engine.apply(change(7, 1, create(props)));

        assertThat(engine.store().kind(LAYER)).isEqualTo(150);
        assertThat(engine.store().registers(LAYER).keySet()).containsExactly(NAME, TRANSFORM);
        assertThat(engine.register(LAYER, NAME)).isEqualTo(new Register(value(props, NAME), LAYER));
        assertThat(engine.clock().max()).isEqualTo(1);

        byte[] before = engine.stateHash();
        engine.apply(change(7, 1, create(layer(CommonProps.newBuilder().setName("again")))));
        assertThat(engine.stateHash()).as("a node is created once").isEqualTo(before);
    }

    @Test
    void createNodeWithoutAKnownKindCreatesNothing() {
        Engine engine = new Engine();
        NodeProps group = NodeProps.newBuilder()
                .setUnknownFields(UnknownFieldSet.newBuilder()
                        .addField(5, UnknownFieldSet.Field.newBuilder().addGroup(UnknownFieldSet.getDefaultInstance()).build())
                        .build())
                .build();
        engine.apply(change(1, 1,
                create(NodeProps.getDefaultInstance()),
                create(raw(Wire.message().string(999, "x").build())),
                create(group),
                create(raw(Wire.message().varint(150, 3).build()))));

        assertThat(engine.store().nodes()).isEmpty();
        assertThat(engine.clock().max()).isEqualTo(4);
    }

    @Test
    void greaterOpIdWinsAndLosersAreRetained() {
        Engine engine = withLayer();
        Op alice = set(LAYER, layer(CommonProps.newBuilder().setName("Alice")), NAME);
        Op bob = set(LAYER, layer(CommonProps.newBuilder().setName("Bob")), NAME);
        engine.apply(change(2, 5, bob));
        engine.apply(change(1, 5, alice));
        engine.apply(change(2, 5, bob));           // replay: ignored entirely

        assertThat(engine.register(LAYER, NAME).op()).isEqualTo(new OpId(5, 2));
        assertThat(engine.losingWrites(LAYER, NAME)).extracting(Write::op).containsExactly(LAYER, new OpId(5, 1));
        assertThat(engine.store().writes(LAYER, NAME)).hasSize(3);
        assertThat(engine.clock().peek()).isEqualTo(6);
    }

    @Test
    void aPathWithoutAValueClears() {
        Engine engine = withLayer();
        engine.apply(change(1, 2, clear(LAYER, NAME)));

        assertThat(engine.register(LAYER, NAME)).isEqualTo(new Register(null, new OpId(2, 1)));
        engine.apply(change(1, 3, set(LAYER, layer(CommonProps.newBuilder().setUrl("u")), URL, LOCKED)));
        assertThat(engine.register(LAYER, LOCKED).isSet()).as("proto3 default reads as unset").isFalse();
        assertThat(engine.register(LAYER, URL).isSet()).isTrue();
    }

    @Test
    void aStructPathWritesEveryLeafBeneathIt() {
        Engine engine = withLayer();
        engine.apply(change(1, 2, set(LAYER,
                layer(CommonProps.newBuilder().setTextWrap(TextWrap.newBuilder().setEnabled(true))), WRAP)));

        assertThat(engine.register(LAYER, WRAP.child(1)).isSet()).isTrue();
        assertThat(engine.register(LAYER, WRAP.child(2))).isEqualTo(new Register(null, new OpId(2, 1)));

        engine.apply(change(1, 3, clear(LAYER, RegisterPath.of(150, 1))));
        assertThat(engine.store().registers(LAYER).values()).allMatch(register -> register.op().equals(new OpId(3, 1)));
        assertThat(engine.register(LAYER, RegisterPath.of(150, 1, 5))).as("NodeRef canvas is one register").isNotNull();
    }

    @Test
    void opsNamingNothingUsableAreNoOps() {
        Engine engine = withLayer();
        byte[] before = engine.stateHash();
        NodeProps name = layer(CommonProps.newBuilder().setName("x"));
        FieldPath elementHead = FieldPath.newBuilder()
                .addSegments(PathSegment.newBuilder().setElement(ElementId.newBuilder().setCounter(1))).build();
        FieldPath elementLater = NAME.toProto().toBuilder()
                .setSegments(1, PathSegment.newBuilder().setElement(ElementId.newBuilder().setCounter(1))).build();
        NodeProps groupValues = NodeProps.newBuilder()
                .setUnknownFields(UnknownFieldSet.newBuilder()
                        .addField(9, UnknownFieldSet.Field.newBuilder().addGroup(UnknownFieldSet.getDefaultInstance()).build())
                        .build())
                .build();
        engine.apply(change(1, 2,
                set(new OpId(99, 9), name, NAME),                          // unknown node
                set(OpId.wellKnown(4), name, NAME),                        // collection without props
                set(LAYER, name, RegisterPath.of(3, 1, 1)),                // wrong kind
                set(LAYER, name, NAME.child(1)),                           // past an ATOMIC field
                set(LAYER, name, RegisterPath.of(150, 1, 5, 1)),           // into a NodeRef
                set(LAYER, name, RegisterPath.of(150, 1, 999)),            // unknown field
                set(LAYER, groupValues, NAME),                             // malformed values
                Op.newBuilder().setSet(SetFields.newBuilder().setNode(LAYER.toProto())
                        .addPaths(FieldPath.getDefaultInstance())
                        .addPaths(elementHead)
                        .addPaths(elementLater)).build(),
                Op.newBuilder().setNoop(Noop.getDefaultInstance()).build(),
                Op.newBuilder().setMove(MoveNode.getDefaultInstance()).build(),   // a well-known node
                Op.getDefaultInstance()));

        assertThat(engine.stateHash()).isEqualTo(before);
        assertThat(engine.clock().max()).isEqualTo(12);
    }

    @Test
    void wellKnownDocumentAndSettingsTakeWrites() {
        Engine engine = new Engine();
        engine.apply(change(1, 1,
                set(OpId.ZERO, raw(Wire.message().message(1, Wire.message().message(1, Wire.message().string(1, "Doc"))).build()),
                        RegisterPath.of(1, 1, 1)),
                set(OpId.wellKnown(1), raw(Wire.message().message(2, Wire.message().message(1, Wire.message().varint(3, 1))).build()),
                        RegisterPath.of(2, 1, 3))));

        assertThat(engine.store().nodes()).containsExactly(OpId.ZERO, OpId.wellKnown(1));
        assertThat(engine.register(OpId.wellKnown(1), RegisterPath.of(2, 1, 3)).value()).containsExactly(0x18, 1);
    }

    @Test
    void variantsWriteOnlyThePresentCasesAndClearEveryCase() {
        Engine engine = new Engine(Tables.shapes());
        engine.apply(change(1, 1, create(raw(Wire.message().message(Tables.K, Wire.message().string(1, "k")).build()))));
        OpId node = new OpId(1, 1);
        RegisterPath v = RegisterPath.of(Tables.K, 6);

        // kind = 1 with case c1: kind, c1.x and the non-case note are written; c2 is left alone.
        engine.apply(change(1, 2, set(node, raw(Wire.message().message(Tables.K, Wire.message().message(6,
                Wire.message().varint(1, 1).message(2, Wire.message().fixed64(1, 5)))).build()), v)));
        assertThat(engine.store().registers(node).keySet())
                .containsExactly(RegisterPath.of(Tables.K, 1), v.child(1), v.child(2).child(1), v.child(4));

        engine.apply(change(1, 3, clear(node, v)));
        assertThat(engine.register(node, v.child(3).child(1))).isEqualTo(new Register(null, new OpId(3, 1)));
        assertThat(engine.register(node, v.child(2).child(1)).op()).isEqualTo(new OpId(3, 1));
    }

    @Test
    void recursiveAndNonRegisterFieldsAreSkippedOrRejected() {
        Engine engine = new Engine(Tables.shapes());
        engine.apply(change(1, 1, create(raw(Wire.message().message(Tables.K,
                Wire.message().string(1, "k").message(2, Wire.message().string(1, "inner"))).build()))));
        OpId node = new OpId(1, 1);
        // CreateNode enters the recursive message once (present leaves only).
        assertThat(engine.store().registers(node).keySet()).containsExactly(RegisterPath.of(Tables.K, 1));

        engine.apply(change(1, 2, set(node, raw(Wire.message().message(Tables.K, Wire.message().message(2,
                Wire.message().string(1, "deep"))).build()), RegisterPath.of(Tables.K, 2, 1))));
        assertThat(engine.register(node, RegisterPath.of(Tables.K, 2, 1)).op()).isEqualTo(new OpId(2, 1));

        byte[] before = engine.stateHash();
        engine.apply(change(1, 3,
                clear(node, RegisterPath.of(Tables.K, 3)),        // SEQUENCE
                clear(node, RegisterPath.of(Tables.K, 4, 1)),     // repeated STRUCT
                clear(node, RegisterPath.of(Tables.K, 5)),        // STRUCT without a type
                clear(node, RegisterPath.of(Tables.K, 8))));      // repeated NodeRef
        assertThat(engine.stateHash()).isEqualTo(before);

        engine.apply(change(1, 4, clear(node, RegisterPath.of(Tables.K))));
        assertThat(engine.store().registers(node).keySet()).containsExactly(
                RegisterPath.of(Tables.K, 1), RegisterPath.of(Tables.K, 2, 1), RegisterPath.of(Tables.K, 6, 1), RegisterPath.of(Tables.K, 6, 2, 1),
                RegisterPath.of(Tables.K, 6, 3, 1), RegisterPath.of(Tables.K, 6, 4), RegisterPath.of(Tables.K, 7));
        assertThat(engine.register(node, RegisterPath.of(Tables.K, 2, 1)).op()).as("the recursive field is not expanded")
                .isEqualTo(new OpId(2, 1));
    }

    @Test
    void hashesAreOrderIndependent() {
        Op a = set(LAYER, layer(CommonProps.newBuilder().setName("A")), NAME);
        Op b = set(LAYER, layer(CommonProps.newBuilder().setLocked(true)), LOCKED);
        Engine one = withLayer();
        one.apply(change(1, 2, a));
        one.apply(change(2, 2, b));
        Engine two = withLayer();
        two.apply(change(2, 2, b));
        two.apply(change(1, 2, a));

        assertThat(Arrays.equals(one.stateHash(), two.stateHash())).isTrue();
    }
}
