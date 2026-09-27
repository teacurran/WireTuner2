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
/// change seq applied from it, the highest server_seq it has acknowledged -- the greatest
/// `base_server_seq` among its changes, which says everything up to there had reached it -- and
/// its stable counter: every op of the replica below it is causally stable (CRDT-010).
public struct ReplicaState: Hashable, Sendable {
    public internal(set) var seq: UInt64
    public internal(set) var ackedServerSeq: UInt64
    public internal(set) var stableCounter: UInt64 = 0
}

/// One change the state records (`SequencedChange` in doc/v1/snapshot.proto): the server_seq it
/// was sequenced at and one past the last counter its ops took, each 0 while unknown.
struct ChangeRecord: Hashable, Sendable {
    var serverSeq: UInt64 = 0
    var endCounter: UInt64 = 0
}

/// What one garbage collection dropped (CRDT-010), for logs and tests.
public struct Collected: Hashable, Sendable {
    public internal(set) var characters = 0
    public internal(set) var elements = 0
    public internal(set) var moveLogEntries = 0
    public internal(set) var setTags = 0
    public internal(set) var nodes = 0
    public internal(set) var changes = 0

    public init() {}
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
    /// Local-only registers (`LocalOnly`): written by this replica's local changes only, by the
    /// last-writer-wins rule and without a change log.  Not part of the state hash, a snapshot,
    /// `registers(_:)` or `nodes`; `register(_:_:)` reads them.
    private var local: [OpID: [RegisterPath: Register]] = [:]
    private var log: [OpID: [RegisterPath: [Write]]] = [:]
    private var deletedFlags: [OpID: Cell<Bool>] = [:]
    /// Elements by node, then by element path (the SEQUENCE field's path plus the element id).
    private var elements: [OpID: [RegisterPath: Element]] = [:]
    /// Set members by node, set path and member value.
    private var sets: [OpID: [RegisterPath: [[UInt8]: MemberHistory]]] = [:]
    /// The server_seq and end counter of each change, by replica and seq; dropped once stable.
    private var changeRecords: [ChangeKey: ChangeRecord] = [:]
    /// The wall time of the change that wrote each node's current `deleted` value.
    private var deletedTimes: [OpID: Int64] = [:]
    /// The stable point the state was last collected at (0: never).
    public private(set) var stableSeq: UInt64 = 0
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
    /// alone.  `wallTime` is the writing change's `wall_time_ms`, kept while the write holds.
    mutating func setDeleted(_ node: OpID, _ deleted: Bool, _ op: OpID, wallTime: Int64 = 0) {
        guard created[node] != nil else { return }
        if deletedFlags[node] == nil {
            deletedFlags[node] = Cell(deleted, op)
        } else {
            deletedFlags[node]!.write(deleted, op)
        }
        if deletedFlags[node]!.current.op == op {
            deletedTimes[node] = wallTime
        }
    }

    /// The wall time of the change that wrote the current `deleted` value of `node` (0: unknown).
    public func deletedTime(_ node: OpID) -> Int64 {
        deletedTimes[node] ?? 0
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
        // The register holds the newest op of its log (a snapshot restores registers with an
        // empty log), so an op newer than the register's -- every local write -- is not in the
        // log and the scan is skipped: repeated writes to one register stay linear.  The log is
        // appended in place, never through a copy.
        let current = registers[node]?[path]
        if let current, op <= current.op, log[node]?[path]?.contains(where: { $0.op == op }) == true {
            return false
        }
        log[node, default: [:]][path, default: []].append(Write(node: node, path: path, value: value, op: op))
        if let current, current.op > op {
            return false
        }
        registers[node, default: [:]][path] = Register(value: value, op: op)
        return true
    }

    /// The register at `path` of `node`, or nil when it was never written.  A local-only
    /// register is read from the local registers (a value an older replica merged into the shared
    /// state before local-only paths were ignored is read when there is no local one).
    public func register(_ node: OpID, _ path: RegisterPath) -> Register? {
        local[node]?[path] ?? registers[node]?[path]
    }

