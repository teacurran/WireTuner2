import Foundation
import Synchronization
import WTCRDT
import WTInterchange
import WTProto

/// Re-issue of a document state as fresh ops (saving.adoc, "Client"; IO-006, shared with IO-004's
/// Duplicate): an opened package's state becomes a new document by recreating every live node in
/// tree order from the importing replica, so none of the original's OpIds enter it and two imports
/// of one package are two unrelated documents.
///
/// First every node is created (one `CreateNode` of its kind alone, parents before children,
/// siblings in order with fresh positions); then each SEQUENCE gets one `ElementInsert` of its live
/// elements carrying their registers (outer sequences first) and each TEXT field one `TextInsert`
/// of its live characters; then every register outside an element is written by one `SetFields`
/// per node, with the element registers whose references could not be resolved when their element
/// was inserted (one `SetFields` per element); then the text marks (`TextMark`, one per mark) and
/// the SET members (`SetAdd`).  References are rewritten on the way: a `NodeRef` to a re-issued
/// node points at its copy (one to a node left behind is cleared), an `ElementId` naming a
/// re-issued element or character names its copy.  Deleted nodes, elements and characters are left
/// out, as are `local_only` registers.  Blobs listed as missing from the package become
/// placeholder `asset` nodes keeping the hash, unless an asset already carries it.
///
/// The ops are cut into changes of at most `maxOps` ops or `maxBytes` bytes (a change is closed
/// after the step that reaches either), each performed as a `ReissueChunk` command labelled
/// "Import package"; `isFinished` says when the last has run.
public final class PackageReissue: Sendable {
    public static let maxOps = 5_000
    public static let maxBytes = 2 << 20
    public static let label = "Import package"

    enum Step: Hashable, Sendable {
        case create(node: OpID, parent: OpID, position: [UInt8])
        case elements(node: OpID, sequence: RegisterPath)
        case text(node: OpID, field: RegisterPath)
        case registers(node: OpID)
        case marks(node: OpID)
        case sets(node: OpID)
        case placeholder(PackageBlobReference)
    }

    struct Progress: Sendable {
        var next = 0
        var nodes: [OpID: OpID] = [:]
        var elements: [OpID: OpID] = [:]
        /// Element registers written with a reference not yet re-issued, by node: the element
        /// path they belong to.
        var deferred: [OpID: [RegisterPath]] = [:]

        /// The copy of `node`; a well-known node is its own.
        func copy(_ node: OpID) -> OpID { nodes[node] ?? node }
    }

    /// A register of the source: where and its value.
    struct Register: Sendable {
        var path: RegisterPath
        var value: [UInt8]
    }

    let source: EngineState
    let steps: [Step]
    let limits: (ops: Int, bytes: Int)
    /// Each node's registers with a value, by the element they belong to (the path up to and
    /// including their last element segment; nil for the node's own).
    let registers: [OpID: [RegisterPath?: [Register]]]
    /// Every live element and character that will be re-issued.
    let reissued: Set<OpID>
    private let progress = Mutex(Progress())

    /// A re-issue of the live nodes of `source`; `missing` lists blobs the package did not carry.
    public convenience init(_ source: EngineState, missing: [PackageBlobReference] = []) throws {
        try self.init(source, missing: missing, maxOps: Self.maxOps, maxBytes: Self.maxBytes)
    }

