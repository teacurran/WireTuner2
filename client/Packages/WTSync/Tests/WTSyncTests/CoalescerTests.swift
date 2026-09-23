import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// SYNC-002: coalescing never changes the merged result -- an engine fed the raw log and one fed
/// the coalesced log end with the same state hash -- and it shrinks what is sent.
@Suite struct CoalescerTests {
    static let r: UInt64 = 7
    static let remote: UInt64 = 99

    /// Applies `log` in order, with `outbox` standing in for its outbox changes.
    static func hash(_ log: [Coalescer.Entry], outbox: [Wiretuner_Doc_V1_Change]? = nil) -> [UInt8] {
        var state = EngineState()
        var local = (outbox ?? []).makeIterator()
        var serverSeq: UInt64 = 0
        for entry in log {
            switch entry {
            case .outbox(let change):
                state.apply(outbox == nil ? change : local.next()!)
            case .other(let change):
                serverSeq += 1
                state.apply(change, serverSeq: serverSeq)
            }
        }
        return state.stateHash
    }

    static func substantive(_ changes: [Wiretuner_Doc_V1_Change]) -> Int {
        changes.reduce(0) { $0 + $1.ops.filter { $0.op != .noop(Wiretuner_Doc_V1_Noop()) }.count }
    }

    /// Checks the invariants every coalesced outbox keeps: same seqs, labels, counter ranges.
    static func expectShape(_ raw: [Wiretuner_Doc_V1_Change], _ coalesced: [Wiretuner_Doc_V1_Change]) {
        #expect(raw.map(\.seq) == coalesced.map(\.seq) && raw.map(\.label) == coalesced.map(\.label))
        // Counters: the same range overall, each change starting where the one before ended.
        let end = { (c: Wiretuner_Doc_V1_Change) in c.ops.reduce(c.startCounter) { $0 + EngineState.counters($1) } }
        #expect(raw.first?.startCounter == coalesced.first?.startCounter && raw.last.map(end) == coalesced.last.map(end))
        for (a, b) in zip(zip(raw, raw.dropFirst()), zip(coalesced, coalesced.dropFirst())) where end(a.0) == a.1.startCounter {
            #expect(!b.0.ops.isEmpty && end(b.0) == b.1.startCounter)
        }
    }

    /// A minute of dragging at 60 Hz: 3,600 changes, one register each.
    @Test func aMinuteOfDraggingCoalescesToOneOp() {
        let node = OpID(counter: 1, replica: Self.r)
        var log: [Coalescer.Entry] = [.outbox(Fixture.change(Self.r, seq: 1, start: 1, [Fixture.createLayer("A")]))]
        for step in 0..<3_600 {
            log.append(.outbox(Fixture.change(Self.r, seq: UInt64(step + 2), start: UInt64(step + 2), [Fixture.moveTo(node, Double(step))],
                                              label: "Move")))
        }
        let raw = log.map { if case .outbox(let c) = $0 { c } else { fatalError() } }
        let coalesced = Coalescer.coalesce(log)
        Self.expectShape(raw, coalesced)
        #expect(Self.substantive(coalesced) == 2)   // the create and the last move
        #expect(Self.hash(log) == Self.hash(log, outbox: coalesced))
    }

    @Test func anotherReplicasWriteBetweenKeepsTheEarlierWrite() {
        let node = OpID(counter: 1, replica: Self.r)
        let log: [Coalescer.Entry] = [
            .outbox(Fixture.change(Self.r, seq: 1, start: 1, [Fixture.createLayer("A")])),
            .outbox(Fixture.change(Self.r, seq: 2, start: 2, [Ops.set(node, [Fixture.name, Fixture.note], values: Fixture.layer(name: "B", note: "n"))])),
            .other(Fixture.change(Self.remote, seq: 1, start: 3, [Fixture.rename(node, "R")])),
            .other(Fixture.change(Self.remote, seq: 2, start: 4, [Fixture.createLayer("X")])),
            .outbox(Fixture.change(Self.r, seq: 3, start: 10, [Ops.set(node, [Fixture.name, Fixture.note], values: Fixture.layer(name: "C", note: "m"))])),
        ]
        let coalesced = Coalescer.coalesce(log)
        // The note had no other write between: dropped from the earlier op.  The name stays.
        #expect(coalesced[1].ops[0].set.paths == [Fixture.name.proto])
        #expect(Self.hash(log) == Self.hash(log, outbox: coalesced))
    }

