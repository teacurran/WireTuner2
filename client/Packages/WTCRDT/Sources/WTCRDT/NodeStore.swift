/// One element of a SEQUENCE field (docs/spec/crdt-model.adoc, "Sequences"): a position register
/// and a `deleted` register; its fields are registers under the element's path.
public struct Element: Hashable, Sendable {
    /// The fractional position among the sequence's elements (written by the insert, then moves).
    public internal(set) var position: Cell<[UInt8]>
    /// The `deleted` register, or nil when no `ElementDelete` has written it.
    public internal(set) var deleted: Cell<Bool>?

    /// Whether the element is a tombstone.
    public var isDeleted: Bool { deleted?.current.value ?? false }
}

/// An add of one member to a SET field: the `SetAdd` op and the seq of its change.
struct SetAddition: Hashable, Sendable {
    let op: OpID
    let seq: UInt64
}

/// A remove of one member: the `SetRemove` op, the seq of its change and its causal past.
struct SetRemoval: Hashable, Sendable {
    let op: OpID
    let seq: UInt64
    let base: UInt64
}

/// Every add and remove of one member of one set.
struct MemberHistory: Sendable {
    var adds: [SetAddition] = []
    var removes: [SetRemoval] = []
}

/// What the state knows about one replica (`ReplicaState` in doc/v1/snapshot.proto): the highest
/// change seq applied from it, and the highest server_seq it has acknowledged -- the greatest
/// `base_server_seq` among its changes, which says everything up to there had reached it.
public struct ReplicaState: Hashable, Sendable {
    public internal(set) var seq: UInt64
    public internal(set) var ackedServerSeq: UInt64
}

/// The merged state: which nodes exist and of what kind, the node tree, every register keyed by
/// node and `RegisterPath` with the change log of every write -- winning or losing -- per
/// register, `deleted` flags, sequence elements, set members, TEXT fields and what is known of
/// each replica.
public struct NodeStore: Sendable {
    /// Kinds of the well-known nodes that carry properties: document (0:0) and settings (0:1).
    private static let wellKnownKinds: [OpID: UInt32] = [.wellKnown(0): 1, .wellKnown(1): 2]
    /// Well-known nodes use replica 0 and counters below this (crdt-model.adoc, "The node tree").
    static let wellKnownLimit: UInt64 = 16

    private struct ChangeKey: Hashable {
        let replica: UInt64
        let seq: UInt64
    }

    private var created: [OpID: UInt32] = [:]
    private var registers: [OpID: [RegisterPath: Register]] = [:]
    private var log: [OpID: [RegisterPath: [Write]]] = [:]
    private var deletedFlags: [OpID: Cell<Bool>] = [:]
    /// Elements by node, then by element path (the SEQUENCE field's path plus the element id).
    private var elements: [OpID: [RegisterPath: Element]] = [:]
    /// Set members by node, set path and member value.
    private var sets: [OpID: [RegisterPath: [[UInt8]: MemberHistory]]] = [:]
    /// The server_seq of each sequenced change, by replica and seq.
    private var sequenced: [ChangeKey: UInt64] = [:]
    /// TEXT fields by node, then by the field's path; only fields holding a character or a mark.
    private var texts: [OpID: [RegisterPath: TextSequence]] = [:]
    /// What is known of each replica, by id.
    private var replicaStates: [UInt64: ReplicaState] = [:]
    /// The node tree and its move log.
    private(set) var tree = Tree()

    public init() {}

    // MARK: Nodes and the tree

    /// The kind of `node` (the field number of its `NodeProps.kind` case), or 0 when the node does
    /// not exist or is a well-known collection without properties.
    public func kind(_ node: OpID) -> UInt32 {
        created[node] ?? Self.wellKnownKinds[node] ?? 0
    }

    /// Whether `node` was created by a `CreateNode`.
    public func isCreated(_ node: OpID) -> Bool {
        created[node] != nil
    }

    /// Whether `node` was created or is a well-known node.
    public func exists(_ node: OpID) -> Bool {
        created[node] != nil || Tree.isWellKnown(node)
    }

    /// Records a node created with `kind`; returns false if it already existed.
    mutating func create(_ node: OpID, kind: UInt32) -> Bool {
        guard !exists(node) else { return false }
        created[node] = kind
        return true
    }

    /// Applies a tree op (a `CreateNode` or `MoveNode`) in OpId order.
    mutating func applyTree(op: OpID, node: OpID, parent: OpID, position: [UInt8], creates: Bool) {
        tree.apply(op: op, node: node, parent: parent, position: position, creates: creates)
    }

    /// Where `node` sits, or nil for the document root and nodes without a parent.
    public func placement(_ node: OpID) -> Placement? {
        tree.placement(node)
    }

    /// The children of `node`, deleted ones included, by position then id.
    public func children(_ node: OpID) -> [OpID] {
        tree.children(node)
    }

    /// The unstable move log, ascending by op.
    public var moveLog: [MoveLogEntry] { tree.log }

