import Foundation
import WTProto

/// `DocumentSnapshot` encoding and decoding (docs/spec/crdt-model.adoc, "Snapshots"; CRDT-009),
/// byte for byte the same as wt-crdt's `Snapshot`.  The engines write the message themselves,
/// field by field in number order with proto3 defaults left out, rather than through generated
/// classes: a register's value is its records exactly as they arrived, which swift-protobuf and
/// protobuf-java would each reorder differently when re-serialising unknown fields.
///
/// * `nodes`: every node the state hash covers, by id.  `Node.props` holds the kind case and every
///   register's current value, assembled from the register paths: fields in number order, a
///   SEQUENCE field as one occurrence per element (tombstones included, in sequence order, `id`
///   first), a TEXT field as its `RichText` (`chars` in document order with id, codepoint,
///   deleted, origins and the paragraph registers; `marks` by id).  `registers` stamps every
///   written register by path (an unset one has a stamp and no value); `elements` holds every
///   sequence element and character by path (a character's position is empty).
/// * `move_log`, `replicas` (highest seq, greatest `base_server_seq`), `max_counter` (the clock),
///   `state_hash` (`StateHash` of the state, verified on decode).
/// * Fields doc.v1 does not declare yet, written at numbers proposed for snapshot.proto (see
///   the CRDT-009 notes on the page): `NodeState.sets = 6` (every set member's add and remove
///   history, which presence is computed from), `NodeState.texts = 7` (the paths of the node's
///   TEXT fields), `MoveLogEntry.old_op = 8` (the op of the placement an entry replaced), and
///   `DocumentSnapshot.sequenced = 9` (the server_seq of every sequenced change, which set
///   removes are judged by).
///
/// The change log -- the losing writes -- is not part of a snapshot; a decoded state retains the
/// writes applied after it.
public enum Snapshot {
    /// Why a snapshot could not be decoded.
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    static let nodeSets: UInt32 = 6
    static let nodeTexts: UInt32 = 7
    static let moveOldOp: UInt32 = 8
    static let sequencedField: UInt32 = 9

    // MARK: Encoding

    /// The canonical `DocumentSnapshot` of `state` at `serverSeq`.
    public static func encode(_ state: EngineState, serverSeq: UInt64 = 0) -> [UInt8] {
        let store = state.store
        var out = WireWriter()
        out.varintField(1, serverSeq)
        for node in store.nodes {
            out.lenField(2, nodeState(store, node))
        }
        for entry in store.moveLog {
            out.lenField(3, moveLogEntry(entry))
        }
        for (replica, replicaState) in store.replicas {
            var inner = WireWriter()
            inner.fixed64Field(1, replica)
            inner.varintField(2, replicaState.seq)
            inner.varintField(3, replicaState.ackedServerSeq)
            out.lenField(4, inner.bytes)
        }
        out.varintField(6, state.clock.max)
        out.lenField(8, StateHash.of(store))
        for change in store.sequencedChanges {
            var inner = WireWriter()
            inner.fixed64Field(1, change.replica)
            inner.varintField(2, change.seq)
            inner.varintField(3, change.serverSeq)
            out.lenField(sequencedField, inner.bytes)
        }
        return out.bytes
    }

    private static func nodeState(_ store: NodeStore, _ node: OpID) -> [UInt8] {
        let placement = store.placement(node)
        let deleted = store.deleted(node)?.current
        var plain = WireWriter()
        plain.idField(1, node)
        if let placement {
            plain.idField(2, placement.parent)
            plain.bytesField(3, placement.position)
        }
        plain.varintField(4, deleted?.value == true ? 1 : 0)
        plain.bytesField(5, props(store, node))
        var out = WireWriter()
        out.lenField(1, plain.bytes)
        if let placement {
            out.idField(2, placement.op)
        }
        if let deleted {
            out.idField(3, deleted.op)
        }
        for (path, register) in store.registers(node) {
            var stamp = WireWriter()
            stamp.lenField(1, WireWriter.path(path))
            stamp.idField(2, register.op)
            out.lenField(4, stamp.bytes)
        }
        for element in elementStates(store, node) {
            out.lenField(5, element)
        }
        for (path, members) in store.setHistories(node) {
            var set = WireWriter()
            set.lenField(1, WireWriter.path(path))
            for (member, history) in members {
                var entry = WireWriter()
                entry.lenField(1, member)
                for add in history.adds {
                    entry.lenField(2, tag(add.op, seq: add.seq, base: 0))
                }
                for removal in history.removes {
                    entry.lenField(3, tag(removal.op, seq: removal.seq, base: removal.base))
                }
                set.lenField(2, entry.bytes)
            }
            out.lenField(nodeSets, set.bytes)
        }
        for path in store.textPaths(node) {
            out.lenField(nodeTexts, WireWriter.path(path))
        }
        return out.bytes
    }

