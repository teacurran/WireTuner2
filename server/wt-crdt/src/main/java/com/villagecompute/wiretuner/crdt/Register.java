package com.villagecompute.wiretuner.crdt;

import java.util.Arrays;

/**
 * A last-writer-wins register (docs/spec/crdt-model.adoc, "Merge rules"): a value and the id of
 * the operation that wrote it. {@code value} is {@code null} when the register holds
 * <em>unset</em> -- a clear competes with concurrent writes like any other value. Otherwise it
 * is the field's protobuf records exactly as the operation carried them (tag and payload, every
 * occurrence in order), so a reader decodes it with the generated message types and a field
 * newer than this replica is kept byte for byte.
 */
public record Register(byte[] value, OpId op) {

    /** Whether the register holds a value rather than unset. */
    public boolean isSet() {
        return value != null;
    }

    /** A copy of the value, or {@code null} for unset. */
    @Override
    public byte[] value() {
        return value == null ? null : value.clone();
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof Register register
                && Arrays.equals(value, register.value)
                && op.equals(register.op);
    }

    @Override
    public int hashCode() {
        return 31 * Arrays.hashCode(value) + op.hashCode();
    }

    @Override
    public String toString() {
        return (value == null ? "unset" : Bytes.hex(value)) + "@" + op;
    }
}
