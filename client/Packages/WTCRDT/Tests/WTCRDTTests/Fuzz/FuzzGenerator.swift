import Foundation
@testable import WTCRDT
import WTProto

/// The cross-engine fuzzer's generator (CRDT-012; docs/spec/testing.adoc, "Fuzzing").  From one
/// seed it writes conformance vectors: each simulates a few replicas editing one document on the
/// test kind through a hub, with random partitions (a disconnected replica keeps editing and
/// syncs later), random interleavings of pushes and pulls, and garbage collection at the points
/// the hub publishes (crdt-model.adoc, "Garbage collection").  Every replica's own application
/// order -- its changes as it made them, the others' as it pulled them, its collections -- and the
/// hub's (the server log) become the vector's deliveries, which must all reach one state.
///
/// Ops are generated against the replica's own state, as a client would: they name nodes,
/// elements, characters and members it holds, text origins come from the insertion read-out, and
/// nothing collectable at the replica's horizon (the newest point the hub published to it) is
/// named.  Everything draws from one `SplitMix64`, so a seed always writes the same vectors.
struct FuzzGenerator {
    typealias Vector = Wiretuner_Conformance_V1_Vector
    typealias Change = Wiretuner_Conformance_V1_Change
    typealias Op = Wiretuner_Conformance_V1_Op

    static let setupReplica: UInt64 = 7
    static let hour: Int64 = 3_600_000
    static let kind: UInt32 = 1000
    static let layers = OpID.wellKnown(4)
    static let label = RegisterPath([1000, 2])
    static let name = RegisterPath([1000, 1, 1])
    static let locked = RegisterPath([1000, 1, 3])
    static let tail = RegisterPath([1000, 10, 1])
    static let tags = RegisterPath([1000, 3])
    static let codes = RegisterPath([1000, 4])
    static let contours = RegisterPath([1000, 7])
    static let stops = RegisterPath([1000, 8])
    static let text = RegisterPath([1000, 9])

    /// A collection point, or a horizon: a stable point and the clock published with it.
    struct Point: Equatable {
        var stable: UInt64
        var time: Int64
    }

    /// One step of a replica's application order.
    enum Step {
        case pick(UInt64, UInt64)
        case collect(Point)
    }

    private struct Replica {
        let id: UInt64
        var engine: EngineState
        var seq: UInt64 = 0
        var pulled: UInt64 = 1
        var outbox: [Change] = []
        var connected = true
        /// The newest publication it has seen: its horizon.
        var publication = 0
        var steps: [Step] = []
    }

    private struct Hub {
        /// The server log; a change's server_seq is its index plus one (the setup is 1).
        var log: [Change] = []
        /// The horizon each change's author had when it made the change.
        var horizons: [Point] = []
        /// The stable points published so far (the smallest acknowledged server_seq) and the clock.
        var publications: [Point] = []
        var clock: Int64 = 0
        var steps: [Step] = []
    }

    /// What one generated vector took.
    struct Summary {
        var ops = 0
        var changes = 0
        var collections = 0
        /// The state hash each simulated replica ended with (they must all equal the vector's).
        var replicaHashes: [String] = []
    }

    private var random: SplitMix64

    init(seed: UInt64) {
        random = SplitMix64(seed: seed)
    }

    // MARK: Randomness

    private mutating func below(_ bound: Int) -> Int {
        Int(random.next() % UInt64(bound))
    }

    private mutating func chance(_ percent: Int) -> Bool {
        below(100) < percent
    }

    private mutating func pick<T>(_ items: [T]) -> T? {
        items.isEmpty ? nil : items[below(items.count)]
    }

    private mutating func word() -> String {
        String((0..<(1 + below(4))).map { _ in "abcdefgh".randomElement(using: &random)! })
    }

    // MARK: Vectors

