import AppKit
import Observation
import SwiftUI

/// The Customize Toolbars window's state (BASIC-029): the search text and the selected
/// command, which highlights its buttons on every toolbar; a button clicked while the window is
/// open selects its command here.
@MainActor
@Observable
final class CustomizeToolbarsModel {
    struct Group: Identifiable, Equatable {
        let title: String
        let commands: [CommandID]
        var id: String { title }
    }

    static let toolsCategory = "Tools"
    static let unmenuedCategory = "Tools/Commands"

    var query = ""
    var selection: CommandID? {
        didSet { controller.highlighted = selection }
    }
    @ObservationIgnored let controller: ToolbarController

    init(controller: ToolbarController) {
        self.controller = controller
    }

    /// Menu commands under their top-level menu (the menu bar's order), tools under *Tools*,
    /// commands without a menu item under *Tools/Commands*; filtered by the search text.
    static func groups(_ commands: [Command], query: String, menuOrder: [String] = MenuTreeBuilder.standardMenuOrder) -> [Group] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        var order: [String] = []
        var members: [String: [CommandID]] = [:]
        for command in commands where needle.isEmpty || matches(command, needle) {
            let title = category(of: command)
            if members[title] == nil { order.append(title) }
            members[title, default: []].append(command.id)
        }
        let ranked = MenuTreeBuilder.orderedMenuTitles(order, preferring: menuOrder + [toolsCategory, unmenuedCategory])
        return ranked.map { Group(title: $0, commands: members[$0]!) }
    }

    static func category(of command: Command) -> String {
        if let menu = command.menuPath?.menu { return menu }
        return command.id.rawValue.hasPrefix("tool.") ? toolsCategory : unmenuedCategory
    }

    static func matches(_ command: Command, _ needle: String) -> Bool {
        ([command.title] + command.keywords).contains { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    var groups: [Group] { Self.groups(controller.commands.commands, query: query) }

    /// "Text, Tools": the toolbars that show the selected command.
    var selectionPlacement: String {
        guard let selection else { return "" }
        let toolbars = controller.toolbars(showing: selection).map(\.title)
        return toolbars.isEmpty ? "On no toolbar" : "On " + toolbars.joined(separator: ", ")
    }
}

struct CustomizeToolbarsView: View {
    @Bindable var model: CustomizeToolbarsModel
    let done: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drag a command onto a toolbar.  Drag a button off a toolbar to remove it.").font(.callout).foregroundStyle(.secondary)
            TextField("Search", text: $model.query).textFieldStyle(.roundedBorder).accessibilityIdentifier("toolbars.customize.search")
            // Every command: filled over two updates (ListRowGrowth).
            let groups = model.groups
            GrowingRows(count: groups.reduce(0) { $0 + $1.commands.count }) { limit in
                List(selection: $model.selection) {
                    ForEach(ListRowGrowth.prefix(groups, limit: limit, rows: \.commands) { .init(title: $0.title, commands: $1) }) { group in
                        Section(group.title) {
                            ForEach(group.commands, id: \.self) { command in
                                row(command).tag(command)
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("toolbars.customize.commands")
            Text(model.selectionPlacement).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("toolbars.customize.placement")
            HStack {
                Button("Reset Toolbars", action: model.controller.reset).accessibilityIdentifier("toolbars.customize.reset")
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction).accessibilityIdentifier("toolbars.customize.done")
            }
        }
        .padding(12)
        .frame(minWidth: 360, minHeight: 440)
    }

    private func row(_ command: CommandID) -> some View {
        let controller = model.controller
        return HStack {
            Image(systemName: controller.symbol(for: command) ?? "square.dashed").frame(width: 20)
            Text(controller.title(of: command))
        }
        .onDrag(ToolbarDragPayload(command: command, source: nil).itemProvider)
        .accessibilityIdentifier("toolbars.customize.\(command.rawValue)")
    }
}

/// menu:Window[Toolbars > Customize…].  While it is open every toolbar is in edit mode.
@MainActor
final class CustomizeToolbarsWindowController: NSWindowController, NSWindowDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("toolbars.customize")

    let model: CustomizeToolbarsModel

    init(controller: ToolbarController) {
        model = CustomizeToolbarsModel(controller: controller)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 520), styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false
        )
        window.identifier = Self.identifier
        window.title = "Customize Toolbars"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: makeView())
        window.delegate = self
        controller.onSelectCommand = { [weak self] command in self?.model.selection = command }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CustomizeToolbarsWindowController is built in code")
    }

    func makeView() -> CustomizeToolbarsView {
        CustomizeToolbarsView(model: model) { [weak self] in self?.close() }
    }

    func show() {
        model.controller.setCustomizing(true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.controller.setCustomizing(false)
        model.selection = nil
    }
}
