package com.villagecompute.wiretuner.crdt;

import java.util.Arrays;

/**
 * Where a node sits: its parent, its position among the parent's children, and the tree op
 * ({@code CreateNode} or {@code MoveNode}) that put it there.
 */
public record Placement(OpId parent, byte[] position, OpId op) {

    /** A copy of the position. */
    @Override
    public byte[] position() {
        return position.clone();
    }

    byte[] positionBytes() {
        return position;
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof Placement placement
                && parent.equals(placement.parent)
                && Arrays.equals(position, placement.position)
                && op.equals(placement.op);
    }

    @Override
    public int hashCode() {
        return (parent.hashCode() * 31 + Arrays.hashCode(position)) * 31 + op.hashCode();
    }

    @Override
    public String toString() {
        return parent + "/" + Bytes.hex(position) + "@" + op;
    }
}
