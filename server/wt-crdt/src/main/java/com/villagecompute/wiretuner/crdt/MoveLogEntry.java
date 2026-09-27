package com.villagecompute.wiretuner.crdt;

import java.util.Arrays;
import java.util.Objects;

/**
 * One tree op as the move log records it ({@code MoveLogEntry} in doc/v1/snapshot.proto): what
 * the op asked for, the node's placement before it ({@code null}: none, or not applied), and
 * whether it applied.
 */
public record MoveLogEntry(OpId op, OpId node, OpId parent, byte[] position, boolean creates,
        Placement old, boolean applied) {

    @Override
    public boolean equals(Object other) {
        return other instanceof MoveLogEntry(var thatOp, var thatNode, var thatParent, var thatPosition,
                var thatCreates, var thatOld, var thatApplied)
                && Objects.equals(op, thatOp)
                && Objects.equals(node, thatNode)
                && Objects.equals(parent, thatParent)
                && Arrays.equals(position, thatPosition)
                && creates == thatCreates
                && Objects.equals(old, thatOld)
                && applied == thatApplied;
    }

    @Override
    public int hashCode() {
        return Objects.hash(op, node, parent, Arrays.hashCode(position), creates, old, applied);
    }

    /** {@inheritDoc} Byte arrays show as hex. */
    @Override
    public String toString() {
        return "MoveLogEntry[op=" + op
                + ", node=" + node
                + ", parent=" + parent
                + ", position=" + Bytes.show(position)
                + ", creates=" + creates
                + ", old=" + old
                + ", applied=" + applied + "]";
    }

    MoveLogEntry withOutcome(Placement old, boolean applied) {
        return new MoveLogEntry(op, node, parent, position, creates, old, applied);
    }
}
