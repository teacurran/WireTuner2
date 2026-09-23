import Foundation
import WTProto

/// How a SET field encodes its members, so an inverse can write one back.
public struct MemberField: Hashable, Sendable {
    public let number: UInt32
    public let type: String
    public let typeName: String?

    init(_ row: Schema.FieldPolicy) {
        number = UInt32(row.fieldNumber)
        type = row.type
        typeName = row.typeName
    }

    /// A SET field's encoding: its field number, protobuf type and message type name (a stored
    /// or joined inverse is rebuilt from these).
    public init(number: UInt32, type: String, typeName: String?) {
        self.number = number
        self.type = type
        self.typeName = typeName
    }

    /// The protobuf record holding `member` (a canonical member, crdt-model.adoc "Sets").
    func record(_ member: [UInt8]) -> [UInt8] {
        var out = WireWriter()
        if type == "message" {
            let id = OpID(counter: Self.u64(member, 0), replica: Self.u64(member, 8))
            out.idField(number, id)
        } else if type == "string" || type == "bytes" {
            out.lenField(number, member)
        } else if member.count == 8 && (type == "fixed64" || type == "sfixed64" || type == "double") {
            out.tag(number, WireMessage.fixed64)
            out.raw(member)
        } else if member.count == 4 {
            out.tag(number, WireMessage.fixed32)
            out.raw(member)
        } else {
            out.varintField(number, Self.u64(member, 0), always: true)
        }
        return out.bytes
    }

    private static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        bytes[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
}

/// One register beneath a deleted newline character: the path after the character's element
/// segment, and its value (nil = unset).
public struct ParagraphRegister: Hashable, Sendable {
    public let suffix: [RegisterPath.Segment]
    public let value: [UInt8]?

    public init(suffix: [RegisterPath.Segment], value: [UInt8]?) {
        self.suffix = suffix
        self.value = value
    }
}

/// A character a local `TextDelete` deleted, with what re-inserting it needs: its scalar, the
/// values of the attributes it showed, and its paragraph registers when it is a newline.
public struct DeletedChar: Hashable, Sendable {
    public let id: OpID
    public let scalar: UInt32
    public let attributes: [[UInt8]]
    public let paragraph: [ParagraphRegister]

    public init(id: OpID, scalar: UInt32, attributes: [[UInt8]], paragraph: [ParagraphRegister]) {
        self.id = id
        self.scalar = scalar
        self.attributes = attributes
        self.paragraph = paragraph
    }
}

/// What formatted a character before a local mark: the winning value of the mark's attribute
/// (nil: none).
public struct PriorFormat: Hashable, Sendable {
    public let char: OpID
    public let value: [UInt8]?

    public init(char: OpID, value: [UInt8]?) {
        self.char = char
        self.value = value
    }
}

/// The inverse of a local change (crdt-model.adoc, "Undo"; CRDT-008), recorded against the state
/// just before each op: the prior `(value, OpId)` of every register written, the prior parent and
/// position of each moved node, the inserted element and character ids, the deleted characters
/// with their content.  `EngineState.undoChange` turns it into the change that undoes it.
public struct Inverse: Hashable, Sendable {
    /// One undoable effect of one op, in application order.
    public enum Step: Hashable, Sendable {
        /// A `CreateNode` made `node`; undo deletes it.
        case created(node: OpID)
        /// A register write; undo restores `prior` (nil: never written, restored as unset).
        case register(node: OpID, path: RegisterPath, prior: Register?, wrote: OpID)
        /// A `MoveNode`; undo moves the node back.
        case placement(node: OpID, prior: Placement?, wrote: OpID)
        /// A `SetDeleted`; undo writes the prior flag (false when never written).
        case deleted(node: OpID, prior: Stamped<Bool>?, wrote: OpID)
        /// An `ElementInsert` element; undo deletes it.
        case elementInserted(node: OpID, element: RegisterPath)
        /// An `ElementMove`; undo moves the element back.
        case elementPosition(node: OpID, element: RegisterPath, prior: Stamped<[UInt8]>, wrote: OpID)
        /// An `ElementDelete`; undo writes the prior flag (false when never written).
        case elementDeleted(node: OpID, element: RegisterPath, prior: Stamped<Bool>?, wrote: OpID)
        /// A `SetAdd` of a member (`wasPresent`: whether it was a member before); undo removes it.
        case memberAdded(node: OpID, set: RegisterPath, member: [UInt8], tag: OpID, wasPresent: Bool, field: MemberField)
        /// A `SetRemove` that took a member out; undo adds it back.
        case memberRemoved(node: OpID, set: RegisterPath, member: [UInt8], field: MemberField)
        /// A `TextInsert`; undo deletes the characters.
        case textInserted(node: OpID, text: RegisterPath, chars: [OpID])
        /// A `TextDelete`; undo re-inserts the text as new characters at the original place.
        case textDeleted(node: OpID, text: RegisterPath, chars: [DeletedChar])
        /// A `TextMark`; undo re-applies each character's prior value of the attribute.
        case textMarked(node: OpID, text: RegisterPath, mark: OpID, key: MarkKey, value: [UInt8], prior: [PriorFormat])
    }