    /// Writes the `deleted` register of a created node; well-known and unknown nodes are left
    /// alone.
    mutating func setDeleted(_ node: OpID, _ deleted: Bool, _ op: OpID) {
        guard created[node] != nil else { return }
        if deletedFlags[node] == nil {
            deletedFlags[node] = Cell(deleted, op)
        } else {
            deletedFlags[node]!.write(deleted, op)
        }
    }

    /// The `deleted` register of `node`, or nil when it was never written.
    public func deleted(_ node: OpID) -> Cell<Bool>? {
        deletedFlags[node]
    }

    // MARK: Registers

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

    // MARK: Sequences

    /// Inserts an element at `path` (the sequence path plus the element id) unless it exists;
    /// returns whether it was inserted.
    mutating func insertElement(_ node: OpID, _ path: RegisterPath, position: [UInt8], op: OpID) -> Bool {
        guard elements[node]?[path] == nil else { return false }
        elements[node, default: [:]][path] = Element(position: Cell(position, op), deleted: nil)
        return true
    }

    /// Writes an existing element's position register.
    mutating func moveElement(_ node: OpID, _ path: RegisterPath, position: [UInt8], op: OpID) {
        elements[node]?[path]?.position.write(position, op)
    }

    /// Writes an existing element's `deleted` register.
    mutating func deleteElement(_ node: OpID, _ path: RegisterPath, deleted: Bool, op: OpID) {
        guard var element = elements[node]?[path] else { return }
        if element.deleted == nil {
            element.deleted = Cell(deleted, op)
        } else {
            element.deleted!.write(deleted, op)
        }
        elements[node]![path] = element
    }

    /// The element at `path` of `node`, or nil when it was never inserted.
    public func element(_ node: OpID, _ path: RegisterPath) -> Element? {
        elements[node]?[path]
    }

    /// The element ids of the sequence at `sequence`, tombstones included, in order: by position,
    /// then by id.
    public func elementOrder(_ node: OpID, _ sequence: RegisterPath) -> [OpID] {
        (elements[node] ?? [:]).compactMap { path, element -> (position: [UInt8], id: OpID)? in
            guard path.parent == sequence, case .element(let id) = path.segments.last! else { return nil }
            return (position: element.position.current.value, id: id)
        }
        .sorted(by: FractionalIndex.childOrder)
        .map(\.id)
    }

    /// Every element of `node`, in path order.
    public func elements(_ node: OpID) -> [(path: RegisterPath, element: Element)] {
        (elements[node] ?? [:]).sorted { $0.key < $1.key }.map { (path: $0.key, element: $0.value) }
    }

    // MARK: Sets

    /// Records the server_seq the server gave change `seq` of `replica`: the causal context a set
    /// remove is judged by.
    mutating func sequence(replica: UInt64, seq: UInt64, serverSeq: UInt64) {
        sequenced[ChangeKey(replica: replica, seq: seq)] = serverSeq
    }

    /// Records an add of `member` to the set at `path`; replays are ignored.  Returns whether the
    /// add is new.
    @discardableResult
    mutating func addMember(_ node: OpID, _ path: RegisterPath, _ member: [UInt8], _ add: SetAddition) -> Bool {
        var history = sets[node]?[path]?[member] ?? MemberHistory()
        guard !history.adds.contains(where: { $0.op == add.op }) else { return false }
        history.adds.append(add)
        sets[node, default: [:]][path, default: [:]][member] = history
        return true
    }

    /// Records a remove of `member` from the set at `path`; replays are ignored.
    mutating func removeMember(_ node: OpID, _ path: RegisterPath, _ member: [UInt8], _ removal: SetRemoval) {
        var history = sets[node]?[path]?[member] ?? MemberHistory()
        guard !history.removes.contains(where: { $0.op == removal.op }) else { return }
        history.removes.append(removal)
        sets[node, default: [:]][path, default: [:]][member] = history
    }

    /// Whether `removal` observed `add`: the add is in the remove's causal past, i.e. an earlier op
    /// of the same replica, or in a change the server sequenced at or before the remove's
    /// `base_server_seq` (crdt-model.adoc, "Sets").
    private func observed(_ add: SetAddition, by removal: SetRemoval) -> Bool {
        if add.op.replica == removal.op.replica {
            return add.op < removal.op
        }
        guard let serverSeq = sequenced[ChangeKey(replica: add.op.replica, seq: add.seq)] else { return false }
        return serverSeq <= removal.base
    }

    /// The adds of `member` that no remove observed, ascending: the member is present while any
    /// remains (add-wins).
    public func liveTags(_ node: OpID, _ path: RegisterPath, _ member: [UInt8]) -> [OpID] {
        guard let history = sets[node]?[path]?[member] else { return [] }
        return history.adds.filter { add in !history.removes.contains { observed(add, by: $0) } }
            .map(\.op)
            .sorted()
    }

    /// The members of the set at `path`, ascending bytewise.
    public func members(_ node: OpID, _ path: RegisterPath) -> [[UInt8]] {
        (sets[node]?[path] ?? [:]).keys
            .filter { !liveTags(node, path, $0).isEmpty }
            .sorted(by: FractionalIndex.less)
    }

