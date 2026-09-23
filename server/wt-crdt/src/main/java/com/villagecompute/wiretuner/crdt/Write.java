package com.villagecompute.wiretuner.crdt;

import java.util.Arrays;

/**
 * One register write as the change log retains it (docs/spec/crdt-model.adoc, "Merge rules"):
 * the node, the register, the value ({@code null} = unset) and the writing operation. Losing
 * writes stay in the log so the conflict review can show them and offer them back.
 */
public record Write(OpId node, RegisterPath path, byte[] value, OpId op) {

    /** A copy of the value, or {@code null} for unset. */
    @Override
    public byte[] value() {
        return value == null ? null : value.clone();
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof Write write
                && node.equals(write.node)
                && path.equals(write.path)
                && Arrays.equals(value, write.value)
                && op.equals(write.op);
    }

    @Override
    public int hashCode() {
        return ((node.hashCode() * 31 + path.hashCode()) * 31 + Arrays.hashCode(value)) * 31 + op.hashCode();
    }

    @Override
    public String toString() {
        return node + "/" + path + "=" + (value == null ? "unset" : Bytes.hex(value)) + "@" + op;
    }
}
