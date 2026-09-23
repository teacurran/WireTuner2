import CryptoKit
import Foundation

/// The deterministic state hash: SHA-256 over the canonical encoding that
/// docs/spec/crdt-model.adoc ("Canonical encoding") defines, byte for byte the same as wt-crdt's
/// `StateHash`.  All integers are big-endian and fixed width:
///
///     state    = u32 node_count, node*                                  nodes ascending by OpId
///     node     = id, u32 kind, tree, flag, u32 register_count, register*,
///                u32 element_count, element*, u32 set_count, set*, u32 text_count, text*
///     tree     = u8 placed, [id parent, block position, id op]          placed = 1 iff it has a parent
///     flag     = u8 written, [u8 value, id op]                          a deleted register
///     register = block path, id, u8 set, [block value]                  ascending by path
///     element  = block path, block position, id position_op, flag       ascending by path
///     set      = block path, u32 member_count, member*                  ascending by path
///     member   = block value, u32 tag_count, id*                        ascending bytewise; tags ascending
///     text     = block path, u32 char_count, char*, u32 mark_count, mark*   ascending by path
///     char     = id, u32 codepoint, id left_origin, id right_origin, u8 deleted, [id op]   document order
///     mark     = id, anchor start, anchor end, block value              ascending by id
///     anchor   = id, u8 before
///     path     = (0x01, u32 field | 0x02, id)*
///     block    = u32 length, bytes
///     id       = u64 counter, u64 replica
public enum StateHash {
    /// The state hash of `store`: 32 bytes.
    public static func of(_ store: NodeStore) -> [UInt8] {
        let nodes = store.nodes
        var count: [UInt8] = []
        Bytes.u32(UInt32(nodes.count), into: &count)
        var hasher = SHA256()
        hasher.update(data: count)
        // Node encodings are independent: large states encode in parallel runs, hashed in order.
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, nodes.count / 1_024))
        var runs = [[UInt8]](repeating: [], count: workers)
        runs.withUnsafeMutableBufferPointer { slots in
            let slots = UnsafeSendable(slots)
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                var out: [UInt8] = []
                for index in (nodes.count * worker / workers)..<(nodes.count * (worker + 1) / workers) {
                    out.append(contentsOf: encode(store, nodes[index]))
                }
                slots.value[worker] = out
            }
        }
        for run in runs {
            hasher.update(data: run)
        }
        return Array(hasher.finalize())
    }

    /// SHA-256 of one node's encoding (`node` above): what a divergence report compares to name
    /// the first differing node.
    public static func of(_ store: NodeStore, node: OpID) -> [UInt8] {
        Bytes.sha256(encode(store, node))
    }

    /// Lower-case hex, as vectors spell hashes.
    public static func hex(_ hash: [UInt8]) -> String {
        Bytes.hex(hash)
    }

    static func encode(_ store: NodeStore, _ node: OpID) -> [UInt8] {
        var out: [UInt8] = []
        Bytes.id(node, into: &out)
        Bytes.u32(store.kind(node), into: &out)
        if let placement = store.placement(node) {
            out.append(1)
            Bytes.id(placement.parent, into: &out)
            Bytes.block(placement.position, into: &out)
            Bytes.id(placement.op, into: &out)
        } else {
            out.append(0)
        }
        flag(store.deleted(node), into: &out)
        let registers = store.registers(node)
        Bytes.u32(UInt32(registers.count), into: &out)
        for (path, register) in registers {
            Bytes.block(path.canonical, into: &out)
            Bytes.id(register.op, into: &out)
            if let value = register.value {
                out.append(1)
                Bytes.block(value, into: &out)
            } else {
                out.append(0)
            }
        }
        let elements = store.elements(node)
        Bytes.u32(UInt32(elements.count), into: &out)
        for (path, element) in elements {
            Bytes.block(path.canonical, into: &out)
            Bytes.block(element.position.current.value, into: &out)
            Bytes.id(element.position.current.op, into: &out)
            flag(element.deleted, into: &out)
        }
        let sets = store.setPaths(node)
        Bytes.u32(UInt32(sets.count), into: &out)
        for path in sets {
            Bytes.block(path.canonical, into: &out)
            let members = store.members(node, path)
            Bytes.u32(UInt32(members.count), into: &out)
            for member in members {
                Bytes.block(member, into: &out)
                let tags = store.liveTags(node, path, member)
                Bytes.u32(UInt32(tags.count), into: &out)
                for tag in tags {
                    Bytes.id(tag, into: &out)
                }
            }
        }
        let texts = store.textPaths(node)
        Bytes.u32(UInt32(texts.count), into: &out)
        for path in texts {
            let text = store.text(node, path)!
            Bytes.block(path.canonical, into: &out)
            let order = text.order
            Bytes.u32(UInt32(order.count), into: &out)
            for char in order {
                let origins = text.origins(char)!
                Bytes.id(char, into: &out)
                Bytes.u32(text.codepoint(char)!, into: &out)
                Bytes.id(origins.left, into: &out)
                Bytes.id(origins.right, into: &out)
                if let deleted = text.deletedOp(char) {
                    out.append(1)
                    Bytes.id(deleted, into: &out)
                } else {
                    out.append(0)
                }
            }
            let marks = text.sortedMarks
            Bytes.u32(UInt32(marks.count), into: &out)
            for mark in marks {
                Bytes.id(mark.id, into: &out)
                anchor(mark.start, into: &out)
                anchor(mark.end, into: &out)
                Bytes.block(mark.value, into: &out)
            }
        }
        return out
    }

    private static func anchor(_ anchor: Anchor, into out: inout [UInt8]) {
        Bytes.id(anchor.char, into: &out)
        out.append(anchor.before ? 1 : 0)
    }

    private static func flag(_ cell: Cell<Bool>?, into out: inout [UInt8]) {
        guard let current = cell?.current else {
            out.append(0)
            return
        }
        out.append(1)
        out.append(current.value ? 1 : 0)
        Bytes.id(current.op, into: &out)
    }
}