    /// The paths of the sets of `node` that have at least one member, in path order.
    public func setPaths(_ node: OpID) -> [RegisterPath] {
        (sets[node] ?? [:]).keys.filter { !members(node, $0).isEmpty }.sorted()
    }

    // MARK: Text

    /// The TEXT field at `path` of `node`, or nil when it holds nothing.
    public func text(_ node: OpID, _ path: RegisterPath) -> TextSequence? {
        texts[node]?[path]
    }

    /// The paths of the TEXT fields of `node` that hold something, in path order.
    public func textPaths(_ node: OpID) -> [RegisterPath] {
        (texts[node] ?? [:]).keys.sorted()
    }

    /// Whether `path` (a TEXT field's path plus a character id) names a newline character, the
    /// element that carries its paragraph's registers.
    func isNewline(_ node: OpID, _ path: RegisterPath) -> Bool {
        guard case .element(let id)? = path.segments.last, let field = path.parent else { return false }
        return texts[node]?[field]?.codepoint(id) == 0x0A
    }

    /// Changes one TEXT field in place, dropping it again if it is left holding nothing.
    mutating func editText<Result>(_ node: OpID, _ path: RegisterPath, _ edit: (inout TextSequence) -> Result) -> Result {
        let result = edit(&texts[node, default: [:]][path, default: TextSequence()])
        if texts[node]![path]!.isEmpty {
            texts[node]![path] = nil
            if texts[node]!.isEmpty {
                texts[node] = nil
            }
        }
        return result
    }

    // MARK: Replicas

    /// Records that change `seq` of `replica`, made with causal past `baseServerSeq`, was applied.
    mutating func recordChange(replica: UInt64, seq: UInt64, baseServerSeq: UInt64) {
        var state = replicaStates[replica] ?? ReplicaState(seq: 0, ackedServerSeq: 0)
        state.seq = max(state.seq, seq)
        state.ackedServerSeq = max(state.ackedServerSeq, baseServerSeq)
        replicaStates[replica] = state
    }

    /// What is known of `replica`, or nil when no change of it was applied.
    public func replicaState(_ replica: UInt64) -> ReplicaState? {
        replicaStates[replica]
    }

    /// Every replica with an applied change, ascending by id.
    public var replicas: [(replica: UInt64, state: ReplicaState)] {
        replicaStates.sorted { $0.key < $1.key }.map { (replica: $0.key, state: $0.value) }
    }

    /// The server_seq of every sequenced change, ascending by replica then seq.
    var sequencedChanges: [(replica: UInt64, seq: UInt64, serverSeq: UInt64)] {
        sequenced.map { (replica: $0.key.replica, seq: $0.key.seq, serverSeq: $0.value) }
            .sorted { ($0.replica, $0.seq) < ($1.replica, $1.seq) }
    }

    // MARK: Snapshots

    /// Every set of `node` with any history, in path order; members ascending bytewise, their adds
    /// and removes ascending by op.
    func setHistories(_ node: OpID) -> [(path: RegisterPath, members: [(member: [UInt8], history: MemberHistory)])] {
        (sets[node] ?? [:]).sorted { $0.key < $1.key }.map { path, members in
            (path: path, members: members.sorted { FractionalIndex.less($0.key, $1.key) }.map { member, history in
                (member: member, history: MemberHistory(adds: history.adds.sorted { $0.op < $1.op },
                                                        removes: history.removes.sorted { $0.op < $1.op }))
            })
        }
    }

    /// The pieces of a state as a snapshot holds them (`Snapshot.decode`); the change log starts
    /// empty.
    mutating func restore(
        created: [OpID: UInt32], registers: [OpID: [RegisterPath: Register]], deleted: [OpID: Cell<Bool>],
        elements: [OpID: [RegisterPath: Element]], sets: [OpID: [RegisterPath: [[UInt8]: MemberHistory]]],
        texts: [OpID: [RegisterPath: TextSequence]], sequenced: [(replica: UInt64, seq: UInt64, serverSeq: UInt64)],
        replicas: [UInt64: ReplicaState], tree: Tree
    ) {
        self.created = created
        self.registers = registers
        deletedFlags = deleted
        self.elements = elements
        self.sets = sets
        self.texts = texts
        self.sequenced = Dictionary(sequenced.map { (ChangeKey(replica: $0.replica, seq: $0.seq), $0.serverSeq) },
                                    uniquingKeysWith: { a, _ in a })
        replicaStates = replicas
        self.tree = tree
    }

    // MARK: Hashing

    /// The nodes the state hash covers, ascending: every created node and every node holding a
    /// register, a `deleted` flag, an element, a set member's history or a TEXT field.
    public var nodes: [OpID] {
        Set(created.keys).union(registers.keys).union(deletedFlags.keys).union(elements.keys).union(sets.keys)
            .union(texts.keys).sorted()
    }
}