    private static func tag(_ op: OpID, seq: UInt64, base: UInt64) -> [UInt8] {
        var out = WireWriter()
        out.idField(1, op)
        out.varintField(2, seq)
        out.varintField(3, base)
        return out.bytes
    }

    // Every sequence element and character of `node`, by path.
    private static func elementStates(_ store: NodeStore, _ node: OpID) -> [[UInt8]] {
        var states: [(path: RegisterPath, bytes: [UInt8])] = []
        for (path, element) in store.elements(node) {
            guard case .element(let id)? = path.segments.last else { continue }
            var out = WireWriter()
            out.lenField(1, WireWriter.path(path))
            out.bytesField(2, element.position.current.value)
            if element.position.current.op != id {
                out.idField(3, element.position.current.op)
            }
            if let deleted = element.deleted?.current {
                out.varintField(4, deleted.value ? 1 : 0)
                out.idField(5, deleted.op)
            }
            states.append((path: path, bytes: out.bytes))
        }
        for path in store.textPaths(node) {
            let text = store.text(node, path)!
            for char in text.order {
                var out = WireWriter()
                out.lenField(1, WireWriter.path(path.element(char)))
                if let deleted = text.deletedOp(char) {
                    out.varintField(4, 1)
                    out.idField(5, deleted)
                }
                states.append((path: path.element(char), bytes: out.bytes))
            }
        }
        return states.sorted { $0.path < $1.path }.map(\.bytes)
    }

    private static func moveLogEntry(_ entry: MoveLogEntry) -> [UInt8] {
        var out = WireWriter()
        out.idField(1, entry.op)
        out.idField(2, entry.node)
        if let old = entry.old {
            out.idField(3, old.parent)
            out.bytesField(4, old.position)
        }
        out.idField(5, entry.parent)
        out.bytesField(6, entry.position)
        out.varintField(7, entry.applied ? 1 : 0)
        if let old = entry.old {
            out.idField(moveOldOp, old.op)
        }
        return out.bytes
    }

    // MARK: Node.props

    /// The registers, elements and texts of one node as a tree of field and element segments.
    private final class PropsTree {
        var leaf: [UInt8]?
        var fields: [UInt32: PropsTree] = [:]
        var elements: [OpID: PropsTree] = [:]
        /// The element order of a SEQUENCE field.
        var order: [OpID]?
        /// The text of a TEXT field.
        var text: TextSequence?

        func child(_ segment: RegisterPath.Segment) -> PropsTree {
            switch segment {
            case .field(let number):
                if let child = fields[number] { return child }
                let child = PropsTree()
                fields[number] = child
                return child
            case .element(let id):
                if let child = elements[id] { return child }
                let child = PropsTree()
                elements[id] = child
                return child
            }
        }

        func at(_ path: RegisterPath) -> PropsTree {
            path.segments.reduce(self) { $0.child($1) }
        }

        func encode() -> [UInt8] {
            var out = WireWriter()
            for number in fields.keys.sorted() {
                let child = fields[number]!
                if let leaf = child.leaf {
                    out.raw(leaf)
                } else if let order = child.order {
                    for id in order {
                        out.lenField(number, elementWithID(id, child))
                    }
                } else if let text = child.text {
                    out.lenField(number, richText(text, child))
                } else {
                    out.lenField(number, child.encode())
                }
            }
            return out.bytes
        }