    @Test func typedTextJoinsWithinAndAcrossChanges() {
        let node = OpID(counter: 1, replica: Self.r)
        let c = { (n: UInt64) in OpID(counter: n, replica: Self.r) }
        let log: [Coalescer.Entry] = [
            .outbox(Fixture.change(Self.r, seq: 1, start: 1, [Ops.create(parent: Fixture.layers, position: [0x80], props: Fixture.textBlock())])),
            // "ab" then "c" in one change (counters 2-3, 4)
            .outbox(Fixture.change(Self.r, seq: 2, start: 2, [Ops.textInsert(node, Fixture.text, "ab"),
                                                              Ops.textInsert(node, Fixture.text, "c", left: c(3))], label: "Typing")),
            .other(Fixture.change(Self.remote, seq: 1, start: 50, [Fixture.createLayer("X")])),
            // "d" continues it from the next change, which has a second op: joins across.
            .outbox(Fixture.change(Self.r, seq: 3, start: 5, [Ops.textInsert(node, Fixture.text, "d", left: c(4)),
                                                              Fixture.createLayer("Y")], label: "Typing")),
            // "e" is the only op of its change: stays (a change keeps an op).
            .outbox(Fixture.change(Self.r, seq: 4, start: 7, [Ops.textInsert(node, Fixture.text, "e", left: c(5))], label: "Typing")),
            // Not adjacent: a different left origin.
            .outbox(Fixture.change(Self.r, seq: 5, start: 8, [Ops.textInsert(node, Fixture.text, "f", left: c(2)),
                                                              Ops.textInsert(node, Fixture.text, "g", left: c(4))], label: "Typing")),
        ]
        let raw = log.compactMap { if case .outbox(let c) = $0 { c } else { nil } }
        let coalesced = Coalescer.coalesce(log)
        Self.expectShape(raw, coalesced)
        #expect(coalesced[1].ops.count == 1 && coalesced[1].ops[0].textInsert.chars == "abcd")
        #expect(coalesced[2].ops.count == 1 && coalesced[2].startCounter == 6)
        #expect(coalesced[3] == raw[3] && coalesced[4] == raw[4])
        #expect(Self.hash(log) == Self.hash(log, outbox: coalesced))
    }

    @Test func textNeverJoinsPastTheInsertLimit() {
        let node = OpID(counter: 1, replica: Self.r)
        let big = String(repeating: "a", count: Coalescer.maxTextBytes)
        let change = Fixture.change(Self.r, seq: 1, start: 2, [Ops.textInsert(node, Fixture.text, big),
                                                               Ops.textInsert(node, Fixture.text, "b", left: OpID(counter: UInt64(big.count) + 1, replica: Self.r))])
        #expect(Coalescer.coalesce([.outbox(change)])[0].ops.count == 2)
    }

    @Test func createThenDeleteBecomesNoopsWhenNothingRefersToTheNode() {
        let log: [Coalescer.Entry] = [
            .outbox(Fixture.change(Self.r, seq: 1, start: 1, [Fixture.createLayer("A")])),                          // 1:7
            .outbox(Fixture.change(Self.r, seq: 2, start: 2, [Fixture.rename(OpID(counter: 1, replica: Self.r), "B"),
                                                              Fixture.createLayer("C")])),                         // 3:7
            .outbox(Fixture.change(Self.r, seq: 3, start: 4, [Ops.setDeleted(OpID(counter: 1, replica: Self.r))])),
            // 3:7 is deleted too, but a child names it as parent.
            .outbox(Fixture.change(Self.r, seq: 4, start: 5, [Ops.create(parent: OpID(counter: 3, replica: Self.r), position: [0x80],
                                                                         props: Fixture.layer(name: "D")),
                                                              Ops.setDeleted(OpID(counter: 3, replica: Self.r))])),
            // 7:7 is created, typed into (multi-counter) and deleted: kept.
            .outbox(Fixture.change(Self.r, seq: 5, start: 7, [Ops.create(parent: Fixture.layers, position: [0x81], props: Fixture.textBlock()),
                                                              Ops.textInsert(OpID(counter: 7, replica: Self.r), Fixture.text, "xy"),
                                                              Ops.setDeleted(OpID(counter: 7, replica: Self.r))])),
            // 11:7 is deleted then restored: kept.
            .outbox(Fixture.change(Self.r, seq: 6, start: 11, [Fixture.createLayer("E"), Ops.setDeleted(OpID(counter: 11, replica: Self.r)),
                                                               Ops.setDeleted(OpID(counter: 11, replica: Self.r), false)])),
            // 14:7 is deleted but another replica mentions it.
            .outbox(Fixture.change(Self.r, seq: 7, start: 14, [Fixture.createLayer("F"), Ops.setDeleted(OpID(counter: 14, replica: Self.r))])),
            .other(Fixture.change(Self.remote, seq: 1, start: 90, [Fixture.rename(OpID(counter: 14, replica: Self.r), "Z")])),
        ]
        let raw = log.compactMap { if case .outbox(let c) = $0 { c } else { nil } }
        let coalesced = Coalescer.coalesce(log, rules: .createThenDelete)
        Self.expectShape(raw, coalesced)
        let noop = Ops.noop()
        #expect(coalesced[0].ops == [noop] && coalesced[1].ops[0] == noop && coalesced[2].ops == [noop])
        #expect(coalesced[1].ops[1] == raw[1].ops[1] && coalesced[3] == raw[3] && coalesced[4] == raw[4] && coalesced[5] == raw[5])
        #expect(coalesced[6] == raw[6])
        // What a user sees is the same; the creating replica keeps a tombstone the others never get.
        #expect(Self.hash(log) != Self.hash(log, outbox: coalesced))
        #expect(Coalescer.coalesce(log) .map { Self.substantive([$0]) } == raw.map { Self.substantive([$0]) })
    }

