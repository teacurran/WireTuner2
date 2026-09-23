import Foundation
import Synchronization
import WTCRDT
import WTModel
import WTProto

/// What replica salvage recovered (docs/spec/offline.adoc, "Replica expiry and salvage"; SYNC-010):
/// the unsent changes of a retired replica re-issued as new changes of a fresh one against the
/// current state, and the ops dropped because what they named is gone (a tombstone garbage
/// collection removed, or an object a dropped op would have created).
public struct SalvageReport: Sendable, Hashable, Codable {
    /// Why the replica was retired.
    public enum Reason: String, Sendable, Hashable, Codable {
        /// `REPLICA_EXPIRED`: the review shows "changes recovered from an expired session".
        case expired
        /// `REPLICA_CONFLICT`, or a store opened on another Mac: the same rotation, no prose.
        case conflict
    }

    /// One dropped op, named for the review sheet.
    public struct Dropped: Sendable, Hashable, Codable {
        /// The change it belonged to: its replica, seq and label.
        public var replica: UInt64
        public var seq: UInt64
        public var label: String
        /// Its index in the change and its kind ("SetFields", "TextInsert", ...).
        public var opIndex: Int
        public var op: String
        /// What it names that no longer exists (counter and replica).
        public var missingCounter: UInt64
        public var missingReplica: UInt64

        public var missing: OpID { OpID(counter: missingCounter, replica: missingReplica) }
    }

    public var reason: Reason
    /// Changes read from the retired replicas, and how many were re-issued with how many ops.
    public var salvagedChanges: Int
    public var recoveredChanges: Int
    public var reissuedOps: Int
    public var dropped: [Dropped]

    public init(reason: Reason, salvagedChanges: Int = 0, recoveredChanges: Int = 0, reissuedOps: Int = 0, dropped: [Dropped] = []) {
        self.reason = reason
        self.salvagedChanges = salvagedChanges
        self.recoveredChanges = recoveredChanges
        self.reissuedOps = reissuedOps
        self.dropped = dropped
    }

    /// Whether the review sheet shows it before anything is sent: always after expiry, and after a
    /// conflict only when something was dropped.
    public var needsReview: Bool { reason == .expired || !dropped.isEmpty }
}

/// The rebase of salvaged changes, one change at a time, onto a replica with fresh counters.
///
/// Each salvaged change becomes one change of the new replica whose ops take the same counter
/// offsets, so every id a salvaged change created maps by one delta per change -- a later op
/// naming a salvaged node, element or character (in its target, its parent, a text origin, a
/// field path or anywhere in its values) is rewritten to the new id.  An op naming something the
/// current state does not have is dropped and listed; its counters are kept by `Noop`s so the
/// deltas hold.  A change left with nothing is not issued, and its ids map nowhere.
struct SalvageRebase {
    struct Range {
        let start: UInt64
        let end: UInt64
        let delta: UInt64
    }

    let replica: UInt64
    private(set) var ranges: [UInt64: [Range]] = [:]
    private(set) var report: SalvageReport

    init(replica: UInt64, reason: SalvageReport.Reason) {
        self.replica = replica
        report = SalvageReport(reason: reason)
    }

    /// The ops re-issuing `change` from `startCounter`, or nil when none survives.
    mutating func rebase(_ change: Wiretuner_Doc_V1_Change, startCounter: UInt64, state: EngineState) -> [Wiretuner_Doc_V1_Op]? {
        report.salvagedChanges += 1
        let total = change.ops.reduce(UInt64(0)) { $0 &+ EngineState.counters($1) }
        ranges[change.replica, default: []].append(Range(start: change.startCounter, end: change.startCounter &+ total,
                                                         delta: startCounter &- change.startCounter))
        var created: Set<OpID> = []
        var ops: [Wiretuner_Doc_V1_Op] = []
        var drops: [SalvageReport.Dropped] = []
        var kept = 0
        var counter = startCounter
        for (index, op) in change.ops.enumerated() {
            let count = EngineState.counters(op)
            defer { counter &+= count }
            if case .noop? = op.op {
                ops.append(op)
                continue
            }
            let rewritten = remap(op)
            if let missing = Self.missing(rewritten, state: state, created: created) {
                drops.append(SalvageReport.Dropped(replica: change.replica, seq: change.seq, label: change.label, opIndex: index,
                                                   op: Self.name(op), missingCounter: missing.counter, missingReplica: missing.replica))
                ops += (0..<count).map { _ in Ops.noop() }
                continue
            }
            kept += 1
            created.formUnion(Self.creates(rewritten, id: OpID(counter: counter, replica: replica)))
            ops.append(rewritten)
        }
        report.dropped += drops
        guard kept > 0 else {
            ranges[change.replica]!.removeLast()
            return nil
        }
        report.recoveredChanges += 1
        report.reissuedOps += kept
        return ops
    }

