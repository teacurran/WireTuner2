import Foundation
import WTCRDT
import WTModel

/// The stack row the Object panel is editing (APP-007), for what the canvas draws for it: the
/// centre handles of a selected Bend, Duet or Transform effect (live-effects.adoc, "Controls") and
/// the selected gradient fill's handles in full colour (gradients.adoc, "Handles").  The
/// Attributes list sets it as its selection changes; every canvas that asked redraws its overlay
/// when it does.
@MainActor
final class InspectorFocus {
    static let shared = InspectorFocus()

    /// The objects the row was chosen for, in selection order.
    private(set) var targets: [OpID] = []
    /// The row of the first target; nil for the root row.
    private(set) var row: AppearanceRow?
    private var redraws: [UUID: @MainActor () -> Void] = [:]

    init() {}

    func set(_ row: AppearanceRow?, targets: [OpID]) {
        guard row != self.row || targets != self.targets else { return }
        self.row = row
        self.targets = targets
        for redraw in redraws.values { redraw() }
    }

    /// The focused row when `targets` are what is selected now; nil otherwise.
    func row(for targets: [OpID]) -> AppearanceRow? {
        targets == self.targets ? row : nil
    }

    /// Calls `redraw` after every change until `stopObserving`.
    @discardableResult
    func observe(_ redraw: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        redraws[id] = redraw
        return id
    }

    func stopObserving(_ id: UUID) {
        redraws[id] = nil
    }

    var observerCount: Int { redraws.count }
}
