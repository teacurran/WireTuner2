import Foundation
import Testing
@testable import WTCRDT
import WTProto

/// Builders for tree ops (mirrors wt-crdt's test `Trees`).
enum Trees {
    static func create(_ parent: OpID, _ position: [UInt8], name: String = "g") -> Wiretuner_Doc_V1_Op {
        var create = Wiretuner_Doc_V1_CreateNode()
        create.parent = parent.proto
        create.position = Data(position)
        var group = Wiretuner_Doc_V1_GroupProps()
        group.common.name = name
        create.props.group = group
        var op = Wiretuner_Doc_V1_Op()
        op.create = create
        return op
    }

    static func move(_ node: OpID, _ parent: OpID, _ position: [UInt8]) -> Wiretuner_Doc_V1_Op {
        var move = Wiretuner_Doc_V1_MoveNode()
        move.node = node.proto
        move.parent = parent.proto
        move.position = Data(position)
        var op = Wiretuner_Doc_V1_Op()
        op.move = move
        return op
    }

    static func delete(_ node: OpID, _ deleted: Bool) -> Wiretuner_Doc_V1_Op {
        var setDeleted = Wiretuner_Doc_V1_SetDeleted()
        setDeleted.node = node.proto
        setDeleted.deleted = deleted
        var op = Wiretuner_Doc_V1_Op()
        op.setDeleted = setDeleted
        return op
    }

    static func id(_ counter: UInt64, _ replica: UInt64) -> OpID {
        OpID(counter: counter, replica: replica)
    }
}

@Suite struct TreeTests {
    static let layers = OpID.wellKnown(4)
    static let layer = Trees.id(1, 7)

    static func withLayer() -> EngineState {
        var engine = EngineState()
        engine.apply(Changes.change(7, 1, Trees.create(layers, [0x80], name: "L")))
        return engine
    }

    @Test func createPlacesTheNodeAndChildrenSortByPositionThenID() {
        var engine = Self.withLayer()
        engine.apply(Changes.change(7, 2, Trees.create(Self.layer, [0x81]), Trees.create(Self.layer, [0x80]),
                                    Trees.create(Self.layer, [0x81])))
        #expect(engine.store.placement(Self.layer) == Placement(parent: Self.layers, position: [0x80], op: Self.layer))
        #expect(engine.store.children(Self.layer) == [Trees.id(3, 7), Trees.id(2, 7), Trees.id(4, 7)])
        #expect(engine.store.children(Self.layers) == [Self.layer])
        #expect(engine.store.moveLog.map(\.op) == [Self.layer, Trees.id(2, 7), Trees.id(3, 7), Trees.id(4, 7)])
        #expect(engine.store.moveLog.allSatisfy { $0.creates && $0.applied && $0.old == nil })
    }

    @Test func wellKnownNodesSitUnderTheDocumentAndNeverMove() {
        var engine = Self.withLayer()
        #expect(engine.store.placement(.zero) == nil)
        #expect(engine.store.placement(.wellKnown(15)) == Placement(parent: .zero, position: [], op: .zero))
        #expect(engine.store.children(.zero) == (1..<16).map(OpID.wellKnown))
        let before = engine.stateHash
        engine.apply(Changes.change(7, 2, Trees.move(.wellKnown(4), Self.layer, [0x80]), Trees.delete(.wellKnown(4), true),
                                    Trees.delete(Trees.id(9, 9), true)))
        #expect(engine.stateHash == before)
        #expect(engine.store.deleted(.wellKnown(4)) == nil)
        #expect(engine.store.moveLog.last?.applied == false)
    }

    @Test func movesThatWouldMakeACycleAreSkipped() {
        var engine = Self.withLayer()
        engine.apply(Changes.change(7, 2, Trees.create(Self.layer, [0x80]), Trees.create(Trees.id(2, 7), [0x80])))
        let a = Trees.id(2, 7)
        let b = Trees.id(3, 7)
        engine.apply(Changes.change(1, 4, Trees.move(a, b, [0x80])))
        engine.apply(Changes.change(1, 5, Trees.move(a, a, [0x80])))
        #expect(engine.store.placement(a)?.parent == Self.layer)
        #expect(engine.store.moveLog.suffix(2).allSatisfy { !$0.applied })
        engine.apply(Changes.change(1, 6, Trees.move(b, Self.layer, [0x90])))
        engine.apply(Changes.change(1, 7, Trees.move(a, b, [0x80])))
        #expect(engine.store.placement(a) == Placement(parent: b, position: [0x80], op: Trees.id(7, 1)))
    }

