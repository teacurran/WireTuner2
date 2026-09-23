import WTProto

/// The merge state of one document replica (docs/spec/crdt-model.adoc): a `LamportClock`, the
/// `NodeStore` and the `Schema` it merges with.  Every op applies to every state; an op the
/// engine cannot use is a deterministic no-op ("Totality").  `Engine` is the actor over it;
/// wt-crdt's `Engine` is this type in Java.
///
/// CRDT-001 implements registers: `SetFields` and the register part of `CreateNode` (the node's
/// kind and initial values; parent and position arrive with the tree in CRDT-002).  Other ops
/// only advance the clock until their tasks land.
public struct EngineState: Sendable {
    /// Version of the merge semantics this engine implements, as wt-crdt's `Engine.VERSION`.
    public static let version = "0.1.0"

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

    /// Applies every op of `change`; op `i` has id `(start_counter + i, replica)`.
    public mutating func apply(_ change: Wiretuner_Doc_V1_Change) {
        for (index, op) in change.ops.enumerated() {
            apply(op, id: OpID(counter: change.startCounter &+ UInt64(index), replica: change.replica))
        }
    }

    /// Applies one op with id `id`.
    public mutating func apply(_ op: Wiretuner_Doc_V1_Op, id: OpID) {
        clock.observe(id.counter)
        switch op.op {
        case .create(let create):
            self.create(create, id: id)
        case .set(let set):
            self.set(set, id: id)
        default:
            break  // Tree, sequence, text and set ops arrive with CRDT-002..007.
        }
    }

    private mutating func create(_ create: Wiretuner_Doc_V1_CreateNode, id: OpID) {
        guard let props = WireMessage.parse(Self.bytes(create.props)) else { return }
        let kind = props.lastMessage(of: schema.kinds)
        guard kind != 0, store.create(id, kind: kind) else { return }
        for write in resolver.initial(kind: kind, props: props) {
            store.write(id, write.path, write.value, id)
        }
    }

    private mutating func set(_ set: Wiretuner_Doc_V1_SetFields, id: OpID) {
        let node = OpID(set.node)
        let kind = store.kind(node)
        guard kind != 0, let values = WireMessage.parse(Self.bytes(set.values)) else { return }
        for path in set.paths {
            for write in resolver.resolve(kind: kind, path: path, values: values) ?? [] {
                store.write(node, write.path, write.value, id)
            }
        }
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

    /// Applies a change, local or remote.
    public func apply(_ change: Wiretuner_Doc_V1_Change) {
        state.apply(change)
    }

    /// Takes counters for a local change of `count` ops and returns the first.
    public func allocate(_ count: Int) -> UInt64 {
        state.clock.allocate(count)
    }

    /// The state hash of the merged state.
    public var stateHash: [UInt8] { state.stateHash }
}