        private func elementWithID(_ id: OpID, _ container: PropsTree) -> [UInt8] {
            var out = WireWriter()
            out.idField(1, id)
            out.raw(container.elements[id]?.encode() ?? [])
            return out.bytes
        }

        private func richText(_ text: TextSequence, _ container: PropsTree) -> [UInt8] {
            var out = WireWriter()
            for char in text.order {
                let origins = text.origins(char)!
                var entry = WireWriter()
                entry.idField(1, char)
                entry.varintField(2, UInt64(text.codepoint(char)!))
                entry.varintField(3, text.isDeleted(char) ? 1 : 0)
                entry.optionalIdField(4, origins.left)
                entry.optionalIdField(5, origins.right)
                entry.raw(container.elements[char]?.encode() ?? [])
                out.lenField(PathResolver.charsField, entry.bytes)
            }
            for mark in text.sortedMarks {
                var entry = WireWriter()
                entry.idField(1, mark.id)
                entry.lenField(2, anchor(mark.start))
                entry.lenField(3, anchor(mark.end))
                entry.lenField(4, mark.value)
                out.lenField(2, entry.bytes)
            }
            return out.bytes
        }

        private func anchor(_ anchor: Anchor) -> [UInt8] {
            var out = WireWriter()
            out.optionalIdField(1, anchor.char)
            out.varintField(2, anchor.before ? 1 : 0)
            return out.bytes
        }
    }

    // Every node a snapshot holds has a kind: a created node, or the document or settings node.
    private static func props(_ store: NodeStore, _ node: OpID) -> [UInt8] {
        let kind = store.kind(node)
        let root = PropsTree()
        _ = root.child(.field(kind))
        for path in store.textPaths(node) {
            root.at(path).text = store.text(node, path)
        }
        var sequences: Set<RegisterPath> = []
        for (path, _) in store.elements(node) {
            _ = root.at(path)
            sequences.insert(path.parent!)
        }
        for sequence in sequences {
            root.at(sequence).order = store.elementOrder(node, sequence)
        }
        for (path, register) in store.registers(node) {
            if let value = register.value {
                root.at(path).leaf = value
            }
        }
        return root.encode()
    }

    // MARK: Decoding

    /// The state `bytes` (a `DocumentSnapshot`) holds, merging with `schema`.  Throws when the
    /// bytes are not a snapshot or the decoded state does not have the snapshot's `state_hash`.
    public static func decode(_ bytes: [UInt8], schema: Schema = .generated) throws(Failure) -> EngineState {
        var nodes: [Range<Int>] = []
        var log: [MoveLogEntry] = []
        var replicas: [UInt64: ReplicaState] = [:]
        var sequenced: [(replica: UInt64, seq: UInt64, serverSeq: UInt64)] = []
        var maxCounter: UInt64 = 0
        var hash: [UInt8]?
        try Scan.each(bytes[...]) { (record: Scan.Record) throws(Failure) in
            switch record.number {
            case 2: nodes.append(record.payload.startIndex..<record.payload.endIndex)
            case 3: log.append(try moveLogEntry(record.payload))
            case 4:
                var replica: UInt64 = 0
                var state = ReplicaState(seq: 0, ackedServerSeq: 0)
                try Scan.each(record.payload) { (field: Scan.Record) throws(Failure) in
                    switch field.number {
                    case 1: replica = field.value
                    case 2: state.seq = field.value
                    case 3: state.ackedServerSeq = field.value
                    default: break
                    }
                }
                replicas[replica] = state
            case 6: maxCounter = record.value
            case 8: hash = Array(record.payload)
            case sequencedField:
                var change: (replica: UInt64, seq: UInt64, serverSeq: UInt64) = (0, 0, 0)
                try Scan.each(record.payload) { (field: Scan.Record) throws(Failure) in
                    switch field.number {
                    case 1: change.replica = field.value
                    case 2: change.seq = field.value
                    case 3: change.serverSeq = field.value
                    default: break
                    }
                }
                sequenced.append(change)
            default: break
            }
        }
        let decoder = try decodeNodes(bytes, nodes, schema: schema)
        var state = EngineState(schema: schema)
        state.clock = LamportClock(max: maxCounter)
        state.store.restore(created: decoder.created, registers: decoder.registers, deleted: decoder.deleted,
                            elements: decoder.elements, sets: decoder.sets, texts: decoder.texts, sequenced: sequenced,
                            replicas: replicas,
                            tree: Tree(log: log, placements: decoder.placements, live: Set(decoder.created.keys)))
        if let hash, hash != state.stateHash {
            throw Failure(description: "state_hash \(Bytes.hex(hash)) does not match the decoded state's \(Bytes.hex(state.stateHash))")
        }
        return state
    }

