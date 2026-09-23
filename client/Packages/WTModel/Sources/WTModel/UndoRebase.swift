import WTCRDT

// The engine undoes a step only where no other replica has written its target since (CRDT-010:
// a write by this replica, such as the undo of a later step, still counts as its own), so undoing
// twice in a row needs no bookkeeping for registers, placements, deletions, elements or members.
// One case remains: an undone text deletion re-inserts its characters as *new* characters, so a
// step that typed the originals would not delete the copies when it is undone in turn.  After
// every undo and redo the stack is rebased: characters the reversal re-inserted stand for the
// originals in the steps that typed them.

extension UndoStack {
    /// Rebases every step after a reversal whose own inverse is `reversal`, applied to give
    /// `state`.
    mutating func rebase(reversal: Inverse, state: EngineState) {
        let remap = Remap(reversal: reversal, state: state)
        guard !remap.isEmpty else { return }
        rewrite { remap.apply(to: $0) }
    }
}

/// The characters a reversal re-inserted, per TEXT field: original → copy.
struct Remap {
    struct Field: Hashable {
        let node: OpID
        let path: RegisterPath
    }

    private(set) var chars: [Field: [OpID: OpID]] = [:]

    var isEmpty: Bool { chars.isEmpty }

    init(reversal: Inverse, state: EngineState) {
        for case .textInserted(let node, let path, let inserted) in reversal.steps {
            for (original, copy) in Self.originals(of: inserted, in: state.text(node, path)) {
                chars[Field(node: node, path: path), default: [:]][original] = copy
            }
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

    /// `inverse` with each typing step also naming the copies of the characters it typed.
    func apply(to inverse: Inverse) -> Inverse {
        Inverse(steps: inverse.steps.map { step in
            guard case .textInserted(let node, let path, let typed) = step, let map = chars[Field(node: node, path: path)] else { return step }
            return .textInserted(node: node, text: path, chars: typed + typed.compactMap { map[$0] })
        })
    }
}