    @Test func aLateMoveIsUndoneAndRedoneAroundTheLaterOnes() {
        var inOrder = Self.withLayer()
        var late = Self.withLayer()
        let setup = Changes.change(7, 2, Trees.create(Self.layer, [0x80]), Trees.create(Self.layer, [0x81]),
                                   Trees.create(Self.layer, [0x82]))
        inOrder.apply(setup)
        late.apply(setup)
        let first = Changes.change(1, 5, Trees.move(Trees.id(2, 7), Trees.id(3, 7), [0x80]))
        let second = Changes.change(2, 6, Trees.move(Trees.id(3, 7), Trees.id(2, 7), [0x80]))
        let third = Changes.change(3, 7, Trees.move(Trees.id(4, 7), Trees.id(3, 7), [0x80]))
        for change in [first, second, third] { inOrder.apply(change) }
        for change in [third, second, first, first] { late.apply(change) }
        #expect(late.stateHash == inOrder.stateHash)
        #expect(late.store.moveLog == inOrder.store.moveLog)
        #expect(late.store.placement(Trees.id(3, 7))?.parent == Self.layer)
        #expect(late.store.children(Trees.id(3, 7)) == [Trees.id(2, 7), Trees.id(4, 7)])
    }

    @Test func createsUnderUnknownParentsAreOrphansUntilMoved() {
        var engine = Self.withLayer()
        let orphan = Trees.id(2, 7)
        engine.apply(Changes.change(7, 2, Trees.create(Trees.id(99, 9), [0x80])))
        #expect(engine.store.kind(orphan) == 50)
        #expect(engine.store.placement(orphan) == nil)
        #expect(engine.store.moveLog.last?.applied == false)
        engine.apply(Changes.change(7, 3, Trees.move(orphan, Self.layer, [0x80])))
        #expect(engine.store.placement(orphan)?.parent == Self.layer)
    }

    @Test func aCreateArrivingAfterMovesOfItsNodeIsReplayedInOrder() {
        var engine = Self.withLayer()
        engine.apply(Changes.change(1, 5, Trees.move(Trees.id(2, 7), .wellKnown(5), [0x80])))
        #expect(engine.store.placement(Trees.id(2, 7)) == nil)
        engine.apply(Changes.change(7, 2, Trees.create(Self.layer, [0x80])))
        #expect(engine.store.placement(Trees.id(2, 7))?.parent == .wellKnown(5))
    }

    @Test func deletedIsARegisterOnCreatedNodes() {
        var engine = Self.withLayer()
        engine.apply(Changes.change(2, 3, Trees.delete(Self.layer, true)))
        engine.apply(Changes.change(1, 3, Trees.delete(Self.layer, false)))
        engine.apply(Changes.change(1, 3, Trees.delete(Self.layer, false)))
        let deleted = engine.store.deleted(Self.layer)
        #expect(deleted?.current == Stamped(true, Trees.id(3, 2)))
        #expect(deleted?.losing == [Stamped(false, Trees.id(3, 1))])
        #expect(deleted?.writes.count == 2)
        engine.apply(Changes.change(1, 4, Trees.delete(Self.layer, false)))
        #expect(engine.store.deleted(Self.layer)?.current == Stamped(false, Trees.id(4, 1)))
    }

    @Test func placementsPrint() {
        #expect(Placement(parent: Self.layer, position: [0x80, 0x01], op: Trees.id(2, 1)).description == "1:7/8001@2:1")
    }

    // MARK: Fuzz against a sequential oracle

    /// A tree op for the oracle: its id, node, parent and position; `creates` for a CreateNode.
    struct TreeOp {
        let id: OpID
        let node: OpID
        let parent: OpID
        let position: [UInt8]
        let creates: Bool
    }

    /// Applies every op in OpId order with the rules of crdt-model.adoc, "Tree moves", on a plain map.
    static func oracle(_ ops: [TreeOp]) -> [OpID: OpID] {
        var parents: [OpID: OpID] = [Self.layer: Self.layers]
        var live: Set<OpID> = [Self.layer]
        func exists(_ node: OpID) -> Bool { live.contains(node) || Tree.isWellKnown(node) }
        func isAncestor(_ ancestor: OpID, of node: OpID) -> Bool {
            var current: OpID? = node
            while let at = current {
                if at == ancestor { return true }
                current = parents[at]
            }
            return false
        }
        for op in ops.sorted(by: { $0.id < $1.id }) {
            if op.creates { live.insert(op.node) }
            if live.contains(op.node) && exists(op.parent) && !isAncestor(op.node, of: op.parent) {
                parents[op.node] = op.parent
            }
        }
        return parents
    }

