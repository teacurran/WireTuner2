import AppKit

/// The two *Panels* preferences every group applies live (panels.adoc, "Panel appearance").
struct PanelAppearance: Equatable, Sendable {
    enum LabelStyle: String, Sendable {
        case text
        case icon
        case textAndIcon = "text_and_icon"
    }

    var labelStyle: LabelStyle
    var showsTooltips: Bool

    static let standard = PanelAppearance(labelStyle: .textAndIcon, showsTooltips: true)

    @MainActor
    init(preferences: PreferenceStore) {
        self.init(
            labelStyle: LabelStyle(rawValue: preferences[PreferenceCatalog.Panels.labelStyle]) ?? .textAndIcon,
            showsTooltips: preferences[PreferenceCatalog.Panels.showTooltips]
        )
    }

    init(labelStyle: LabelStyle, showsTooltips: Bool) {
        self.labelStyle = labelStyle
        self.showsTooltips = showsTooltips
    }

    /// Whether a change to preference `id` changes the appearance.
    static func isAppearancePreference(_ id: String) -> Bool {
        id == PreferenceCatalog.Panels.labelStyle.id || id == PreferenceCatalog.Panels.showTooltips.id
    }

    /// The tab's title and image under this style.
    func tabLabel(title: String, icon: String) -> (title: String, image: NSImage?) {
        let image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        switch labelStyle {
        case .text: return (title, nil)
        case .icon: return ("", image)
        case .textAndIcon: return (title, image)
        }
    }
}

/// One entry of a panel's Options menu (panels.adoc, "The Options menu"): the panel's own
/// items, then the tail every panel shares.
enum PanelOption: Equatable, Sendable {
    /// The panel's own item at `index` of its descriptor's `optionsMenu`.
    case custom(index: Int, title: String, isEnabled: Bool)
    /// Group <panel> With ▸ one of the other groups.
    case groupWith(PanelGroup.ID, title: String)
    /// Group <panel> With ▸ New Panel Group.
    case newGroup
    case rename
    case float
    case dock
    case close
    case collapse
    case help(slug: String)

    var title: String {
        switch self {
        case let .custom(_, title, _), let .groupWith(_, title): title
        case .newGroup: "New Panel Group"
        case .rename: "Rename Panel Group…"
        case .float: "Float Group"
        case .dock: "Dock Group"
        case .close: "Close Group"
        case .collapse: "Collapse Group"
        case .help: "Help"
        }
    }

    /// The menu for `panel`: its own items, a separator, then Group With (a submenu),
    /// Rename, Float or Dock, Close (floating) or Collapse (docked), and Help.  Returned as
    /// sections; `groupWith` and `newGroup` entries belong in the submenu.
    @MainActor
    static func menu(for panel: PanelID, layout: PanelLayout, registry: PanelRegistry) -> (custom: [PanelOption], groupWith: [PanelOption], tail: [PanelOption]) {
        let descriptor = registry.descriptor(for: panel)
        let custom = (descriptor?.optionsMenu() ?? []).enumerated().map { PanelOption.custom(index: $0.offset, title: $0.element.title, isEnabled: $0.element.isEnabled) }
        guard let group = layout.group(containing: panel) else { return (custom, [], []) }
        let title = registry.title(for:)
        let others = layout.groups.filter { $0.id != group.id }.map { PanelOption.groupWith($0.id, title: $0.displayName(titles: title)) }
        let floating = layout.edge(of: group.id) == nil
        var tail: [PanelOption] = [.rename, floating ? .dock : .float, floating ? .close : .collapse]
        if let slug = descriptor?.helpSlug { tail.append(.help(slug: slug)) }
        return (custom, others + [.newGroup], tail)
    }

    /// "Group Swatches With", "Help for Swatches".
    static func groupWithTitle(_ panelTitle: String) -> String { "Group \(panelTitle) With" }
    static func helpTitle(_ panelTitle: String) -> String { "Help for \(panelTitle)" }
}

/// Renaming a group from its title bar: kbd:[Return] commits, kbd:[Esc] or clicking elsewhere
/// cancels, an empty name cancels.
enum GroupRename {
    enum Outcome: Equatable {
        case commit(String)
        case cancel
    }

    static func outcome(text: String, committed: Bool) -> Outcome {
        let name = text.trimmingCharacters(in: .whitespaces)
        return committed && !name.isEmpty ? .commit(name) : .cancel
    }
}

/// What a panel drag carries: one panel (a tab) or a whole group (its gripper).
enum PanelDragPayload: Equatable, Sendable {
    case panel(PanelID)
    case group(PanelGroup.ID)

    nonisolated static let panelType = NSPasteboard.PasteboardType("com.villagecompute.wiretuner.panel-id")
    nonisolated static let groupType = NSPasteboard.PasteboardType("com.villagecompute.wiretuner.panel-group")

    static func read(from pasteboard: NSPasteboard) -> PanelDragPayload? {
        if let panel = pasteboard.string(forType: panelType) { return .panel(PanelID(rawValue: panel)) }
        if let group = pasteboard.string(forType: groupType) { return .group(group) }
        return nil
    }

    var pasteboardItem: NSPasteboardItem {
        let item = NSPasteboardItem()
        switch self {
        case let .panel(panel): item.setString(panel.rawValue, forType: Self.panelType)
        case let .group(group): item.setString(group, forType: Self.groupType)
        }
        return item
    }
}
