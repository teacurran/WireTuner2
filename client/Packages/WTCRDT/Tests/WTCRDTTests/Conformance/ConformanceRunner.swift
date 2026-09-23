import Foundation
import SwiftProtobuf
import WTCRDT
import WTProto

/// Replays the conformance vectors (`crdt-conformance/vectors/<area>/<name>.textproto`, schema
/// `crdt-conformance/schema/vector.proto`) through WTCRDT, exactly as server/conformance's
/// `ConformanceRunner` does through wt-crdt (docs/spec/testing.adoc, CRDT-011).  A vector passes
/// when every delivery order reaches the same state and that state has the expected hash and
/// read-outs; a failure names the vector and the first differing node.
enum ConformanceRunner {
    typealias Vector = Wiretuner_Conformance_V1_Vector
    typealias Change = Wiretuner_Doc_V1_Change

    static let suffix = ".textproto"

    /// What replaying one vector produced.  `failures` is empty when it passed.
    struct Outcome {
        let name: String
        let failures: [String]
        let stateHash: String

        var passed: Bool { failures.isEmpty }
        var report: String { "\(name):\n  " + failures.joined(separator: "\n  ") }
    }

    /// The repository's vector directory, found from this file's path.
    static var vectorsRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }  // Conformance, WTCRDTTests, Tests, WTCRDT, Packages, client
        return url.appendingPathComponent("crdt-conformance/vectors")
    }

    /// Every vector file under `root`, sorted by path (none when the directory is missing).
    static func vectors(_ root: URL) -> [URL] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        let files = (walker?.allObjects as? [URL] ?? []).filter { url in
            url.lastPathComponent.hasSuffix(suffix)
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        return files.sorted { $0.path < $1.path }
    }

    /// The name a vector at `file` must declare: its path below `root` without the suffix.
    static func expectedName(_ root: URL, _ file: URL) -> String {
        let relative = file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)
        return String(relative.dropLast(suffix.count))
    }

    /// Loads and replays the vector at `file` below `root`.
    static func run(_ root: URL, _ file: URL) throws -> Outcome {
        let vector = try Vector(textFormatString: String(contentsOf: file, encoding: .utf8))
        return run(vector, expectedName: expectedName(root, file))
    }

    /// Replays `vector`, which must be named `expectedName`.
    static func run(_ vector: Vector, expectedName: String) -> Outcome {
        var failures: [String] = []
        if vector.name != expectedName {
            failures.append("name is \"\(vector.name)\" but the file says \"\(expectedName)\"")
        }
        let schema = schema(vector, &failures)
        let orders = deliveryOrders(vector, &failures)
        guard failures.isEmpty else { return Outcome(name: expectedName, failures: failures, stateHash: "") }
        var reference: EngineState?
        var referenceOrder = ""
        for (index, order) in orders.enumerated() {
            let engine = replay(schema, vector, order)
            let described = describe(vector, index)
            if let reference {
                if engine.stateHash != reference.stateHash {
                    failures.append("delivery \(described) diverges from \(referenceOrder) at node "
                        + "\(firstDifference(reference, engine).map(String.init(describing:)) ?? "?")")
                }
            } else {
                reference = engine
                referenceOrder = described
            }
        }
        checkExpectations(vector, reference!, &failures)
        return Outcome(name: expectedName, failures: failures, stateHash: StateHash.hex(reference!.stateHash))
    }

    /// The generated merge table with the vector's overrides applied.
    static func schema(_ vector: Vector, _ failures: inout [String]) -> Schema {
        var schema = Schema.generated
        for override in vector.schemaOverride {
            switch override.change {
            case .policy(let change):
                guard let policy = Schema.Policy(rawValue: change.policy) else {
                    failures.append("schema_override: no policy \(change.policy)")
                    continue
                }
                do {
                    schema = try schema.with(change.message, field: Int(change.field), policy: policy)
                } catch {
                    failures.append("schema_override: \(error)")
                }
            case .variant(let change):
                schema = schema.withVariant(change.message, kindField: Int(change.kindField),
                                            caseFields: change.caseFields.map(Int.init))
            case nil:
                failures.append("schema_override: empty schema_override")
            }
        }
        return schema
    }

    /// The changes of each delivery order, validated against the replicas.
    static func deliveryOrders(_ vector: Vector, _ failures: inout [String]) -> [[Change]] {
        let replicas = vector.replica.sorted { $0.id < $1.id }
        for replica in replicas {
            for change in replica.change where change.replica != replica.id {
                failures.append("replica \(replica.id) holds a change of replica \(change.replica)")
            }
        }
        var deliveries = vector.deliveries.map(\.order)
        if deliveries.isEmpty {
            deliveries = [replicas.flatMap { replica in replica.change.map { _ in replica.id } }]
        }
        return deliveries.map { order in
            var pending = Dictionary(replicas.map { ($0.id, ArraySlice($0.change)) }, uniquingKeysWith: { a, _ in a })
            var changes: [Change] = []
            for id in order {
                if let next = pending[id]?.popFirst() {
                    changes.append(next)
                } else {
                    failures.append("delivery \(order) names replica \(id) more often than it has changes")
                }
            }
            if pending.values.contains(where: { !$0.isEmpty }) {
                failures.append("delivery \(order) leaves changes undelivered")
            }
            return changes
        }
    }

    private static func replay(_ schema: Schema, _ vector: Vector, _ order: [Change]) -> EngineState {
        var engine = EngineState(schema: schema)
        for change in vector.setup.change + order {
            engine.apply(change)
        }
        return engine
    }

    private static func describe(_ vector: Vector, _ index: Int) -> String {
        index < vector.deliveries.count ? "\(vector.deliveries[index].order)" : "(replica order)"
    }

    /// The first node, in OpId order, whose encoding differs between two states.
    static func firstDifference(_ a: EngineState, _ b: EngineState) -> OpID? {
        Set(a.store.nodes + b.store.nodes).sorted().first { node in
            StateHash.of(a.store, node: node) != StateHash.of(b.store, node: node)
        }
    }

    private static func checkExpectations(_ vector: Vector, _ engine: EngineState, _ failures: inout [String]) {
        let actual = StateHash.hex(engine.stateHash)
        if actual != vector.expect.stateHash {
            failures.append("state_hash: expected \"\(vector.expect.stateHash)\", got \"\(actual)\""
                + firstNamedDifference(vector, engine))
        }
        for node in vector.expect.node {
            let id = OpID(node.id)
            let nodeHash = StateHash.hex(StateHash.of(engine.store, node: id))
            if !node.nodeHash.isEmpty && node.nodeHash != nodeHash {
                failures.append("node \(id): node_hash expected \"\(node.nodeHash)\", got \"\(nodeHash)\"")
            }
            for register in node.register {
                checkRegister(engine, id, register, &failures)
            }
        }
    }

    private static func firstNamedDifference(_ vector: Vector, _ engine: EngineState) -> String {
        for node in vector.expect.node {
            let id = OpID(node.id)
            let nodeHash = StateHash.hex(StateHash.of(engine.store, node: id))
            if !node.nodeHash.isEmpty && node.nodeHash != nodeHash {
                return "; first differing node \(id)"
            }
        }
        let hashes = engine.store.nodes.map { "\($0)=\(StateHash.hex(StateHash.of(engine.store, node: $0)))" }
        return "; no expected node_hash differs; actual node hashes: " + hashes.joined(separator: " ")
    }

    private static func checkRegister(
        _ engine: EngineState, _ node: OpID, _ expected: Wiretuner_Conformance_V1_ExpectRegister,
        _ failures: inout [String]
    ) {
        guard let path = RegisterPath(expected.path) else {
            failures.append("node \(node): expected register path must be field numbers only")
            return
        }
        let actual = engine.register(node, path)
        let value = expected.hasValue ? path.value(in: try! expected.value.serializedBytes()) : nil
        let want = Register(value: value, op: OpID(expected.op))
        if want != actual {
            failures.append("node \(node) register \(path): expected \(want), got \(actual.map(String.init(describing:)) ?? "null")")
        }
        let losing = engine.losingWrites(node, path).map(\.op)
        let wantLosing = expected.losing.map(OpID.init)
        if losing != wantLosing {
            failures.append("node \(node) register \(path): losing writes expected \(wantLosing), got \(losing)")
        }
    }
}
