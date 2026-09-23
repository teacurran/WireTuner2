package com.villagecompute.wiretuner.crdt;

/** A value and the op that wrote it. */
public record Stamped<V>(V value, OpId op) {
}
