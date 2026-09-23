import Foundation
import Testing
@testable import WTCRDT
import WTProto

/// The CRDT performance budget (docs/spec/crdt-model.adoc, "Performance budget"): inserts into a
/// 200,000-character text (CRDT-005) and bootstrapping the design-point document from a snapshot
/// (CRDT-009).  The figures are printed; the budgets are `PerfBudget`s, held in the perf run only
/// (`make client-perf`: release, `WT_PERF=1`).
@Suite struct PerformanceTests {
    static func seconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    @Test func insertsIntoA200000CharacterText() {
        var text = TextSequence()
        let scalars = Array(repeating: UInt32(0x61), count: 1_000)
        var counter: UInt64 = 1
        for _ in 0..<200 {
            text.insert(scalars, first: OpID(counter: counter, replica: 1), left: counter == 1 ? .zero : OpID(counter: counter - 1, replica: 1), right: .zero)
            counter += 1_000
        }
        #expect(text.count == 200_000)
        // Typing in the middle: each keystroke goes after the character before the caret.
        var caret = text.char(at: 100_000)!
        let inserts = 2_000
        let elapsed = Self.seconds {
            for index in 0..<inserts {
                let id = OpID(counter: counter + UInt64(index), replica: 2)
                text.insert([0x62], first: id, left: caret, right: text.successor(of: caret))
                caret = id
            }
        }
        let perInsert = elapsed / Double(inserts) * 1e6
        print("TextSequence: \(String(format: "%.2f", perInsert)) µs per insert into 200,000 characters")
        #expect(text.count == 202_000)
        PerfBudget.expect(.microseconds(perInsert), within: .microseconds(50))
    }

    /// The design point (crdt-model.adoc, "Performance budget"): 50,000 nodes with 20 registers
    /// each (1,000,000), five stops each, and a 200,000-character text.  Correctness runs use a
    /// tenth of it, so the suite stays quick; the perf run measures the whole.
    static let scale = PerfBudget.isMeasuring ? 1 : 10

    static func designPoint() -> EngineState {
        var engine = EngineState(schema: Scenario.schema)
        var counter: UInt64 = 1
        let common = #"common { name: "Object" note: "n" locked: true url: "https://example.com" alt: "a" decorative: true origin_layer: "L" transform { a: 1 d: 1 } text_wrap { enabled: true } }"#
        for index in 0..<(50_000 / scale) {
            let node = counter
            engine.apply(Scenario.change(
                7, UInt64(index + 1), counter,
                #"create { parent { counter: 4 } position: "\x80" props { test { label: "Node" \#(common) } } }"#,
                #"set { node { counter: \#(node) replica: 7 } paths { segments { field: 1000 } segments { field: 1 } segments { field: 9 } } values { test { common { alt: "b" } } } }"#,
                #"element_insert { node { counter: \#(node) replica: 7 } sequence { segments { field: 1000 } segments { field: 8 } } positions: ["\x80", "\x81", "\x82", "\x83", "\x84"] values { test { stops { offset: 1 color: "red" } stops { offset: 2 color: "red" } stops { offset: 3 color: "red" } stops { offset: 4 color: "red" } stops { offset: 5 color: "red" } } } }"#))
            counter += 7
        }
        let chunk = String(repeating: "lorem ipsum dolor sit amet ", count: 37)  // 999 scalars
        var left: OpID?
        for _ in 0..<(200 / scale) {
            let change = Scenario.change(7, 60_000 + counter, counter, Scenario.insert(chunk, left: left))
            engine.apply(change)
            left = OpID(counter: counter + 998, replica: 7)
            counter += 999
        }
        return engine
    }

    @Test func bootstrapsTheDesignPointFromASnapshot() throws {
        let engine = Self.designPoint()
        let registers = engine.store.nodes.reduce(0) { $0 + engine.store.registers($1).count }
        #expect(registers >= 1_000_000 / Self.scale)
        #expect(engine.text(Scenario.node, Scenario.text)?.count == 199_800 / Self.scale)
        var frames: [Wiretuner_Doc_V1_SnapshotFrame] = []
        let encode = Self.seconds { frames = SnapshotTransfer.frames(engine, serverSeq: 1) }
        var decoded: EngineState?
        let load = try Self.seconds2 { decoded = try SnapshotTransfer.state(frames, schema: Scenario.schema) }
        let bytes = frames.dropFirst().reduce(0) { $0 + $1.chunk.count }
        print("Snapshot: design point \(registers) registers, \(bytes) compressed bytes in \(frames.count - 1) chunks; "
            + "encode \(String(format: "%.2f", encode)) s, bootstrap \(String(format: "%.2f", load)) s")
        #expect(decoded?.stateHash == engine.stateHash)
        PerfBudget.expect(.seconds(load), within: .seconds(1.5))
    }

    static func seconds2(_ body: () throws -> Void) throws -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }
}
