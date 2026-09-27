import Foundation
import WTModel
import WTProto

/// A continuous edit that writes its intent, not its input events (D-076): while the gesture runs
/// -- a handle dragged, a slider or a colour moved, a key held -- `update` shows its command on
/// every canvas as if performed (`DocumentHandle.preview`: nothing reaches the outbox or the undo
/// list), and `commit` performs the last one as the gesture's one change.  `cancel` drops the
/// preview and writes nothing.
///
/// For a source with no end event (a colour well that streams changes, a key that repeats),
/// `settleAfter` commits once updates pause.
@MainActor
final class GestureEdit {
    /// How long updates must pause before `settleAfter` commits.
    static let pause: Duration = .milliseconds(400)

    let document: DocumentHandle
    /// The command shown now; nil when nothing is previewed.
    private(set) var command: (any WTModel.Command)?
    private var settling: Task<Void, Never>?

    init(document: DocumentHandle) {
        self.document = document
    }

    /// Whether a gesture's command is being previewed.
    var isActive: Bool { command != nil }

    /// Shows `command` as the gesture so far (nil shows the document as it is).
    func update(_ command: (any WTModel.Command)?) {
        self.command = command
        document.preview(command)
    }

    /// `update`, then commits by itself once updates pause for `pause`.
    func updateSettling(_ command: (any WTModel.Command)?, after pause: Duration = GestureEdit.pause) {
        update(command)
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            self?.commit()
        }
    }

    /// Ends the gesture: the preview goes and the last command is performed as one change (the
    /// preview's pixels stay on screen until the change's have rendered, D-076).
    @discardableResult
    func commit() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        settling?.cancel()
        settling = nil
        guard let command else { return nil }
        self.command = nil
        document.preview(nil)
        return document.perform(command)
    }

    /// Ends the gesture writing nothing.
    func cancel() {
        settling?.cancel()
        settling = nil
        guard command != nil else { return }
        command = nil
        document.preview(nil)
    }
}

/// Input with no end event -- a colour well streaming its colour, a held arrow key repeating --
/// that should still write once (D-076): commands performed inside `settle` are previewed and the
/// last one is written once the input pauses for `GestureEdit.pause` (`DocumentHandle.perform`).
@MainActor
enum ContinuousInput {
    /// Whether `perform` is inside `settle`.
    private(set) static var isSettling = false

    /// Runs `body` with its commands previewed and written once input pauses.
    static func settle(_ body: () -> Void) {
        let outer = isSettling
        isSettling = true
        defer { isSettling = outer }
        body()
    }
}
