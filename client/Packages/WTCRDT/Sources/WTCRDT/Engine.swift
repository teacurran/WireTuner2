import Foundation
import WTProto

/// The merge state of one document replica (docs/spec/crdt-model.adoc): a `LamportClock`, the
/// `NodeStore` and the `Schema` it merges with.  Every op applies to every state; an op the
/// engine cannot use is a deterministic no-op ("Totality").  `Engine` is the actor over it;
/// wt-crdt's `Engine` is this type in Java.
///
/// Implemented: registers (`SetFields`, CRDT-001), the node tree (`CreateNode`, `MoveNode`,
/// `SetDeleted`, CRDT-002), sets (`SetAdd`, `SetRemove`, CRDT-007), sequences (`ElementInsert`,
/// `ElementMove`, `ElementDelete`, CRDT-004), changes with their inverses (CRDT-008), text
/// (`TextInsert`, `TextDelete`, CRDT-005), formatting marks (`TextMark`, CRDT-006), snapshots
/// (CRDT-009) and garbage collection (`collect`, CRDT-010).
public struct EngineState: Sendable {
    /// Version of the merge semantics this engine implements, as wt-crdt's `Engine.VERSION`.
    public static let version = "0.4.0"

    /// How long a deleted node stays restorable before garbage collection compacts it: 30 days
    /// (crdt-model.adoc, "Garbage collection").
    public static let deletedNodeRetentionMs: Int64 = 30 * 24 * 60 * 60 * 1_000

    /// The change an op belongs to: its seq, causal past and wall time (0 for an op applied on
    /// its own).
    public struct Context: Sendable {
        public var seq: UInt64
        public var baseServerSeq: UInt64
        public var wallTimeMs: Int64

        public init(seq: UInt64 = 0, baseServerSeq: UInt64 = 0, wallTimeMs: Int64 = 0) {
            self.seq = seq
            self.baseServerSeq = baseServerSeq
            self.wallTimeMs = wallTimeMs
        }
    }

    /// The merge table this engine uses.
    public let schema: Schema
    private let resolver: PathResolver
    /// This replica's Lamport clock; every applied op advances it.
    public var clock = LamportClock()
    /// The merged state.
    public internal(set) var store = NodeStore()
    /// The inverse steps of the local change being applied (`applyLocal`), else nil.
    private var recording: [Inverse.Step]?

    /// An engine over `schema` (the generated merge table by default).
    public init(schema: Schema = .generated) {
        self.schema = schema
        resolver = PathResolver(schema: schema)
    }

    /// Applies `change` as a unit (CRDT-008): every op in order, op `i` with counter
    /// `start_counter` plus the counters the ops before it took (one each, or one per element or
    /// character for inserts, change.proto), then records the change against its replica (highest
    /// seq, highest `base_server_seq`).  A change applied again changes nothing: every op is
    /// recognised by its id.  `serverSeq` is the server's sequence number for the change when known
    /// (a remote change, or a local one already acknowledged): sets judge a concurrent remove by
    /// it.  A change the state has already collected as stable -- sequenced at or before the stable
    /// point, or starting below its replica's stable counter -- is a replay and changes nothing.
    public mutating func apply(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64? = nil) {
        let stable = store.replicaState(change.replica)?.stableCounter ?? 0
        if change.startCounter < stable || serverSeq.map({ $0 != 0 && $0 <= store.stableSeq }) == true {
            return
        }
        if let serverSeq {
            acknowledge(replica: change.replica, seq: change.seq, serverSeq: serverSeq)
        }
        let context = Context(seq: change.seq, baseServerSeq: change.baseServerSeq, wallTimeMs: change.wallTimeMs)
        var counter = change.startCounter
        for op in change.ops {
            apply(op, id: OpID(counter: counter, replica: change.replica), context: context)
            counter &+= Self.counters(op)
        }
        store.recordChange(replica: change.replica, seq: change.seq, baseServerSeq: change.baseServerSeq, endCounter: counter)
    }

