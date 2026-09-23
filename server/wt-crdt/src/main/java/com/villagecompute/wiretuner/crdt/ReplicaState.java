package com.villagecompute.wiretuner.crdt;

/**
 * What the state knows about one replica ({@code ReplicaState} in doc/v1/snapshot.proto): the
 * highest change seq applied from it, the highest server_seq it has acknowledged -- the greatest
 * {@code base_server_seq} among its changes -- and its stable counter: every op of the replica
 * below it is causally stable (CRDT-010). Mirrors {@code WTCRDT.ReplicaState}.
 */
public record ReplicaState(long seq, long ackedServerSeq, long stableCounter) {

    /** A replica state without a stable counter. */
    public ReplicaState(long seq, long ackedServerSeq) {
        this(seq, ackedServerSeq, 0);
    }

    ReplicaState withStableCounter(long counter) {
        return new ReplicaState(seq, ackedServerSeq, counter);
    }
}
