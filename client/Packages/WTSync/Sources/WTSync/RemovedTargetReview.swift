import Foundation
import WTCRDT
import WTModel
import WTProto

// The "placed an instance of a removed symbol" and "uses a removed style" rows of the review sheet
// (library.adoc, "Delete symbol versus place instance"; styles.adoc, "Remove versus apply").  One side
// removed a symbol or a graphic style while the other placed an instance of it or applied it to an
// object: the new object shares no node with the removal, so the overlap never finds it, and it
// reads as a placeholder (the instance) or through the deleted style's registers (the object).  Both
// are measured beside the overlap and always listed, each with its two choices: *Restore symbol* /
// *Release*, and *Restore style* / *Keep look*.

/// One object that refers to something the other side removed.
public struct RemovedTargetEntry: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case removedSymbol
        case removedStyle

        public var title: String {
            switch self {
            case .removedSymbol: "Placed an instance of a removed symbol"
            case .removedStyle: "Uses a removed style"
            }
        }
    }

    public enum Choice: Sendable, Hashable, CaseIterable {
        /// `deleted = false` on the symbol and its artwork, or on the style.
        case restore
        /// *Release*: the instance becomes the artwork as it was when the symbol was removed.
        case release
        /// *Keep look*: the object's look baked into overrides on the removed style's successor.
        case keepLook

        public var title: String {
            switch self {
            case .restore: "Restore"
            case .release: "Release"
            case .keepLook: "Keep look"
            }
        }
    }

    public var kind: Kind
    /// The instance, or the styled object.
    public var object: OpID
    /// The removed symbol or style.
    public var target: OpID
    /// The replicas that removed it.
    public var authors: [UInt64]

    public init(kind: Kind, object: OpID, target: OpID, authors: [UInt64]) {
        self.kind = kind
        self.object = object
        self.target = target
        self.authors = authors
    }

    public var id: String { "removed-target:\(object)" }

    public var choices: [Choice] { kind == .removedSymbol ? [.restore, .release] : [.restore, .keepLook] }

    /// The choice as one change; nil when it writes nothing or is not offered.
    public func command(_ choice: Choice, in state: EngineState) throws -> (any Command)? {
        guard choices.contains(choice) else { return nil }
        let restore = RemovedTargetReview.restoreOps(target, in: state)
        switch choice {
        case .restore:
            guard !restore.isEmpty else { return nil }
            return OpsCommand(kind == .removedSymbol ? "Restore Symbol" : "Restore Style", ops: restore)
        case .release:
            return try RemovedTargetReview.against(restored: restore, in: state, ReleaseInstances([object], label: "Release Instance"))
        case .keepLook:
            return try RemovedTargetReview.against(restored: restore, in: state, RemoveGraphicStyle(target))
        }
    }
}

/// Measuring the rows.
public enum RemovedTargetReview {
    /// The `NodeProps.kind` field of a graphic style (`StyleProps`).
    static let graphicStyleKind: UInt32 = 154

    /// Objects one side placed or styled that refer to a symbol or graphic style the other side removed.
    public static func rows(local: [Wiretuner_Doc_V1_Change], remote: [Wiretuner_Doc_V1_Change], state: EngineState) -> [RemovedTargetEntry] {
        var rows: [RemovedTargetEntry] = []
        for (removers, placers) in [(remote, local), (local, remote)] {
            // Only removed symbols and graphic styles matter; most reconnects have none.
            let removed = removals(removers, state: state).filter { target, _ in
                state.nodeKind(target) == .symbol || state.store.kind(target) == graphicStyleKind
            }
            guard !removed.isEmpty else { continue }
            for node in touched(placers) where state.isLive(node) {
                if state.nodeKind(node) == .instance {
                    let target = OpID(state.props(node).instance.symbol.id)
                    if let authors = removed[target], state.nodeKind(target) == .symbol {
                        rows.append(RemovedTargetEntry(kind: .removedSymbol, object: node, target: target, authors: authors.sorted()))
                        continue
                    }
                }
                // `CommonProps.style` read from its register alone.
                let kind = state.store.kind(node)
                guard kind != 0, let bytes = state.store.register(node, RegisterPath([kind, 1, 7]))?.value,
                      let common = try? Wiretuner_Doc_V1_CommonProps(serializedBytes: bytes), common.hasStyle else { continue }
                let target = OpID(common.style.id)
                if let authors = removed[target], state.store.kind(target) == graphicStyleKind {
                    rows.append(RemovedTargetEntry(kind: .removedStyle, object: node, target: target, authors: authors.sorted()))
                }
            }
        }
        return rows.sorted { $0.object < $1.object }
    }

    /// Nodes `changes` left deleted, with who deleted them (merged state still deleted).
    static func removals(_ changes: [Wiretuner_Doc_V1_Change], state: EngineState) -> [OpID: Set<UInt64>] {
        var out: [OpID: Set<UInt64>] = [:]
        for change in changes {
            for op in change.ops {
                guard case .setDeleted(let flag)? = op.op, flag.deleted else { continue }
                let node = OpID(flag.node)
                if state.store.deleted(node)?.current.value == true { out[node, default: []].insert(change.replica) }
            }
        }
        return out
    }

    /// Nodes `changes` created or wrote, in first-touch order.
    static func touched(_ changes: [Wiretuner_Doc_V1_Change]) -> [OpID] {
        var seen: Set<OpID> = []
        var out: [OpID] = []
        for change in changes {
            for (op, id) in zip(change.ops, change.opIDs) {
                let node: OpID
                switch op.op {
                case .create: node = id
                case .set(let set): node = OpID(set.node)
                default: continue
                }
                if seen.insert(node).inserted { out.append(node) }
            }
        }
        return out
    }

    /// `deleted = false` on `target` and on every deleted node under it.
    static func restoreOps(_ target: OpID, in state: EngineState) -> [Wiretuner_Doc_V1_Op] {
        var ops: [Wiretuner_Doc_V1_Op] = []
        var pending = [target]
        while let node = pending.popLast() {
            if state.store.deleted(node)?.current.value == true { ops.append(Ops.setDeleted(node, false)) }
            pending += state.store.children(node)
        }
        return ops
    }

    /// `command` built against `state` with `restore` applied as if it had happened, keeping only
    /// its own ops (the release or the bake reads the removed node's registers as they are).
    static func against(restored restore: [Wiretuner_Doc_V1_Op], in state: EngineState, _ command: any Command) throws -> (any Command)? {
        var scratch = state
        var change = Wiretuner_Doc_V1_Change()
        change.replica = UInt64.max >> 12
        change.seq = 1
        change.startCounter = scratch.clock.peek
        change.ops = restore
        scratch.apply(change)
        var builder = ChangeBuilder(replica: 1, startCounter: 1)
        try command.execute(&builder, state: scratch)
        guard !builder.ops.isEmpty else { return nil }
        return Prebuilt(label: command.label, command: command, scratch: scratch)
    }

    /// A command that builds against a prepared scratch state.
    struct Prebuilt: Command {
        let label: String
        let command: any Command
        let scratch: EngineState

        func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
            try command.execute(&builder, state: scratch)
        }
    }
}
