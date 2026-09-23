import Foundation
import WTCRDT
import WTModel
import WTProto
import WTSync
@testable import WireTuner

/// A reconnect for the review sheet's tests (WTSync's `Divergent`): a shared base, unsent local
/// changes of replica `me`, and remote changes by Priya, all applied to one state; `measure()`
/// gives the real `ReviewModel` the sheet shows.
struct ReviewWorld {
    static let me: UInt64 = 42
    static let priya: UInt64 = 7
    static let base: UInt64 = 9
    static let layers = OpID.wellKnown(4)
    static let text = RegisterPath([130, 2])
    static let rectSize = RegisterPath([NodeKind.rect.rawValue, 2])
    static let rectTransform = RegisterPath([NodeKind.rect.rawValue, 1, 4])
    static let rectName = RegisterPath([NodeKind.rect.rawValue, 1, 1])

    var state = EngineState()
    var local: [Wiretuner_Doc_V1_Change] = []
    var remote: [Wiretuner_Doc_V1_Change] = []
    private var counter: UInt64 = 1
    private var serverSeq: UInt64 = 0
    private var seqs: [UInt64: UInt64] = [:]

    private mutating func change(_ replica: UInt64, _ ops: [Wiretuner_Doc_V1_Op]) -> (Wiretuner_Doc_V1_Change, OpID) {
        let seq = seqs[replica, default: 0] + 1
        seqs[replica] = seq
        var change = Wiretuner_Doc_V1_Change()
        change.replica = replica
        change.seq = seq
        change.startCounter = counter
        change.ops = ops
        let first = OpID(counter: counter, replica: replica)
        counter += ops.reduce(0) { $0 + EngineState.counters($1) }
        return (change, first)
    }

    @discardableResult
    mutating func base(_ ops: [Wiretuner_Doc_V1_Op]) -> OpID {
        let (change, first) = change(Self.base, ops)
        serverSeq += 1
        state.apply(change, serverSeq: serverSeq)
        return first
    }

    @discardableResult
    mutating func mine(_ ops: [Wiretuner_Doc_V1_Op]) -> OpID {
        let (change, first) = change(Self.me, ops)
        _ = state.applyLocal(change)
        local.append(change)
        return first
    }

    @discardableResult
    mutating func theirs(_ ops: [Wiretuner_Doc_V1_Op]) -> OpID {
        let (change, first) = change(Self.priya, ops)
        serverSeq += 1
        state.apply(change, serverSeq: serverSeq)
        remote.append(change)
        return first
    }

    func measure() -> ReviewModel {
        let divergence = Divergence.measure(local: local, remote: remote, state: state)
        return ReviewModel(divergence, decision: divergence.decision(.standard), names: [Self.priya: "Priya"])
    }

    /// A document over the merged state, writing as `me`.
    @MainActor
    func document(title: String = "Logo") -> DocumentHandle {
        let core = DocumentCore(state: state, replica: Self.me, nextSeq: (seqs[Self.me] ?? 0) + 1)
        return DocumentHandle(title: title, model: WTModel.Document(memory: core))
    }

    // MARK: Fixtures

    static func layer(_ name: String) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.layer.common.name = name
        props.layer.visible = true
        props.layer.printing = true
        return props
    }

    static func rect(width: Double, height: Double = 20, tx: Double = 0, name: String = "") -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.rect.size.width = width
        props.rect.size.height = height
        props.rect.common.name = name
        props.rect.common.transform.a = 1
        props.rect.common.transform.d = 1
        props.rect.common.transform.tx = tx
        props.rect.appearance = Appearances.standard
        return props
    }

    static func textBlock() -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.text = Wiretuner_Doc_V1_TextProps()
        return props
    }

    static func resize(_ node: OpID, width: Double) -> Wiretuner_Doc_V1_Op {
        Ops.set(node, [rectSize], values: rect(width: width))
    }

    static func move(_ node: OpID, tx: Double) -> Wiretuner_Doc_V1_Op {
        Ops.set(node, [rectTransform], values: rect(width: 0, tx: tx))
    }

    static func rename(_ node: OpID, _ name: String) -> Wiretuner_Doc_V1_Op {
        Ops.set(node, [rectName], values: rect(width: 0, name: name))
    }
}
