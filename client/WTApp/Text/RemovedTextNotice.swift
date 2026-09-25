import Foundation
import WTCRDT
import WTModel
import WTProto

/// The *Restore* notice (editing-text.adoc, "Working with others"; TYPE-016): when someone else
/// deletes the text block this person is editing, editing ends and the window's banner says so with
/// btn:[Restore], which writes `deleted = false` as one undoable change.
@MainActor
final class RemovedTextNotice {
    unowned let window: DocumentWindowController
    /// The block the Text tool edits, as last seen.
    private(set) var editing: OpID?
    private var token: DocumentHandle.ObservationToken?

    static let action = "Restore"

    init(window: DocumentWindowController) {
        self.window = window
        token = window.documentHandle.observe { [weak self] change in self?.documentDidChange(change.change) }
    }

    func stop() {
        if let token { window.documentHandle.stopObserving(token) }
        token = nil
    }

    /// Records the block the Text tool is editing (called as the overlay redraws).
    func track() {
        if let node = window.objectEditing.textSession?.node, window.objectEditing.textSession?.isLive == true {
            editing = node
        } else if let node = editing, window.documentHandle.state.isLive(node) {
            // Editing ended with the block still there: nothing to watch.
            editing = nil
        }
    }

    /// The text of the notice for a block removed by `author`.
    static func text(author: String) -> String { "\(author) deleted the text you were editing." }

    /// A change arrived: when it is someone else's and it deleted the block being edited, the
    /// notice is posted.
    func documentDidChange(_ change: Wiretuner_Doc_V1_Change?) {
        track()
        guard let node = editing, let change, change.replica != window.documentHandle.model?.replica,
              window.documentHandle.state.store.kind(node) != 0, !window.documentHandle.state.isLive(node) else { return }
        editing = nil
        let author = window.collaboration.session?.author(of: change.replica)?.name ?? "Someone"
        window.pageNotices.post(Self.text(author: author), action: Self.action, command: OpsCommand("Restore text", ops: [Ops.setDeleted(node, false)]))
        window.showNotices()
    }
}