    /// A vector named `name` (its path below the vector root) of about `budget` ops.
    mutating func vector(name: String, ops budget: Int, schema: Schema) -> (vector: Vector, summary: Summary) {
        var ids: [UInt64] = []
        let count = 2 + below(3)
        while ids.count < count {
            let id = random.next()
            if id != 0 && id != Self.setupReplica && !ids.contains(id) {
                ids.append(id)
            }
        }
        let setup = Self.setupChange()
        var base = EngineState(schema: schema)
        base.apply(ConformanceRunner.docChange(setup), serverSeq: 1)
        var replicas = ids.map { Replica(id: $0, engine: base) }
        var hub = Hub(log: [setup], horizons: [Point(stable: 0, time: 0)], publications: [Point(stable: 1, time: 0)])
        var summary = Summary()
        var steps = 0
        while summary.ops < budget {
            steps += 1
            precondition(steps < 100 * budget + 1_000, "the generator stopped making changes")
            let index = below(replicas.count)
            switch below(20) {
            case 0..<12:
                if let change = makeChange(&replicas[index], hub) {
                    summary.ops += change.ops.count
                    summary.changes += 1
                }
            case 12..<17:
                if replicas[index].connected {
                    sync(&replicas, index, &hub, collect: true)
                }
            case 17:
                replicas[index].connected.toggle()
            default:
                hub.clock += Int64(below(72)) * Self.hour
            }
        }
        // Everyone reconnects and syncs until the log is quiet, twice more so the published point
        // reaches the end of the log, then everyone collects there.
        for index in replicas.indices {
            replicas[index].connected = true
        }
        while replicas.contains(where: { !$0.outbox.isEmpty || $0.pulled != UInt64(hub.log.count) }) {
            for index in replicas.indices {
                sync(&replicas, index, &hub, collect: false)
            }
        }
        for _ in 0..<2 {
            for index in replicas.indices {
                sync(&replicas, index, &hub, collect: false)
            }
        }
        let last = Self.collectionPoint(replicas, hub)
        for index in replicas.indices {
            collect(&replicas[index], last)
        }
        hub.steps.append(.collect(last))
        summary.collections = (replicas.map(\.steps) + [hub.steps]).joined().filter { if case .collect = $0 { true } else { false } }.count
        summary.replicaHashes = replicas.map { StateHash.hex($0.engine.stateHash) }
        return (vector: Self.vector(name: name, setup: setup, replicas: replicas, hub: hub, summary: summary), summary: summary)
    }

    private static func vector(name: String, setup: Change, replicas: [Replica], hub: Hub, summary: Summary) -> Vector {
        var vector = Vector()
        vector.name = name
        vector.description_p = "Generated by the fuzzer (CRDT-012): \(replicas.count) replicas, \(summary.changes) changes, "
            + "\(summary.ops) ops, \(summary.collections) collections; each replica's application order and the server log's."
        vector.setup.change = [setup]
        for replica in replicas {
            var entry = Wiretuner_Conformance_V1_Replica()
            entry.id = replica.id
            entry.change = hub.log.filter { $0.replica == replica.id }
            vector.replica.append(entry)
        }
        for steps in replicas.map(\.steps) + [hub.steps] {
            var delivery = Wiretuner_Conformance_V1_Delivery()
            for step in steps {
                switch step {
                case .pick(let replica, let seq):
                    var pick = Wiretuner_Conformance_V1_Pick()
                    pick.replica = replica
                    pick.seq = seq
                    delivery.picks.append(pick)
                case .collect(let point):
                    var collect = Wiretuner_Conformance_V1_Collect()
                    collect.after = UInt32(delivery.picks.count)
                    collect.stableSeq = point.stable
                    collect.nowMs = point.time
                    delivery.collect.append(collect)
                }
            }
            vector.deliveries.append(delivery)
        }
        return vector
    }

