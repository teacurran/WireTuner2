package com.villagecompute.wiretuner.crdt;

import java.io.ByteArrayOutputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.List;
import java.util.Map;
import java.util.NavigableMap;
import java.util.NavigableSet;

/**
 * The deterministic state hash: SHA-256 over the canonical encoding that
 * docs/spec/crdt-model.adoc ("Canonical encoding") defines, byte for byte the same as
 * {@code WTCRDT.StateHash}. All integers are big-endian and fixed width:
 *
 * <pre>
 * state    = u32 node_count, node*                                  nodes ascending by OpId
 * node     = id, u32 kind, tree, flag, u32 register_count, register*,
 *            u32 element_count, element*, u32 set_count, set*, u32 text_count, text*
 * tree     = u8 placed, [id parent, block position, id op]          placed = 1 iff it has a parent
 * flag     = u8 written, [u8 value, id op]                          a deleted register
 * register = block path, id, u8 set, [block value]                  ascending by path
 * element  = block path, block position, id position_op, flag       ascending by path
 * set      = block path, u32 member_count, member*                  ascending by path
 * member   = block value, u32 tag_count, id*                        ascending bytewise; tags ascending
 * text     = block path, u32 char_count, char*, u32 mark_count, mark*   ascending by path
 * char     = id, u32 codepoint, id left_origin, id right_origin, u8 deleted, [id op]   document order
 * mark     = id, anchor start, anchor end, block value              ascending by id
 * anchor   = id, u8 before
 * path     = (0x01, u32 field | 0x02, id)*
 * block    = u32 length, bytes
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
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        Bytes.writeId(out, node);
        Bytes.writeU32(out, store.kind(node));
        Placement placement = store.placement(node);
        out.write(placement == null ? 0 : 1);
        if (placement != null) {
            Bytes.writeId(out, placement.parent());
            Bytes.writeBlock(out, placement.positionBytes());
            Bytes.writeId(out, placement.op());
        }
        writeFlag(out, store.deleted(node));
        NavigableMap<RegisterPath, Register> registers = store.registers(node);
        Bytes.writeU32(out, registers.size());
        for (Map.Entry<RegisterPath, Register> entry : registers.entrySet()) {
            Register register = entry.getValue();
            Bytes.writeBlock(out, entry.getKey().canonicalBytes());
            Bytes.writeId(out, register.op());
            out.write(register.isSet() ? 1 : 0);
            if (register.isSet()) {
                Bytes.writeBlock(out, register.value());
            }
        }
        NavigableMap<RegisterPath, Element> elements = store.elements(node);
        Bytes.writeU32(out, elements.size());
        for (Map.Entry<RegisterPath, Element> entry : elements.entrySet()) {
            Stamped<byte[]> position = entry.getValue().position().current();
            Bytes.writeBlock(out, entry.getKey().canonicalBytes());
            Bytes.writeBlock(out, position.value());
            Bytes.writeId(out, position.op());
            writeFlag(out, entry.getValue().deleted());
        }
        List<RegisterPath> sets = store.setPaths(node);
        Bytes.writeU32(out, sets.size());
        for (RegisterPath path : sets) {
            Bytes.writeBlock(out, path.canonicalBytes());
            List<byte[]> members = store.members(node, path);
            Bytes.writeU32(out, members.size());
            for (byte[] member : members) {
                Bytes.writeBlock(out, member);
                List<OpId> tags = store.liveTags(node, path, member);
                Bytes.writeU32(out, tags.size());
                for (OpId tag : tags) {
                    Bytes.writeId(out, tag);
                }
            }
        }
        List<RegisterPath> texts = store.textPaths(node);
        Bytes.writeU32(out, texts.size());
        for (RegisterPath path : texts) {
            TextSequence text = store.text(node, path);
            Bytes.writeBlock(out, path.canonicalBytes());
            List<OpId> order = text.order();
            Bytes.writeU32(out, order.size());
            for (OpId c : order) {
                TextSequence.Origins origins = text.origins(c);
                Bytes.writeId(out, c);
                Bytes.writeU32(out, text.codepoint(c));
                Bytes.writeId(out, origins.left());
                Bytes.writeId(out, origins.right());
                OpId deleted = text.deletedOp(c);
                out.write(deleted == null ? 0 : 1);
                if (deleted != null) {
                    Bytes.writeId(out, deleted);
                }
            }
            List<TextMark> marks = text.sortedMarks();
            Bytes.writeU32(out, marks.size());
            for (TextMark mark : marks) {
                Bytes.writeId(out, mark.id());
                writeAnchor(out, mark.start());
                writeAnchor(out, mark.end());
                Bytes.writeBlock(out, mark.valueBytes());
            }
        }
        return out.toByteArray();
    }

    private static void writeAnchor(ByteArrayOutputStream out, Anchor anchor) {
        Bytes.writeId(out, anchor.character());
        out.write(anchor.before() ? 1 : 0);
    }

    private static void writeFlag(ByteArrayOutputStream out, Cell<Boolean> cell) {
        out.write(cell == null ? 0 : 1);
        if (cell != null) {
            out.write(cell.current().value() ? 1 : 0);
            Bytes.writeId(out, cell.current().op());
        }
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
