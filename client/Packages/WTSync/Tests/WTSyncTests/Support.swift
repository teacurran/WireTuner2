import Foundation
import Synchronization
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// Layers (NodeProps.layer = 150) and text blocks (NodeProps.text = 130) of the generated table.
enum Fixture {
    static let layers = OpID.wellKnown(4)
    static let name = RegisterPath([150, 1, 1])
    static let note = RegisterPath([150, 1, 2])
    static let transform = RegisterPath([150, 1, 4])
    static let text = RegisterPath([130, 2])

    static func layer(name: String? = nil, note: String? = nil, tx: Double? = nil) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.layer = Wiretuner_Doc_V1_LayerProps()
        if let name { props.layer.common.name = name }
        if let note { props.layer.common.note = note }
        if let tx {
            props.layer.common.transform.a = 1
            props.layer.common.transform.d = 1
            props.layer.common.transform.tx = tx
        }
        return props
    }

    static func textBlock() -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.text = Wiretuner_Doc_V1_TextProps()
        return props
    }

    static func createLayer(_ name: String, position: [UInt8] = [0x80]) -> Wiretuner_Doc_V1_Op {
        Ops.create(parent: layers, position: position, props: layer(name: name))
    }

    static func rename(_ node: OpID, _ name: String) -> Wiretuner_Doc_V1_Op {
        Ops.set(node, [Self.name], values: layer(name: name))
    }

    static func moveTo(_ node: OpID, _ tx: Double) -> Wiretuner_Doc_V1_Op {
        Ops.set(node, [transform], values: layer(tx: tx))
    }

    static func nameValue(_ name: String) -> [UInt8]? {
        EngineState().registerValue(in: layer(name: name), kind: 150, path: Self.name)
    }

    static func change(_ replica: UInt64, seq: UInt64, start: UInt64, _ ops: [Wiretuner_Doc_V1_Op],
                       label: String = "", base: UInt64 = 0) -> Wiretuner_Doc_V1_Change {
        var change = Wiretuner_Doc_V1_Change()
        change.replica = replica
        change.seq = seq
        change.startCounter = start
        change.baseServerSeq = base
        change.label = label
        change.ops = ops
        return change
    }

    static func recording(limit: Int = 100) -> DocumentCore.Recording {
        DocumentCore.Recording(limit: limit, now: Date(timeIntervalSince1970: 1_000))
    }
}

/// A fresh directory for one test's stores.  Every test's directory sits under one folder per
/// test process, removed when the process exits; folders left by processes that crashed are swept
/// once they are an hour old.  (Each store is a few hundred kilobytes and the suite makes hundreds,
/// so leaving them behind filled the disk.)
struct Scratch {
    let directory: URL

    init() {
        directory = Scratch.processRoot.appending(path: UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static let processRoot: URL = {
        let temporary = FileManager.default.temporaryDirectory
        let stale = Date().addingTimeInterval(-3600)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        for name in names where name.hasPrefix("WTSyncTests-") {
            let url = temporary.appending(path: name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < stale { try? FileManager.default.removeItem(at: url) }
        }
        let root = temporary.appending(path: "WTSyncTests-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Scratch.removeAtExit = root.path
        atexit { if let path = Scratch.removeAtExit { try? FileManager.default.removeItem(atPath: path) } }
        return root
    }()

    nonisolated(unsafe) private static var removeAtExit: String?

    func url(_ name: String = "doc") -> URL {
        directory.appending(components: name, "store.sqlite")
    }

    /// Copies the store at `name` -- database, WAL and shared memory, as they are on disk this
    /// moment -- to `copy`: what a crash leaves.
    func crashImage(of name: String, to copy: String) throws -> URL {
        let source = url(name)
        let target = url(copy)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.copyItem(at: from, to: URL(fileURLWithPath: target.path + suffix))
            }
        }
        return target
    }
}

/// Replica ids handed out in order.
final class Replicas: Sendable {
    private let next: Mutex<UInt64>

    init(from first: UInt64 = 42) {
        next = Mutex(first)
    }

    var function: @Sendable () -> UInt64 {
        { self.next.withLock { value in defer { value += 1 }; return value } }
    }
}

/// Options with a fixed Mac and predictable replica ids.
func options(hardware: String = "MAC-A", replicas: Replicas = Replicas(), interval: Duration = .seconds(300)) -> LocalStore.Options {
    LocalStore.Options(snapshotInterval: interval, hardwareUUID: { hardware }, makeReplicaID: replicas.function)
}

/// A command that creates layer `name`.
func createLayer(_ name: String, position: [UInt8] = [0x80]) -> OpsCommand {
    OpsCommand("Create Layer", ops: [Fixture.createLayer(name, position: position)])
}
