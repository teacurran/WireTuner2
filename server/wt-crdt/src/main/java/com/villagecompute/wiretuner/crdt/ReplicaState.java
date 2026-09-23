package com.villagecompute.wiretuner.crdt;

/**
 * What the state knows about one replica ({@code ReplicaState} in doc/v1/snapshot.proto): the
 * highest change seq applied from it, and the highest server_seq it has acknowledged -- the
 * greatest {@code base_server_seq} among its changes. Mirrors {@code WTCRDT.ReplicaState}.
 */
public record ReplicaState(long seq, long ackedServerSeq) {
}