    init(_ source: EngineState, missing: [PackageBlobReference], maxOps: Int, maxBytes: Int) throws {
        self.source = source
        limits = (maxOps, maxBytes)
        var nodes: [OpID] = [WellKnown.document]
        var creates: [Step] = []
        func visit(_ parent: OpID) throws {
            let children = source.liveChildren(parent)
            let keys = try PathEditing.keys(between: nil, and: nil, count: children.count)
            for (child, key) in zip(children, keys) {
                if child.replica != 0 { creates.append(.create(node: child, parent: parent, position: key)) }
                nodes.append(child)
                try visit(child)
            }
        }
        try visit(WellKnown.document)
        var structure: [Step] = []
        var reissued = Set<OpID>()
        var registers: [OpID: [RegisterPath?: [Register]]] = [:]
        var assetHashes = Set<Data>()
        for node in nodes {
            let store = source.store
            var sequences = Set<RegisterPath>()
            for (path, element) in store.elements(node) where !element.isDeleted {
                if let sequence = path.parent { sequences.insert(sequence) }
            }
            for sequence in sequences.sorted(by: { ($0.segments.count, $0) < ($1.segments.count, $1) }) {
                reissued.formUnion(source.liveElements(node, sequence))
                structure.append(.elements(node: node, sequence: sequence))
            }
            for (field, text) in store.textPaths(node).compactMap({ field in store.text(node, field).map { (field, $0) } }) where text.liveCount > 0 {
                reissued.formUnion(text.liveChars)
                structure.append(.text(node: node, field: field))
            }
            var byChain: [RegisterPath?: [Register]] = [:]
            for (path, register) in store.registers(node) {
                guard let value = register.value else { continue }
                byChain[Self.chain(of: path), default: []].append(Register(path: path, value: value))
            }
            registers[node] = byChain
            if case .asset(let asset)? = source.props(node).kind { assetHashes.insert(asset.sha256) }
        }
        self.registers = registers
        self.reissued = reissued
        steps = creates + structure + nodes.map { .registers(node: $0) } + nodes.map { .marks(node: $0) } + nodes.map { .sets(node: $0) }
            + missing.filter { !assetHashes.contains($0.sha256) }.map { .placeholder($0) }
    }

    /// The path of the element a register at `path` belongs to: up to and including its last
    /// element segment; nil for a register of the node itself.
    static func chain(of path: RegisterPath) -> RegisterPath? {
        guard let last = path.segments.lastIndex(where: { if case .element = $0 { true } else { false } }) else { return nil }
        return RegisterPath(segments: Array(path.segments[...last]))
    }

    /// The registers of `node` that belong to the element `chain` (nil: the node's own).
    func registers(of node: OpID, _ chain: RegisterPath?) -> [Register] {
        registers[node]?[chain] ?? []
    }

    /// Whether every step has been performed.
    public var isFinished: Bool { progress.withLock { $0.next >= steps.count } }

    /// The next change's command.
    public func nextChunk() -> ReissueChunk { ReissueChunk(plan: self) }

    /// The copy of `node` (nil before it is re-issued, or when it was left out).
    public func copy(of node: OpID) -> OpID? {
        progress.withLock { $0.nodes[node] }
    }

    /// Appends the next steps' ops to `builder` until a limit is reached.
    func run(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try progress.withLock { progress in
            var bytes = 0
            while progress.next < steps.count {
                let before = builder.ops.count
                try perform(steps[progress.next], builder: &builder, state: state, progress: &progress)
                progress.next += 1
                for op in builder.ops[before...] {
                    let encoded: [UInt8] = Wire.bytes { try op.serializedBytes() }
                    bytes += encoded.count
                }
                if builder.ops.count >= limits.ops || bytes >= limits.bytes { break }
            }
        }
    }

    // MARK: Steps

