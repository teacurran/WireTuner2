package com.villagecompute.wiretuner.crdt;

/**
 * One element of a SEQUENCE field (docs/spec/crdt-model.adoc, "Sequences"): a position register
 * and a {@code deleted} register ({@code null} until an {@code ElementDelete} writes it); its
 * fields are registers under the element's path.
 */
public final class Element {

    private final Cell<byte[]> position;
    private Cell<Boolean> deleted;

    Element(byte[] position, OpId op) {
        this.position = new Cell<>(position, op);
    }

    /** The fractional position among the sequence's elements. */
    public Cell<byte[]> position() {
        return position;
    }

    /** The {@code deleted} register, or {@code null} when never written. */
    public Cell<Boolean> deleted() {
        return deleted;
    }

    /** Whether the element is a tombstone. */
    public boolean isDeleted() {
        return deleted != null && deleted.current().value();
    }

    void delete(boolean value, OpId op) {
        if (deleted == null) {
            deleted = new Cell<>(value, op);
        } else {
            deleted.write(value, op);
        }
    }
}
