import Foundation

/// One row of the command palette (customizing.adoc, "Command palette"): something the palette
/// can run -- a command, a tool, a panel, a page, a layer, a named view, a recent document.
struct PaletteItem: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case command, tool, panel, page, layer, view, document
    }

    /// Stable across launches: the history file refers to it.
    let id: String
    let title: String
    let subtitle: String
    let kind: Kind
    let symbolName: String?
    let shortcut: KeyEquivalent?
    let isEnabled: Bool
    /// Why the item cannot run now; the row shows it in place of the subtitle.
    let reason: String?
    let run: @MainActor @Sendable () -> Void

    init(
        id: String, title: String, subtitle: String = "", kind: Kind, symbolName: String? = nil, shortcut: KeyEquivalent? = nil,
        isEnabled: Bool = true, reason: String? = nil, run: @escaping @MainActor @Sendable () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.symbolName = symbolName
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.reason = reason
        self.run = run
    }

    /// What the row shows under the title: the reason when disabled.
    var detail: String { isEnabled ? subtitle : (reason ?? subtitle) }

    /// VoiceOver: title, shortcut, and the enabled state with its reason.
    var accessibilityLabel: String {
        var parts = [title]
        if let shortcut { parts.append(shortcut.displayString) }
        parts.append(isEnabled ? "enabled" : "dimmed, \(reason ?? "not available")")
        return parts.joined(separator: ", ")
    }
}

/// Something that lists palette items.  Sources register with the palette from their own epics
/// (pages, layers, named views, recent documents); the palette never imports their models.
@MainActor
protocol PaletteSource {
    func items() -> [PaletteItem]
}

/// A source from a closure (the registration API's common case).
struct ClosurePaletteSource: PaletteSource {
    let make: @MainActor () -> [PaletteItem]

    func items() -> [PaletteItem] { make() }
}

/// Every registered command, tools included: the subtitle is the menu path, the shortcut comes
/// from the active set, and disabled commands carry the registry's validation reason.  Panel
/// items come from `PanelPaletteSource` ("Show Swatches"), so the Window menu's panel toggles
/// are skipped here, as is the palette's own command.
struct CommandPaletteSource: PaletteSource {
    let registry: CommandRegistry
    let shortcuts: @MainActor () -> ShortcutSet
    /// Runs a command exactly as its menu item would.
    let perform: @MainActor @Sendable (CommandID) -> Void

    static let panelCommandPrefix = "panel.show."

    func items() -> [PaletteItem] {
        let set = shortcuts()
        return registry.commands.compactMap { command in
            let raw = command.id.rawValue
            guard !raw.hasPrefix(Self.panelCommandPrefix), command.id != StandardCommands.ID.commandPalette else { return nil }
            let validation = command.validation()
            let isTool = raw.hasPrefix("tool.")
            let perform = perform
            let id = command.id
            return PaletteItem(
                id: raw, title: validation.title ?? command.title,
                subtitle: command.menuPath.map { $0.components.joined(separator: " > ") } ?? (isTool ? "Tool" : ShortcutCategories.menuless),
                kind: isTool ? .tool : .command, symbolName: isTool ? "wrench.and.screwdriver" : "command",
                shortcut: set.keyEquivalent(for: command.id), isEnabled: validation.isEnabled, reason: validation.reason,
                run: { perform(id) }
            )
        }
    }
}

/// "Show Swatches": every registered panel, brought to the front.
struct PanelPaletteSource: PaletteSource {
    let panels: PanelRegistry
    let show: @MainActor @Sendable (PanelID) -> Void

    func items() -> [PaletteItem] {
        panels.descriptors.map { descriptor in
            let id = descriptor.id
            let show = show
            return PaletteItem(
                id: "panel.\(id.rawValue)", title: "Show \(descriptor.title)", subtitle: "Panel", kind: .panel,
                symbolName: descriptor.icon, run: { show(id) }
            )
        }
    }
}

/// "Go to Page 3": the pages of the front document.
struct PagePaletteSource: PaletteSource {
    let document: @MainActor () -> DocumentHandle?
    let goToPage: @MainActor @Sendable (Int) -> Void

    func items() -> [PaletteItem] {
        guard let document = document() else { return [] }
        let goToPage = goToPage
        return document.pages.indices.map { index in
            PaletteItem(
                id: "page.\(index)", title: "Go to \(PageSelection.name(of: index))", subtitle: document.title, kind: .page,
                symbolName: "doc", run: { goToPage(index) }
            )
        }
    }
}