    /// Applies a local change (one this replica just made) and returns its inverse: the prior
    /// value of everything it changed, from which `undoChange` builds the change that undoes it
    /// (crdt-model.adoc, "Undo").
    public mutating func applyLocal(_ change: Wiretuner_Doc_V1_Change) -> Inverse {
        recording = []
        apply(change)
        let steps = recording!
        recording = nil
        return Inverse(steps: steps)
    }

    /// Records the server_seq of change `seq` of `replica` (the ack of a local change).
    public mutating func acknowledge(replica: UInt64, seq: UInt64, serverSeq: UInt64) {
        store.sequence(replica: replica, seq: seq, serverSeq: serverSeq)
    }

    /// How many counters `op` takes: one per element of an `ElementInsert` or Unicode scalar of a
    /// `TextInsert`, at least one; one for every other op.
    public static func counters(_ op: Wiretuner_Doc_V1_Op) -> UInt64 {
        switch op.op {
        case .elementInsert(let insert): UInt64(max(1, insert.positions.count))
        case .textInsert(let insert): UInt64(max(1, insert.chars.unicodeScalars.count))
        default: 1
        }
    }

    private mutating func record(_ step: Inverse.Step) {
        recording?.append(step)
    }

    /// Applies one op with id `id` (its first counter).  An op below its replica's stable counter
    /// is a replay of one garbage collection already folded in, and is ignored.
    public mutating func apply(_ op: Wiretuner_Doc_V1_Op, id: OpID, context: Context = Context()) {
        clock.observe(id.counter &+ Self.counters(op) &- 1)
        guard !store.isStable(id) else { return }
        switch op.op {
        case .create(let create):
            self.create(create, id: id)
        case .set(let set):
            self.set(set, id: id)
        case .move(let move):
            let node = OpID(move.node)
            // A node's id is the id of the CreateNode that made it, so no move is its own node.
            guard node != id else { return }
            let prior = store.placement(node)
            store.applyTree(op: id, node: node, parent: OpID(move.parent), position: Array(move.position), creates: false)
            if store.placement(node)?.op == id {
                record(.placement(node: node, prior: prior, wrote: id))
            }
        case .setDeleted(let setDeleted):
            let node = OpID(setDeleted.node)
            let prior = store.deleted(node)?.current
            store.setDeleted(node, setDeleted.deleted, id, wallTime: context.wallTimeMs)
            if store.deleted(node)?.current.op == id {
                record(.deleted(node: node, prior: prior, wrote: id))
            }
        case .elementInsert(let insert):
            self.insert(insert, id: id)
        case .elementMove(let move):
            let node = OpID(move.node)
            if case .element(let path, _, _, _)? = walk(node, move.element, values: nil),
               let prior = store.element(node, path)?.position.current {
                store.moveElement(node, path, position: Array(move.position), op: id)
                if store.element(node, path)?.position.current.op == id {
                    record(.elementPosition(node: node, element: path, prior: prior, wrote: id))
                }
            }
        case .elementDelete(let delete):
            let node = OpID(delete.node)
            for element in delete.elements {
                if case .element(let path, _, _, _)? = walk(node, element, values: nil), store.element(node, path) != nil {
                    let prior = store.element(node, path)?.deleted?.current
                    store.deleteElement(node, path, deleted: delete.deleted, op: id)
                    if store.element(node, path)?.deleted?.current.op == id {
                        record(.elementDeleted(node: node, element: path, prior: prior, wrote: id))
                    }
                }
            }
        case .setAdd(let add):
            let node = OpID(add.node)
            if let (path, row, members) = members(node, add.set, add.values) {
                for member in members {
                    let present = !store.liveTags(node, path, member).isEmpty
                    if store.addMember(node, path, member, SetAddition(op: id, seq: context.seq)) {
                        record(.memberAdded(node: node, set: path, member: member, tag: id, wasPresent: present,
                                            field: MemberField(row)))
                    }
                }
            }
        case .setRemove(let remove):
            let node = OpID(remove.node)
            if let (path, row, members) = members(node, remove.set, remove.values) {
                for member in members {
                    let present = !store.liveTags(node, path, member).isEmpty
                    store.removeMember(node, path, member, SetRemoval(op: id, seq: context.seq, base: context.baseServerSeq))
                    if present && store.liveTags(node, path, member).isEmpty {
                        record(.memberRemoved(node: node, set: path, member: member, field: MemberField(row)))
                    }
                }
            }
        case .textInsert(let insert):
            self.insertText(insert, id: id)
        case .textDelete(let delete):
            self.deleteText(delete, id: id)
        case .textMark(let mark):
            self.mark(mark, id: id)
        default:
            break  // Noop only keeps its counter.
        }
    }

