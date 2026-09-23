import Foundation
@testable import WTCRDT
import WTProto

/// Shrinks a failing vector (CRDT-012) by delta debugging (Zeller and Hildebrandt's ddmin) over,
/// in turn, its deliveries, its changes (dropped from the replicas and from every delivery's
/// picks), its collections and its ops (each replaced by as many `Noop`s as it took counters, so
/// the ops after it keep their ids), until no step shrinks it further.  `fails` decides whether a
/// candidate still shows the failure: a divergence inside WTCRDT, or (with the Java oracle) a
/// disagreement between the engines.
enum FuzzMinimizer {
    typealias Vector = Wiretuner_Conformance_V1_Vector
    typealias Change = Wiretuner_Conformance_V1_Change

    /// A change by replica and seq.
    struct Key: Hashable {
        let replica: UInt64
        let seq: UInt64
    }

    /// One op of one change.
    struct OpKey: Hashable {
        let change: Key
        let index: Int
    }

    /// One collection of one delivery.
    struct CollectKey: Hashable {
        let delivery: Int
        let index: Int
    }

    static func minimize(_ vector: Vector, fails: (Vector) -> Bool) -> Vector {
        var current = vector
        var shrinking = true
        while shrinking {
            shrinking = false
            let deliveries = ddmin(Array(current.deliveries.indices), minimum: 1) { fails(keeping(current, deliveries: $0)) }
            if deliveries.count < current.deliveries.count {
                current = keeping(current, deliveries: deliveries)
                shrinking = true
            }
            let changes = current.replica.flatMap { replica in replica.change.map { Key(replica: replica.id, seq: $0.seq) } }
            let keptChanges = ddmin(changes) { fails(keeping(current, changes: Set($0))) }
            if keptChanges.count < changes.count {
                current = keeping(current, changes: Set(keptChanges))
                shrinking = true
            }
            let collects = current.deliveries.enumerated().flatMap { delivery, entry in
                entry.collect.indices.map { CollectKey(delivery: delivery, index: $0) }
            }
            let keptCollects = ddmin(collects) { fails(keeping(current, collects: Set($0))) }
            if keptCollects.count < collects.count {
                current = keeping(current, collects: Set(keptCollects))
                shrinking = true
            }
            let ops = current.replica.flatMap { replica in
                replica.change.flatMap { change in
                    change.ops.indices.filter { !isNoop(change.ops[$0]) }
                        .map { OpKey(change: Key(replica: replica.id, seq: change.seq), index: $0) }
                }
            }
            let keptOps = ddmin(ops) { fails(keeping(current, ops: Set($0), among: Set(ops))) }
            if keptOps.count < ops.count {
                current = keeping(current, ops: Set(keptOps), among: Set(ops))
                shrinking = true
            }
        }
        return current
    }

    /// ddmin: the smallest subsequence of `items` (at least `minimum` long) it finds for which
    /// `fails` holds, removing ever smaller chunks while any removal keeps it failing.
    static func ddmin<T>(_ items: [T], minimum: Int = 0, _ fails: ([T]) -> Bool) -> [T] {
        var items = items
        var chunks = 2
        while items.count > minimum && items.count >= 2 {
            let size = (items.count + chunks - 1) / chunks
            var reduced = false
            for start in stride(from: 0, to: items.count, by: size) {
                let complement = Array(items[..<start]) + Array(items[min(start + size, items.count)...])
                if complement.count >= minimum && fails(complement) {
                    items = complement
                    chunks = max(chunks - 1, 2)
                    reduced = true
                    break
                }
            }
            if !reduced {
                guard chunks < items.count else { break }
                chunks = min(items.count, chunks * 2)
            }
        }
        if items.count == 1 && minimum == 0 && fails([]) {
            return []
        }
        return items
    }

    static func isNoop(_ op: Wiretuner_Conformance_V1_Op) -> Bool {
        if case .noop? = op.op { return true }
        return false
    }

    static func keeping(_ vector: Vector, deliveries: [Int]) -> Vector {
        var out = vector
        out.deliveries = deliveries.map { vector.deliveries[$0] }
        return out
    }

    /// The vector with only `changes`: the others leave their replica and every delivery, and each
    /// collection keeps its place among the picks that remain.
    static func keeping(_ vector: Vector, changes: Set<Key>) -> Vector {
        var out = vector
        for index in out.replica.indices {
            let id = out.replica[index].id
            out.replica[index].change.removeAll { !changes.contains(Key(replica: id, seq: $0.seq)) }
        }
        out.replica.removeAll { $0.change.isEmpty }
        for index in out.deliveries.indices {
            let delivery = vector.deliveries[index]
            var kept = Wiretuner_Conformance_V1_Delivery()
            var remaining: [UInt32] = []
            var count: UInt32 = 0
            for pick in delivery.picks {
                remaining.append(count)
                if changes.contains(Key(replica: pick.replica, seq: pick.seq)) {
                    kept.picks.append(pick)
                    count += 1
                }
            }
            remaining.append(count)
            kept.collect = delivery.collect.map { collect in
                var moved = collect
                moved.after = remaining[min(Int(collect.after), remaining.count - 1)]
                return moved
            }
            out.deliveries[index] = kept
        }
        return out
    }

    static func keeping(_ vector: Vector, collects: Set<CollectKey>) -> Vector {
        var out = vector
        for index in out.deliveries.indices {
            out.deliveries[index].collect = vector.deliveries[index].collect.enumerated()
                .filter { collects.contains(CollectKey(delivery: index, index: $0.offset)) }
                .map(\.element)
        }
        return out
    }

    /// The vector with the ops of `among` not in `ops` replaced by Noops, one per counter.
    static func keeping(_ vector: Vector, ops: Set<OpKey>, among: Set<OpKey>) -> Vector {
        var out = vector
        for (replicaIndex, replica) in vector.replica.enumerated() {
            for (changeIndex, change) in replica.change.enumerated() {
                var rebuilt: [Wiretuner_Conformance_V1_Op] = []
                for (index, op) in change.ops.enumerated() {
                    let key = OpKey(change: Key(replica: replica.id, seq: change.seq), index: index)
                    guard among.contains(key) && !ops.contains(key) else {
                        rebuilt.append(op)
                        continue
                    }
                    let counters = EngineState.counters(ConformanceRunner.docChange(single(op)).ops[0])
                    rebuilt += (0..<counters).map { _ in
                        var noop = Wiretuner_Conformance_V1_Op()
                        noop.noop = Wiretuner_Doc_V1_Noop()
                        return noop
                    }
                }
                out.replica[replicaIndex].change[changeIndex].ops = rebuilt
            }
        }
        return out
    }

    private static func single(_ op: Wiretuner_Conformance_V1_Op) -> Change {
        var change = Change()
        change.ops = [op]
        return change
    }
}