    private func perform(_ step: Step, builder: inout ChangeBuilder, state: EngineState, progress: inout Progress) throws {
        var rewriter = ReferenceRewriter(schema: source.schema, nodes: progress.nodes, elements: progress.elements, reissued: reissued)
        switch step {
        case .create(let node, let parent, let position):
            let props = try Wiretuner_Doc_V1_NodeProps(serializedBytes: Wire.field(source.store.kind(node), []))
            progress.nodes[node] = builder.append(Ops.create(parent: progress.nodes[parent] ?? parent, position: position, props: props))
        case .elements(let node, let sequence):
            try insertElements(node, sequence: sequence, builder: &builder, rewriter: &rewriter, progress: &progress)
        case .text(let node, let field):
            insertText(node, field: field, builder: &builder, rewriter: &rewriter, progress: &progress)
        case .registers(let node):
            try writeRegisters(node, builder: &builder, rewriter: rewriter, progress: progress)
        case .marks(let node):
            try writeMarks(node, copy: progress.copy(node), builder: &builder, rewriter: rewriter)
        case .sets(let node):
            try addMembers(node, copy: progress.copy(node), builder: &builder, rewriter: rewriter)
        case .placeholder(let blob):
            var props = Wiretuner_Doc_V1_NodeProps()
            props.asset.common.name = String(blob.name.prefix(256))
            props.asset.common.note = "Missing from the package"
            props.asset.sha256 = blob.sha256
            props.asset.byteSize = blob.size
            props.asset.mediaType = String(blob.mediaType.prefix(128))
            props.asset.link.kind = .embedded
            builder.append(Ops.create(parent: WellKnown.assets, position: try PathEditing.topPosition(in: WellKnown.assets, state: state), props: props))
        }
    }

    /// One `ElementInsert` of the live elements of `sequence`, each with its own registers.
    private func insertElements(_ node: OpID, sequence: RegisterPath, builder: inout ChangeBuilder, rewriter: inout ReferenceRewriter,
                                progress: inout Progress) throws {
        // A sequence inside a left-out element is left out with it.
        guard let target = rewriter.path(sequence) else { return }
        let copy = progress.copy(node)
        let live = source.liveElements(node, sequence)
        let keys = try PathEditing.keys(between: nil, and: nil, count: live.count)
        for (index, element) in live.enumerated() {
            rewriter.elements[element] = OpID(counter: builder.nextCounter + UInt64(index), replica: builder.replica)
        }
        let values = SparseProps()
        for element in live {
            let chain = sequence.element(element)
            values.open(rewriter.valuesPath(rewriter.path(chain)!, schema: source.schema))
            for register in registers(of: node, chain) {
                guard let row = rewriter.row(at: register.path) else { continue }
                var unresolved = false
                values.put(rewriter.record(register.value, row: row, unresolved: &unresolved),
                           at: rewriter.valuesPath(rewriter.path(register.path)!, schema: source.schema))
                if unresolved { progress.deferred[node, default: []].append(chain) }
            }
        }
        builder.append(Ops.elementInsert(copy, target, positions: keys, values: try Wiretuner_Doc_V1_NodeProps(serializedBytes: values.encoded())))
        progress.elements = rewriter.elements
    }

    /// One `TextInsert` of the live characters of the TEXT field `field`.
    private func insertText(_ node: OpID, field: RegisterPath, builder: inout ChangeBuilder, rewriter: inout ReferenceRewriter,
                            progress: inout Progress) {
        // A TEXT field is only ever at a field path (never inside an element), and `textPaths`
        // lists fields that hold something.
        let text = source.store.text(node, field)!
        let chars = text.liveChars
        let first = builder.append(Ops.textInsert(progress.copy(node), field, text.string))
        for (index, char) in chars.enumerated() {
            progress.elements[char] = OpID(counter: first.counter + UInt64(index), replica: first.replica)
            // A character's registers (a newline's paragraph) are written with the node's.
            if !registers(of: node, field.element(char)).isEmpty { progress.deferred[node, default: []].append(field.element(char)) }
        }
    }

    /// One `SetFields` of the node's own registers, and one per element whose registers are still
    /// to be written.
    private func writeRegisters(_ node: OpID, builder: inout ChangeBuilder, rewriter: ReferenceRewriter, progress: Progress) throws {
        let copy = progress.copy(node)
        let chains: [RegisterPath?] = [nil] + (progress.deferred[node] ?? [])
        var written = Set<RegisterPath?>()
        for chain in chains where written.insert(chain).inserted {
            let values = SparseProps()
            var paths: [RegisterPath] = []
            for register in registers(of: node, chain) {
                guard let target = rewriter.path(register.path), let row = rewriter.row(at: register.path) else { continue }
                var unresolved = false
                values.put(rewriter.record(register.value, row: row, unresolved: &unresolved), at: rewriter.valuesPath(target, schema: source.schema))
                paths.append(target)
            }
            guard !paths.isEmpty else { continue }
            builder.append(Ops.set(copy, paths, values: try Wiretuner_Doc_V1_NodeProps(serializedBytes: values.encoded())))
        }
    }

