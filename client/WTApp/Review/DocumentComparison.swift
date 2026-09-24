import Foundation
import WTCRDT
import WTModel
import WTProto

/// Two states of a document compared node by node (COLLAB-002; collaboration.adoc, "The Review
/// Changes sheet", compare mode): every object that differs between A and B -- its registers, its
/// place in the tree or whether it is live -- with how it differs, and, given the state both came
/// from (`base`), whether both sides changed it since.  The comments collection is left out (a
/// comment is never part of a comparison, comments.adoc).
struct DocumentComparison: Sendable {
    /// How one node differs.
    enum Kind: Equatable, Sendable {
        /// Live on both sides with different registers or a different place.
        case changed
        /// Live in A only (added in A, or deleted in B).
        case onlyA
        /// Live in B only.
        case onlyB
    }

    struct Entry: Equatable, Identifiable, Sendable {
        let node: OpID
        let kind: Kind
        /// Both sides changed it since `base` (nil base: never).
        let overlaps: Bool
        var id: OpID { node }
    }

    let a: EngineState
    let b: EngineState
    let base: EngineState?
    let entries: [Entry]

    init(a: EngineState, b: EngineState, base: EngineState? = nil) {
        self.a = a
        self.b = b
        self.base = base
        var entries: [Entry] = []
        let nodes = Set(a.store.nodes).union(b.store.nodes).subtracting(Self.excluded)
        for node in nodes.sorted() where !Self.isComment(node, a: a, b: b) {
            guard let kind = Self.kind(node, a: a, b: b) else { continue }
            let overlaps = base.map { Self.kind(node, a: $0, b: a) != nil && Self.kind(node, a: $0, b: b) != nil } ?? false
            entries.append(Entry(node: node, kind: kind, overlaps: overlaps))
        }
        self.entries = entries
    }

    /// The well-known roots that are never listed.
    static let excluded: Set<OpID> = [CommentFields.collection]

    static func isComment(_ node: OpID, a: EngineState, b: EngineState) -> Bool {
        CommentFields.isThread(node, in: a) || CommentFields.isThread(node, in: b)
    }

    /// How `node` differs between `a` and `b`; nil when it does not.
    static func kind(_ node: OpID, a: EngineState, b: EngineState) -> Kind? {
        let inA = a.isLive(node), inB = b.isLive(node)
        switch (inA, inB) {
        case (false, false): return nil
        case (true, false): return .onlyA
        case (false, true): return .onlyB
        case (true, true):
            let placed = a.store.placement(node)?.parent == b.store.placement(node)?.parent
            return placed && a.props(node) == b.props(node) ? nil : .changed
        }
    }

    /// The entry of `node`, when it differs.
    func entry(_ node: OpID) -> Entry? { entries.first { $0.node == node } }

    /// *Use mine* in compare mode: re-asserts A's version of `node` on `target` -- its registers
    /// (or its deletion, or its return) -- as one change; nil when `target` already matches A.
    static func useA(_ node: OpID, a: EngineState, target: EngineState, name: String) -> OpsCommand? {
        guard kind(node, a: a, b: target) != nil else { return nil }
        guard a.isLive(node) else {
            return target.isLive(node) ? OpsCommand("Use \(name) from the other version", ops: [Ops.setDeleted(node)]) : nil
        }
        var ops: [Wiretuner_Doc_V1_Op] = []
        if !target.isLive(node), target.store.isCreated(node) { ops.append(Ops.setDeleted(node, false)) }
        let paths = a.store.registers(node).map(\.path)
        if !paths.isEmpty { ops.append(Ops.set(node, paths, values: a.props(node))) }
        return ops.isEmpty ? nil : OpsCommand("Use \(name) from the other version", ops: ops)
    }
}
