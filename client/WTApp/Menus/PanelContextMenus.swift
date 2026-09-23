import SwiftUI

/// Panel context menus (context-menus.adoc, "Panel menus"; BASIC-019).  A panel's rows and
/// empty areas show the commands the owning panel registered with the row's `MenuContext`,
/// built by the same `ContextMenuBuilder` as the canvas menus.  The app installs `nodes` and
/// `perform`; panel bodies attach `panelContextMenu(_:)`.
@MainActor
enum PanelContextMenus {
    /// The menu for a context; nil until the app installs it.
    static var nodes: (@MainActor (MenuContext) -> [MenuNode])?
    /// Runs a command as the menu bar would.
    static var perform: (@MainActor (CommandID) -> Void)?

    /// The context of each placeholder panel's body until the panels' epics give their rows
    /// their own (a page thumbnail, the swatch area, the colour box, a tint, a layer, a style, a
    /// symbol).
    static let bodyContexts: [PanelID: MenuContext] = [
        "document": .pageThumbnail, "swatches": .swatchesArea, "colorMixer": .colorBox, "tints": .tint,
        "layers": .layer, "styles": .style, "library": .symbol,
    ]

    static func menu(for context: MenuContext) -> [MenuNode] {
        nodes?(context) ?? []
    }
}

/// Renders menu nodes as SwiftUI menu content.
struct ContextMenuContent: View {
    let nodes: [MenuNode]

    var body: some View {
        ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
            ContextMenuNodeView(node: node)
        }
    }
}

struct ContextMenuNodeView: View {
    let node: MenuNode

    var body: some View {
        switch node {
        case .separator:
            Divider()
        case let .item(item):
            Button(item.title) { PanelContextMenus.perform?(item.commandID) }
                .accessibilityIdentifier(MainMenuBuilder.accessibilityIdentifier(for: item.commandID))
        case let .submenu(title, items):
            Menu(title) { ContextMenuContent(nodes: items) }
        }
    }
}

extension View {
    /// The context menu of a panel row or area for `context`.
    func panelContextMenu(_ context: MenuContext?) -> some View {
        contextMenu {
            if let context { ContextMenuContent(nodes: PanelContextMenus.menu(for: context)) }
        }
    }
}
