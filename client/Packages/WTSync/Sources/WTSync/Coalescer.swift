import Foundation
import WTCRDT
import WTModel
import WTProto

/// Outbox coalescing (docs/spec/offline.adoc, "Outbox and coalescing"; SYNC-002): rewrites the
/// unacknowledged local changes before sending where doing so cannot change the merged result.
/// Every change keeps its seq, label and counter range, so history stays readable and acks match
/// the stored rows; an op coalesced away leaves a `Noop` in its counter slot so the replica's
/// counters stay dense.  The undo stack is unaffected: it holds inverses, not sent ops.
public enum Coalescer {
    /// One change of the local log in application order: an unacknowledged local change (which may
    /// be rewritten), or any other applied change (remote, or already acknowledged), which is kept
    /// only to judge what lies between two local changes.
    public enum Entry: Sendable {
        case outbox(Wiretuner_Doc_V1_Change)
        case other(Wiretuner_Doc_V1_Change)
    }

    /// Which rules apply.
    public struct Rules: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Two `SetFields` writing the same register path of the same node with no other replica's
        /// write to it between them: the earlier write is dropped (a whole op becomes a `Noop`).
        public static let registers = Rules(rawValue: 1)
        /// Adjacent `TextInsert`s of consecutive characters: one op.
        public static let text = Rules(rawValue: 2)
        /// A node created and then deleted with nothing else referencing it: its ops become
        /// `Noop`s.  Off by default: the creating replica still holds the tombstone, so its state
        /// hash would differ from every other replica's (docs/spec/offline.adoc records this).
        public static let createThenDelete = Rules(rawValue: 4)

        public static let standard: Rules = [.registers, .text]
    }

    /// The most characters one TextInsert carries (ops.proto: 64 KiB of characters).
    public static let maxTextBytes = 65_536

    /// The outbox changes of `log`, coalesced, in order.
    public static func coalesce(_ log: [Entry], rules: Rules = .standard) -> [Wiretuner_Doc_V1_Change] {
        var work = Work(log)
        if rules.contains(.registers) {
            work.dropOverwrittenRegisters()
        }
        if rules.contains(.createThenDelete) {
            work.dropCreatedThenDeleted()
        }
        if rules.contains(.text) {
            work.joinAdjacentText()
        }
        return work.outbox
    }
}

private struct Work {
    /// Index into `outbox` of each outbox entry, nil for the others.
    let slots: [Int?]
    let others: [Wiretuner_Doc_V1_Change]
    let otherSlots: [Int?]
    var outbox: [Wiretuner_Doc_V1_Change] = []

    init(_ log: [Coalescer.Entry]) {
        var slots: [Int?] = []
        var otherSlots: [Int?] = []
        var others: [Wiretuner_Doc_V1_Change] = []
        for entry in log {
            switch entry {
            case .outbox(let change):
                slots.append(outbox.count)
                otherSlots.append(nil)
                outbox.append(change)
            case .other(let change):
                slots.append(nil)
                otherSlots.append(others.count)
                others.append(change)
            }
        }
        self.slots = slots
        self.others = others
        self.otherSlots = otherSlots
    }

    struct RegisterKey: Hashable {
        let node: OpID
        let path: Wiretuner_Doc_V1_FieldPath
    }

    // Walking back from the newest change: a path a later local SetFields writes is "covered", and
    // an earlier local SetFields drops covered paths; another replica's write to a path uncovers it.
    mutating func dropOverwrittenRegisters() {
        var covered: Set<RegisterKey> = []
        for index in slots.indices.reversed() {
            guard let slot = slots[index] else {
                for op in others[otherSlots[index]!].ops {
                    if case .set(let set) = op.op {
                        for path in set.paths {
                            covered.remove(RegisterKey(node: OpID(set.node), path: path))
                        }
                    }
                }
                continue
            }
            for opIndex in outbox[slot].ops.indices.reversed() {
                guard case .set(var set) = outbox[slot].ops[opIndex].op else { continue }
                let node = OpID(set.node)
                let keys = set.paths.map { RegisterKey(node: node, path: $0) }
                let kept = set.paths.filter { !covered.contains(RegisterKey(node: node, path: $0)) }
                covered.formUnion(keys)
                if kept.isEmpty {
                    outbox[slot].ops[opIndex] = Ops.noop()
                } else if kept.count < set.paths.count {
                    set.paths = kept
                    outbox[slot].ops[opIndex].set = set
                }
            }
        }
    }

    // A node created by an outbox op, whose last deleted write in the outbox is `true`, and which
    // no op other than the ones targeting it mentions (as a parent, a reference, anywhere in its
    // bytes): every op targeting it becomes Noops.  Only single-counter ops are dropped, so a
    // change never grows past its op limit.
    struct Position: Hashable {
        let slot: Int
        let op: Int
    }