    /// Every mark of each TEXT field of `node`, in id order, anchored on the copies of its
    /// characters (an anchor on a deleted character moves to the nearest live one inside the
    /// span; a mark with no live character left is dropped).
    private func writeMarks(_ node: OpID, copy: OpID, builder: inout ChangeBuilder, rewriter: ReferenceRewriter) throws {
        for path in source.store.textPaths(node) {
            let text = source.store.text(node, path)!
            let order = text.order
            let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            for mark in text.marks.values.sorted(by: { $0.id < $1.id }) {
                guard let start = anchor(mark.start, order: order, index: index, forward: true, rewriter: rewriter),
                      let end = anchor(mark.end, order: order, index: index, forward: false, rewriter: rewriter) else { continue }
                var op = Wiretuner_Doc_V1_TextMark()
                op.node = copy.proto
                op.text = path.proto
                op.start = start
                op.end = end
                var unresolved = false
                op.value = try Wiretuner_Doc_V1_TextMarkValue(serializedBytes: rewriter.message(mark.value, type: "wiretuner.doc.v1.TextMarkValue",
                                                                                               unresolved: &unresolved))
                var wrapped = Wiretuner_Doc_V1_Op()
                wrapped.textMark = op
                builder.append(wrapped)
            }
        }
    }

    /// `anchor` on the copies: the text's ends stay; a live character maps to its copy; a deleted
    /// one moves to the next live character (`forward`) or the previous one.
    private func anchor(_ anchor: Anchor, order: [OpID], index: [OpID: Int], forward: Bool, rewriter: ReferenceRewriter) -> Wiretuner_Doc_V1_Anchor? {
        var value = Wiretuner_Doc_V1_Anchor()
        value.before = anchor.before
        guard anchor.char != .zero else {
            value.char = Ops.elementID(.zero)
            return value
        }
        if let copy = rewriter.elements[anchor.char] {
            value.char = Ops.elementID(copy)
            return value
        }
        guard let position = index[anchor.char] else { return nil }
        let candidates = forward ? Array(order[position...]) : Array(order[...position].reversed())
        guard let live = candidates.lazy.compactMap({ rewriter.elements[$0] }).first else { return nil }
        value.char = Ops.elementID(live)
        value.before = forward
        return value
    }

    /// One `SetAdd` per SET field of `node` holding its members.
    private func addMembers(_ node: OpID, copy: OpID, builder: inout ChangeBuilder, rewriter: ReferenceRewriter) throws {
        for path in source.store.setPaths(node) {
            guard let target = rewriter.path(path), let row = rewriter.row(at: path) else { continue }
            let values = SparseProps()
            values.put(source.store.members(node, path).flatMap { rewriter.member($0, row: row) }, at: rewriter.valuesPath(target, schema: source.schema))
            builder.append(Ops.setAdd(copy, target, values: try Wiretuner_Doc_V1_NodeProps(serializedBytes: values.encoded())))
        }
    }
}

/// A blob listed in a package's manifest (`PackageBlob`), as the re-issue needs it.
public struct PackageBlobReference: Hashable, Sendable {
    public var sha256: Data
    public var size: UInt64
    public var mediaType: String
    public var name: String

    public init(sha256: Data, size: UInt64 = 0, mediaType: String = "", name: String = "") {
        self.sha256 = sha256
        self.size = size
        self.mediaType = mediaType
        self.name = name
    }

    public init(_ blob: PackageBlob) {
        self.init(sha256: blob.sha256, size: blob.size, mediaType: blob.mediaType, name: blob.name)
    }
}

/// One change of a re-issue (`PackageReissue`).
public struct ReissueChunk: Command {
    public let plan: PackageReissue
    public var label: String { PackageReissue.label }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try plan.run(&builder, state: state)
    }
}

