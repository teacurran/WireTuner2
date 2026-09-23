package com.villagecompute.wiretuner.crdt;

import java.io.ByteArrayOutputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Map;
import java.util.NavigableMap;
import java.util.NavigableSet;

/**
 * The deterministic state hash: SHA-256 over the canonical encoding of the registers that
 * docs/spec/crdt-model.adoc ("Snapshots", "Canonical encoding") defines, byte for byte the same
 * as {@code WTCRDT.StateHash}. All integers are big-endian and fixed width:
 *
 * <pre>
 * state    = u32 node_count, node*                  nodes ascending by OpId
 * node     = id, u32 kind, u32 register_count, register*   registers ascending by path
 * register = u32 len, path, id, u8 set, [u32 len, value]   set = 1 iff the register holds a value
 * path     = (0x01, u32 field)*
 * id       = u64 counter, u64 replica
 * </pre>
 */
public final class StateHash {

    private StateHash() {
    }

    /** The state hash of {@code store}: 32 bytes. */
    public static byte[] of(NodeStore store) {
        NavigableSet<OpId> nodes = store.nodes();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        Bytes.writeU32(out, nodes.size());
        for (OpId node : nodes) {
            out.writeBytes(encodeNode(store, node));
        }
        return sha256(out.toByteArray());
    }

    /**
     * SHA-256 of one node's encoding ({@code node} above): what a divergence report compares to
     * name the first differing node.
     */
    public static byte[] ofNode(NodeStore store, OpId node) {
        return sha256(encodeNode(store, node));
    }

    /** Lower-case hex, as vectors spell hashes. */
    public static String hex(byte[] hash) {
        return Bytes.hex(hash);
    }

    static byte[] encodeNode(NodeStore store, OpId node) {
        NavigableMap<RegisterPath, Register> registers = store.registers(node);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        Bytes.writeId(out, node);
        Bytes.writeU32(out, store.kind(node));
        Bytes.writeU32(out, registers.size());
        for (Map.Entry<RegisterPath, Register> entry : registers.entrySet()) {
            Register register = entry.getValue();
            Bytes.writeBlock(out, entry.getKey().canonical());
            Bytes.writeId(out, register.op());
            out.write(register.isSet() ? 1 : 0);
            if (register.isSet()) {
                Bytes.writeBlock(out, register.value());
            }
        }
        return out.toByteArray();
    }

    static byte[] sha256(byte[] data) {
        return digest("SHA-256").digest(data);
    }

    static MessageDigest digest(String algorithm) {
        try {
            return MessageDigest.getInstance(algorithm);
        } catch (NoSuchAlgorithmException e) {
            // Every Java platform is required to provide SHA-256 (MessageDigest's javadoc).
            throw new IllegalStateException(algorithm + " is unavailable", e);
        }
    }
}