    public let steps: [Step]

    /// The inverse made of `steps`, in application order: one recorded by `applyLocal`, several
    /// joined into one undo step, or one read back from the local store.
    public init(steps: [Step]) {
        self.steps = steps
    }

    /// This inverse followed by `later`: the inverse of this change and then `later` applied as
    /// one unit, which `undoChange` undoes together.
    public func followed(by later: Inverse) -> Inverse {
        Inverse(steps: steps + later.steps)
    }

    /// Whether the change changed nothing undoable.
    public var isEmpty: Bool { steps.isEmpty }
}

extension EngineState {
    /// The change undoing `inverse` against the current state, or nil when nothing of it is left
    /// to undo.  Each step is undone only where no other replica has written its target since
    /// (the state holds this replica's write, or a later one of this replica's, such as its undo of
    /// a later change): undo never reverts other people's work (crdt-model.adoc, "Undo").  A target
    /// that no longer exists (collected, CRDT-010) is skipped.  The change is undone as
    /// a unit: where several of its ops wrote one register (or placement, flag, member), the value
    /// before the first is restored if the state still holds the last; characters it inserted are
    /// not re-inserted.  The ops are numbered from `startCounter` (the clock's next counter);
    /// applying the result with `applyLocal` gives the inverse that redoes it.
    public func undoChange(
        _ inverse: Inverse, replica: UInt64, seq: UInt64, startCounter: UInt64, baseServerSeq: UInt64 = 0,
        label: String = ""
    ) -> Wiretuner_Doc_V1_Change? {
        var builder = UndoBuilder(state: self, inverse: inverse, replica: replica, counter: startCounter)
        for (index, step) in inverse.steps.enumerated().reversed() {
            builder.undo(step, at: index)
        }
        guard !builder.ops.isEmpty else { return nil }
        var change = Wiretuner_Doc_V1_Change()
        change.replica = replica
        change.seq = seq
        change.startCounter = startCounter
        change.baseServerSeq = baseServerSeq
        change.label = label
        change.ops = builder.ops
        return change
    }
}

/// What one step targets, so the steps of one change touching the same thing undo as one.
private enum StepKey: Hashable {
    case register(OpID, RegisterPath)
    case placement(OpID)
    case deleted(OpID)
    case elementPosition(OpID, RegisterPath)
    case elementDeleted(OpID, RegisterPath)
    case member(OpID, RegisterPath, [UInt8])

    init?(_ step: Inverse.Step) {
        switch step {
        case .register(let node, let path, _, _): self = .register(node, path)
        case .placement(let node, _, _): self = .placement(node)
        case .deleted(let node, _, _): self = .deleted(node)
        case .elementPosition(let node, let element, _, _): self = .elementPosition(node, element)
        case .elementDeleted(let node, let element, _, _): self = .elementDeleted(node, element)
        case .memberAdded(let node, let set, let member, _, _, _), .memberRemoved(let node, let set, let member, _):
            self = .member(node, set, member)
        default: return nil
        }
    }
}

/// Builds the ops of an undo change, numbering them as it goes so an op can name the characters an
/// earlier op of the same change inserts.
private struct UndoBuilder {
    let state: EngineState
    let replica: UInt64
    var counter: UInt64
    var ops: [Wiretuner_Doc_V1_Op] = []
    /// For each target, the first step of the change that touched it (whose prior is restored)
    /// and the last (whose write must still hold).
    private var first: [StepKey: Inverse.Step] = [:]
    private var last: [StepKey: Int] = [:]
    /// The `deleted` writes of the change, which do not stop undoing a creation or an insert.
    private var wrote: Set<OpID> = []
    /// The characters the change inserted, which undoing a delete does not bring back.
    private var inserted: Set<OpID> = []
    /// The adds of the change, by member.
    private var tags: [StepKey: Set<OpID>] = [:]