    /// Applies one local-only register write by the last-writer-wins rule (no change log: the
    /// conflict review never shows local-only values).  Returns whether it now holds the register.
    @discardableResult
    mutating func writeLocal(_ node: OpID, _ path: RegisterPath, _ value: [UInt8]?, _ op: OpID) -> Bool {
        if let current = local[node]?[path], current.op >= op {
            return false
        }
        local[node, default: [:]][path] = Register(value: value, op: op)
        return true
    }

    /// The local-only registers of `node`, in path order.
    public func localRegisters(_ node: OpID) -> [(path: RegisterPath, register: Register)] {
        (local[node] ?? [:]).sorted { $0.key < $1.key }.map { (path: $0.key, register: $0.value) }
    }

    /// Every local-only register as the write that holds it, by node then path: what a local store
    /// keeps beside the shared state so the values survive a relaunch (`restoreLocal`).
    public var localWrites: [Write] {
        local.keys.sorted().flatMap { node in
            localRegisters(node).map { Write(node: node, path: $0.path, value: $0.register.value, op: $0.register.op) }
        }
    }

    /// Restores local-only registers kept beside the shared state (`localWrites`), each by the
    /// last-writer-wins rule.
    public mutating func restoreLocal(_ writes: [Write]) {
        for write in writes {
            writeLocal(write.node, write.path, write.value, write.op)
        }
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
    /// remove is judged by.  A server_seq at or below the stable point is already folded into the
    /// replica's stable counter.
    mutating func sequence(replica: UInt64, seq: UInt64, serverSeq: UInt64) {
        guard serverSeq > stableSeq else { return }
        changeRecords[ChangeKey(replica: replica, seq: seq), default: ChangeRecord()].serverSeq = serverSeq
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

    /// The server_seq of an add's change; for a stable add whose record was collected, the stable
    /// point (it was sequenced at or before it, and every remove it has not been judged against
    /// yet has a causal past reaching the stable point).
    private func serverSeq(of add: SetAddition) -> UInt64? {
        if let record = changeRecords[ChangeKey(replica: add.op.replica, seq: add.seq)], record.serverSeq != 0 {
            return record.serverSeq
        }
        return add.seq != 0 && isStable(add.op) ? stableSeq : nil
    }

    /// Whether `removal` observed `add`: the add is in the remove's causal past, i.e. an earlier op
    /// of the same replica, or in a change the server sequenced at or before the remove's
    /// `base_server_seq` (crdt-model.adoc, "Sets").
    private func observed(_ add: SetAddition, by removal: SetRemoval) -> Bool {
        if add.op.replica == removal.op.replica {
            return add.op < removal.op
        }
        guard let serverSeq = serverSeq(of: add) else { return false }
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

    /// Records that change `seq` of `replica`, made with causal past `baseServerSeq` and taking
    /// counters up to `endCounter` (exclusive), was applied.
    mutating func recordChange(replica: UInt64, seq: UInt64, baseServerSeq: UInt64, endCounter: UInt64 = 0) {
        var state = replicaStates[replica] ?? ReplicaState(seq: 0, ackedServerSeq: 0)
        state.seq = max(state.seq, seq)
        state.ackedServerSeq = max(state.ackedServerSeq, baseServerSeq)
        replicaStates[replica] = state
        if endCounter > state.stableCounter {
            changeRecords[ChangeKey(replica: replica, seq: seq), default: ChangeRecord()].endCounter = endCounter
        }
    }

    /// What is known of `replica`, or nil when no change of it was applied.
    public func replicaState(_ replica: UInt64) -> ReplicaState? {
        replicaStates[replica]
    }

    /// Every replica with an applied change, ascending by id.
    public var replicas: [(replica: UInt64, state: ReplicaState)] {
        replicaStates.sorted { $0.key < $1.key }.map { (replica: $0.key, state: $0.value) }
    }

    /// Every change record (server_seq and end counter), ascending by replica then seq.
    var sequencedChanges: [(replica: UInt64, seq: UInt64, record: ChangeRecord)] {
        changeRecords.map { (replica: $0.key.replica, seq: $0.key.seq, record: $0.value) }
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
        texts: [OpID: [RegisterPath: TextSequence]], sequenced: [(replica: UInt64, seq: UInt64, record: ChangeRecord)],
        replicas: [UInt64: ReplicaState], tree: Tree, deletedTimes: [OpID: Int64] = [:], stableSeq: UInt64 = 0
    ) {
        self.created = created
        self.registers = registers
        deletedFlags = deleted
        self.elements = elements
        self.sets = sets
        self.texts = texts
        changeRecords = Dictionary(sequenced.map { (ChangeKey(replica: $0.replica, seq: $0.seq), $0.record) },
                                   uniquingKeysWith: { a, _ in a })
        replicaStates = replicas
        self.tree = tree
        self.deletedTimes = deletedTimes
        self.stableSeq = stableSeq
    }

    // MARK: Garbage collection

    /// Whether `op` is causally stable in this state: below its replica's stable counter, which
    /// garbage collection advances (CRDT-010).
    public func isStable(_ op: OpID) -> Bool {
        op.counter < (replicaStates[op.replica]?.stableCounter ?? 0)
    }

    /// Each replica's stable counter at stable point `stableSeq`: one past the last counter of its
    /// changes sequenced at or before it (a replica's changes are sequenced in seq order and take
    /// increasing counters), and at least the counter a collection already reached.
    public func stableCounters(at stableSeq: UInt64) -> [UInt64: UInt64] {
        var out: [UInt64: UInt64] = [:]
        for (replica, state) in replicaStates where state.stableCounter > 0 {
            out[replica] = state.stableCounter
        }
        for (key, record) in changeRecords where record.serverSeq != 0 && record.serverSeq <= stableSeq {
            out[key.replica] = max(out[key.replica] ?? 0, record.endCounter)
        }
        return out
    }

    /// The stable point the replica acks give: the smallest server_seq acknowledged by a replica
    /// that is not `retired` (0 when there is none).
    public func stablePoint(retired: Set<UInt64> = []) -> UInt64 {
        replicaStates.filter { !retired.contains($0.key) }.map(\.value.ackedServerSeq).min() ?? 0
    }

    /// Drops what stable point `target` makes causally stable (crdt-model.adoc, "Garbage
    /// collection"): set history that can no longer change a member's presence, sequence element
    /// and character tombstones whose delete is stable (a character only while no mark anchors it
    /// and no character hangs below it in the Fugue tree), stable move-log entries, and the change
    /// records at or below `target`, which become each replica's stable counter; then compacts
    /// every node deleted by a stable write at least `retention` ms before `now`, with its
    /// subtree, unless an unstable move-log entry still names one of them.  A target below the
    /// last one collects nothing; the same one again only compacts (by a later `now`).
    mutating func collect(stableSeq target: UInt64, now: Int64, retention: Int64) -> Collected {
        var collected = Collected()
        guard target >= stableSeq else { return collected }
        let counters = stableCounters(at: target)
        let stable: (OpID) -> Bool = { $0.counter < (counters[$0.replica] ?? 0) }
        collectSets(stable, &collected)
        collectElements(stable, &collected)
        collectTexts(stable, &collected)
        collected.moveLogEntries = tree.prune(stable)
        for (key, record) in changeRecords where record.serverSeq != 0 && record.serverSeq <= target {
            changeRecords[key] = nil
            collected.changes += 1
        }
        for (replica, counter) in counters {
            replicaStates[replica]?.stableCounter = counter
        }
        stableSeq = target
        let (cutoff, overflow) = now.subtractingReportingOverflow(retention)
        compactNodes(stable, cutoff: overflow ? Int64.min : cutoff, &collected)
        return collected
    }

    // A stable add some remove observed is dead for good, and a stable remove observes no add
    // that is not stable (an add it observes is sequenced before it); both go.  A stable live add
    // stays, judged from now on as sequenced at the stable point.
    private mutating func collectSets(_ stable: (OpID) -> Bool, _ collected: inout Collected) {
        for (node, fields) in sets {
            for (path, members) in fields {
                for (member, history) in members {
                    let adds = history.adds.filter { add in
                        !(stable(add.op) && history.removes.contains { observed(add, by: $0) })
                    }
                    let removes = history.removes.filter { !stable($0.op) }
                    collected.setTags += history.adds.count - adds.count + history.removes.count - removes.count
                    sets[node]![path]![member] = adds.isEmpty && removes.isEmpty ? nil
                        : MemberHistory(adds: adds, removes: removes)
                }
                if sets[node]![path]!.isEmpty {
                    sets[node]![path] = nil
                }
            }
            if sets[node]!.isEmpty {
                sets[node] = nil
            }
        }
    }

    // Sequence tombstones whose `deleted` write is stable go with everything beneath them.
    private mutating func collectElements(_ stable: (OpID) -> Bool, _ collected: inout Collected) {
        for (node, nodeElements) in elements {
            let gone = Set(nodeElements.compactMap { path, element in
                element.isDeleted && stable(element.deleted!.current.op) ? path : nil
            })
            if !gone.isEmpty {
                collected.elements += removeUnder(node, gone)
            }
        }
    }

    // Character tombstones the text can drop (`TextSequence.collectable`) go with their
    // paragraph registers.
    private mutating func collectTexts(_ stable: (OpID) -> Bool, _ collected: inout Collected) {
        for (node, fields) in texts {
            for (path, text) in fields {
                let gone = text.collectable(stable)
                guard !gone.isEmpty else { continue }
                collected.characters += gone.count
                let remaining = text.removing(gone)
                texts[node]![path] = remaining.isEmpty ? nil : remaining
                removeUnder(node, Set(gone.map(path.element)))
            }
            if texts[node]?.isEmpty == true {
                texts[node] = nil
            }
        }
    }

    // Removes every register, change log, element, set and text of `node` at or below one of
    // `prefixes` (element or character paths); returns how many elements went.
    @discardableResult
    private mutating func removeUnder(_ node: OpID, _ prefixes: Set<RegisterPath>) -> Int {
        func under(_ path: RegisterPath) -> Bool {
            for index in path.segments.indices where index > 0 {
                if case .element = path.segments[index],
                   prefixes.contains(RegisterPath(segments: Array(path.segments[...index]))) {
                    return true
                }
            }
            return false
        }
        registers[node] = registers[node]?.filter { !under($0.key) }.nilIfEmpty
        local[node] = local[node]?.filter { !under($0.key) }.nilIfEmpty
        log[node] = log[node]?.filter { !under($0.key) }.nilIfEmpty
        sets[node] = sets[node]?.filter { !under($0.key) }.nilIfEmpty
        texts[node] = texts[node]?.filter { !under($0.key) }.nilIfEmpty
        let before = elements[node]?.count ?? 0
        elements[node] = elements[node]?.filter { !under($0.key) }.nilIfEmpty
        return before - (elements[node]?.count ?? 0)
    }

    // Nodes deleted by a stable write at or before `cutoff`, each with its subtree.
    private mutating func compactNodes(_ stable: (OpID) -> Bool, cutoff: Int64, _ collected: inout Collected) {
        let candidates = deletedFlags.compactMap { node, flag -> OpID? in
            flag.current.value && stable(flag.current.op) && (deletedTimes[node] ?? 0) <= cutoff ? node : nil
        }
        for node in candidates.sorted() where created[node] != nil {
            let subtree = tree.subtree(node)
            guard !tree.names(subtree) else { continue }
            for member in subtree {
                created[member] = nil
                registers[member] = nil
                local[member] = nil
                log[member] = nil
                deletedFlags[member] = nil
                deletedTimes[member] = nil
                elements[member] = nil
                sets[member] = nil
                texts[member] = nil
            }
            tree.remove(subtree)
            collected.nodes += subtree.count
        }
    }

    // MARK: Hashing

    /// The nodes the state hash covers, ascending: every created node and every node holding a
    /// register, a `deleted` flag, an element, a set member's history or a TEXT field.
    public var nodes: [OpID] {
        Set(created.keys).union(registers.keys).union(deletedFlags.keys).union(elements.keys).union(sets.keys)
            .union(texts.keys).sorted()
    }
}

extension Dictionary {
    /// The dictionary, or nil when it is empty.
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
