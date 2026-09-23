import Foundation

/// The result of asking a command whether it can run right now.  Menus disable the item and
/// show `reason` as a tooltip; the command palette lists disabled commands greyed with the
/// reason; `isChecked` draws the check mark; `title` overrides the static title ("Undo Move").
struct CommandValidation: Equatable, Sendable {
    var isEnabled: Bool
    var reason: String?
    var isChecked: Bool
    var title: String?

    init(isEnabled: Bool = true, reason: String? = nil, isChecked: Bool = false, title: String? = nil) {
        self.isEnabled = isEnabled
        self.reason = reason
        self.isChecked = isChecked
        self.title = title
    }

    static let enabled = CommandValidation()

    static func disabled(_ reason: String) -> CommandValidation {
        CommandValidation(isEnabled: false, reason: reason)
    }

    static func checked(_ isChecked: Bool) -> CommandValidation {
        CommandValidation(isChecked: isChecked)
    }
}

/// What running a command does.
enum CommandAction: Sendable {
    /// Runs in the app after validation.
    case perform(@MainActor @Sendable () -> Void)
    /// Sent down the responder chain by selector name (`"cut:"`).  AppKit validates and
    /// performs it, so text fields, the canvas and the window all get their standard behavior.
    case responder(String)

    var responderSelectorName: String? {
        if case let .responder(name) = self { return name }
        return nil
    }
}

/// Where a command lives in the menu bar.  `components` is the path of titles from the
/// top-level menu (`["View", "Magnification"]`); `section` groups the entries of the top-level
/// menu (an item, or the submenu the command is in), and `subsection` groups the items inside
/// the command's submenu.  Sections are separated by a line; within a section commands keep
/// registration order.
struct MenuPath: Hashable, Sendable, Codable {
    var components: [String]
    var section: Int
    var subsection: Int

    init(_ components: String..., section: Int = 0, subsection: Int = 0) {
        self.components = components
        self.section = section
        self.subsection = subsection
    }

    init(components: [String], section: Int, subsection: Int = 0) {
        self.components = components
        self.section = section
        self.subsection = subsection
    }

    enum CodingKeys: String, CodingKey {
        case components, section, subsection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        components = try container.decode([String].self, forKey: .components)
        section = try container.decode(Int.self, forKey: .section)
        subsection = try container.decodeIfPresent(Int.self, forKey: .subsection) ?? 0
    }

    /// The top-level menu title.
    var menu: String { components[0] }

    /// The grouping at `depth` (1 is the top-level menu's own entries).
    func section(atDepth depth: Int) -> Int { depth <= 1 ? section : subsection }
}

/// The situations a context menu can be opened in (Context menus page, BASIC-018).  A command
/// with a non-empty set appears in the context menu of those targets.
enum MenuContext: String, Hashable, Sendable, Codable, CaseIterable {
    case path, text, bitmap, importedGraphic, group, blend, clip, connector, symbolInstance, chart, envelope
    case multiple, pasteboard, page, guide, presence, swatch, layer, style, symbol, tint
    case pageThumbnail, tab, panelTab, textEditing
    /// The Swatches panel's empty area and the Color Mixer or Tints panel's color box.
    case swatchesArea, colorBox
}

/// One entry in the command registry: everything the menu bar, the shortcut editor, context
/// menus and the palette need to know about a command.
struct Command: Sendable, Identifiable {
    let id: CommandID
    var title: String
    /// The binding in the built-in default shortcut set; `nil` for an unbound command.
    var defaultKey: KeyEquivalent?
    /// More keys the default set binds (a tool's digit beside its letter); never in the menu.
    var alternateKeys: [KeyEquivalent]
    /// `nil` for commands with no menu item (tools, palette-only commands).
    var menuPath: MenuPath?
    var contexts: Set<MenuContext>
    /// Extra words the palette matches besides the title.
    var keywords: [String]
    var validation: @MainActor @Sendable () -> CommandValidation
    var action: CommandAction

    init(
        id: CommandID,
        title: String,
        key: KeyEquivalent? = nil,
        alternateKeys: [KeyEquivalent] = [],
        menu: MenuPath? = nil,
        contexts: Set<MenuContext> = [],
        keywords: [String] = [],
        validation: @escaping @MainActor @Sendable () -> CommandValidation = { .enabled },
        action: CommandAction
    ) {
        self.id = id
        self.title = title
        self.defaultKey = key
        self.alternateKeys = alternateKeys
        self.menuPath = menu
        self.contexts = contexts
        self.keywords = keywords
        self.validation = validation
        self.action = action
    }

    /// The single shared no-op every placeholder runs.
    static let noop: @MainActor @Sendable () -> Void = {}

    static let placeholderReason = "Not available yet"

    /// A menu item for a feature a later task delivers: it shows in the menu with its default
    /// shortcut, disabled with a reason, and does nothing if run.
    static func placeholder(
        id: CommandID, title: String, key: KeyEquivalent? = nil, menu: MenuPath? = nil,
        contexts: Set<MenuContext> = [], keywords: [String] = []
    ) -> Command {
        Command(
            id: id, title: title, key: key, menu: menu, contexts: contexts, keywords: keywords,
            validation: { .disabled(placeholderReason) }, action: .perform(noop)
        )
    }

    /// A standard AppKit command that the responder chain validates and performs.
    static func responder(
        id: CommandID, title: String, key: KeyEquivalent? = nil, menu: MenuPath? = nil,
        contexts: Set<MenuContext> = [], keywords: [String] = [], selector: String
    ) -> Command {
        Command(
            id: id, title: title, key: key, menu: menu, contexts: contexts, keywords: keywords,
            action: .responder(selector)
        )
    }
}