    /// Decodes the `NodeState`s in parallel: each worker copies the bytes of a contiguous run of
    /// nodes (so no two threads share a buffer's reference count) and decodes them on its own; the
    /// results merge by node, which never overlap.
    private static func decodeNodes(_ bytes: [UInt8], _ nodes: [Range<Int>], schema: Schema) throws(Failure) -> Decoder {
        let workers = Swift.max(1, Swift.min(ProcessInfo.processInfo.activeProcessorCount, nodes.count / 1_024))
        var results = [Result<Decoder, Failure>?](repeating: nil, count: workers)
        results.withUnsafeMutableBufferPointer { slots in
            let slots = UnsafeSendable(slots)
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                let first = nodes.count * worker / workers
                let end = nodes.count * (worker + 1) / workers
                slots.value[worker] = Result { () throws(Failure) -> Decoder in
                    var decoder = Decoder(schema: schema)
                    guard first < end else { return decoder }
                    let base = nodes[first].lowerBound
                    let local = Array(bytes[base..<nodes[end - 1].upperBound])
                    for index in first..<end {
                        try decoder.node(local[(nodes[index].lowerBound - base)..<(nodes[index].upperBound - base)])
                    }
                    return decoder
                }
            }
        }
        var merged = Decoder(schema: schema)
        for result in results {
            try merged.merge(result!.get())
        }
        return merged
    }

    /// The `state_hash` an encoded snapshot carries, or nil when it has none or does not parse.
    public static func stateHash(_ bytes: [UInt8]) -> [UInt8]? {
        var hash: [UInt8]?
        try? Scan.each(bytes[...]) { (record: Scan.Record) throws(Failure) in
            if record.number == 8 {
                hash = Array(record.payload)
            }
        }
        return hash
    }

    private static func moveLogEntry(_ bytes: ArraySlice<UInt8>) throws(Failure) -> MoveLogEntry {
        var op = OpID.zero, node = OpID.zero, parent = OpID.zero
        var position: [UInt8] = []
        var oldParent: OpID?
        var oldPosition: [UInt8] = []
        var oldOp = OpID.zero
        var applied = false
        try Scan.each(bytes) { (field: Scan.Record) throws(Failure) in
            switch field.number {
            case 1: op = try Scan.id(field.payload)
            case 2: node = try Scan.id(field.payload)
            case 3: oldParent = try Scan.id(field.payload)
            case 4: oldPosition = Array(field.payload)
            case 5: parent = try Scan.id(field.payload)
            case 6: position = Array(field.payload)
            case 7: applied = field.value != 0
            case moveOldOp: oldOp = try Scan.id(field.payload)
            default: break
            }
        }
        return MoveLogEntry(op: op, node: node, parent: parent, position: position, creates: op == node,
                            old: oldParent.map { Placement(parent: $0, position: oldPosition, op: oldOp) }, applied: applied)
    }
}

/// Zero-copy reads of protobuf records for snapshot decoding: each record's field number, wire
/// type, varint or fixed value, and payload as a slice of the snapshot's bytes.
enum Scan {
    struct Record {
        let number: UInt32
        let wireType: Int
        /// A VARINT's value, or a fixed value read little-endian.
        let value: UInt64
        /// A LEN record's payload (empty otherwise).
        let payload: ArraySlice<UInt8>
    }

