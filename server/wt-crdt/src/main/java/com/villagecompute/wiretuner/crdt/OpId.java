package com.villagecompute.wiretuner.crdt;

/**
 * An operation id (docs/spec/crdt-model.adoc, "Identifiers"): a Lamport {@code counter} and the
 * {@code replica} that created the operation, both unsigned 64-bit values held in {@code long}s.
 * The natural order -- counter, then replica, each compared as an unsigned integer -- is the total
 * order that decides every last-writer-wins tie. It never involves wall-clock time.
 */
public record OpId(long counter, long replica) implements Comparable<OpId> {

    /** The zero id: the document root, and "no id" in wire messages. */
    public static final OpId ZERO = new OpId(0, 0);

    /** The id of a well-known node ({@code WellKnown} in doc/v1/node.proto): replica 0. */
    public static OpId wellKnown(long counter) {
        return new OpId(counter, 0);
    }

    /** Converts the wire message. */
    public static OpId of(com.villagecompute.wiretuner.doc.v1.OpId id) {
        return new OpId(id.getCounter(), id.getReplica());
    }

    /** The wire message for this id. */
    public com.villagecompute.wiretuner.doc.v1.OpId toProto() {
        return com.villagecompute.wiretuner.doc.v1.OpId.newBuilder()
                .setCounter(counter)
                .setReplica(replica)
                .build();
    }

    @Override
    public int compareTo(OpId other) {
        int byCounter = Long.compareUnsigned(counter, other.counter);
        return byCounter != 0 ? byCounter : Long.compareUnsigned(replica, other.replica);
    }

    /** {@code counter:replica} in unsigned decimal, as the spec writes ids. */
    @Override
    public String toString() {
        return Long.toUnsignedString(counter) + ":" + Long.toUnsignedString(replica);
    }
}
