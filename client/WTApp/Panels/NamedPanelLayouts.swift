import AppKit
import SwiftUI

/// Named panel layouts on disk (customizing.adoc, "Panel layouts"; BASIC-030): one JSON file per
/// layout under `Application Support/WireTuner/Layouts/<name>.json`, in the format of the
/// current layout's file (`PanelLayoutStore`), and the *Current* arrangement kept while a
/// named one is shown as `.current.json` beside them.
struct NamedLayoutStore: Sendable {
    static let directoryName = "Layouts"
    static let currentFileName = ".current.json"

    let directory: URL

    static var defaultDirectory: URL {
        PanelLayoutStore.defaultURL.deletingLastPathComponent().appending(path: directoryName)
    }

    /// A layout name as a file name: path separators and a leading dot are replaced.
    static func fileName(for name: String) -> String {
        var safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if safe.hasPrefix(".") { safe = "_" + safe.dropFirst() }
        return safe + ".json"
    }

    private func store(_ fileName: String) -> PanelLayoutStore {
        PanelLayoutStore(url: directory.appending(path: fileName))
    }

    /// Saved layout names, sorted.
    func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.map { String($0.dropLast(5)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func load(_ name: String) throws -> PanelLayout? { try store(Self.fileName(for: name)).load() }
    func save(_ layout: PanelLayout, as name: String) throws { try store(Self.fileName(for: name)).save(layout) }

    func delete(_ name: String) throws {
        try FileManager.default.removeItem(at: directory.appending(path: Self.fileName(for: name)))
    }

    func loadCurrent() -> PanelLayout? { try? store(Self.currentFileName).load() }
    func saveCurrent(_ layout: PanelLayout) throws { try store(Self.currentFileName).save(layout) }
}

extension PanelLayout {
    /// Floating groups on a display that is not connected, or off every screen, move onto the
    /// main display (panels.adoc, "Layout persistence").
    mutating func moveFloatingGroups(onto main: LayoutRect, displays: Set<String>, screens: [LayoutRect]) {
        for index in floating.indices {
            let group = floating[index]
            let missingDisplay = group.display.map { !displays.contains($0) } ?? false
            guard missingDisplay || !screens.contains(where: group.frame.intersects) else { continue }
            floating[index].frame.x = main.x + 40
            floating[index].frame.y = main.maxY - group.frame.height - 40
            floating[index].display = nil
        }
    }
}

/// The connected displays, for restoring a layout.
struct DisplayGeometry: Sendable {
    var main: LayoutRect
    var screens: [LayoutRect]
    var displayIDs: Set<String>

    @MainActor
    static func current() -> DisplayGeometry {
        let screens = NSScreen.screens
        func rect(_ screen: NSScreen) -> LayoutRect {
            LayoutRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: screen.frame.height)
        }
        let main = (NSScreen.main ?? screens.first).map(rect) ?? LayoutRect(x: 0, y: 0, width: 1440, height: 900)
        let ids = screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue }
        return DisplayGeometry(main: main, screens: screens.map(rect), displayIDs: Set(ids))
    }
}

/// Saving, switching, updating and deleting named layouts, and the menu:Window[Panel Layout]
/// items for them.  Switching away from an arrangement keeps it as *Current*, so switching back
/// loses nothing.
@MainActor
final class NamedLayoutController {
    enum ID {
        static let save: CommandID = "panels.layout.save"
        static let manage: CommandID = "panels.layout.manage"
        static let current: CommandID = "panels.layout.current"
        static func named(_ name: String) -> CommandID { CommandID("panels.layout.named.\(name)") }
    }

    static let currentTitle = "Current"

    let layout: PanelLayoutController
    let store: NamedLayoutStore
    let commands: CommandRegistry
    var displays: @MainActor () -> DisplayGeometry = { DisplayGeometry.current() }
    /// Asks for a name, offering the saved ones (picking one updates it); nil cancels.
    var askName: @MainActor ([String]) -> String? = NamedLayoutController.runNameAlert
    /// The menu bar must be rebuilt (a layout was added or deleted).
    var onMenuChange: @MainActor () -> Void = {}
    /// The named layout shown; nil while *Current* is.
    private(set) var activeName: String?
    private(set) var names: [String] = []
    private(set) var lastError: (any Error)?
    private var manageWindow: NSWindow?

    init(layout: PanelLayoutController, store: NamedLayoutStore, commands: CommandRegistry) {
        self.layout = layout
        self.store = store
        self.commands = commands
        names = store.names()
    }

    // MARK: Operations

    /// Save Layout…: the current arrangement under `name` (an existing name is updated).
    @discardableResult
    func save(as name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != Self.currentTitle else { return false }
        attempt { try store.save(layout.layout, as: trimmed) }
        activeName = trimmed
        refresh()
        return true
    }