    /// Replicas with Lamport clocks that create and move nodes, occasionally catching up with each
    /// other; returns the setup changes and each replica's changes in its own order.
    static func workload(seed: UInt64, replicas: Int, moves: Int) -> (setup: [Wiretuner_Doc_V1_Change], streams: [[Wiretuner_Doc_V1_Change]], ops: [TreeOp]) {
        var random = SplitMix64(seed: seed)
        func pick(_ n: Int) -> Int { Int(random.next() % UInt64(n)) }
        var ops: [TreeOp] = []
        var setupOps: [Wiretuner_Doc_V1_Op] = []
        var nodes: [OpID] = [Self.layer]
        for counter in UInt64(2)...UInt64(61) {
            let parent = nodes[pick(nodes.count)]
            let position: [UInt8] = [UInt8(1 + pick(250))]
            setupOps.append(Trees.create(parent, position))
            ops.append(TreeOp(id: Trees.id(counter, 7), node: Trees.id(counter, 7), parent: parent, position: position, creates: true))
            nodes.append(Trees.id(counter, 7))
        }
        var clocks = [UInt64](repeating: 61, count: replicas)
        var known = [[OpID]](repeating: nodes, count: replicas)
        var streams = [[Wiretuner_Doc_V1_Change]](repeating: [], count: replicas)
        var created: [(id: OpID, by: Int)] = []
        for _ in 0..<moves {
            let r = pick(replicas)
            if pick(20) == 0 {  // catch up: see everything created so far and the largest clock
                clocks[r] = clocks.max()!
                known[r] = nodes + created.map(\.id)
            }
            clocks[r] += 1
            let id = Trees.id(clocks[r], UInt64(r + 1))
            let parent = known[r][pick(known[r].count)]
            let position: [UInt8] = [UInt8(1 + pick(250)), UInt8(1 + pick(250))]
            if pick(10) == 0 {
                ops.append(TreeOp(id: id, node: id, parent: parent, position: position, creates: true))
                streams[r].append(Changes.change(UInt64(r + 1), id.counter, Trees.create(parent, position)))
                known[r].append(id)
                created.append((id: id, by: r))
            } else {
                let node = known[r][pick(known[r].count)]
                ops.append(TreeOp(id: id, node: node, parent: parent, position: position, creates: false))
                streams[r].append(Changes.change(UInt64(r + 1), id.counter, Trees.move(node, parent, position)))
            }
        }
        return ([Changes.change(7, 1, Trees.create(Self.layers, [0x80], name: "L"))] + [Changes.change(7, 2, setupOps)], streams, ops)
    }

    static func check(_ engine: EngineState, against ops: [TreeOp]) {
        let expected = oracle(ops)
        for op in ops where op.creates {
            #expect(engine.store.placement(op.node)?.parent == expected[op.node], "node \(op.node)")
        }
    }

    @Test func tenThousandRandomMovesMatchTheSequentialOracle() {
        let (setup, streams, ops) = Self.workload(seed: 7, replicas: 5, moves: 10_000)
        var engine = EngineState()
        setup.forEach { engine.apply($0) }
        var random = SplitMix64(seed: 99)
        var cursors = [Int](repeating: 0, count: streams.count)
        while let r = (0..<streams.count).filter({ cursors[$0] < streams[$0].count }).randomElement(using: &random) {
            engine.apply(streams[r][cursors[r]])
            cursors[r] += 1
        }
        Self.check(engine, against: ops)
        #expect(engine.store.moveLog.count == ops.count + 1)
    }

    @Test func aFullyShuffledRunMatchesTheSequentialOracle() {
        let (setup, streams, ops) = Self.workload(seed: 11, replicas: 3, moves: 1_000)
        var random = SplitMix64(seed: 5)
        var engine = EngineState()
        setup.forEach { engine.apply($0) }
        for change in streams.flatMap({ $0 }).shuffled(using: &random) {
            engine.apply(change)
        }
        Self.check(engine, against: ops)
    }

    // MARK: Performance

    /// A late move on a 50,000-node tree (crdt-model.adoc, "Performance budget"; CRDT-002): the
    /// tree is built in order, 1,000 moves follow, then moves whose OpIds precede those 1,000
    /// arrive.  Each is undone-and-redone around the 1,000 later moves.
    @Test func aLateMoveOnAFiftyThousandNodeTreeIsFast() {
        var engine = Self.withLayer()
        var random = SplitMix64(seed: 3)
        let groups = (0..<50).map { Trees.id(2 + UInt64($0), 7) }
        engine.apply(Changes.change(7, 2, (0..<50).map { Trees.create(Self.layer, [UInt8(1 + $0)]) }))
        var counter: UInt64 = 52
        while counter < 50_002 {
            let ops = (0..<1_000).map { _ in Trees.create(groups[Int(random.next() % 50)], [UInt8(1 + random.next() % 250)]) }
            engine.apply(Changes.change(7, counter, ops))
            counter += 1_000
        }
        let objects = (52..<counter).map { Trees.id($0, 7) }
        let tail = counter + 100
        for index in 0..<1_000 {
            let node = objects[Int(random.next() % UInt64(objects.count))]
            engine.apply(Changes.change(1, tail + UInt64(index), Trees.move(node, groups[Int(random.next() % 50)], [0x80])))
        }
        var samples: [Duration] = []
        for index in 0..<21 {
            let late = Changes.change(2, counter + UInt64(index), Trees.move(objects[index], groups[index], [0x81]))
            let clock = ContinuousClock()
            let start = clock.now
            engine.apply(late)
            samples.append(clock.now - start)
        }
        let median = samples.sorted()[samples.count / 2]
        print("late move on a 50,000-node tree behind 1,000 later tree ops: median \(median)")
        #expect(engine.store.children(Self.layer).count == 50)
        PerfBudget.expect(median, within: .milliseconds(1), "median of 21")
    }
}