    private static func varint(_ bytes: ArraySlice<UInt8>, _ index: inout Int) throws(Snapshot.Failure) -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.endIndex && shift < 70 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 {
                return value
            }
            shift += 7
        }
        throw Snapshot.Failure(description: "a snapshot message does not parse")
    }

    /// The records of one message, in order.
    struct Iterator {
        let bytes: ArraySlice<UInt8>
        var index: Int

        init(_ bytes: ArraySlice<UInt8>) {
            self.bytes = bytes
            index = bytes.startIndex
        }

        mutating func next() throws(Snapshot.Failure) -> Record? {
            guard index < bytes.endIndex else { return nil }
            let tag = try varint(bytes, &index)
            let number = tag >> 3
            let wireType = Int(tag & 7)
            guard number >= 1, number <= 0x1FFF_FFFF else { throw Snapshot.Failure(description: "a snapshot message does not parse") }
            switch wireType {
            case WireMessage.varint:
                return Record(number: UInt32(number), wireType: wireType, value: try varint(bytes, &index), payload: [])
            case WireMessage.len:
                let length = try varint(bytes, &index)
                guard length <= UInt64(bytes.endIndex - index) else { throw Snapshot.Failure(description: "a snapshot message does not parse") }
                let payload = bytes[index..<index + Int(length)]
                index += Int(length)
                return Record(number: UInt32(number), wireType: wireType, value: 0, payload: payload)
            case WireMessage.fixed64, WireMessage.fixed32:
                let width = wireType == WireMessage.fixed64 ? 8 : 4
                guard width <= bytes.endIndex - index else { throw Snapshot.Failure(description: "a snapshot message does not parse") }
                var value: UInt64 = 0
                for offset in stride(from: width - 1, through: 0, by: -1) {
                    value = value << 8 | UInt64(bytes[index + offset])
                }
                index += width
                return Record(number: UInt32(number), wireType: wireType, value: value, payload: [])
            default:
                throw Snapshot.Failure(description: "a snapshot message does not parse")
            }
        }
    }

    /// Calls `body` with every record of `bytes`, in order.
    static func each(
        _ bytes: ArraySlice<UInt8>, _ body: (Record) throws(Snapshot.Failure) -> Void
    ) throws(Snapshot.Failure) {
        var records = Iterator(bytes)
        while let record = try records.next() {
            try body(record)
        }
    }

    /// An `OpId`/`ElementId` message.
    static func id(_ bytes: ArraySlice<UInt8>) throws(Snapshot.Failure) -> OpID {
        var id = OpID.zero
        var records = Iterator(bytes)
        while let field = try records.next() {
            if field.number == 1 { id.counter = field.value } else if field.number == 2 { id.replica = field.value }
        }
        return id
    }

    /// A `FieldPath` message's segments.
    static func segments(_ bytes: ArraySlice<UInt8>) throws(Snapshot.Failure) -> [RegisterPath.Segment] {
        var segments: [RegisterPath.Segment] = []
        var records = Iterator(bytes)
        while let segment = try records.next() {
            guard segment.number == 1 else { continue }
            var parsed = RegisterPath.Segment.field(0)
            var fields = Iterator(segment.payload)
            while let field = try fields.next() {
                if field.number == 1 {
                    parsed = .field(UInt32(truncatingIfNeeded: field.value))
                } else if field.number == 2 {
                    parsed = .element(try id(field.payload))
                }
            }
            segments.append(parsed)
        }
        guard !segments.isEmpty else { throw Snapshot.Failure(description: "an empty path") }
        return segments
    }
}

/// A value handed to concurrent work that only touches disjoint parts of it.
struct UnsafeSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Decodes `NodeState`s, interning the register paths many nodes share.
private struct Decoder {
    let schema: Schema
    let resolver: PathResolver
    var created: [OpID: UInt32] = [:]
    var registers: [OpID: [RegisterPath: Register]] = [:]
    var deleted: [OpID: Cell<Bool>] = [:]
    var elements: [OpID: [RegisterPath: Element]] = [:]
    var sets: [OpID: [RegisterPath: [[UInt8]: MemberHistory]]] = [:]
    var texts: [OpID: [RegisterPath: TextSequence]] = [:]
    var placements: [OpID: Placement] = [:]
    private var paths: [PathKey: RegisterPath] = [:]

