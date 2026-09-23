import WTProto

/// The merge state of one document replica (docs/spec/crdt-model.adoc): a `LamportClock`, the
/// `NodeStore` and the `Schema` it merges with.  Every op applies to every state; an op the
/// engine cannot use is a deterministic no-op ("Totality").  `Engine` is the actor over it;
/// wt-crdt's `Engine` is this type in Java.
///
/// Implemented: registers (`SetFields`, CRDT-001), the node tree (`CreateNode`, `MoveNode`,
/// `SetDeleted`, CRDT-002), sets (`SetAdd`, `SetRemove`, CRDT-007) and sequences
/// (`ElementInsert`, `ElementMove`, `ElementDelete`, CRDT-004).  Text ops only advance the clock
/// until CRDT-005/006.
public struct EngineState: Sendable {
    /// Version of the merge semantics this engine implements, as wt-crdt's `Engine.VERSION`.
    public static let version = "0.2.0"

    /// The change an op belongs to: its seq and causal past (0 for an op applied on its own).
    public struct Context: Sendable {
        public var seq: UInt64
        public var baseServerSeq: UInt64

        public init(seq: UInt64 = 0, baseServerSeq: UInt64 = 0) {
            self.seq = seq
            self.baseServerSeq = baseServerSeq
        }
    }

    /// The merge table this engine uses.
    public let schema: Schema
    private let resolver: PathResolver
    /// This replica's Lamport clock; every applied op advances it.
    public var clock = LamportClock()
    /// The merged state.
    public private(set) var store = NodeStore()

    /// An engine over `schema` (the generated merge table by default).
    public init(schema: Schema = .generated) {
        self.schema = schema
        resolver = PathResolver(schema: schema)
    }

    /// Applies every op of `change`.  Op `i` has counter `start_counter` plus the counters the ops
    /// before it took: one each, or one per element or character for inserts (change.proto).
    /// `serverSeq` is the server's sequence number for the change when known (a remote change, or
    /// a local one already acknowledged): sets judge a concurrent remove by it.
    public mutating func apply(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64? = nil) {
        if let serverSeq {
            acknowledge(replica: change.replica, seq: change.seq, serverSeq: serverSeq)
        }
        let context = Context(seq: change.seq, baseServerSeq: change.baseServerSeq)
        var counter = change.startCounter
        for op in change.ops {
            apply(op, id: OpID(counter: counter, replica: change.replica), context: context)
            counter &+= Self.counters(op)
        }
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

    /// Applies one op with id `id` (its first counter).
    public mutating func apply(_ op: Wiretuner_Doc_V1_Op, id: OpID, context: Context = Context()) {
        clock.observe(id.counter &+ Self.counters(op) &- 1)
        switch op.op {
        case .create(let create):
            self.create(create, id: id)
        case .set(let set):
            self.set(set, id: id)
        case .move(let move):
            store.applyTree(op: id, node: OpID(move.node), parent: OpID(move.parent), position: Array(move.position),
                            creates: false)
        case .setDeleted(let setDeleted):
            store.setDeleted(OpID(setDeleted.node), setDeleted.deleted, id)
        case .elementInsert(let insert):
            self.insert(insert, id: id)
        case .elementMove(let move):
            let node = OpID(move.node)
            if case .element(let path, _, _)? = walk(node, move.element, values: nil) {
                store.moveElement(node, path, position: Array(move.position), op: id)
            }
        case .elementDelete(let delete):
            let node = OpID(delete.node)
            for element in delete.elements {
                if case .element(let path, _, _)? = walk(node, element, values: nil) {
                    store.deleteElement(node, path, deleted: delete.deleted, op: id)
                }
            }
        case .setAdd(let add):
            let node = OpID(add.node)
            if let (path, members) = members(node, add.set, add.values) {
                for member in members {
                    store.addMember(node, path, member, SetAddition(op: id, seq: context.seq))
                }
            }
        case .setRemove(let remove):
            let node = OpID(remove.node)
            if let (path, members) = members(node, remove.set, remove.values) {
                for member in members {
                    store.removeMember(node, path, member, SetRemoval(op: id, seq: context.seq, base: context.baseServerSeq))
                }
            }
        default:
            break  // Text ops arrive with CRDT-005/006; Noop only keeps its counter.
        }
    }

    private mutating func create(_ create: Wiretuner_Doc_V1_CreateNode, id: OpID) {
        guard let props = WireMessage.parse(Self.bytes(create.props)) else { return }
        let kind = props.lastMessage(of: schema.kinds)
        guard kind != 0, store.create(id, kind: kind) else { return }
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
            let writes = resolver.resolve(kind: kind, path: path, values: values) { self.store.element(node, $0) != nil }
            for write in writes ?? [] {
                store.write(node, write.path, write.value, id)
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
            let value = index < occurrences.count ? occurrences[index] : nil
            for write in resolver.initial(element: message, at: path, values: value) {
                store.write(node, write.path, write.value, element)
            }
        }
    }

    // The SET field `path` names on `node` and the members `props` holds there.
    private func members(
        _ node: OpID, _ path: Wiretuner_Doc_V1_FieldPath, _ props: Wiretuner_Doc_V1_NodeProps
    ) -> (RegisterPath, [[UInt8]])? {
        guard let values = WireMessage.parse(Self.bytes(props)) else { return nil }
        return members(walk(node, path, values: values))
    }

    private func members(_ target: PathResolver.Target?) -> (RegisterPath, [[UInt8]])? {
        guard case .field(let at, let row, let container)? = target, row.policy == .set,
              let members = (container ?? WireMessage.parse([])!).members(
                  UInt32(row.fieldNumber), type: row.type, typeName: row.typeName) else { return nil }
        return (at, members)
    }

    private func walk(_ node: OpID, _ path: Wiretuner_Doc_V1_FieldPath, values: WireMessage?) -> PathResolver.Target? {
        let kind = store.kind(node)
        guard kind != 0 else { return nil }
        return resolver.walk(kind: kind, path: path, values: values) { store.element(node, $0) != nil }
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
        members(resolver.walk(kind: kind, path: path, values: WireMessage.parse(Self.bytes(values))) { _ in true })?.1
    }

    /// The state hash of the merged state (32 bytes, `StateHash`).
    public var stateHash: [UInt8] { StateHash.of(store) }
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

    /// Applies a change, local or remote (`serverSeq` when the server has sequenced it).
    public func apply(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64? = nil) {
        state.apply(change, serverSeq: serverSeq)
    }

    /// Records the server_seq of a local change once the server acknowledges it.
    public func acknowledge(replica: UInt64, seq: UInt64, serverSeq: UInt64) {
        state.acknowledge(replica: replica, seq: seq, serverSeq: serverSeq)
    }

    /// Takes counters for a local change of `count` counters and returns the first.
    public func allocate(_ count: Int) -> UInt64 {
        state.clock.allocate(count)
    }

    /// The state hash of the merged state.
    public var stateHash: [UInt8] { state.stateHash }
}
