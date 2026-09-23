import WTCRDT

// The engine undoes one inverse against the current state and restores a target only where the
// state still holds the exact write the inverse recorded (`undoChange`, CRDT-008).  An undo or a
// redo is itself a new write, so after undoing the top step the steps below it would find their
// targets holding the undo's OpId rather than their own and skip them: renaming twice and undoing
// twice would undo only once.  The rule the user sees is by *who* wrote (undo.adoc: only what
// someone else changed is skipped), so after every undo and redo the stack is rebased: wherever
// the reversal restored a target to the value some step wrote, that step now names the reversal's
// write as its own; a node or element the reversal un-deleted counts as not deleted by anyone
// else for the step that created it; a member the reversal re-added counts among the adds of the
// steps that added it; and characters the reversal re-inserted stand for the originals in the
// steps that typed them.

extension UndoStack {
    /// Rebases every step after `reverted` (a step's inverse) was reversed by a change whose own
    /// inverse is `reversal`, applied to give `state`.
    mutating func rebase(reverted: Inverse, reversal: Inverse, state: EngineState) {
        let remap = Remap(reverted: reverted, reversal: reversal, state: state)
        guard !remap.isEmpty else { return }
        rewrite { remap.apply(to: $0) }
    }
}

/// What a reversal changed hands: per target, the write it replaced and its own.
struct Remap {
    enum Target: Hashable {
        case register(OpID, RegisterPath)
        case placement(OpID)
        case deleted(OpID)
        case elementPosition(OpID, RegisterPath)
        case elementDeleted(OpID, RegisterPath)
    }

    struct Member: Hashable {
        let node: OpID
        let set: RegisterPath
        let member: [UInt8]
    }

    struct Field: Hashable {
        let node: OpID
        let path: RegisterPath
    }

    /// Target → (the write the restored value was made by, nil when never written; the
    /// reversal's write).
    private(set) var writes: [Target: (old: OpID?, new: OpID)] = [:]
    /// Member → the tag the reversal re-added it with.
    private(set) var tags: [Member: OpID] = [:]
    /// TEXT field → original character → the character the reversal re-inserted for it.
    private(set) var chars: [Field: [OpID: OpID]] = [:]

    var isEmpty: Bool { writes.isEmpty && tags.isEmpty && chars.isEmpty }

    init(reverted: Inverse, reversal: Inverse, state: EngineState) {
        var restored: [Target: OpID?] = [:]
        for step in reverted.steps {
            guard let (target, prior) = Self.prior(step), restored[target] == nil else { continue }
            restored[target] = .some(prior)
        }
        for step in reversal.steps {
            switch step {
            case .memberAdded(let node, let set, let member, let tag, _, _):
                tags[Member(node: node, set: set, member: member)] = tag
            case .textInserted(let node, let path, let inserted):
                for (original, copy) in Self.originals(of: inserted, in: state.text(node, path)) {
                    chars[Field(node: node, path: path), default: [:]][original] = copy
                }
            default:
                if let (target, wrote) = Self.wrote(step), let old = restored[target] {
                    writes[target] = (old: old, new: wrote)
                }
            }
        }
    }

    // The target of a step and the write of its prior value.
    private static func prior(_ step: Inverse.Step) -> (Target, OpID?)? {
        switch step {
        case .register(let node, let path, let prior, _): (.register(node, path), prior?.op)
        case .placement(let node, let prior, _): (.placement(node), prior?.op)
        case .deleted(let node, let prior, _): (.deleted(node), prior?.op)
        case .elementPosition(let node, let element, let prior, _): (.elementPosition(node, element), prior.op)
        case .elementDeleted(let node, let element, let prior, _): (.elementDeleted(node, element), prior?.op)
        default: nil
        }
    }

    // The target of a step and the write it made.
    private static func wrote(_ step: Inverse.Step) -> (Target, OpID)? {
        switch step {
        case .register(let node, let path, _, let wrote): (.register(node, path), wrote)
        case .placement(let node, _, let wrote): (.placement(node), wrote)
        case .deleted(let node, _, let wrote): (.deleted(node), wrote)
        case .elementPosition(let node, let element, _, let wrote): (.elementPosition(node, element), wrote)
        case .elementDeleted(let node, let element, _, let wrote): (.elementDeleted(node, element), wrote)
        default: nil
        }
    }

    // Re-inserted characters go right after the last original of their run (its left origin), and
    // a run is characters adjacent in document order: the originals are the run's length of
    // characters ending at that one.
    static func originals(of inserted: [OpID], in text: TextSequence?) -> [OpID: OpID] {
        let order = text?.order ?? []
        guard let first = inserted.first, let last = text?.origins(first)?.left, let end = order.firstIndex(of: last),
              end + 1 >= inserted.count else { return [:] }
        let run = order[(end + 1 - inserted.count)...end]
        return Dictionary(uniqueKeysWithValues: zip(run, inserted))
    }

    /// `inverse` rebased.
    func apply(to inverse: Inverse) -> Inverse {
        var extra: [Inverse.Step] = []
        var added: Set<Member> = []
        let steps = inverse.steps.map { step -> Inverse.Step in
            switch step {
            case .register(let node, let path, let prior, let wrote):
                return .register(node: node, path: path, prior: prior, wrote: remapped(.register(node, path), wrote))
            case .placement(let node, let prior, let wrote):
                return .placement(node: node, prior: prior, wrote: remapped(.placement(node), wrote))
            case .deleted(let node, let prior, let wrote):
                return .deleted(node: node, prior: prior, wrote: remapped(.deleted(node), wrote))
            case .elementPosition(let node, let element, let prior, let wrote):
                return .elementPosition(node: node, element: element, prior: prior,
                                        wrote: remapped(.elementPosition(node, element), wrote))
            case .elementDeleted(let node, let element, let prior, let wrote):
                return .elementDeleted(node: node, element: element, prior: prior,
                                       wrote: remapped(.elementDeleted(node, element), wrote))
            case .created(let node):
                if let write = writes[.deleted(node)], write.old == nil {
                    extra.append(.deleted(node: node, prior: nil, wrote: write.new))
                }
                return step
            case .elementInserted(let node, let element):
                if let write = writes[.elementDeleted(node, element)], write.old == nil {
                    extra.append(.elementDeleted(node: node, element: element, prior: nil, wrote: write.new))
                }
                return step
            case .memberAdded(let node, let set, let member, _, let wasPresent, let field):
                let key = Member(node: node, set: set, member: member)
                if let tag = tags[key], added.insert(key).inserted {
                    extra.append(.memberAdded(node: node, set: set, member: member, tag: tag, wasPresent: wasPresent, field: field))
                }
                return step
            case .textInserted(let node, let path, let typed):
                guard let map = chars[Field(node: node, path: path)] else { return step }
                return .textInserted(node: node, text: path, chars: typed + typed.compactMap { map[$0] })
            default:
                return step
            }
        }
        return .assembled(steps + extra)
    }

    private func remapped(_ target: Target, _ wrote: OpID) -> OpID {
        guard let write = writes[target], write.old == wrote else { return wrote }
        return write.new
    }
}