    // MARK: Remapping

    /// The new id of `id`, or `id` when it is not one a salvaged change created.
    func map(_ id: OpID) -> OpID {
        guard let range = range(of: id) else { return id }
        return OpID(counter: id.counter &+ range.delta, replica: replica)
    }

    private func range(of id: OpID) -> Range? {
        ranges[id.replica]?.first { id.counter >= $0.start && id.counter < $0.end }
    }

    /// `op` with every salvaged id in it replaced; a text delete's ranges are split where they
    /// cross from one salvaged change's ids into another's.
    func remap(_ op: Wiretuner_Doc_V1_Op) -> Wiretuner_Doc_V1_Op {
        guard !ranges.isEmpty else { return op }
        var op = op
        if case .textDelete(var delete)? = op.op {
            delete.ranges = delete.ranges.flatMap(split)
            op.textDelete = delete
        }
        // swiftlint:disable force_try
        // Every doc.v1 message encodes to JSON and back: no Any fields, no proto2 required fields.
        let json = try! JSONSerialization.jsonObject(with: try! op.jsonUTF8Data())
        return try! Wiretuner_Doc_V1_Op(jsonUTF8Data: try! JSONSerialization.data(withJSONObject: rewrite(json)))
        // swiftlint:enable force_try
    }

    /// Splits a range of consecutive character ids at the bounds of the salvaged changes.
    private func split(_ whole: Wiretuner_Doc_V1_ElementIdRange) -> [Wiretuner_Doc_V1_ElementIdRange] {
        var out: [Wiretuner_Doc_V1_ElementIdRange] = []
        var first = OpID(whole.first)
        var remaining = whole.count
        while remaining > 0 {
            let bound = range(of: first).map(\.end)
                ?? ranges[first.replica]?.map(\.start).filter { $0 > first.counter }.min()
                ?? first.counter &+ remaining
            let length = min(remaining, bound &- first.counter)
            var piece = Wiretuner_Doc_V1_ElementIdRange()
            piece.first = Ops.elementID(first)
            piece.count = length
            out.append(piece)
            first = OpID(counter: first.counter &+ length, replica: first.replica)
            remaining -= length
        }
        return out
    }

    /// The JSON value with every `{counter, replica}` object (an `OpId` or `ElementId`) mapped.
    private func rewrite(_ value: Any) -> Any {
        if let array = value as? [Any] {
            return array.map(rewrite)
        }
        guard let object = value as? [String: Any] else { return value }
        if let replica = object["replica"], Set(object.keys).isSubset(of: ["counter", "replica"]),
           let replicaValue = Self.integer(replica), let counterValue = Self.integer(object["counter"] ?? 0) {
            let mapped = map(OpID(counter: counterValue, replica: replicaValue))
            return ["counter": String(mapped.counter), "replica": String(mapped.replica)]
        }
        return object.mapValues(rewrite)
    }

    /// A proto3 JSON 64-bit integer: a string, or a number.
    static func integer(_ value: Any) -> UInt64? {
        if let text = value as? String { return UInt64(text) }
        return (value as? NSNumber)?.uint64Value
    }

    // MARK: Checking against the current state