    @Test func everyOpTargetingACreatedNodeGoesWithIt() {
        let node = OpID(counter: 1, replica: Self.r)
        let guides = RegisterPath([3, 7])
        let element = guides.element(OpID(counter: 6, replica: Self.r))
        var mark = Wiretuner_Doc_V1_TextMark()
        mark.node = node.proto
        mark.text = Fixture.text.proto
        var markOp = Wiretuner_Doc_V1_Op()
        markOp.textMark = mark
        var codepoints = Wiretuner_Doc_V1_NodeProps()
        codepoints.glyph.codepoints = [65]
        let ops: [Wiretuner_Doc_V1_Op] = [
            Fixture.createLayer("A"),
            Ops.move(node, parent: Fixture.layers, position: [0x90]),
            Ops.setAdd(node, RegisterPath([220, 3]), values: codepoints),
            Ops.setRemove(node, RegisterPath([220, 3]), values: codepoints),
            Ops.noop(),
            Ops.elementInsert(node, guides, positions: [[0x80]]),
            Ops.elementMove(node, element, position: [0x81]),
            Ops.elementDelete(node, [element]),
            Ops.textDelete(node, Fixture.text, first: OpID(counter: 99, replica: Self.r), count: 1),
            markOp,
            Ops.setDeleted(node),
        ]
        let coalesced = Coalescer.coalesce([.outbox(Fixture.change(Self.r, seq: 1, start: 1, ops))], rules: .createThenDelete)
        #expect(coalesced[0].ops == Array(repeating: Ops.noop(), count: ops.count))
    }

    /// The perf budget (docs/spec/testing.adoc): coalesce and encode a 20,000-op outbox in 500 ms.
    @Test func coalescesAndEncodesTwentyThousandOps() throws {
        var log: [Coalescer.Entry] = []
        var counter: UInt64 = 1
        let nodes = (0..<100).map { OpID(counter: UInt64($0) + 1, replica: Self.r) }
        log.append(.outbox(Fixture.change(Self.r, seq: 1, start: counter, nodes.map { _ in Fixture.createLayer("N") })))
        counter += 100
        var seq: UInt64 = 2
        var text: [Wiretuner_Doc_V1_Op] = [Ops.create(parent: Fixture.layers, position: [0x90], props: Fixture.textBlock())]
        let block = OpID(counter: counter, replica: Self.r)
        counter += 1
        for index in 0..<200 {
            text.append(Ops.textInsert(block, Fixture.text, "w", left: index == 0 ? .zero : OpID(counter: counter - 1, replica: Self.r)))
            counter += 1
        }
        log.append(.outbox(Fixture.change(Self.r, seq: seq, start: counter - 201, text)))
        seq += 1
        var total = 301
        while total < 20_000 {
            let ops = nodes.prefix(10).map { Fixture.moveTo($0, Double(seq)) }
            total += ops.count
            log.append(.outbox(Fixture.change(Self.r, seq: seq, start: counter, ops, label: "Move")))
            counter += UInt64(ops.count)
            seq += 1
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let coalesced = Coalescer.coalesce(log)
        let bytes = try coalesced.reduce(0) { $0 + (try $1.serializedData()).count }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        print("Coalescer: 20,000-op outbox coalesced and encoded in \(String(format: "%.3f", seconds)) s, \(bytes) bytes")
        #expect(Self.hash(log) == Self.hash(log, outbox: coalesced))
        PerfBudget.expect(.seconds(seconds), within: .milliseconds(500))
    }

    @Test func thePendingUploadOfAStoreIsItsCoalescedOutbox() async throws {
        let scratch = Scratch()
        let store = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        let created = try await store.perform(createLayer("A"), recording: Fixture.recording()).change!
        let node = OpID(counter: created.startCounter, replica: created.replica)
        try await store.acknowledge(seq: 1, serverSeq: 1)
        for step in 0..<120 {
            _ = try await store.perform(OpsCommand("Move", ops: [Fixture.moveTo(node, Double(step))]), recording: Fixture.recording())
        }
        _ = try await store.receive(Fixture.change(99, seq: 1, start: 500, [Fixture.createLayer("X")]), serverSeq: 2)
        let pending = try await store.pendingUpload()
        #expect(pending.count == 120 && Self.substantive(pending) == 1)
        let raw = try await store.outbox()
        #expect(raw.count == 120 && Self.substantive(raw) == 120)
        #expect(try await store.pendingUpload(rules: []) == raw)
    }
}
