package com.villagecompute.wiretuner.crdt;

import com.google.protobuf.ByteString;
import com.google.protobuf.InvalidProtocolBufferException;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.CommonProps;
import com.villagecompute.wiretuner.doc.v1.CreateNode;
import com.villagecompute.wiretuner.doc.v1.GroupProps;
import com.villagecompute.wiretuner.doc.v1.LayerProps;
import com.villagecompute.wiretuner.doc.v1.MoveNode;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.SetDeleted;
import com.villagecompute.wiretuner.doc.v1.SetFields;

/** Builders for the changes the engine tests apply. */
final class Changes {

    static final RegisterPath NAME = RegisterPath.of(150, 1, 1);
    static final RegisterPath LOCKED = RegisterPath.of(150, 1, 3);
    static final RegisterPath TRANSFORM = RegisterPath.of(150, 1, 4);
    static final RegisterPath URL = RegisterPath.of(150, 1, 6);
    static final RegisterPath WRAP = RegisterPath.of(150, 1, 13);

    private Changes() {
    }

    static Change change(long replica, long start, Op... ops) {
        Change.Builder change = Change.newBuilder().setReplica(replica).setSeq(1).setStartCounter(start);
        for (Op op : ops) {
            change.addOps(op);
        }
        return change.build();
    }

    static Op create(NodeProps props) {
        return Op.newBuilder()
                .setCreate(CreateNode.newBuilder().setParent(OpId.wellKnown(4).toProto()).setProps(props))
                .build();
    }

    static Op createUnder(OpId parent, int position, NodeProps props) {
        return Op.newBuilder().setCreate(CreateNode.newBuilder().setParent(parent.toProto())
                .setPosition(ByteString.copyFrom(new byte[] {(byte) position})).setProps(props)).build();
    }

    static Op move(OpId node, OpId parent, int position) {
        return Op.newBuilder().setMove(MoveNode.newBuilder().setNode(node.toProto()).setParent(parent.toProto())
                .setPosition(ByteString.copyFrom(new byte[] {(byte) position}))).build();
    }

    static Op setDeleted(OpId node, boolean deleted) {
        return Op.newBuilder().setSetDeleted(SetDeleted.newBuilder().setNode(node.toProto()).setDeleted(deleted)).build();
    }

    static NodeProps group() {
        return NodeProps.newBuilder().setGroup(GroupProps.getDefaultInstance()).build();
    }

    static Op set(OpId node, NodeProps values, RegisterPath... paths) {
        SetFields.Builder set = SetFields.newBuilder().setNode(node.toProto()).setValues(values);
        for (RegisterPath path : paths) {
            set.addPaths(path.toProto());
        }
        return Op.newBuilder().setSet(set).build();
    }

    static Op clear(OpId node, RegisterPath... paths) {
        return set(node, NodeProps.getDefaultInstance(), paths);
    }

    static NodeProps layer(CommonProps.Builder common) {
        return NodeProps.newBuilder().setLayer(LayerProps.newBuilder().setCommon(common)).build();
    }

    /** A NodeProps holding arbitrary wire bytes (kept as unknown fields where they are unknown). */
    static NodeProps raw(byte[] bytes) {
        try {
            return NodeProps.parseFrom(bytes);
        } catch (InvalidProtocolBufferException e) {
            throw new IllegalArgumentException(e);
        }
    }
}