    /// The first id `op` names that neither the state nor an earlier op of the change has.
    static func missing(_ op: Wiretuner_Doc_V1_Op, state: EngineState, created: Set<OpID>) -> OpID? {
        func node(_ id: Wiretuner_Doc_V1_OpId) -> OpID? {
            let id = OpID(id)
            return id.replica == 0 || state.store.exists(id) || created.contains(id) ? nil : id
        }
        func char(_ owner: Wiretuner_Doc_V1_OpId, _ field: Wiretuner_Doc_V1_FieldPath, _ id: Wiretuner_Doc_V1_ElementId) -> OpID? {
            let char = OpID(id)
            guard char != .zero, !created.contains(char) else { return nil }
            guard let path = RegisterPath(field), state.text(OpID(owner), path)?.contains(char) == true else { return char }
            return nil
        }
        func elements(_ owner: Wiretuner_Doc_V1_OpId, _ path: Wiretuner_Doc_V1_FieldPath) -> OpID? {
            guard let path = RegisterPath(path) else { return nil }
            let owner = OpID(owner)
            for (index, segment) in path.segments.enumerated() {
                guard case .element(let id) = segment, !created.contains(id) else { continue }
                let prefix = RegisterPath(segments: Array(path.segments[...index]))
                if state.store.element(owner, prefix) != nil { continue }
                if index > 0, state.text(owner, RegisterPath(segments: Array(path.segments[..<index])))?.contains(id) == true { continue }
                return id
            }
            return nil
        }
        switch op.op {
        case .create(let create):
            return node(create.parent)
        case .set(let set):
            return node(set.node) ?? set.paths.lazy.compactMap { elements(set.node, $0) }.first
        case .move(let move):
            return node(move.node) ?? node(move.parent)
        case .setDeleted(let flag):
            return node(flag.node)
        case .elementInsert(let insert):
            return node(insert.node) ?? elements(insert.node, insert.sequence)
        case .elementMove(let move):
            return node(move.node) ?? elements(move.node, move.element)
        case .elementDelete(let delete):
            return node(delete.node) ?? delete.elements.lazy.compactMap { elements(delete.node, $0) }.first
        case .textInsert(let insert):
            return node(insert.node) ?? char(insert.node, insert.text, insert.leftOrigin) ?? char(insert.node, insert.text, insert.rightOrigin)
        case .textDelete(let delete):
            return node(delete.node) ?? delete.ranges.lazy.compactMap { char(delete.node, delete.text, $0.first) }.first
        case .textMark(let mark):
            return node(mark.node) ?? char(mark.node, mark.text, mark.start.char) ?? char(mark.node, mark.text, mark.end.char)
        case .setAdd(let add):
            return node(add.node)
        case .setRemove(let remove):
            return node(remove.node)
        default:
            return nil
        }
    }

    /// The ids a kept op creates at `id`: its node, or its elements or characters.
    static func creates(_ op: Wiretuner_Doc_V1_Op, id: OpID) -> [OpID] {
        switch op.op {
        case .create:
            return [id]
        case .elementInsert, .textInsert:
            return (0..<EngineState.counters(op)).map { OpID(counter: id.counter &+ $0, replica: id.replica) }
        default:
            return []
        }
    }

    /// The op's message name, for the dropped list.
    static func name(_ op: Wiretuner_Doc_V1_Op) -> String {
        switch op.op {
        case .create: "CreateNode"
        case .set: "SetFields"
        case .move: "MoveNode"
        case .setDeleted: "SetDeleted"
        case .elementInsert: "ElementInsert"
        case .elementMove: "ElementMove"
        case .elementDelete: "ElementDelete"
        case .textInsert: "TextInsert"
        case .textDelete: "TextDelete"
        case .textMark: "TextMark"
        case .setAdd: "SetAdd"
        case .setRemove: "SetRemove"
        default: "Op"
        }
    }
}

/// One salvaged change re-issued through `DocumentCore.perform`, so it is numbered, applied,
/// written to the outbox and recorded for undo like any local change.
struct SalvageCommand: Command {
    /// The rebase every salvaged change of one salvage shares.
    final class Shared: Sendable {
        let rebase: Mutex<SalvageRebase>

        init(_ rebase: SalvageRebase) {
            self.rebase = Mutex(rebase)
        }

        var report: SalvageReport { rebase.withLock { $0.report } }
    }

    let change: Wiretuner_Doc_V1_Change
    let shared: Shared

    var label: String { change.label.isEmpty ? "Recovered Changes" : change.label }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let start = builder.startCounter
        guard let ops = shared.rebase.withLock({ $0.rebase(change, startCounter: start, state: state) }) else { return }
        for op in ops {
            builder.append(op)
        }
    }
}
