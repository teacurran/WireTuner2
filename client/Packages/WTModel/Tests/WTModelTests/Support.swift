import Foundation
import Synchronization
import WTCRDT
import WTModel
import WTProto

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

    static func createLayer(_ name: String) -> Wiretuner_Doc_V1_Op {
        Ops.create(parent: layers, position: [0x80], props: layer(name: name))
    }

    static func rename(_ node: OpID, _ name: String) -> Wiretuner_Doc_V1_Op {
        Ops.set(node, [Self.name], values: layer(name: name))
    }

    static func moveTo(_ node: OpID, _ tx: Double) -> Wiretuner_Doc_V1_Op {
        Ops.set(node, [transform], values: layer(tx: tx))
    }

    /// The register bytes a layer named `name` holds at `Fixture.name`.
    static func nameValue(_ name: String) -> [UInt8]? {
        EngineState().registerValue(in: layer(name: name), kind: 150, path: Self.name)
    }

    static func txValue(_ tx: Double) -> [UInt8]? {
        EngineState().registerValue(in: layer(tx: tx), kind: 150, path: transform)
    }

    /// A change of `replica` at `seq`, first counter `start`.
    static func change(_ replica: UInt64, seq: UInt64, start: UInt64, _ ops: [Wiretuner_Doc_V1_Op],
                       label: String = "") -> Wiretuner_Doc_V1_Change {
        var change = Wiretuner_Doc_V1_Change()
        change.replica = replica
        change.seq = seq
        change.startCounter = start
        change.label = label
        change.ops = ops
        return change
    }
}

/// A command that types `chars` after `left` in a text block.
struct Typing: Command {
    let node: OpID
    let left: OpID
    let chars: String
    var label: String { "Typing" }
    var coalescing: UndoCoalescing {
        .typing(node: node, field: Fixture.text, endsWord: chars.last.map { $0 == " " || $0.isPunctuation } ?? false)
    }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        builder.append(Ops.textInsert(node, Fixture.text, chars, left: left))
    }
}

/// A command that fails.
struct Failing: Command {
    struct Failure: Error {}
    var label: String { "Fail" }
    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        builder.append(Ops.noop())
        throw Failure()
    }
}

/// A settable clock.
final class TestClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_000_000))

    var now: Date { value.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var function: @Sendable () -> Date { { self.now } }
}