    mutating func dropCreatedThenDeleted() {
        var created: [OpID: [Position]] = [:]
        var order: [OpID] = []
        var deleted: [OpID: Bool] = [:]
        for slot in outbox.indices {
            var counter = outbox[slot].startCounter
            for (opIndex, op) in outbox[slot].ops.enumerated() {
                let id = OpID(counter: counter, replica: outbox[slot].replica)
                counter &+= EngineState.counters(op)
                if case .create = op.op {
                    created[id] = [Position(slot: slot, op: opIndex)]
                    order.append(id)
                } else if let target = Self.target(op), created[target] != nil {
                    created[target]!.append(Position(slot: slot, op: opIndex))
                    if case .setDeleted(let flag) = op.op {
                        deleted[target] = flag.deleted
                    }
                }
            }
        }
        for node in order where deleted[node] == true {
            let group = created[node]!
            guard group.allSatisfy({ EngineState.counters(outbox[$0.slot].ops[$0.op]) == 1 }),
                  !mentioned(node, outside: Set(group)) else { continue }
            for member in group {
                outbox[member.slot].ops[member.op] = Ops.noop()
            }
        }
    }

    // Whether any op of the log other than `group` carries `node`'s id in its bytes.
    private func mentioned(_ node: OpID, outside group: Set<Position>) -> Bool {
        let pattern: [UInt8] = try! node.proto.serializedBytes()
        let local = outbox.indices.flatMap { slot in
            outbox[slot].ops.indices.filter { !group.contains(Position(slot: slot, op: $0)) }.map { outbox[slot].ops[$0] }
        }
        return (local + others.flatMap(\.ops)).contains { Self.contains(try! $0.serializedBytes(), pattern) }
    }

    private static func contains(_ bytes: [UInt8], _ pattern: [UInt8]) -> Bool {
        guard bytes.count >= pattern.count else { return false }
        for start in 0...(bytes.count - pattern.count) where bytes[start..<start + pattern.count].elementsEqual(pattern) {
            return true
        }
        return false
    }

    // The node an op writes to.
    private static func target(_ op: Wiretuner_Doc_V1_Op) -> OpID? {
        switch op.op {
        case .set(let op): OpID(op.node)
        case .move(let op): OpID(op.node)
        case .setDeleted(let op): OpID(op.node)
        case .elementInsert(let op): OpID(op.node)
        case .elementMove(let op): OpID(op.node)
        case .elementDelete(let op): OpID(op.node)
        case .textInsert(let op): OpID(op.node)
        case .textDelete(let op): OpID(op.node)
        case .textMark(let op): OpID(op.node)
        case .setAdd(let op): OpID(op.node)
        case .setRemove(let op): OpID(op.node)
        default: nil
        }
    }

    // A TextInsert followed by one continuing it -- same field, its left origin the previous
    // insert's last character, the same right origin, and the next counters -- becomes one op:
    // each character keeps its id and origins.  The two are adjacent within a change, or the first
    // ends one change and the second starts the next outbox change and is not its only op (a
    // change keeps at least one op, and its start counter moves past the characters it gave up).
    mutating func joinAdjacentText() {
        for slot in outbox.indices {
            let replica = outbox[slot].replica
            var opIndex = 0
            var counter = outbox[slot].startCounter
            while opIndex < outbox[slot].ops.count {
                let op = outbox[slot].ops[opIndex]
                if opIndex + 1 < outbox[slot].ops.count {
                    if let joined = Self.join(op, counter, outbox[slot].ops[opIndex + 1], counter &+ EngineState.counters(op),
                                              replica: replica) {
                        outbox[slot].ops[opIndex] = joined
                        outbox[slot].ops.remove(at: opIndex + 1)
                        continue
                    }
                } else if slot + 1 < outbox.count, outbox[slot + 1].ops.count > 1, outbox[slot + 1].replica == replica,
                          let joined = Self.join(op, counter, outbox[slot + 1].ops[0], outbox[slot + 1].startCounter, replica: replica) {
                    outbox[slot].ops[opIndex] = joined
                    outbox[slot + 1].startCounter &+= EngineState.counters(outbox[slot + 1].ops[0])
                    outbox[slot + 1].ops.removeFirst()
                    continue
                }
                counter &+= EngineState.counters(op)
                opIndex += 1
            }
        }
    }

    private static func join(_ a: Wiretuner_Doc_V1_Op, _ aCounter: UInt64, _ b: Wiretuner_Doc_V1_Op, _ bCounter: UInt64,
                             replica: UInt64) -> Wiretuner_Doc_V1_Op? {
        guard case .textInsert(var first) = a.op, case .textInsert(let second) = b.op,
              !first.chars.isEmpty, !second.chars.isEmpty,
              first.node == second.node, first.text == second.text, first.rightOrigin == second.rightOrigin else { return nil }
        let length = UInt64(first.chars.unicodeScalars.count)
        guard bCounter == aCounter &+ length, first.chars.utf8.count + second.chars.utf8.count <= Coalescer.maxTextBytes,
              second.leftOrigin == Ops.elementID(OpID(counter: aCounter &+ length &- 1, replica: replica)) else { return nil }
        first.chars += second.chars
        var op = Wiretuner_Doc_V1_Op()
        op.textInsert = first
        return op
    }
}
