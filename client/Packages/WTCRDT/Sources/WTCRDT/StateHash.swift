/// The deterministic state hash: SHA-256 over the canonical encoding of the registers that
/// docs/spec/crdt-model.adoc ("Snapshots", "Canonical encoding") defines, byte for byte the same
/// as wt-crdt's `StateHash`.  All integers are big-endian and fixed width:
///
///     state    = u32 node_count, node*                         nodes ascending by OpId
///     node     = id, u32 kind, u32 register_count, register*   registers ascending by path
///     register = u32 len, path, id, u8 set, [u32 len, value]   set = 1 iff it holds a value
///     path     = (0x01, u32 field)*
///     id       = u64 counter, u64 replica
public enum StateHash {
    /// The state hash of `store`: 32 bytes.
    public static func of(_ store: NodeStore) -> [UInt8] {
        let nodes = store.nodes
        var out: [UInt8] = []
        Bytes.u32(UInt32(nodes.count), into: &out)
        for node in nodes {
            out.append(contentsOf: encode(store, node))
        }
        return Bytes.sha256(out)
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
        let registers = store.registers(node)
        var out: [UInt8] = []
        Bytes.id(node, into: &out)
        Bytes.u32(store.kind(node), into: &out)
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
        return out
    }
}
