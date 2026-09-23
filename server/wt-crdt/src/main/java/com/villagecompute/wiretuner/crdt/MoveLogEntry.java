package com.villagecompute.wiretuner.crdt;

/**
 * One tree op as the move log records it ({@code MoveLogEntry} in doc/v1/snapshot.proto): what
 * the op asked for, the node's placement before it ({@code null}: none, or not applied), and
 * whether it applied.
 */
public record MoveLogEntry(OpId op, OpId node, OpId parent, byte[] position, boolean creates,
        Placement old, boolean applied) {

    MoveLogEntry withOutcome(Placement old, boolean applied) {
        return new MoveLogEntry(op, node, parent, position, creates, old, applied);
    }
}