    private mutating func create(_ create: Wiretuner_Doc_V1_CreateNode, id: OpID) {
        guard let props = WireMessage.parse(Self.bytes(create.props)) else { return }
        let kind = props.lastMessage(of: schema.kinds)
        guard kind != 0, store.create(id, kind: kind) else { return }
        record(.created(node: id))
        for write in resolver.initial(kind: kind, props: props) {
            store.write(id, write.path, write.value, id)
        }
        store.applyTree(op: id, node: id, parent: OpID(create.parent), position: Array(create.position), creates: true)
    }

    private mutating func set(_ set: Wiretuner_Doc_V1_SetFields, id: OpID) {
        let node = OpID(set.node)
        let kind = store.kind(node)
        guard kind != 0, let values = WireMessage.parse(Self.bytes(set.values)) else { return }
        for path in set.paths {
            let writes = resolver.resolve(kind: kind, path: path, values: values) { exists(node, $0) }
            for write in writes ?? [] {
                let prior = store.register(node, write.path)
                if store.write(node, write.path, write.value, id) {
                    record(.register(node: node, path: write.path, prior: prior, wrote: id))
                }
            }
        }
    }

    // Element ids are this op's counter, counter + 1, ...; each takes its position and, from the
    // i-th occurrence of the SEQUENCE field in `values`, its initial field values.
    private mutating func insert(_ insert: Wiretuner_Doc_V1_ElementInsert, id: OpID) {
        let node = OpID(insert.node)
        guard let values = WireMessage.parse(Self.bytes(insert.values)),
              case .field(let sequence, let row, let container)? = walk(node, insert.sequence, values: values),
              row.policy == .sequence, let message = row.typeName else { return }
        let occurrences = container?.occurrences(UInt32(row.fieldNumber)) ?? []
        for (index, position) in insert.positions.enumerated() {
            let element = OpID(counter: id.counter &+ UInt64(index), replica: id.replica)
            let path = sequence.element(element)
            guard store.insertElement(node, path, position: Array(position), op: element) else { continue }
            record(.elementInserted(node: node, element: path))
            let value = index < occurrences.count ? occurrences[index] : nil
            for write in resolver.initial(element: message, at: path, values: value) {
                store.write(node, write.path, write.value, element)
            }
        }
    }

    // The SET field `path` names on `node`, its row, and the members `props` holds there.
    private func members(
        _ node: OpID, _ path: Wiretuner_Doc_V1_FieldPath, _ props: Wiretuner_Doc_V1_NodeProps
    ) -> (RegisterPath, Schema.FieldPolicy, [[UInt8]])? {
        guard let values = WireMessage.parse(Self.bytes(props)) else { return nil }
        return members(walk(node, path, values: values))
    }

    private func members(_ target: PathResolver.Target?) -> (RegisterPath, Schema.FieldPolicy, [[UInt8]])? {
        guard case .field(let at, let row, let container)? = target, row.policy == .set,
              let members = (container ?? WireMessage.parse([])!).members(
                  UInt32(row.fieldNumber), type: row.type, typeName: row.typeName) else { return nil }
        return (at, row, members)
    }

    // Whether the element or newline character at `path` of `node` exists.
    private func exists(_ node: OpID, _ path: RegisterPath) -> Bool {
        store.element(node, path) != nil || store.isNewline(node, path)
    }

    private func walk(_ node: OpID, _ path: Wiretuner_Doc_V1_FieldPath, values: WireMessage?) -> PathResolver.Target? {
        let kind = store.kind(node)
        guard kind != 0 else { return nil }
        return resolver.walk(kind: kind, path: path, values: values) { exists(node, $0) }
    }

