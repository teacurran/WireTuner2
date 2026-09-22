import Foundation

/// Owns the current `PanelLayout`: applies operations, tells observers (the dock, the Window
/// menu), and saves to the store 500 ms after the last change.  Foundation only.
@MainActor
final class PanelLayoutController {
    struct ObservationToken: Hashable, Sendable {
        fileprivate let id: UUID
    }

    let registry: PanelRegistry
    let store: PanelLayoutStore?
    let debounce: Duration

    private(set) var layout: PanelLayout {
        didSet { for observer in observers.values { observer(layout) } }
    }
    private var observers: [UUID: @MainActor (PanelLayout) -> Void] = [:]
    private(set) var pendingSave: Task<Void, Never>?
    private(set) var lastSaveError: (any Error)?
    private(set) var loadError: (any Error)?

    init(registry: PanelRegistry, store: PanelLayoutStore? = nil, debounce: Duration = .milliseconds(500)) {
        self.registry = registry
        self.store = store
        self.debounce = debounce
        self.layout = PanelLayout.standard(for: registry.descriptors)
    }

    var defaultLayout: PanelLayout { PanelLayout.standard(for: registry.descriptors) }

    /// Loads the saved layout, or the default when there is none or it cannot be read, and
    /// reconciles it with the registered panels.
    func load() {
        var loaded: PanelLayout?
        if let store {
            do {
                loaded = try store.load()
                loadError = nil
            } catch {
                loadError = error
            }
        }
        var layout = loaded ?? defaultLayout
        reconcile(&layout)
        self.layout = layout
    }

    private func reconcile(_ layout: inout PanelLayout) {
        layout.prune(keeping: Set(registry.ids))
        layout.add(panels: registry.descriptors)
    }

    /// Puts panels registered since the last load into the layout.
    func addRegisteredPanels() {
        update { reconcile(&$0) }
    }

    @discardableResult
    func observe(_ handler: @escaping @MainActor (PanelLayout) -> Void) -> ObservationToken {
        let token = ObservationToken(id: UUID())
        observers[token.id] = handler
        return token
    }

    func stopObserving(_ token: ObservationToken) {
        observers[token.id] = nil
    }

    /// Applies `change`; a change that leaves the layout equal is dropped.
    func update(_ change: (inout PanelLayout) -> Void) {
        var next = layout
        change(&next)
        guard next != layout else { return }
        layout = next
        scheduleSave()
    }

    func resetToDefault() {
        let standard = defaultLayout
        update { $0 = standard }
    }

    func isVisible(_ panel: PanelID) -> Bool { layout.isVisible(panel) }

    /// menu:Window[<panel>]: shows the panel; if it is already in front, collapses its docked
    /// group or closes its floating group.
    func togglePanel(_ panel: PanelID) {
        if layout.isVisible(panel) {
            update { layout in
                guard let group = layout.group(containing: panel) else { return }
                if case .floating? = layout.location(of: group.id) {
                    for member in group.panels { layout.removePanel(member) }
                } else {
                    layout.setCollapsed(true, group: group.id)
                }
            }
        } else {
            showPanel(panel)
        }
    }

    /// Brings `panel` to the front, putting it back into its default group if it was closed.
    func showPanel(_ panel: PanelID) {
        update { layout in
            if !layout.contains(panel), let descriptor = registry.descriptor(for: panel) {
                layout.add(panels: [descriptor])
            }
            layout.activate(panel)
        }
    }

    /// menu:View[Panels]: hides every dock, or shows them all again.
    var panelsHidden: Bool { !layout.hiddenDocks.isEmpty }

    func toggleAllPanels() {
        let hide = !panelsHidden
        update { layout in
            for edge in DockEdge.allCases { layout.setDockHidden(hide, edge: edge) }
        }
    }

    // MARK: Persistence

    private func scheduleSave() {
        guard let store else { return }
        pendingSave?.cancel()
        let snapshot = layout
        pendingSave = Task { [debounce] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            commitSave(snapshot, to: store)
        }
    }

    private func commitSave(_ layout: PanelLayout, to store: PanelLayoutStore) {
        do {
            try store.save(layout)
            lastSaveError = nil
        } catch {
            lastSaveError = error
        }
    }

    /// Writes the layout now, dropping any pending debounced save.
    func saveNow() throws {
        pendingSave?.cancel()
        pendingSave = nil
        guard let store else { return }
        try store.save(layout)
    }

    /// Waits for a debounced save to finish (tests).
    func flushPendingSave() async {
        await pendingSave?.value
    }
}