    init(state: EngineState, inverse: Inverse, replica: UInt64, counter: UInt64) {
        self.state = state
        self.replica = replica
        self.counter = counter
        for (index, step) in inverse.steps.enumerated() {
            if let key = StepKey(step) {
                if first[key] == nil {
                    first[key] = step
                }
                last[key] = index
            }
            switch step {
            case .deleted(_, _, let op), .elementDeleted(_, _, _, let op):
                wrote.insert(op)
            case .textInserted(_, _, let chars):
                inserted.formUnion(chars)
            case .memberAdded(let node, let set, let member, let tag, _, _):
                tags[.member(node, set, member), default: []].insert(tag)
            default:
                break
            }
        }
    }

    private var store: NodeStore { state.store }

    // Whether the write holding a target is `wrote` or a later one by this replica.
    private func ours(_ holder: OpID?, _ wrote: OpID) -> Bool {
        holder == wrote || holder?.replica == replica
    }

    mutating func add(_ op: Wiretuner_Doc_V1_Op) {
        ops.append(op)
        counter &+= EngineState.counters(op)
    }

    mutating func undo(_ step: Inverse.Step, at index: Int) {
        if let key = StepKey(step) {
            guard last[key] == index else { return }
            undoLast(step, key)
            return
        }
        switch step {
        case .created(let node):
            if store.isCreated(node),
               store.deleted(node).map({ wrote.contains($0.current.op) || $0.current.op.replica == replica }) ?? true {
                add(Ops.setDeleted(node, true))
            }
        case .elementInserted(let node, let element):
            if let inserted = store.element(node, element),
               inserted.deleted.map({ wrote.contains($0.current.op) || $0.current.op.replica == replica }) ?? true {
                add(Ops.elementDelete(node, element, true))
            }
        case .textInserted(let node, let path, let chars):
            guard let text = store.text(node, path) else { break }
            let live = chars.filter { text.contains($0) && !text.isDeleted($0) }
            if !live.isEmpty {
                add(Ops.textDelete(node, path, live))
            }
        case .textDeleted(let node, let path, let chars):
            reinsert(node, path, chars.filter { !inserted.contains($0.id) })
        case .textMarked(let node, let path, let mark, let key, let value, let prior):
            remark(node, path, mark, key, value, prior)
        default:
            break
        }
    }

    // The last step of one target: restore the value before the change's first step, if the state
    // still holds this step's write.
    private mutating func undoLast(_ step: Inverse.Step, _ key: StepKey) {
        let earliest = first[key]!
        switch (step, earliest) {
        case (.register(let node, let path, _, let wrote), .register(_, _, let prior, _)):
            if let holder = store.register(node, path)?.op, ours(holder, wrote) {
                add(Ops.setFields(node, path, values(node, path, prior?.value)))
            }
        case (.placement(let node, _, let wrote), .placement(_, let prior, _)):
            if let holder = store.placement(node)?.op, ours(holder, wrote), let prior {
                add(Ops.move(node, prior.parent, prior.position))
            }
        case (.deleted(let node, _, let wrote), .deleted(_, let prior, _)):
            if let holder = store.deleted(node)?.current.op, ours(holder, wrote) {
                add(Ops.setDeleted(node, prior?.value ?? false))
            }
        case (.elementPosition(let node, let element, _, let wrote), .elementPosition(_, _, let prior, _)):
            if let holder = store.element(node, element)?.position.current.op, ours(holder, wrote) {
                add(Ops.elementMove(node, element, prior.value))
            }
        case (.elementDeleted(let node, let element, _, let wrote), .elementDeleted(_, _, let prior, _)):
            if let holder = store.element(node, element)?.deleted?.current.op, ours(holder, wrote) {
                add(Ops.elementDelete(node, element, prior?.value ?? false))
            }
        case (.memberAdded(let node, let set, let member, _, _, let field), _),
             (.memberRemoved(let node, let set, let member, let field), _):
            undoMember(node, set, member, field, earliest, key)
        default:
            break  // A key's steps are all of one kind.
        }
    }

    // A member the change added or removed: added back when it was a member before and is none
    // now; removed when it was none before and only the change's adds hold it now.
    private mutating func undoMember(
        _ node: OpID, _ set: RegisterPath, _ member: [UInt8], _ field: MemberField, _ earliest: Inverse.Step, _ key: StepKey
    ) {
        var wasPresent = true
        if case .memberAdded(_, _, _, _, let present, _) = earliest {
            wasPresent = present
        }
        let live = Set(store.liveTags(node, set, member))
        let values = values(node, set, field.record(member))
        if wasPresent && live.isEmpty {
            add(Ops.setAdd(node, set, values))
        } else if !wasPresent && !live.isEmpty && live.allSatisfy({ tags[key]?.contains($0) == true || $0.replica == replica }) {
            add(Ops.setRemove(node, set, values))
        }
    }

