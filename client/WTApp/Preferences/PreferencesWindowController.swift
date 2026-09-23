import AppKit
import Observation
import SwiftUI

/// The Preferences window's state: which category is shown and whether Option is held (the
/// Restore button then scopes to the category).
@MainActor
@Observable
final class PreferencesWindowModel {
    var selectedCategory: PreferenceCategory = .general
    var optionHeld = false
    /// Typeface appears in the sidebar only while a typeface document is open.
    var typefaceDocumentOpen = false

    @ObservationIgnored let store: PreferenceStore
    /// Restore Defaults also resets the panel layout (preferences.adoc).
    @ObservationIgnored var onRestoreAll: @MainActor () -> Void

    init(store: PreferenceStore, onRestoreAll: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.onRestoreAll = onRestoreAll
    }

    var categories: [PreferenceCategory] {
        PreferenceCategory.visible(typefaceDocumentOpen: typefaceDocumentOpen)
    }

    /// The synced/local badge beside each category (preferences.adoc, "Synced and local
    /// preferences").
    static func badge(for category: PreferenceCategory) -> String {
        category.scope == .synced ? "Synced" : "This Mac"
    }

    var restoreTitle: String {
        optionHeld ? "Restore This Category" : "Restore Defaults"
    }

    var restoreMessage: String {
        optionHeld
            ? "Restore every \(selectedCategory.title) preference to its default?"
            : "Restore every preference to its default? Your panel layout is reset too; keyboard shortcut sets are not touched."
    }

    /// The Restore button: asks `confirm` with the message, restores when it agrees.
    /// Returns whether it restored.
    @discardableResult
    func confirmAndRestore(_ confirm: @MainActor (String) -> Bool) -> Bool {
        guard confirm(restoreMessage) else { return false }
        restore()
        return true
    }

    /// Performs the restore the button currently offers (after confirmation).
    func restore() {
        if optionHeld {
            store.reset(category: selectedCategory)
        } else {
            store.resetAll()
            onRestoreAll()
        }
    }
}

struct PreferencesSidebar: View {
    @Bindable var model: PreferencesWindowModel

    var body: some View {
        List(model.categories, selection: Binding(
            get: { Optional(model.selectedCategory) },
            set: { if let category = $0 { model.selectedCategory = category } }
        )) { category in
            HStack {
                Label(category.title, systemImage: category.symbolName)
                Spacer()
                Text(PreferencesWindowModel.badge(for: category))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .tag(category)
            .accessibilityIdentifier("pref-sidebar.\(category.rawValue)")
        }
        .listStyle(.sidebar)
    }
}

struct PreferencesDetail: View {
    @Bindable var model: PreferencesWindowModel
    var confirm: @MainActor (String) -> Bool

    var body: some View {
        VStack(spacing: 0) {
            PreferenceCategoryForm(category: model.selectedCategory, store: model.store)
            Divider()
            HStack {
                Spacer()
                Button(model.restoreTitle) {
                    model.confirmAndRestore(confirm)
                }
                .accessibilityIdentifier("pref.restore")
            }
            .padding(12)
        }
        .frame(minWidth: 420, minHeight: 360)
    }
}

/// The Preferences window: a sidebar of categories beside a SwiftUI form per category, in an
/// `NSSplitViewController`.  One per application; `Cmd+,` shows it.
@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("preferences-window")

    let model: PreferencesWindowModel
    private var flagsMonitor: Any?

    init(model: PreferencesWindowModel, confirm: @escaping @MainActor (String) -> Bool = PreferencesWindowController.runConfirmation) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.identifier = Self.identifier
        window.setAccessibilityIdentifier(Self.identifier.rawValue)
        window.title = "Preferences"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false

        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: PreferencesSidebar(model: model)))
        sidebar.minimumThickness = 180
        sidebar.canCollapse = false
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: NSHostingController(rootView: PreferencesDetail(model: model, confirm: confirm))))
        window.contentViewController = split
        window.setContentSize(NSSize(width: 760, height: 540))
        window.setFrameAutosaveName("PreferencesWindow")
        super.init(window: window)
        window.delegate = self
        window.center()
        updateTitle()
        observeSelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreferencesWindowController is built in code")
    }

    static func runConfirmation(_ message: String) -> Bool {
        confirmationAlert(message).runModal() == .alertFirstButtonReturn
    }

    static func confirmationAlert(_ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        startMonitoringOption()
    }

    /// Option held while the window is key turns Restore Defaults into Restore This Category.
    func startMonitoringOption() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.flagsChanged(to: event.modifierFlags)
            return event
        }
    }

    func stopMonitoringOption() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        model.optionHeld = false
    }

    var isMonitoringOption: Bool { flagsMonitor != nil }

    func flagsChanged(to flags: NSEvent.ModifierFlags) {
        model.optionHeld = flags.contains(.option)
    }

    func windowWillClose(_ notification: Notification) {
        stopMonitoringOption()
    }

    private func updateTitle() {
        window?.title = model.selectedCategory.title
    }

    private func observeSelection() {
        withObservationTracking {
            _ = model.selectedCategory
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateTitle()
                self?.observeSelection()
            }
        }
    }
}