    /// Three test nodes under the layers collection, the first holding "hi".
    static func setupChange() -> Change {
        var change = Change()
        change.replica = setupReplica
        change.seq = 1
        change.startCounter = 1
        for (index, position) in [UInt8(0x80), 0x90, 0xA0].enumerated() {
            var op = Op()
            op.create.parent = layers.proto
            op.create.position = Data([position])
            op.create.props.test.label = "n\(index)"
            change.ops.append(op)
        }
        var op = Op()
        op.textInsert.node = OpID(counter: 1, replica: setupReplica).proto
        op.textInsert.text = text.proto
        op.textInsert.chars = "hi"
        change.ops.append(op)
        return change
    }

    // MARK: The hub

    /// The collection point the hub publishes now: the stable point that was current when every
    /// replica had seen it (its smallest horizon), lowered below the horizon of every change after
    /// it, so no change any replica may still apply names what a collection there drops.
    private static func collectionPoint(_ replicas: [Replica], _ hub: Hub) -> Point {
        var point = hub.publications[replicas.map(\.publication).min()!]
        var lowered = true
        while lowered {
            lowered = false
            for (index, horizon) in hub.horizons.enumerated() where UInt64(index + 1) > point.stable && horizon.stable < point.stable {
                point.stable = horizon.stable
                lowered = true
            }
        }
        for (index, horizon) in hub.horizons.enumerated() where UInt64(index + 1) > point.stable {
            point.time = min(point.time, horizon.time)
        }
        return point
    }

    // A replica syncs: pushes its outbox (the hub sequences each change), pulls the log, receives
    // a publication, and may collect at the published collection point, as may the server.
    private mutating func sync(_ replicas: inout [Replica], _ index: Int, _ hub: inout Hub, collect: Bool) {
        var replica = replicas[index]
        let horizon = hub.publications[replica.publication]
        for var change in replica.outbox {
            change.serverSeq = UInt64(hub.log.count + 1)
            hub.log.append(change)
            hub.horizons.append(horizon)
            hub.steps.append(.pick(change.replica, change.seq))
            replica.engine.acknowledge(replica: change.replica, seq: change.seq, serverSeq: change.serverSeq)
        }
        replica.outbox = []
        while replica.pulled < UInt64(hub.log.count) {
            let change = hub.log[Int(replica.pulled)]
            replica.pulled += 1
            if change.replica != replica.id {
                replica.engine.apply(ConformanceRunner.docChange(change), serverSeq: change.serverSeq)
                replica.steps.append(.pick(change.replica, change.seq))
            }
        }
        replicas[index] = replica
        hub.publications.append(Point(stable: replicas.map(\.pulled).min()!, time: hub.clock))
        replicas[index].publication = hub.publications.count - 1
        guard collect else { return }
        let point = Self.collectionPoint(replicas, hub)
        if chance(50) {
            self.collect(&replicas[index], point)
        }
        if chance(30) {
            hub.steps.append(.collect(point))
        }
    }

    private func collect(_ replica: inout Replica, _ point: Point) {
        guard point.stable >= replica.engine.store.stableSeq else { return }
        replica.engine.collect(stableSeq: point.stable, now: point.time)
        replica.steps.append(.collect(point))
    }

    // MARK: Changes

    private mutating func makeChange(_ replica: inout Replica, _ hub: Hub) -> Change? {
        let horizon = hub.publications[replica.publication]
        let view = View(engine: replica.engine, horizon: horizon)
        var ops: [Op] = []
        let wanted = 1 + below(3)
        for _ in 0..<(wanted * 4) where ops.count < wanted {
            if let op = makeOp(view) {
                ops.append(op)
            }
        }
        guard !ops.isEmpty else { return nil }
        replica.seq += 1
        var change = Change()
        change.replica = replica.id
        change.seq = replica.seq
        change.startCounter = replica.engine.clock.peek
        change.baseServerSeq = replica.pulled
        change.wallTimeMs = hub.clock
        change.ops = ops
        replica.engine.apply(ConformanceRunner.docChange(change))
        replica.outbox.append(change)
        replica.steps.append(.pick(replica.id, replica.seq))
        return change
    }

