import Foundation
import GRDB
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// SYNC-001's open budget: the design-point document (docs/spec/crdt-model.adoc, "Performance
/// budget": 50,000 nodes, 1,000,000 registers, 200,000 characters) opens in under 2 s -- snapshot
/// decompressed and decoded, a tail of changes replayed, the undo stack read.  Debug builds use a
/// tenth of it and only print; release builds (`swift test -c release -Xswiftc -enable-testing`)
/// measure the whole and enforce the budget, as WTCRDT's PerformanceTests do.
@Suite struct DesignPointTests {
    #if DEBUG
    static let scale = 10
    static let enforced = false
    #else
    static let scale = 1
    static let enforced = true
    #endif

    static let r: UInt64 = 7

    /// A layer with 20 registers.
    static func props(_ index: Int) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        var layer = Wiretuner_Doc_V1_LayerProps()
        layer.common.name = "Layer \(index)"
        layer.common.note = "note"
        layer.common.locked = true
        layer.common.transform.a = 1
        layer.common.transform.d = 1
        layer.common.transform.tx = Double(index)
        layer.common.url = "https://example.com/\(index)"
        layer.common.alt = "alt"
        layer.common.decorative = true
        layer.common.originLayer = "origin"
        layer.common.textWrap.enabled = true
        layer.common.textWrap.standoff = 2
        layer.common.navigation.alt = "nav"
        layer.common.navigation.target = Wiretuner_Doc_V1_LinkTarget(rawValue: 1)!
        layer.role = Wiretuner_Doc_V1_LayerRole(rawValue: 1)!
        layer.visible = true
        layer.locked = true
        layer.printing = true
        layer.keyline = true
        layer.highlight.rgb.r = 1
        layer.frame.hold = 3
        layer.frame.excluded = true
        props.layer = layer
        return props
    }

    static func designPoint() -> (EngineState, registers: Int) {
        var state = EngineState()
        var counter: UInt64 = 1
        var seq: UInt64 = 1
        let nodes = 50_000 / scale
        for batch in stride(from: 0, to: nodes, by: 100) {
            let ops = (batch..<min(batch + 100, nodes)).map { Ops.create(parent: Fixture.layers, position: [0x80], props: props($0)) }
            state.apply(Fixture.change(r, seq: seq, start: counter, ops), serverSeq: seq)
            counter += UInt64(ops.count)
            seq += 1
        }
        let block = OpID(counter: counter, replica: r)
        state.apply(Fixture.change(r, seq: seq, start: counter, [Ops.create(parent: Fixture.layers, position: [0x81], props: Fixture.textBlock())]),
                    serverSeq: seq)
        counter += 1
        seq += 1
        let chunk = String(repeating: "lorem ipsum dolor sit amet ", count: 37)   // 999 scalars
        var left = OpID.zero
        for _ in 0..<(200 / scale) {
            state.apply(Fixture.change(r, seq: seq, start: counter, [Ops.textInsert(block, Fixture.text, chunk, left: left)]), serverSeq: seq)
            left = OpID(counter: counter + 998, replica: r)
            counter += 999
            seq += 1
        }
        let registers = state.store.nodes.reduce(0) { $0 + state.store.registers($1).count }
        return (state, registers)
    }

    /// Writes the snapshot and 1,000 remote changes; returns the state with the changes applied.
    static func seed(_ queue: DatabaseQueue, state: EngineState, snapshot: [UInt8], compressed: [UInt8]) throws -> EngineState {
        var tail = state
        try queue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO snapshot (id, server_seq, raw_size, data, written_at) VALUES (1, 1, ?, ?, 0)",
                           arguments: [snapshot.count, Data(compressed)])
            for index in 0..<1_000 {
                let node = OpID(counter: UInt64(1 + index * 7 % (50_000 / scale)), replica: r)
                let change = Fixture.change(99, seq: UInt64(index + 1), start: 10_000_000 + UInt64(index * 10),
                                            [Fixture.rename(node, "R\(index)"), Ops.set(node, [Fixture.note], values: Fixture.layer(note: "n\(index)"))])
                tail.apply(change, serverSeq: UInt64(index + 2))
                try db.execute(sql: "INSERT INTO changes (replica, seq, server_seq, local, label, data) VALUES (99, ?, ?, 0, '', ?)",
                               arguments: [index + 1, index + 2, try change.serializedData()])
            }
        }
        return tail
    }

    @Test func theDesignPointOpensInUnderTwoSeconds() async throws {
        let scratch = Scratch()
        let (state, registers) = Self.designPoint()
        #expect(registers >= 1_000_000 / Self.scale)
        // A store holding the design point's snapshot and a day's tail of 1,000 remote changes.
        let store = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        try await store.close()
        let snapshot = Snapshot.encode(state, serverSeq: 1)
        let compressed = Zstd.compress(snapshot)
        let queue = try DatabaseQueue(path: scratch.url().path)
        let tail = try Self.seed(queue, state: state, snapshot: snapshot, compressed: compressed)
        try queue.close()
        let reopened = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        let seconds = reopened.report.seconds
        print("LocalStore: design point / \(Self.scale): \(registers) registers, \(compressed.count) compressed snapshot bytes, "
            + "\(reopened.report.replayed) changes replayed; open \(String(format: "%.2f", seconds)) s")
        let rewriteStart = DispatchTime.now().uptimeNanoseconds
        try await reopened.rewriteSnapshot()
        print("LocalStore: design point / \(Self.scale): snapshot rewrite "
            + String(format: "%.2f", Double(DispatchTime.now().uptimeNanoseconds - rewriteStart) / 1e9) + " s")
        #expect(reopened.report.replayed == 1_000)
        #expect(await reopened.read { $0.stateHash } == tail.stateHash)
        if Self.enforced {
            #expect(seconds < 2)
        }
    }

    /// SYNC-006's budget: measuring the divergence of the design-point document -- a day offline
    /// (20,000 ops in 2,000 unsent changes) against 5,000 remote ops, 1% of the objects overlapping
    /// -- takes under 200 ms, reading and decoding both sets from the store included.
    @Test func theDesignPointDivergenceIsMeasuredInUnderTwoHundredMilliseconds() async throws {
        let scratch = Scratch()
        var (state, _) = Self.designPoint()
        let base = state.store.replicaState(Self.r)!.ackedServerSeq
        let nodes = UInt64(50_000 / Self.scale)
        let store = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        try await store.close()
        var rows: [(replica: UInt64, seq: UInt64, serverSeq: UInt64?, change: Wiretuner_Doc_V1_Change)] = []
        for index in 0..<(2_000 / Self.scale) {
            let ops = (0..<10).map { op in
                Fixture.rename(OpID(counter: 1 + UInt64(index * 10 + op) % nodes, replica: Self.r), "mine \(index)")
            }
            let change = Fixture.change(42, seq: UInt64(index + 1), start: 20_000_000 + UInt64(index * 10), ops)
            _ = state.applyLocal(change)
            rows.append((42, change.seq, nil, change))
        }
        for index in 0..<(500 / Self.scale) {
            let ops = (0..<10).map { op in
                let node = index % 5 == 0 ? UInt64(index * 10 + op) : nodes / 2 + UInt64(index * 10 + op)
                return Fixture.note(OpID(counter: 1 + node % nodes, replica: Self.r), "theirs \(index)")
            }
            let change = Fixture.change(99, seq: UInt64(index + 1), start: 30_000_000 + UInt64(index * 10), ops)
            let serverSeq = base + UInt64(index + 1)
            state.apply(change, serverSeq: serverSeq)
            rows.append((99, change.seq, serverSeq, change))
        }
        let snapshot = Snapshot.encode(state, serverSeq: base + UInt64(500 / Self.scale))
        let queue = try DatabaseQueue(path: scratch.url().path)
        let seeded = rows
        try await queue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO snapshot (id, server_seq, raw_size, data, written_at) VALUES (1, ?, ?, ?, 0)",
                           arguments: [base + UInt64(500 / Self.scale), snapshot.count, Data(Zstd.compress(snapshot))])
            for row in seeded {
                try db.execute(sql: """
                    INSERT INTO changes (replica, seq, server_seq, local, in_snapshot, label, data) VALUES (?, ?, ?, ?, 1, '', ?)
                    """, arguments: [row.replica, row.seq, row.serverSeq.map(Int64.init), row.serverSeq == nil, try row.change.serializedData()])
            }
            try db.execute(sql: "UPDATE meta SET last_server_seq = ?, next_seq = ? WHERE id = 1",
                           arguments: [base + UInt64(500 / Self.scale), 2_000 / Self.scale + 1])
        }
        try queue.close()
        let reopened = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        let readStart = ContinuousClock.now
        let (local, remote) = (try await reopened.outbox(), try await reopened.remoteChanges(after: base))
        let read = ContinuousClock.now - readStart
        let pure = ContinuousClock.now
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        _ = Divergence.measure(local: local, remote: remote, state: state, gap: .zero)
        let cpuMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1e6
        print("Divergence: design point / \(Self.scale): reading \(read), measuring \(ContinuousClock.now - pure) (\(cpuMs) ms on the CPU)")
        let start = ContinuousClock.now
        let divergence = try await reopened.divergence(since: base, gap: .seconds(20 * 3600))
        let review = ReviewModel(divergence, decision: divergence.decision(.standard))
        let elapsed = ContinuousClock.now - start
        print("Divergence: design point / \(Self.scale): \(divergence.localOps) local and \(divergence.remoteOps) remote ops, "
            + "\(divergence.overlapCount) overlapping objects (\(review.mode)); measured in \(elapsed)")
        #expect(divergence.localOps == 20_000 / Self.scale && divergence.remoteOps == 5_000 / Self.scale)
        #expect(divergence.overlapCount > 0 && review.mode == .wholeDocument)
        if Self.enforced {
            #expect(elapsed < .milliseconds(200))
        }
        try await reopened.close()
    }
}