    /// A `FieldPath`'s bytes, hashed in bulk.
    private struct PathKey: Hashable {
        let bytes: ArraySlice<UInt8>

        static func == (lhs: PathKey, rhs: PathKey) -> Bool {
            lhs.bytes.elementsEqual(rhs.bytes)
        }

        func hash(into hasher: inout Hasher) {
            bytes.withUnsafeBytes { hasher.combine(bytes: $0) }
        }
    }

    init(schema: Schema) {
        self.schema = schema
        resolver = PathResolver(schema: schema)
    }

    /// Takes in another decoder's nodes (they never overlap: each node is one `NodeState`).
    mutating func merge(_ other: Decoder) {
        created.merge(other.created) { a, _ in a }
        registers.merge(other.registers) { a, _ in a }
        deleted.merge(other.deleted) { a, _ in a }
        elements.merge(other.elements) { a, _ in a }
        sets.merge(other.sets) { a, _ in a }
        texts.merge(other.texts) { a, _ in a }
        placements.merge(other.placements) { a, _ in a }
    }

    /// The `FieldPath` in `bytes`, interned: paths without element segments repeat across nodes;
    /// paths through elements are used once or twice each and are not kept.
    mutating func path(_ bytes: ArraySlice<UInt8>) throws(Snapshot.Failure) -> RegisterPath {
        let key = PathKey(bytes: bytes)
        if let known = paths[key] { return known }
        let segments = try Scan.segments(bytes)
        let path = RegisterPath(segments: segments)
        if !segments.contains(where: { if case .element = $0 { true } else { false } }) {
            paths[key] = path
        }
        return path
    }