    /// What a replica may name: its state seen from its horizon.
    private struct View {
        let engine: EngineState
        let horizon: Point
        let counters: [UInt64: UInt64]
        let nodes: [OpID]

        init(engine: EngineState, horizon: Point) {
            self.engine = engine
            self.horizon = horizon
            counters = engine.store.stableCounters(at: max(horizon.stable, engine.store.stableSeq))
            nodes = engine.store.nodes.filter {
                engine.store.kind($0) == FuzzGenerator.kind && !engine.isCompactable($0, stableSeq: horizon.stable, now: horizon.time)
            }
        }

        var store: NodeStore { engine.store }

        func stable(_ op: OpID) -> Bool {
            op.counter < (counters[op.replica] ?? 0)
        }

        /// The elements of a sequence that are not tombstones stable at the horizon, in order.
        func elements(_ node: OpID, _ sequence: RegisterPath) -> [OpID] {
            store.elementOrder(node, sequence).filter { element in
                guard let deleted = store.element(node, sequence.element(element))?.deleted?.current else { return true }
                return !deleted.value || !stable(deleted.op)
            }
        }

        func position(_ node: OpID, _ sequence: RegisterPath, _ element: OpID) -> [UInt8] {
            store.element(node, sequence.element(element))!.position.current.value
        }

        func text(_ node: OpID) -> TextSequence {
            store.text(node, FuzzGenerator.text) ?? TextSequence()
        }
    }

