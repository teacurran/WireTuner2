package com.villagecompute.wiretuner.crdt;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.FieldPolicy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.Policy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.RefFallback;
import com.villagecompute.wiretuner.doc.v1.ElementDelete;
import com.villagecompute.wiretuner.doc.v1.ElementInsert;
import com.villagecompute.wiretuner.doc.v1.ElementMove;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.SetAdd;
import com.villagecompute.wiretuner.doc.v1.SetRemove;

/**
 * The test kind of crdt-conformance/schema/test-kinds.textproto (NodeProps field 1000) on top of
 * the generated table, and builders for the sequence and set ops the tests apply.
 *
 * <pre>
 * TestProps   1 common STRUCT; 2 label ATOMIC; 3 tags SET string; 4 codes SET uint32;
 *             5 points SET ElementId; 6 nodes SET OpId; 7 contours SEQUENCE TestContour;
 *             8 stops SEQUENCE TestStop; 9 weights SET double; 10 marks SET fixed32;
 *             11 junk SET message (not an id type)
 * TestContour 1 id; 2 closed ATOMIC; 3 anchors SEQUENCE TestPoint; 4 name ATOMIC; 5 tags SET string
 * TestPoint   1 id; 2 anchor ATOMIC Point; 3 weight ATOMIC double
 * TestStop    1 id; 2 offset ATOMIC double; 3 color ATOMIC string
 * </pre>
 */
final class TestKinds {

    static final int K = 1000;
    static final String PROPS = "t.TestProps";
    static final String CONTOUR = "t.TestContour";
    static final String POINT = "t.TestPoint";
    static final String STOP = "t.TestStop";
    static final String ELEMENT_ID = "wiretuner.doc.v1.ElementId";

    static final RegisterPath TAGS = RegisterPath.of(K, 3);
    static final RegisterPath CODES = RegisterPath.of(K, 4);
    static final RegisterPath POINTS = RegisterPath.of(K, 5);
    static final RegisterPath NODES = RegisterPath.of(K, 6);
    static final RegisterPath CONTOURS = RegisterPath.of(K, 7);
    static final RegisterPath STOPS = RegisterPath.of(K, 8);

    private TestKinds() {
    }

    private static FieldPolicy row(int number, Policy policy, String type, boolean repeated, String typeName) {
        return new FieldPolicy(number, "f" + number, policy, RefFallback.UNSET, false, type, repeated, typeName,
                policy == Policy.SEQUENCE ? typeName : null, null);
    }

    static Schema schema() {
        return Schema.generated()
                .withField(Schema.ROOT, new FieldPolicy(K, "test", Policy.STRUCT, RefFallback.UNSET, false, "message",
                        false, PROPS, null, "kind"))
                .withField(PROPS, row(1, Policy.STRUCT, "message", false, "wiretuner.doc.v1.CommonProps"))
                .withField(PROPS, row(2, Policy.ATOMIC, "string", false, null))
                .withField(PROPS, row(3, Policy.SET, "string", true, null))
                .withField(PROPS, row(4, Policy.SET, "uint32", true, null))
                .withField(PROPS, row(5, Policy.SET, "message", true, ELEMENT_ID))
                .withField(PROPS, row(6, Policy.SET, "message", true, "wiretuner.doc.v1.OpId"))
                .withField(PROPS, row(7, Policy.SEQUENCE, "message", true, CONTOUR))
                .withField(PROPS, row(8, Policy.SEQUENCE, "message", true, STOP))
                .withField(PROPS, row(9, Policy.SET, "double", true, null))
                .withField(PROPS, row(10, Policy.SET, "fixed32", true, null))
                .withField(PROPS, row(11, Policy.SET, "message", true, STOP))
                .withField(CONTOUR, row(1, Policy.STRUCT, "message", false, ELEMENT_ID))
                .withField(CONTOUR, row(2, Policy.ATOMIC, "bool", false, null))
                .withField(CONTOUR, row(3, Policy.SEQUENCE, "message", true, POINT))
                .withField(CONTOUR, row(4, Policy.ATOMIC, "string", false, null))
                .withField(CONTOUR, row(5, Policy.SET, "string", true, null))
                .withField(POINT, row(1, Policy.STRUCT, "message", false, ELEMENT_ID))
                .withField(POINT, row(2, Policy.ATOMIC, "message", false, "wiretuner.doc.v1.Point"))
                .withField(POINT, row(3, Policy.ATOMIC, "double", false, null))
                .withField(STOP, row(1, Policy.STRUCT, "message", false, ELEMENT_ID))
                .withField(STOP, row(2, Policy.ATOMIC, "double", false, null))
                .withField(STOP, row(3, Policy.ATOMIC, "string", false, null));
    }

    /** A NodeProps holding {@code inner} as the test kind. */
    static NodeProps props(Wire inner) {
        return Changes.raw(Wire.message().message(K, inner).build());
    }

    static Op create(Wire inner) {
        return Changes.create(props(inner));
    }

    static Op insert(OpId node, RegisterPath sequence, NodeProps values, int... positions) {
        ElementInsert.Builder insert = ElementInsert.newBuilder().setNode(node.toProto())
                .setSequence(sequence.toProto()).setValues(values);
        for (int position : positions) {
            insert.addPositions(ByteString.copyFrom(new byte[] {(byte) position}));
        }
        return Op.newBuilder().setElementInsert(insert).build();
    }

    static Op moveElement(OpId node, RegisterPath element, int position) {
        return Op.newBuilder().setElementMove(ElementMove.newBuilder().setNode(node.toProto())
                .setElement(element.toProto()).setPosition(ByteString.copyFrom(new byte[] {(byte) position}))).build();
    }

    static Op deleteElements(OpId node, boolean deleted, RegisterPath... elements) {
        ElementDelete.Builder delete = ElementDelete.newBuilder().setNode(node.toProto()).setDeleted(deleted);
        for (RegisterPath element : elements) {
            delete.addElements(element.toProto());
        }
        return Op.newBuilder().setElementDelete(delete).build();
    }

    static Op add(OpId node, RegisterPath set, NodeProps values) {
        return Op.newBuilder().setSetAdd(SetAdd.newBuilder().setNode(node.toProto()).setSet(set.toProto())
                .setValues(values)).build();
    }

    static Op remove(OpId node, RegisterPath set, NodeProps values) {
        return Op.newBuilder().setSetRemove(SetRemove.newBuilder().setNode(node.toProto()).setSet(set.toProto())
                .setValues(values)).build();
    }

    static FieldPath path(RegisterPath path) {
        return path.toProto();
    }
}