    // The TEXT field `path` names on `node` and its row.
    private func textField(_ node: OpID, _ path: Wiretuner_Doc_V1_FieldPath) -> (RegisterPath, Schema.FieldPolicy)? {
        guard case .field(let at, let row, _)? = walk(node, path, values: nil), row.policy == .text else { return nil }
        return (at, row)
    }

    // Characters take this op's counter, counter + 1, ..., one per Unicode scalar (CRDT-005).
    private mutating func insertText(_ insert: Wiretuner_Doc_V1_TextInsert, id: OpID) {
        let node = OpID(insert.node)
        guard let (path, _) = textField(node, insert.text) else { return }
        let scalars = insert.chars.unicodeScalars.map(\.value)
        let left = OpID(counter: insert.leftOrigin.counter, replica: insert.leftOrigin.replica)
        let right = OpID(counter: insert.rightOrigin.counter, replica: insert.rightOrigin.replica)
        let inserted = store.editText(node, path) { $0.insert(scalars, first: id, left: left, right: right) }
        if !inserted.isEmpty {
            record(.textInserted(node: node, text: path, chars: inserted))
        }
    }

    // Each range names consecutive character ids; a tombstone keeps the greatest delete.
    private mutating func deleteText(_ delete: Wiretuner_Doc_V1_TextDelete, id: OpID) {
        let node = OpID(delete.node)
        guard let (path, _) = textField(node, delete.text), let text = store.text(node, path) else { return }
        var chars: [OpID] = []
        for range in delete.ranges {
            chars += text.ids(from: OpID(counter: range.first.counter, replica: range.first.replica), count: range.count)
        }
        let content = recording == nil ? [:] : deletedContent(node, path, text, chars)
        var deleted: [DeletedChar] = []
        for char in chars where store.editText(node, path, { $0.delete(char, op: id) }) {
            if let removed = content[char] {
                deleted.append(removed)
            }
        }
        if !deleted.isEmpty {
            record(.textDeleted(node: node, text: path, chars: deleted))
        }
    }

    // What undoing the deletion of `chars` needs: each live one's scalar, attributes and, for a
    // newline, its paragraph registers.
    private func deletedContent(_ node: OpID, _ path: RegisterPath, _ text: TextSequence, _ chars: [OpID]) -> [OpID: DeletedChar] {
        let live = chars.filter { !text.isDeleted($0) }
        let attributes = text.attributes(of: live)
        var out: [OpID: DeletedChar] = [:]
        for char in live {
            let prefix = path.element(char)
            let paragraph = text.codepoint(char) == 0x0A
                ? store.registers(node).filter { $0.path.segments.starts(with: prefix.segments) && $0.path != prefix }
                    .map { ParagraphRegister(suffix: Array($0.path.segments.dropFirst(prefix.segments.count)), value: $0.register.value) }
                : []
            out[char] = DeletedChar(id: char, scalar: text.codepoint(char)!, attributes: attributes[char]!.map(\.value),
                                    paragraph: paragraph)
        }
        return out
    }

    // A mark's id is this op's id; its key is the attribute it formats (CRDT-006).
    private mutating func mark(_ op: Wiretuner_Doc_V1_TextMark, id: OpID) {
        let node = OpID(op.node)
        guard let (path, row) = textField(node, op.text) else { return }
        let value: [UInt8] = try! op.value.serializedBytes()
        let mark = TextMark(id: id, start: Self.anchor(op.start), end: Self.anchor(op.end), value: value,
                            key: MarkValue.key(value, featureField: schema.featureField(text: row)))
        var prior: [PriorFormat] = []
        if recording != nil, let key = mark.key, let text = store.text(node, path), text.known(mark.start), text.known(mark.end) {
            let index = text.orderIndex()
            if let range = TextSequence.covered(mark, index, count: text.count) {
                let chars = text.order[range].filter { !text.isDeleted($0) }
                let winners = text.winners(of: key, for: chars)
                prior = chars.map { PriorFormat(char: $0, value: winners[$0]?.value) }
            }
        }
        if store.editText(node, path, { $0.mark(mark) }), let key = mark.key {
            record(.textMarked(node: node, text: path, mark: id, key: key, value: value, prior: prior))
        }
    }

