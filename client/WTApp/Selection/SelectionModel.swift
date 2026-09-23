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

    init(model: SelectionModel? = nil) {
        self.model = model
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