    // Re-inserts deleted characters as new ones, run by run: each run of characters adjacent in
    // document order goes right after its last (still a tombstone), then gets its attributes back
    // as marks covering exactly the new characters, then its newlines' paragraph registers.
    private mutating func reinsert(_ node: OpID, _ path: RegisterPath, _ chars: [DeletedChar]) {
        guard let text = store.text(node, path) else { return }
        let index = text.orderIndex()
        let present = chars.filter { index[$0.id] != nil }.sorted { index[$0.id]! < index[$1.id]! }
        var runs: [[DeletedChar]] = []
        for char in present {
            if let last = runs.last?.last, index[last.id]! + 1 == index[char.id]! {
                runs[runs.count - 1].append(char)
            } else {
                runs.append([char])
            }
        }
        for run in runs {
            let first = counter
            let last = run.last!.id
            add(Ops.textInsert(node, path, left: last, right: text.successor(of: last), run.map(\.scalar)))
            let ids = run.indices.map { OpID(counter: first &+ UInt64($0), replica: replica) }
            var formats: [[UInt8]] = []
            for char in run {
                for value in char.attributes where !formats.contains(value) {
                    formats.append(value)
                }
            }
            for value in formats {
                var start: Int?
                for index in 0...run.count {
                    let has = index < run.count && run[index].attributes.contains(value)
                    if has && start == nil {
                        start = index
                    } else if !has, let from = start {
                        add(Ops.textMark(node, path, Anchor(char: ids[from], before: true),
                                         Anchor(char: ids[index - 1], before: false), value))
                        start = nil
                    }
                }
            }
            for (offset, char) in run.enumerated() {
                for register in char.paragraph {
                    let target = RegisterPath(segments: path.segments + [.element(ids[offset])] + register.suffix)
                    add(Ops.setFields(node, target, values(node, target, register.value)))
                }
            }
        }
    }

    // Re-applies the prior value of a mark's attribute on the characters the mark still wins,
    // one mark per run of consecutive live characters with the same prior value.
    private mutating func remark(
        _ node: OpID, _ path: RegisterPath, _ mark: OpID, _ key: MarkKey, _ value: [UInt8], _ prior: [PriorFormat]
    ) {
        guard let text = store.text(node, path) else { return }
        let winners = text.winners(of: key, for: prior.map(\.char))
        let still = prior.filter { winners[$0.char].map { ours($0.id, mark) } == true && !text.isDeleted($0.char) }
            .map { (offset: text.offset(of: $0.char)!, format: $0) }
            .sorted { $0.offset < $1.offset }
        var index = 0
        while index < still.count {
            var end = index
            while end + 1 < still.count && still[end + 1].offset == still[end].offset + 1
                && still[end + 1].format.value == still[index].format.value {
                end += 1
            }
            let restored = still[index].format.value ?? MarkValue.cleared(value, key: key)
            add(Ops.textMark(node, path, Anchor(char: still[index].format.char, before: true),
                             Anchor(char: still[end].format.char, before: false), restored))
            index = end + 1
        }
    }

    // A sparse NodeProps holding `records` at `path` (nil: an empty one, which clears).  Element
    // segments are transparent, except that a character's sits inside `RichText.chars`.
    private func values(_ node: OpID, _ path: RegisterPath, _ records: [UInt8]?) -> [UInt8] {
        Values.wrap(path, records) { store.text(node, $0) != nil }
    }
}

/// Sparse `NodeProps` values holding one register's records.
enum Values {
    /// Wraps `records` (the last field's records) in the messages of `path`'s other field
    /// segments; an element segment adds nothing, except after a TEXT field (`isText`), where the
    /// character sits in `RichText.chars`.  Nil records give empty values.
    static func wrap(_ path: RegisterPath, _ records: [UInt8]?, isText: (RegisterPath) -> Bool) -> [UInt8] {
        guard var content = records else { return [] }
        let segments = path.segments
        for index in stride(from: segments.count - 2, through: 0, by: -1) {
            var out = WireWriter()
            switch segments[index] {
            case .field(let number):
                out.lenField(number, content)
                content = out.bytes
            case .element:
                if isText(RegisterPath(segments: Array(segments[..<index]))) {
                    out.lenField(PathResolver.charsField, content)
                    content = out.bytes
                }
            }
        }
        return content
    }
}

/// Builders for the ops an undo change holds.
enum Ops {
    private static func props(_ bytes: [UInt8]) -> Wiretuner_Doc_V1_NodeProps {
        // Values the engine wrote itself always parse: unknown fields are kept as they are.
        try! Wiretuner_Doc_V1_NodeProps(serializedBytes: bytes)
    }

