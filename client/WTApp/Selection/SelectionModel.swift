import Foundation
import Observation

/// The observable selection of one document window (client.adoc, "Panels": a panel body
/// observes the document and the selection).  SwiftUI panel bodies read `selection` and redraw
/// through Observation; AppKit code (the canvas overlay, the status bar) registers a handler.
@MainActor
@Observable
final class SelectionModel {
    struct ObservationToken: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private(set) var selection: Selection = .empty
    @ObservationIgnored private var observers: [UUID: @MainActor (Selection) -> Void] = [:]

    init(_ selection: Selection = .empty) {
        self.selection = selection
    }

    var ids: [SelectionID] { selection.ids }
    var isEmpty: Bool { selection.isEmpty }
    var count: Int { selection.count }

    /// Replaces the selection; observers hear about it only when it changed.
    func set(_ selection: Selection) {
        guard selection != self.selection else { return }
        self.selection = selection
        for observer in observers.values { observer(selection) }
    }

    func apply(_ picked: [SelectionID], sub: [SelectionID: SubSelection] = [:], mode: SelectionMode) {
        set(selection.applying(picked, sub: sub, mode: mode))
    }

    func clear() { set(.empty) }

    @discardableResult
    func observe(_ handler: @escaping @MainActor (Selection) -> Void) -> ObservationToken {
        let id = UUID()
        observers[id] = handler
        return ObservationToken(id: id)
    }

    func stopObserving(_ token: ObservationToken) {
        observers[token.id] = nil
    }
}

/// The selection of the front document window, for the app-wide panels (one Object panel
/// serves every window).  The key window's controller sets `model`; panel bodies read through
/// it and Observation follows both the switch of window and the selection's changes.
@MainActor
@Observable
final class ActiveSelection {
    var model: SelectionModel?
    /// The front window's document (the Object panel's sections read it).
    var document: DocumentHandle?
    /// The front window's object commands (the Transform panel performs through them, so a
    /// transformation is remembered for *Transform Again* and power duplicating).
    var editing: ObjectEditing?
    /// The front window's collaborators (the Object panel's "Priya is editing this object").
    var presence: (any PresenceProviding)?
    /// The app's preferences (the Object panel's stroke width presets).
    var preferences: PreferenceStore?
    /// The front window's active tool (the Object panel's Output Area editor).
    var activeToolID: ToolID?

    init(model: SelectionModel? = nil, document: DocumentHandle? = nil, editing: ObjectEditing? = nil, presence: (any PresenceProviding)? = nil) {
        self.model = model
        self.document = document
        self.editing = editing
        self.presence = presence
    }

    /// "Priya is editing this object" when a collaborator is changing a selected object
    /// (presence.adoc, "Selections and carets"); nil otherwise.
    var editingLine: String? {
        guard let selected = model?.ids, !selected.isEmpty, let participants = presence?.participants else { return nil }
        let names = participants.filter { !Set($0.editing).isDisjoint(with: selected) }.map(\.name)
        guard let first = names.first else { return nil }
        let who = names.count == 1 ? first : "\(first) and \(names.count - 1) more"
        return selected.count == 1 ? "\(who) \(names.count == 1 ? "is" : "are") editing this object" : "\(who) \(names.count == 1 ? "is" : "are") editing the selection"
    }

    /// "Nothing selected", "1 object selected", "3 objects selected".
    var summary: String {
        guard let model else { return "No document" }
        switch model.count {
        case 0: return "Nothing selected"
        case 1: return "1 object selected"
        case let count: return "\(count) objects selected"
        }
    }
}