    private mutating func makeOp(_ view: View) -> Op? {
        var op = Op()
        guard let node = pick(view.nodes) else {
            // Every node is gone or on its way out: start another.
            op.create.parent = Self.layers.proto
            op.create.position = Data(childPosition(view, Self.layers))
            op.create.props.test.label = word()
            return op
        }
        switch below(22) {
        case 0:
            let parent = pick([Self.layers] + view.nodes)!
            op.create.parent = parent.proto
            op.create.position = Data(childPosition(view, parent))
            op.create.props.test.label = word()
        case 1:
            let parent = pick([Self.layers] + view.nodes)!
            op.move.node = node.proto
            op.move.parent = parent.proto
            op.move.position = Data(childPosition(view, parent))
        case 2:
            op.setDeleted.node = node.proto
            op.setDeleted.deleted = chance(60)
        case 3, 4:
            op.set.node = node.proto
            switch below(5) {
            case 0:
                op.set.paths = [Self.label.proto]
                op.set.values.test.label = word()
            case 1:
                op.set.paths = [Self.label.proto]  // cleared
            case 2:
                op.set.paths = [Self.name.proto, Self.locked.proto]
                op.set.values.test.common.name = word()
                op.set.values.test.common.locked = chance(50)
            case 3:
                op.set.paths = [Self.tail.proto]
                op.set.values.test.tail.alignment = UInt32(below(4))
            default:
                op.set.paths = [RegisterPath([1000, 1]).proto]
                op.set.values.test.common.name = word()
            }
        case 5, 6:
            return insertElements(view, node, Self.stops, &op)
        case 7:
            if chance(50) {
                return insertElements(view, node, Self.contours, &op)
            }
            guard let contour = pick(view.elements(node, Self.contours)) else { return nil }
            return insertElements(view, node, Self.contours.element(contour).child(3), &op)
        case 8:
            guard let (sequence, element) = anyElement(view, node) else { return nil }
            let order = view.elements(node, sequence)
            let gap = below(order.count + 1)
            op.elementMove.node = node.proto
            op.elementMove.element = sequence.element(element).proto
            op.elementMove.position = Data(position(gap > 0 ? view.position(node, sequence, order[gap - 1]) : nil,
                                                    gap < order.count ? view.position(node, sequence, order[gap]) : nil))
        case 9:
            guard let (sequence, element) = anyElement(view, node) else { return nil }
            op.elementDelete.node = node.proto
            op.elementDelete.elements = [sequence.element(element).proto]
            op.elementDelete.deleted = view.store.element(node, sequence.element(element))?.isDeleted != true
        case 10:
            guard let (sequence, element) = anyElement(view, node) else { return nil }
            op.set.node = node.proto
            let path = sequence.element(element)
            if sequence == Self.stops {
                op.set.paths = [path.child(2).proto, path.child(3).proto]
                var stop = Wiretuner_Conformance_V1_TestStop()
                stop.offset = Double(below(100))
                stop.color = word()
                op.set.values.test.stops = [stop]
            } else if sequence == Self.contours {
                op.set.paths = [path.child(4).proto, path.child(2).proto]
                var contour = Wiretuner_Conformance_V1_TestContour()
                contour.name = word()
                contour.closed = chance(50)
                op.set.values.test.contours = [contour]
            } else {
                op.set.paths = [path.child(3).proto]
                var point = Wiretuner_Conformance_V1_TestPoint()
                point.weight = Double(below(10))
                var contour = Wiretuner_Conformance_V1_TestContour()
                contour.anchors = [point]
                op.set.values.test.contours = [contour]
            }
        case 11, 12, 13, 14:
            let text = view.text(node)
            let origins = view.engine.insertionOrigins(node, Self.text, at: below(text.liveCount + 1), stableSeq: view.horizon.stable)
            op.textInsert.node = node.proto
            op.textInsert.text = Self.text.proto
            op.textInsert.leftOrigin = Self.element(origins.left)
            op.textInsert.rightOrigin = Self.element(origins.right)
            op.textInsert.chars = chance(15) ? "\n" : word()
        case 15, 16:
            let live = view.text(node).liveChars
            guard let first = pick(live) else { return nil }
            var range = Wiretuner_Doc_V1_ElementIdRange()
            range.first = Self.element(first)
            range.count = 1
            // Longer runs only over live characters (a stable tombstone may be collected).
            while chance(40), live.contains(OpID(counter: first.counter + range.count, replica: first.replica)) {
                range.count += 1
            }
            op.textDelete.node = node.proto
            op.textDelete.text = Self.text.proto
            op.textDelete.ranges = [range]
        case 17:
            let live = view.text(node).liveChars
            guard !live.isEmpty else { return nil }
            let from = below(live.count)
            let to = from + below(live.count - from)
            op.textMark.node = node.proto
            op.textMark.text = Self.text.proto
            op.textMark.start = anchor(chance(20) ? nil : live[from])
            op.textMark.end = anchor(chance(20) ? nil : live[to])
            switch below(4) {
            case 0: op.textMark.value.bold = chance(70)
            case 1: op.textMark.value.size = Double(below(4) * 6)
            case 2: op.textMark.value.fontFamily = chance(80) ? word() : ""
            default:
                var feature = Wiretuner_Conformance_V1_TestFeature()
                feature.tag = pick(["liga", "smcp"])!
                feature.state = UInt32(below(2))
                op.textMark.value.feature = feature
            }
        case 18:
            let text = view.text(node)
            guard let newline = pick(text.liveChars.filter { text.codepoint($0) == 0x0A }) else { return nil }
            op.set.node = node.proto
            op.set.paths = [Self.text.element(newline).child(6).child(chance(50) ? 1 : 4).proto]
            var paragraph = Wiretuner_Conformance_V1_TestParagraph()
            paragraph.alignment = UInt32(below(4))
            paragraph.leftIndent = Double(below(3) * 12)
            var char = Wiretuner_Conformance_V1_TestChar()
            char.paragraph = paragraph
            op.set.values.test.text.chars = [char]
        case 19, 20:
            let add = chance(55)
            if chance(70) {
                var values = Wiretuner_Conformance_V1_NodeProps()
                values.test.tags = [pick(["a", "b", "c", "d"])!]
                if add {
                    op.setAdd.node = node.proto
                    op.setAdd.set = Self.tags.proto
                    op.setAdd.values = values
                } else {
                    op.setRemove.node = node.proto
                    op.setRemove.set = Self.tags.proto
                    op.setRemove.values = values
                }
            } else {
                var values = Wiretuner_Conformance_V1_NodeProps()
                values.test.codes = [UInt32(below(3))]
                if add {
                    op.setAdd.node = node.proto
                    op.setAdd.set = Self.codes.proto
                    op.setAdd.values = values
                } else {
                    op.setRemove.node = node.proto
                    op.setRemove.set = Self.codes.proto
                    op.setRemove.values = values
                }
            }
        default:
            op.noop = Wiretuner_Doc_V1_Noop()
        }
        return op
    }

