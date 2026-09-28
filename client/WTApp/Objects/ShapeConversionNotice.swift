import Foundation
import WTCRDT
import WTModel
import WTProto

/// The status line's note when this person's edit converted live shapes to paths (D-078,
/// rectangles-ellipses-lines.adoc "Editing a shape's points"): "Rectangle converted to a path.
/// Undo brings the live rectangle back."  It blocks nothing and asks nothing; it shows each time a
/// point drag, a point command or a path command converts shapes, and not for menu:Modify[Ungroup],
/// which asks for the conversion by name, nor for someone else's edit.
@MainActor
final class ShapeConversionNotice {
    /// Weak: the document (and its observers) can outlive the window.
    weak var window: DocumentWindowController?
    private var token: DocumentHandle.ObservationToken?
    /// The note last shown (tests).
    private(set) var shown: String?

    init(window: DocumentWindowController) {
        self.window = window
        token = window.documentHandle.observe { [weak self] change in self?.documentDidChange(change.change) }
    }

    func stop() {
        if let token { window?.documentHandle.stopObserving(token) }
        token = nil
    }

    /// The note for shapes of these kind names converted ("Rectangle", "Star"…).
    static func message(_ names: [String]) -> String? {
        guard let first = names.first else { return nil }
        guard names.count > 1 else { return "\(first) converted to a path. Undo brings the live \(first.lowercased()) back." }
        return "\(names.count) shapes converted to paths. Undo brings the live shapes back."
    }

    /// A change arrived: this person's own, other than Ungroup, that converted shapes posts the note.
    func documentDidChange(_ change: Wiretuner_Doc_V1_Change?) {
        guard let window, let change, change.replica == window.documentHandle.model?.replica, change.label != "Ungroup" else { return }
        let state = window.documentHandle.state
        let conversions = ShapeConversion.conversions(in: change, state: state)
        guard let message = Self.message(conversions.keys.sorted().map { ShapeConversion.name(of: $0, in: state) }) else { return }
        shown = message
        window.toolManager.context.host.showStatusMessage(message)
    }
}