/// Rewrites the ids inside register values, paths and set members from the source document's to
/// the copies' (`PackageReissue`), walking values at the wire level with the merge table's
/// message types.
struct ReferenceRewriter {
    static let nodeRef = "wiretuner.doc.v1.NodeRef"
    static let elementID = "wiretuner.doc.v1.ElementId"
    /// The element message of a TEXT field (`RichText.chars`).
    static let textChar = "wiretuner.doc.v1.TextChar"

    let schema: Schema
    var nodes: [OpID: OpID]
    var elements: [OpID: OpID]
    /// Elements that will have copies once re-issued: a reference to one that has none yet is
    /// unresolved (written again later), not dangling.
    var reissued: Set<OpID> = []

    /// `path` with its element segments naming the copies; nil when one was left out.
    func path(_ path: RegisterPath) -> RegisterPath? {
        var segments: [RegisterPath.Segment] = []
        for segment in path.segments {
            switch segment {
            case .field:
                segments.append(segment)
            case .element(let id):
                guard let copy = elements[id] else { return nil }
                segments.append(.element(copy))
            }
        }
        return RegisterPath(segments: segments)
    }

    /// Where `path` sits in a sparse `values` message: element segments are transparent, and a
    /// character of a TEXT field sits in its `RichText.chars` (crdt-model.adoc, "Operations").
    func valuesPath(_ path: RegisterPath, schema: Schema) -> RegisterPath {
        var message = Schema.root
        var segments: [RegisterPath.Segment] = []
        for segment in path.segments {
            segments.append(segment)
            guard case .field(let number) = segment, let row = schema.field(message, Int(number)) else { continue }
            if row.policy == .text { segments.append(.field(1)) }
            message = Self.inner(row)
        }
        return RegisterPath(segments: segments)
    }

    /// The merge-table row of the field `path` ends at; nil when the path is unknown or runs
    /// through a `local_only` field (never re-issued: it never leaves the device).
    func row(at path: RegisterPath) -> Schema.FieldPolicy? {
        var message = Schema.root
        var row: Schema.FieldPolicy?
        for segment in path.segments {
            guard case .field(let number) = segment else { continue }
            guard let next = schema.field(message, Int(number)), !next.localOnly else { return nil }
            row = next
            message = Self.inner(next)
        }
        return row
    }

    /// The message a path continues in after the field of `row`: a sequence's element message, a
    /// TEXT field's character, a message field's type (a scalar has none).
    static func inner(_ row: Schema.FieldPolicy) -> String {
        row.policy == .text ? textChar : row.elementMessage ?? row.typeName ?? ""
    }

    /// A register value (one or more records of `row`'s field) with its references rewritten.
    func record(_ value: [UInt8], row: Schema.FieldPolicy, unresolved: inout Bool) -> [UInt8] {
        guard row.type == "message", let type = row.typeName, let fields = WireReader.fields(value) else { return value }
        var out: [UInt8] = []
        for field in fields where field.wireType == 2 {
            out += Wire.field(field.number, message(field.payload, type: type, unresolved: &unresolved))
        }
        return out
    }

    /// The message `payload` of `type` with its references rewritten.
    func message(_ payload: [UInt8], type: String, unresolved: inout Bool) -> [UInt8] {
        switch type {
        case Self.nodeRef:
            return nodeRef(payload)
        case Self.elementID:
            guard let id = Self.id(payload) else { return payload }
            if let copy = elements[id] { return Self.encode(copy) }
            if reissued.contains(id) { unresolved = true }
            return payload
        default:
            guard let fields = WireReader.fields(payload) else { return payload }
            var out: [UInt8] = []
            for field in fields {
                guard field.wireType == 2, let row = schema.field(type, Int(field.number)), row.type == "message", let inner = row.typeName else {
                    out += field.record
                    continue
                }
                out += Wire.field(field.number, message(field.payload, type: inner, unresolved: &unresolved))
            }
            return out
        }
    }