    private static func elementID(_ id: OpID) -> Wiretuner_Doc_V1_ElementId {
        var out = Wiretuner_Doc_V1_ElementId()
        out.counter = id.counter
        out.replica = id.replica
        return out
    }

    static func setDeleted(_ node: OpID, _ deleted: Bool) -> Wiretuner_Doc_V1_Op {
        var op = Wiretuner_Doc_V1_Op()
        op.setDeleted.node = node.proto
        op.setDeleted.deleted = deleted
        return op
    }

    static func setFields(_ node: OpID, _ path: RegisterPath, _ values: [UInt8]) -> Wiretuner_Doc_V1_Op {
        var op = Wiretuner_Doc_V1_Op()
        op.set.node = node.proto
        op.set.paths = [path.proto]
        op.set.values = props(values)
        return op
    }

    static func move(_ node: OpID, _ parent: OpID, _ position: [UInt8]) -> Wiretuner_Doc_V1_Op {
        var op = Wiretuner_Doc_V1_Op()
        op.move.node = node.proto
        op.move.parent = parent.proto
        op.move.position = Data(position)
        return op
    }

    static func elementMove(_ node: OpID, _ element: RegisterPath, _ position: [UInt8]) -> Wiretuner_Doc_V1_Op {
        var op = Wiretuner_Doc_V1_Op()
        op.elementMove.node = node.proto
        op.elementMove.element = element.proto
        op.elementMove.position = Data(position)
        return op
    }

    static func elementDelete(_ node: OpID, _ element: RegisterPath, _ deleted: Bool) -> Wiretuner_Doc_V1_Op {
        var op = Wiretuner_Doc_V1_Op()
        op.elementDelete.node = node.proto
        op.elementDelete.elements = [element.proto]
        op.elementDelete.deleted = deleted
        return op
    }

    static func setAdd(_ node: OpID, _ set: RegisterPath, _ values: [UInt8]) -> Wiretuner_Doc_V1_Op {
        var op = Wiretuner_Doc_V1_Op()
        op.setAdd.node = node.proto
        op.setAdd.set = set.proto
        op.setAdd.values = props(values)
        return op
    }

    static func setRemove(_ node: OpID, _ set: RegisterPath, _ values: [UInt8]) -> Wiretuner_Doc_V1_Op {
        var op = Wiretuner_Doc_V1_Op()
        op.setRemove.node = node.proto
        op.setRemove.set = set.proto
        op.setRemove.values = props(values)
        return op
    }

    static func textInsert(_ node: OpID, _ text: RegisterPath, left: OpID, right: OpID, _ scalars: [UInt32]) -> Wiretuner_Doc_V1_Op {
        var op = Wiretuner_Doc_V1_Op()
        op.textInsert.node = node.proto
        op.textInsert.text = text.proto
        op.textInsert.leftOrigin = elementID(left)
        op.textInsert.rightOrigin = elementID(right)
        var chars = String.UnicodeScalarView()
        for scalar in scalars {
            chars.append(Unicode.Scalar(scalar) ?? "\u{FFFD}")
        }
        op.textInsert.chars = String(chars)
        return op
    }

    /// A `TextDelete` of `chars`, as runs of consecutive ids.
    static func textDelete(_ node: OpID, _ text: RegisterPath, _ chars: [OpID]) -> Wiretuner_Doc_V1_Op {
        var op = Wiretuner_Doc_V1_Op()
        op.textDelete.node = node.proto
        op.textDelete.text = text.proto
        for char in chars.sorted() {
            if let last = op.textDelete.ranges.last, last.first.replica == char.replica,
               last.first.counter &+ last.count == char.counter {
                op.textDelete.ranges[op.textDelete.ranges.count - 1].count += 1
            } else {
                var range = Wiretuner_Doc_V1_ElementIdRange()
                range.first = elementID(char)
                range.count = 1
                op.textDelete.ranges.append(range)
            }
        }
        return op
    }

    static func textMark(_ node: OpID, _ text: RegisterPath, _ start: Anchor, _ end: Anchor, _ value: [UInt8]) -> Wiretuner_Doc_V1_Op {
        var op = Wiretuner_Doc_V1_Op()
        op.textMark.node = node.proto
        op.textMark.text = text.proto
        op.textMark.start.char = elementID(start.char)
        op.textMark.start.before = start.before
        op.textMark.end.char = elementID(end.char)
        op.textMark.end.before = end.before
        // A TextMarkValue the engine read from an op always parses again.
        op.textMark.value = try! Wiretuner_Doc_V1_TextMarkValue(serializedBytes: value)
        return op
    }
}
