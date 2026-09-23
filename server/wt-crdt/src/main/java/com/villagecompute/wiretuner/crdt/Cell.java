package com.villagecompute.wiretuner.crdt;

import java.util.ArrayList;
import java.util.List;

/**
 * A last-writer-wins register outside the field-path registers: a node's {@code deleted} flag, a
 * sequence element's position and {@code deleted} flag (docs/spec/crdt-model.adoc, "Merge
 * rules"). Like a register it retains every write. Mirrors {@code WTCRDT.Cell}.
 */
public final class Cell<V> {

    private Stamped<V> current;
    private final List<Stamped<V>> writes = new ArrayList<>();

    Cell(V value, OpId op) {
        current = new Stamped<>(value, op);
        writes.add(current);
    }

    /** Applies a write by the last-writer-wins rule; a replay of an op already written is ignored. */
    void write(V value, OpId op) {
        for (Stamped<V> seen : writes) {
            if (seen.op().equals(op)) {
                return;
            }
        }
        Stamped<V> write = new Stamped<>(value, op);
        writes.add(write);
        if (op.compareTo(current.op()) > 0) {
            current = write;
        }
    }

    /** The winning write: the greatest OpId. */
    public Stamped<V> current() {
        return current;
    }

    /** Every write, in arrival order. */
    public List<Stamped<V>> writes() {
        return List.copyOf(writes);
    }

    /** The writes that do not hold the cell, in OpId order. */
    public List<Stamped<V>> losing() {
        return writes.stream()
                .filter(write -> !write.op().equals(current.op()))
                .sorted((a, b) -> a.op().compareTo(b.op()))
                .toList();
    }
}