    /// A `NodeRef`: its id names the copy; one naming a node that was not re-issued is cleared
    /// (the reference reads as dangling) unless it names a well-known node.
    private func nodeRef(_ payload: [UInt8]) -> [UInt8] {
        guard let fields = WireReader.fields(payload) else { return payload }
        var out: [UInt8] = []
        for field in fields {
            guard field.number == 1, field.wireType == 2, let id = Self.id(field.payload) else {
                out += field.record
                continue
            }
            if let copy = nodes[id] {
                out += Wire.field(1, Self.encode(copy))
            } else if id.replica == 0 {
                out += field.record
            }
        }
        return out
    }

    static func id(_ payload: [UInt8]) -> OpID? {
        (try? Wiretuner_Doc_V1_OpId(serializedBytes: payload)).map(OpID.init)
    }

    static func encode(_ id: OpID) -> [UInt8] {
        Wire.bytes { try id.proto.serializedBytes() }
    }

    /// A SET member in its canonical form (crdt-model.adoc, "Sets") as the record of `row`'s field,
    /// an id member naming its copy.
    func member(_ member: [UInt8], row: Schema.FieldPolicy) -> [UInt8] {
        let number = UInt32(row.fieldNumber)
        switch row.type {
        case "message" where member.count == 16:
            var id = OpID(counter: Self.u64(member, 0), replica: Self.u64(member, 8))
            id = (row.typeName == Self.elementID ? elements[id] : nodes[id]) ?? id
            return Wire.field(number, Wire.elementID(id))
        case "string", "bytes", "message":
            return Wire.field(number, member)
        default:
            if member.count == 8 { return Wire.varint(UInt64(number) << 3 | 1) + member }
            if member.count == 4 { return Wire.varint(UInt64(number) << 3 | 5) + member }
            return Wire.varint(UInt64(number) << 3) + Wire.varint(Self.u64(member, 0))
        }
    }

    private static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        bytes[offset..<min(offset + 8, bytes.count)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}

/// A sparse `NodeProps` assembled from register records at their paths (the inverse of reading a
/// register out of a message), for `SetFields`, `ElementInsert` and `SetAdd` values.  An element
/// segment opens the element's message, its `id` first.
final class SparseProps {
    private var records: [UInt8] = []
    private var fields: [UInt32: SparseProps] = [:]
    private var fieldOrder: [UInt32] = []
    private var elements: [OpID: SparseProps] = [:]
    private var elementOrder: [OpID] = []

    /// Places `record` (the records of the field `path` ends at) at `path`.
    func put(_ record: [UInt8], at path: RegisterPath) {
        node(at: Array(path.segments.dropLast())).records += record
    }

    /// Makes sure the element `path` ends at is present, with no registers of its own yet.
    func open(_ path: RegisterPath) {
        _ = node(at: path.segments)
    }

    private func node(at segments: [RegisterPath.Segment]) -> SparseProps {
        var node = self
        for segment in segments {
            switch segment {
            case .field(let number):
                node = node.child(number)
            case .element(let id):
                node = node.element(id)
            }
        }
        return node
    }

    private func child(_ number: UInt32) -> SparseProps {
        if let existing = fields[number] { return existing }
        let node = SparseProps()
        fields[number] = node
        fieldOrder.append(number)
        return node
    }

    private func element(_ id: OpID) -> SparseProps {
        if let existing = elements[id] { return existing }
        let node = SparseProps()
        elements[id] = node
        elementOrder.append(id)
        return node
    }

    /// The message: leaf records, then each sub-message; a field holding elements as one record
    /// per element, its `id` first.
    func encoded() -> [UInt8] {
        var out = records
        for number in fieldOrder {
            let node = fields[number]!
            if node.elementOrder.isEmpty {
                out += Wire.field(number, node.encoded())
            } else {
                for id in node.elementOrder {
                    out += Wire.field(number, Wire.field(1, Wire.elementID(id)) + node.elements[id]!.encoded())
                }
            }
        }
        return out
    }
}