    private static func anchor(_ anchor: Wiretuner_Doc_V1_Anchor) -> Anchor {
        Anchor(char: OpID(counter: anchor.char.counter, replica: anchor.char.replica), before: anchor.before)
    }

    // Proto3 messages without Any fields cannot fail to encode (swift-protobuf only throws for
    // missing proto2 required fields and Any transcoding).
    private static func bytes(_ props: Wiretuner_Doc_V1_NodeProps) -> [UInt8] {
        try! props.serializedBytes()
    }

    /// The register at `path` of `node`, or nil when never written.
    public func register(_ node: OpID, _ path: RegisterPath) -> Register? {
        store.register(node, path)
    }

    /// The retained writes to one register that lost (crdt-model.adoc, "Merge rules").
    public func losingWrites(_ node: OpID, _ path: RegisterPath) -> [Write] {
        store.losingWrites(node, path)
    }

    /// The members `values` (a sparse `NodeProps`) holds at the SET field `path` names on a node
    /// of `kind`, in their canonical form, or nil when the path does not name a SET field.
    public func members(in values: Wiretuner_Doc_V1_NodeProps, kind: UInt32, path: Wiretuner_Doc_V1_FieldPath) -> [[UInt8]]? {
        members(resolver.walk(kind: kind, path: path, values: WireMessage.parse(Self.bytes(values))) { _ in true })?.2
    }

    /// The value `values` (a sparse `NodeProps`) holds for the register at `path` on a node of
    /// `kind` -- the bytes a `SetFields` carrying `values` writes there -- or nil when absent or
    /// when `path` does not name a register field.
    public func registerValue(in values: Wiretuner_Doc_V1_NodeProps, kind: UInt32, path: RegisterPath) -> [UInt8]? {
        guard case .field(_, let row, let container)? = resolver.walk(
            kind: kind, path: path.proto, values: WireMessage.parse(Self.bytes(values)), elementExists: { _ in true }) else { return nil }
        return container?.records(UInt32(row.fieldNumber))
    }

    /// The TEXT field `path` names on `node`, or nil when it holds nothing.
    public func text(_ node: OpID, _ path: RegisterPath) -> TextSequence? {
        store.text(node, path)
    }

    /// The state hash of the merged state (32 bytes, `StateHash`).
    public var stateHash: [UInt8] { StateHash.of(store) }

    // MARK: Garbage collection

    /// The stable point this state's replica acks give (crdt-model.adoc, "Garbage collection"):
    /// the smallest server_seq acknowledged by a replica not `retired`.  A replica the state has
    /// never seen a change from holds nothing back here; the server, which also knows the replicas
    /// that only subscribed, publishes the stable point the replicas collect at.
    public func stablePoint(retired: Set<UInt64> = []) -> UInt64 {
        store.stablePoint(retired: retired)
    }

    /// Whether `op` is causally stable at stable point `stableSeq` (at or above the one collected):
    /// its change was sequenced at or before it.  A replica never writes an op that names a
    /// tombstone deleted by an op stable at the newest stable point it knows, since another
    /// replica may already have collected it.
    public func isStable(_ op: OpID, at stableSeq: UInt64) -> Bool {
        op.counter < (store.stableCounters(at: max(stableSeq, store.stableSeq))[op.replica] ?? 0)
    }

    /// Whether a collection at stable point `stableSeq` and clock `now` would compact `node`: it or
    /// an ancestor is deleted by a write stable there, `deletedNodeRetentionMs` or more before
    /// `now`.  A replica never writes an op naming such a node at the newest point it knows.
    public func isCompactable(_ node: OpID, stableSeq: UInt64, now: Int64) -> Bool {
        let counters = store.stableCounters(at: max(stableSeq, store.stableSeq))
        let (cutoff, overflow) = now.subtractingReportingOverflow(Self.deletedNodeRetentionMs)
        var current: OpID? = node
        while let at = current {
            if let flag = store.deleted(at)?.current, flag.value, flag.op.counter < (counters[flag.op.replica] ?? 0),
               !overflow, store.deletedTime(at) <= cutoff {
                return true
            }
            current = store.placement(at)?.parent
        }
        return false
    }