    mutating func node(_ bytes: ArraySlice<UInt8>) throws(Snapshot.Failure) {
        var plain: ArraySlice<UInt8> = []
        var treeOp = OpID.zero
        var deletedOp: OpID?
        var stamps: [(path: ArraySlice<UInt8>, op: OpID)] = []
        var elementStates: [ArraySlice<UInt8>] = []
        var setStates: [ArraySlice<UInt8>] = []
        var textPaths: Set<RegisterPath> = []
        try Scan.each(bytes) { (field: Scan.Record) throws(Snapshot.Failure) in
            switch field.number {
            case 1: plain = field.payload
            case 2: treeOp = try Scan.id(field.payload)
            case 3: deletedOp = try Scan.id(field.payload)
            case 4:
                var path: ArraySlice<UInt8> = []
                var op = OpID.zero
                try Scan.each(field.payload) { (inner: Scan.Record) throws(Snapshot.Failure) in
                    if inner.number == 1 { path = inner.payload } else if inner.number == 2 { op = try Scan.id(inner.payload) }
                }
                stamps.append((path: path, op: op))
            case 5: elementStates.append(field.payload)
            case Snapshot.nodeSets: setStates.append(field.payload)
            case Snapshot.nodeTexts: textPaths.insert(try path(field.payload))
            default: break
            }
        }
        var id = OpID.zero
        var parent: OpID?
        var position: [UInt8] = []
        var isDeleted = false
        var propsBytes: ArraySlice<UInt8> = []
        try Scan.each(plain) { (field: Scan.Record) throws(Snapshot.Failure) in
            switch field.number {
            case 1: id = try Scan.id(field.payload)
            case 2: parent = try Scan.id(field.payload)
            case 3: position = Array(field.payload)
            case 4: isDeleted = field.value != 0
            case 5: propsBytes = field.payload
            default: break
            }
        }
        guard let props = WireMessage.parse(Array(propsBytes)) else { throw Snapshot.Failure(description: "a snapshot message does not parse") }
        let kind = props.lastField ?? 0
        let wellKnown = Tree.isWellKnown(id)
        if !wellKnown && kind != 0 {
            created[id] = kind
        }
        if let parent, !wellKnown {
            placements[id] = Placement(parent: parent, position: position, op: treeOp)
        }
        if let deletedOp {
            deleted[id] = Cell(isDeleted, deletedOp)
        }
        let reader = PropsReader(props: props, texts: textPaths)
        var nodeRegisters: [RegisterPath: Register] = [:]
        nodeRegisters.reserveCapacity(stamps.count)
        // Stamps come by path, so registers of one message follow each other: its message is
        // looked up once for them all.
        var container: (prefix: ArraySlice<UInt8>, message: WireMessage?)?
        for stamp in stamps {
            let path = try self.path(stamp.path)
            var value: [UInt8]?
            if case .field(let number)? = path.segments.last, path.segments.count > 1 {
                let prefix = path.canonical.dropLast(5)
                if container?.prefix != prefix {
                    container = (prefix: prefix, message: reader.message(path.parent!))
                }
                value = container!.message?.records(number)
            }
            nodeRegisters[path] = Register(value: value, op: stamp.op)
        }
        if !nodeRegisters.isEmpty { registers[id] = nodeRegisters }
        var charDeletes: [RegisterPath: OpID] = [:]
        var nodeElements: [RegisterPath: Element] = [:]
        for state in elementStates {
            var pathBytes: ArraySlice<UInt8> = []
            var elementPosition: [UInt8] = []
            var positionOp: OpID?
            var elementDeleted = false
            var elementDeletedOp: OpID?
            try Scan.each(state) { (field: Scan.Record) throws(Snapshot.Failure) in
                switch field.number {
                case 1: pathBytes = field.payload
                case 2: elementPosition = Array(field.payload)
                case 3: positionOp = try Scan.id(field.payload)
                case 4: elementDeleted = field.value != 0
                case 5: elementDeletedOp = try Scan.id(field.payload)
                default: break
                }
            }
            let path = try path(pathBytes)
            guard case .element(let element)? = path.segments.last, path.segments.count > 1 else { continue }
            if !textPaths.isEmpty, textPaths.contains(path.parent!) {
                charDeletes[path] = elementDeletedOp
                continue
            }
            nodeElements[path] = Element(position: Cell(elementPosition, positionOp ?? element),
                                         deleted: elementDeletedOp.map { Cell(elementDeleted, $0) })
        }
        if !nodeElements.isEmpty { elements[id] = nodeElements }
        var nodeTexts: [RegisterPath: TextSequence] = [:]
        for path in textPaths {
            var featureField: UInt32?
            if case .field(let kind)? = path.segments.first,
               case .field(_, let row, _)? = resolver.walk(kind: kind, path: path.proto, values: nil, elementExists: { _ in true }) {
                featureField = schema.featureField(text: row)
            }
            let text = try Self.text(reader.message(path), path, charDeletes, featureField)
            if !text.isEmpty {
                nodeTexts[path] = text
            }
        }
        if !nodeTexts.isEmpty { texts[id] = nodeTexts }
        var nodeSets: [RegisterPath: [[UInt8]: MemberHistory]] = [:]
        for state in setStates {
            var pathBytes: ArraySlice<UInt8> = []
            var members: [[UInt8]: MemberHistory] = [:]
            try Scan.each(state) { (field: Scan.Record) throws(Snapshot.Failure) in
                if field.number == 1 {
                    pathBytes = field.payload
                } else if field.number == 2 {
                    var member: [UInt8] = []
                    var history = MemberHistory()
                    try Scan.each(field.payload) { (entry: Scan.Record) throws(Snapshot.Failure) in
                        switch entry.number {
                        case 1: member = Array(entry.payload)
                        case 2, 3:
                            var op = OpID.zero
                            var seq: UInt64 = 0
                            var base: UInt64 = 0
                            try Scan.each(entry.payload) { (tag: Scan.Record) throws(Snapshot.Failure) in
                                switch tag.number {
                                case 1: op = try Scan.id(tag.payload)
                                case 2: seq = tag.value
                                case 3: base = tag.value
                                default: break
                                }
                            }
                            if entry.number == 2 {
                                history.adds.append(SetAddition(op: op, seq: seq))
                            } else {
                                history.removes.append(SetRemoval(op: op, seq: seq, base: base))
                            }
                        default: break
                        }
                    }
                    members[member] = history
                }
            }
            nodeSets[try path(pathBytes)] = members
        }
        if !nodeSets.isEmpty { sets[id] = nodeSets }
    }

