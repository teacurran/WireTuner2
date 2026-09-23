/// The merged state: which nodes exist and of what kind, every register keyed by node and
/// `RegisterPath`, and the change log of every write -- winning or losing -- per register.
public struct NodeStore: Sendable {
    /// Kinds of the well-known nodes that carry properties: document (0:0) and settings (0:1).
    private static let wellKnownKinds: [OpID: UInt32] = [.wellKnown(0): 1, .wellKnown(1): 2]
    /// Well-known nodes use replica 0 and counters below this (crdt-model.adoc, "The node tree").
    static let wellKnownLimit: UInt64 = 16

    private var created: [OpID: UInt32] = [:]
    private var registers: [OpID: [RegisterPath: Register]] = [:]
    private var log: [OpID: [RegisterPath: [Write]]] = [:]

    public init() {}

    /// The kind of `node` (the field number of its `NodeProps.kind` case), or 0 when the node does
    /// not exist or is a well-known collection without properties.
    public func kind(_ node: OpID) -> UInt32 {
        created[node] ?? Self.wellKnownKinds[node] ?? 0
    }

    /// Whether `node` was created or is a well-known node.
    public func exists(_ node: OpID) -> Bool {
        created[node] != nil || node.replica == 0 && node.counter < Self.wellKnownLimit
    }

    /// Records a node created with `kind`; returns false if it already existed.
    mutating func create(_ node: OpID, kind: UInt32) -> Bool {
        guard !exists(node) else { return false }
        created[node] = kind
        return true
    }

    /// Applies one register write by the last-writer-wins rule and retains it in the log.  A write
    /// already applied (same register, same op) is ignored entirely, so replays are idempotent.
    /// Returns whether the write now holds the register.
    @discardableResult
    mutating func write(_ node: OpID, _ path: RegisterPath, _ value: [UInt8]?, _ op: OpID) -> Bool {
        let history = log[node, default: [:]][path, default: []]
        guard !history.contains(where: { $0.op == op }) else { return false }
        log[node, default: [:]][path, default: []].append(Write(node: node, path: path, value: value, op: op))
        if let current = registers[node]?[path], current.op > op {
            return false
        }
        registers[node, default: [:]][path] = Register(value: value, op: op)
        return true
    }

    /// The register at `path` of `node`, or nil when it was never written.
    public func register(_ node: OpID, _ path: RegisterPath) -> Register? {
        registers[node]?[path]
    }

    /// Every register of `node`, in path order.
    public func registers(_ node: OpID) -> [(path: RegisterPath, register: Register)] {
        (registers[node] ?? [:]).sorted { $0.key < $1.key }.map { (path: $0.key, register: $0.value) }
    }

    /// Every retained write to one register, in arrival order.
    public func writes(_ node: OpID, _ path: RegisterPath) -> [Write] {
        log[node]?[path] ?? []
    }

    /// The retained writes to one register that do not hold it, in OpId order.
    public func losingWrites(_ node: OpID, _ path: RegisterPath) -> [Write] {
        let current = register(node, path)?.op
        return writes(node, path).filter { $0.op != current }.sorted { $0.op < $1.op }
    }

    /// The nodes the state hash covers, ascending: every created node and every node holding a
    /// register.
    public var nodes: [OpID] {
        Set(created.keys).union(registers.keys).sorted()
    }
}