    /// The origins a client gives a `TextInsert` at live offset `offset` of the TEXT field `path`
    /// of `node` when it knows stable point `stableSeq` (`TextSequence.insertionOrigins(at:skippingStable:)`).
    public func insertionOrigins(_ node: OpID, _ path: RegisterPath, at offset: Int, stableSeq: UInt64) -> (left: OpID, right: OpID) {
        let counters = store.stableCounters(at: max(stableSeq, store.stableSeq))
        return (store.text(node, path) ?? TextSequence()).insertionOrigins(at: offset) {
            $0.counter < (counters[$0.replica] ?? 0)
        }
    }

    /// Collects the state at stable point `stableSeq` (CRDT-010; `NodeStore.collect`): the server
    /// sequence number every replica that could still send an op has acknowledged, which must not
    /// exceed what this state has applied.  Deleted nodes are compacted once their deletion is
    /// stable and `deletedNodeRetentionMs` older than `now` (ms since the epoch; the clock is the
    /// caller's, so replicas collecting at the same point with the same `now` stay equal).  The
    /// state hash is that of the collected state, however many changes arrived between the stable
    /// point and the collection.
    @discardableResult
    public mutating func collect(stableSeq: UInt64, now: Int64 = EngineState.wallClock()) -> Collected {
        store.collect(stableSeq: stableSeq, now: now, retention: Self.deletedNodeRetentionMs)
    }

    /// Milliseconds since the epoch by the system clock: `collect`'s default time source.
    public static func wallClock() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

/// The merge engine actor (docs/spec/client.adoc, "Concurrency"): serialises every change a
/// document's replica applies on its own executor.  `Document` reads the merged state from it.
public actor Engine {
    /// The merge state, readable as a value snapshot.
    public private(set) var state: EngineState

    /// An engine over `schema` (the generated merge table by default).
    public init(schema: Schema = .generated) {
        state = EngineState(schema: schema)
    }

    /// An engine holding `state`, such as one `Snapshot.decode` or `SnapshotTransfer.state` gave.
    public init(state: EngineState) {
        self.state = state
    }

    /// Applies a change, local or remote (`serverSeq` when the server has sequenced it).
    public func apply(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64? = nil) {
        state.apply(change, serverSeq: serverSeq)
    }

    /// Applies a local change and returns its inverse (`EngineState.applyLocal`).
    public func applyLocal(_ change: Wiretuner_Doc_V1_Change) -> Inverse {
        state.applyLocal(change)
    }

    /// Undoes `inverse` as change `seq` of `replica`: builds the undo change from the clock's next
    /// counter (`EngineState.undoChange`), applies it locally, and returns it with the inverse that
    /// redoes it; nil when nothing is left to undo.
    public func undo(
        _ inverse: Inverse, replica: UInt64, seq: UInt64, baseServerSeq: UInt64 = 0, label: String = ""
    ) -> (change: Wiretuner_Doc_V1_Change, redo: Inverse)? {
        guard let change = state.undoChange(inverse, replica: replica, seq: seq, startCounter: state.clock.peek,
                                            baseServerSeq: baseServerSeq, label: label) else { return nil }
        return (change: change, redo: state.applyLocal(change))
    }

    /// Records the server_seq of a local change once the server acknowledges it.
    public func acknowledge(replica: UInt64, seq: UInt64, serverSeq: UInt64) {
        state.acknowledge(replica: replica, seq: seq, serverSeq: serverSeq)
    }

    /// Collects the state at stable point `stableSeq` (`EngineState.collect`).
    @discardableResult
    public func collect(stableSeq: UInt64, now: Int64 = EngineState.wallClock()) -> Collected {
        state.collect(stableSeq: stableSeq, now: now)
    }

    /// Takes counters for a local change of `count` counters and returns the first.
    public func allocate(_ count: Int) -> UInt64 {
        state.clock.allocate(count)
    }

    /// The state hash of the merged state.
    public var stateHash: [UInt8] { state.stateHash }
}