    private mutating func insertElements(_ view: View, _ node: OpID, _ sequence: RegisterPath, _ op: inout Op) -> Op {
        let order = view.elements(node, sequence)
        let gap = below(order.count + 1)
        var lo = gap > 0 ? view.position(node, sequence, order[gap - 1]) : nil
        let hi = gap < order.count ? view.position(node, sequence, order[gap]) : nil
        op.elementInsert.node = node.proto
        op.elementInsert.sequence = sequence.proto
        for _ in 0..<(1 + below(2)) {
            let key = position(lo, hi)
            op.elementInsert.positions.append(Data(key))
            lo = key
            if sequence == Self.stops {
                var stop = Wiretuner_Conformance_V1_TestStop()
                stop.offset = Double(below(100))
                op.elementInsert.values.test.stops.append(stop)
            } else if sequence == Self.contours {
                var contour = Wiretuner_Conformance_V1_TestContour()
                contour.name = word()
                op.elementInsert.values.test.contours.append(contour)
            }
        }
        if sequence != Self.stops && sequence != Self.contours {
            var contour = Wiretuner_Conformance_V1_TestContour()
            contour.anchors = op.elementInsert.positions.map { _ in
                var point = Wiretuner_Conformance_V1_TestPoint()
                point.weight = 1
                return point
            }
            op.elementInsert.values.test.contours = [contour]
        }
        return op
    }

    // An element of any of the node's sequences that is not a stable tombstone (nor inside one).
    private mutating func anyElement(_ view: View, _ node: OpID) -> (RegisterPath, OpID)? {
        var candidates = view.elements(node, Self.stops).map { (Self.stops, $0) }
        for contour in view.elements(node, Self.contours) {
            candidates.append((Self.contours, contour))
            let anchors = Self.contours.element(contour).child(3)
            candidates += view.elements(node, anchors).map { (anchors, $0) }
        }
        return pick(candidates)
    }

    private mutating func childPosition(_ view: View, _ parent: OpID) -> [UInt8] {
        let children = view.store.children(parent).compactMap { view.store.placement($0)?.position }
        let gap = below(children.count + 1)
        return position(gap > 0 ? children[gap - 1] : nil, gap < children.count ? children[gap] : nil)
    }

    // A fractional position between two neighbours; equal neighbours (concurrent inserts can make
    // them) have no room between them, so the key goes after the lower one instead.
    private mutating func position(_ lo: [UInt8]?, _ hi: [UInt8]?) -> [UInt8] {
        if let key = try? FractionalIndex.between(lo, hi, using: &random) {
            return key
        }
        return try! FractionalIndex.between(lo, nil, using: &random)
    }

    private mutating func anchor(_ char: OpID?) -> Wiretuner_Doc_V1_Anchor {
        var anchor = Wiretuner_Doc_V1_Anchor()
        if let char {
            anchor.char = Self.element(char)
            anchor.before = char.counter % 2 == 0
        } else {
            anchor.before = random.next() % 2 == 0
        }
        return anchor
    }

    static func element(_ id: OpID) -> Wiretuner_Doc_V1_ElementId {
        var element = Wiretuner_Doc_V1_ElementId()
        element.counter = id.counter
        element.replica = id.replica
        return element
    }
}
