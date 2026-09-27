import Foundation
import WTCRDT

/// One undo (or redo) step: the label of the action and the inverse that takes it back
/// (docs/_includes/objects/undo.adoc).  An entry on the redo list holds the inverse of the undo,
/// which is what redoes the action.
public struct UndoEntry: Sendable, Hashable {
    /// What the step is called: "Move 3 Objects".  Undo and redo change labels add the verb.
    public var label: String
    /// The inverse of the step's change(s), recorded by `applyLocal`.
    public var inverse: Inverse
    /// When the step last absorbed a change (the typing pause is measured from it).
    public var updatedAt: Date
    /// What the step may still absorb: a drag group or a word being typed.  Nil once closed; an
    /// entry read back from the local store is always closed.
    public var openKey: CoalesceKey?

    public init(label: String, inverse: Inverse, updatedAt: Date, openKey: CoalesceKey? = nil) {
        self.label = label
        self.inverse = inverse
        self.updatedAt = updatedAt
        self.openKey = openKey
    }
}

/// What an open undo step accepts: the commands of one drag group, or one word typed into one
/// TEXT field.
public enum CoalesceKey: Sendable, Hashable {
    case group(UInt64)
    case typing(node: OpID, field: RegisterPath)
    /// A run of typing or deleting in one TEXT field (`TextEditKey`, TYPE-002).
    case text(TextEditKey)
}

/// A change to the undo and redo lists, as the local store persists it in the same transaction as
/// the change it records (docs/spec/offline.adoc, `undo` table).
public enum UndoEdit: Sendable, Hashable {
    /// A new step: the redo list is cleared, `entry` goes on top of the undo list, and the oldest
    /// steps beyond `limit` are dropped.
    case push(UndoEntry, limit: Int)
    /// The top undo step absorbed a change and is now `entry`; the redo list is cleared.
    case replaceTop(UndoEntry)
    /// The top undo step was undone: it leaves the undo list and `redo` goes on the redo list.
    case undo(redo: UndoEntry)
    /// The top redo step was redone: it leaves the redo list and `undo` goes on the undo list,
    /// which keeps at most `limit` steps.
    case redo(undo: UndoEntry, limit: Int)
}

/// The undo and redo lists of one document (docs/spec/client.adoc, "Undo"; `WTModel.UndoStack`
/// in docs/_includes/objects/undo.adoc): the menu titles, validation and the grouping rules.
/// `NSUndoManager` is not used for document changes: its linear stack cannot express "skip what
/// someone else changed", which the engine's `undoChange` does.
public struct UndoStack: Sendable, Hashable {
    /// How long a pause ends a typed word's undo step.
    public static let typingPause: TimeInterval = 1

    /// Undo steps, oldest first.
    public private(set) var undo: [UndoEntry]
    /// Redo steps, oldest first; the last is redone next.
    public private(set) var redo: [UndoEntry]

    public init(undo: [UndoEntry] = [], redo: [UndoEntry] = []) {
        self.undo = undo
        self.redo = redo
    }

    public var canUndo: Bool { !undo.isEmpty }
    public var canRedo: Bool { !redo.isEmpty }

    /// The Edit menu's undo item: "Undo Move 3 Objects", or "Undo" (dimmed) when empty.
    public var undoTitle: String { Self.title("Undo", undo.last?.label) }
    /// The Edit menu's redo item: "Redo Move 3 Objects", or "Redo" (dimmed) when empty.
    public var redoTitle: String { Self.title("Redo", redo.last?.label) }

    static func title(_ verb: String, _ label: String?) -> String {
        guard let label, !label.isEmpty else { return verb }
        return "\(verb) \(label)"
    }

    /// The edit recording a local change's `inverse`: it joins the top step when that step is open
    /// for `key` (and, for typing, the pause since it was updated is under a second), else it is a
    /// new step.  `stillOpen` says whether the resulting step accepts more under `key` (false once
    /// a word ends).  Nil when the change changed nothing undoable.
    public func recording(
        _ inverse: Inverse, label: String, key: CoalesceKey?, stillOpen: Bool, now: Date, limit: Int
    ) -> UndoEdit? {
        recording(inverse, label: label, joining: key, open: stillOpen ? key : nil, now: now, limit: limit)
    }

    /// The edit recording a local change's `inverse` when the key it joins under differs from the
    /// key its step stays open under (`UndoCoalescing.text`): it joins the top step when that step
    /// is open for `joining` (for typing, within the pause), else it is a new step; either way
    /// the step is left open for `open` (nil closes it).
    public func recording(
        _ inverse: Inverse, label: String, joining: CoalesceKey?, open: CoalesceKey?, now: Date, limit: Int
    ) -> UndoEdit? {
        guard !inverse.isEmpty else { return nil }
        if let joining, let top = undo.last, top.openKey == joining, joins(top, key: joining, now: now) {
            return .replaceTop(UndoEntry(label: top.label, inverse: top.inverse.followed(by: inverse), updatedAt: now,
                                         openKey: open))
        }
        return .push(UndoEntry(label: label, inverse: inverse, updatedAt: now, openKey: open), limit: limit)
    }

    /// Whether a change joining under `key` at `now` would join the top step (`recording`).
    public func accepts(_ key: CoalesceKey, now: Date) -> Bool {
        guard let top = undo.last, top.openKey == key else { return false }
        return joins(top, key: key, now: now)
    }

    private func joins(_ top: UndoEntry, key: CoalesceKey, now: Date) -> Bool {
        switch key {
        case .typing, .text:
            return now.timeIntervalSince(top.updatedAt) < Self.typingPause
        case .group:
            return true
        }
    }

    /// Applies `edit` (the same edit the local store persists).
    public mutating func apply(_ edit: UndoEdit) {
        switch edit {
        case .push(let entry, let limit):
            redo.removeAll()
            close()
            undo.append(entry)
            trim(to: limit)
        case .replaceTop(let entry):
            redo.removeAll()
            undo[undo.count - 1] = entry
        case .undo(let entry):
            undo.removeLast()
            redo.append(entry)
        case .redo(let entry, let limit):
            redo.removeLast()
            close()
            undo.append(entry)
            trim(to: limit)
        }
    }

    /// Rewrites every step's inverse (`rebase`).
    mutating func rewrite(_ transform: (Inverse) -> Inverse) {
        for index in undo.indices {
            undo[index].inverse = transform(undo[index].inverse)
        }
        for index in redo.indices {
            redo[index].inverse = transform(redo[index].inverse)
        }
    }

    // Only the top step can be open: a step pushed over it closes it.
    private mutating func close() {
        if !undo.isEmpty {
            undo[undo.count - 1].openKey = nil
        }
    }

    private mutating func trim(to limit: Int) {
        let excess = undo.count - max(1, limit)
        if excess > 0 {
            undo.removeFirst(excess)
        }
    }
}