    /// Asks for a name and saves; returns the name saved.
    @discardableResult
    func saveWithPrompt() -> String? {
        guard let name = askName(names), save(as: name) else { return nil }
        return name
    }

    /// Shows the named layout; the arrangement left behind becomes *Current*.
    func apply(_ name: String) {
        guard name != activeName, let loaded = attemptLoad(name) else { return }
        if activeName == nil { attempt { try store.saveCurrent(layout.layout) } }
        show(loaded)
        activeName = name
    }

    /// Back to *Current*.
    func applyCurrent() {
        guard activeName != nil, let current = store.loadCurrent() else { return }
        show(current)
        activeName = nil
    }

    func delete(_ name: String) {
        attempt { try store.delete(name) }
        if activeName == name { activeName = nil }
        refresh()
    }

    private func show(_ loaded: PanelLayout) {
        let displays = displays()
        var next = loaded
        next.moveFloatingGroups(onto: displays.main, displays: displays.displayIDs, screens: displays.screens)
        layout.update { $0 = next }
        layout.addRegisteredPanels()
    }

    private func attemptLoad(_ name: String) -> PanelLayout? {
        do {
            return try store.load(name)
        } catch {
            lastError = error
            return nil
        }
    }

    private func attempt(_ work: () throws -> Void) {
        do {
            try work()
            lastError = nil
        } catch {
            lastError = error
        }
    }

    // MARK: Menu

    /// Re-reads the directory and rebuilds the menu items: Save Layout…, Manage Layouts…,
    /// Current, the saved layouts, then Reset to Default (moved after them).
    func refresh() {
        names = store.names()
        let stale = Set(commands.ids.filter { $0.rawValue.hasPrefix("panels.layout.named.") }).union([ID.current, PanelCommands.ID.resetLayout])
        let reset = commands.command(PanelCommands.ID.resetLayout)
        commands.remove(stale)
        commands.registerIfAbsent(command(ID.save, "Save Layout…") { [weak self] in self?.saveWithPrompt() })
        commands.registerIfAbsent(command(ID.manage, "Manage Layouts…") { [weak self] in self?.showManage() })
        commands.registerIfAbsent(command(ID.current, Self.currentTitle, subsection: 1, checked: { [weak self] in self?.activeName == nil }) { [weak self] in self?.applyCurrent() })
        for name in names {
            commands.registerIfAbsent(command(ID.named(name), name, subsection: 1, checked: { [weak self] in self?.activeName == name }) { [weak self] in self?.apply(name) })
        }
        if let reset { commands.registerIfAbsent(reset) }
        onMenuChange()
    }

    private func command(
        _ id: CommandID, _ title: String, subsection: Int = 0, checked: (@MainActor @Sendable () -> Bool)? = nil,
        run: @escaping @MainActor @Sendable () -> Void
    ) -> Command {
        Command(
            id: id, title: title,
            menu: MenuPath(StandardCommands.Menu.window, PanelCommands.layoutSubmenu, section: StandardCommands.Section.windowLayout, subsection: subsection),
            keywords: ["panel", "layout"],
            validation: { .checked(checked?() ?? false) },
            action: .perform(run)
        )
    }

    // MARK: UI

    static func runNameAlert(_ existing: [String]) -> String? {
        let alert = nameAlert(existing)
        guard alert.runModal() == .alertFirstButtonReturn, let field = alert.accessoryView as? NSComboBox else { return nil }
        return field.stringValue
    }

    static func nameAlert(_ existing: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Save Layout"
        alert.informativeText = "Name the arrangement of panels.  Choose an existing name to update that layout."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.addItems(withObjectValues: existing)
        field.setAccessibilityIdentifier("panels.layout.name")
        alert.accessoryView = field
        return alert
    }

    /// Manage Layouts…: the saved layouts with Delete.
    @discardableResult
    func showManage() -> NSWindow {
        let window = manageWindow ?? NSWindow(contentViewController: NSHostingController(rootView: ManageLayoutsView(controller: self)))
        window.identifier = NSUserInterfaceItemIdentifier("panels.layout.manage")
        window.title = "Manage Layouts"
        window.isReleasedWhenClosed = false
        manageWindow = window
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

struct ManageLayoutsView: View {
    let controller: NamedLayoutController
    @State private var names: [String]
    @State private var selection: String?

    init(controller: NamedLayoutController, selection: String? = nil) {
        self.controller = controller
        _names = State(initialValue: controller.names)
        _selection = State(initialValue: selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(names, id: \.self, selection: $selection) { name in
                Text(name).accessibilityIdentifier("panels.layout.manage.\(name)")
            }
            HStack {
                Button("Delete", action: deleteSelection).disabled(selection == nil).accessibilityIdentifier("panels.layout.manage.delete")
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 300, height: 280)
    }

    func deleteSelection() {
        guard let selection else { return }
        controller.delete(selection)
        names = controller.names
        self.selection = nil
    }
}
