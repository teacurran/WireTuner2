package com.villagecompute.wiretuner.crdt;

/**
 * What one garbage collection dropped (CRDT-010), for logs and tests. Mirrors
 * {@code WTCRDT.Collected}.
 *
 * @param characters character tombstones
 * @param elements sequence elements (tombstones and the elements nested in them)
 * @param moveLogEntries stable move-log entries
 * @param setTags set adds and removes
 * @param nodes compacted nodes, subtrees included
 * @param changes change records folded into the replicas' stable counters
 */
public record Collected(int characters, int elements, int moveLogEntries, int setTags, int nodes, int changes) {

    /** Nothing collected. */
    public static final Collected NONE = new Collected(0, 0, 0, 0, 0, 0);
}