    private static func text(
        _ richText: WireMessage?, _ path: RegisterPath, _ deletes: [RegisterPath: OpID], _ featureField: UInt32?
    ) throws(Snapshot.Failure) -> TextSequence {
        var chars: [RestoredChar] = []
        var marks: [TextMark] = []
        for bytes in richText?.payloads(PathResolver.charsField) ?? [] {
            var id = OpID.zero, left = OpID.zero, right = OpID.zero
            var scalar: UInt32 = 0
            try Scan.each(bytes[...]) { (field: Scan.Record) throws(Snapshot.Failure) in
                switch field.number {
                case 1: id = try Scan.id(field.payload)
                case 2: scalar = UInt32(truncatingIfNeeded: field.value)
                case 4: left = try Scan.id(field.payload)
                case 5: right = try Scan.id(field.payload)
                default: break
                }
            }
            chars.append(RestoredChar(id: id, scalar: scalar, left: left, right: right, deleted: deletes[path.element(id)]))
        }
        for bytes in richText?.payloads(2) ?? [] {
            var id = OpID.zero
            var start = Anchor.start, end = Anchor.start
            var value: [UInt8] = []
            try Scan.each(bytes[...]) { (field: Scan.Record) throws(Snapshot.Failure) in
                switch field.number {
                case 1: id = try Scan.id(field.payload)
                case 2: start = try anchor(field.payload)
                case 3: end = try anchor(field.payload)
                case 4: value = Array(field.payload)
                default: break
                }
            }
            marks.append(TextMark(id: id, start: start, end: end, value: value, key: MarkValue.key(value, featureField: featureField)))
        }
        return TextSequence.restore(chars: chars, marks: marks)
    }

    private static func anchor(_ bytes: ArraySlice<UInt8>) throws(Snapshot.Failure) -> Anchor {
        var anchor = Anchor(char: .zero, before: false)
        try Scan.each(bytes) { (field: Scan.Record) throws(Snapshot.Failure) in
            if field.number == 1 { anchor.char = try Scan.id(field.payload) } else if field.number == 2 { anchor.before = field.value != 0 }
        }
        return anchor
    }
}

/// Finds the message at a path inside `Node.props`, with the elements of each SEQUENCE or TEXT
/// field indexed by id on first use.
private final class PropsReader {
    private let props: WireMessage
    private let texts: Set<RegisterPath>
    private var messages: [RegisterPath: WireMessage?] = [:]

    private var elements: [RegisterPath: [OpID: WireMessage]] = [:]

    init(props: WireMessage, texts: Set<RegisterPath>) {
        self.props = props
        self.texts = texts
    }

    /// The message at `path` (ending at a message field or an element), or nil when absent.
    func message(_ path: RegisterPath) -> WireMessage? {
        if let cached = messages[path] { return cached }
        let found: WireMessage?
        switch path.segments.last! {
        case .field(let number):
            found = (path.parent.map(message) ?? props)?.message(number)
        case .element(let id):
            found = elementIndex(path.parent!)?[id]
        }
        messages[path] = found
        return found
    }

    private func elementIndex(_ container: RegisterPath) -> [OpID: WireMessage]? {
        if let cached = elements[container] { return cached }
        guard case .field(let number)? = container.segments.last else { return nil }
        let occurrences = texts.contains(container)
            ? message(container)?.occurrences(PathResolver.charsField)
            : (container.parent.map(message) ?? props)?.occurrences(number)
        var index: [OpID: WireMessage] = [:]
        for case let occurrence? in occurrences ?? [] {
            let id = occurrence.lastPayload(1).flatMap(WireMessage.parse)
                .map { OpID(counter: $0.lastVarint(1), replica: $0.lastFixed64(2)) } ?? .zero
            index[id] = occurrence
        }
        elements[container] = index
        return index
    }
}
