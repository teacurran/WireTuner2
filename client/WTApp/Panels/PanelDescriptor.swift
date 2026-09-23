import AppKit
import SwiftUI

/// One panel-specific item at the top of a panel's Options menu (*New Swatch* in Swatches).
struct PanelMenuItem: Sendable {
    var title: String
    var isEnabled: Bool = true
    var action: @MainActor @Sendable () -> Void
}

/// Everything the framework needs to show a panel (panels.adoc, "Client": `PanelDescriptor`).
/// Registering one is the only step a feature performs; the framework adds the Window menu
/// item, the tab, the layout entry, the Options menu tail and the Help link.
struct PanelDescriptor: Identifiable, Sendable {
    let id: PanelID
    var title: String
    /// SF Symbol for the tab (*Label panel tabs with* Icon).
    var icon: String = "square.dashed"
    /// The panel-specific top of the Options menu, asked for each time the menu opens.
    var optionsMenu: @MainActor @Sendable () -> [PanelMenuItem] = { [] }
    /// The group the panel joins in the default layout; groups are named after this.
    var defaultGroup: String
    /// Position in the Window menu (ties keep registration order).
    var menuOrder: Int
    /// The guide page the panel's help button opens.
    var helpSlug: String?
    /// False for the dockable toolbars (BASIC-011): they are listed under
    /// menu:Window[Toolbars], not with the panels.
    var showsInWindowMenu = true
    /// Creates the panel's view.  Called once per panel per dock; the view is reused.
    var makeView: @MainActor @Sendable () -> NSView

    init(
        id: PanelID, title: String, icon: String = "square.dashed", defaultGroup: String, menuOrder: Int = 0, helpSlug: String? = nil,
        optionsMenu: @escaping @MainActor @Sendable () -> [PanelMenuItem] = { [] },
        view: @escaping @MainActor @Sendable () -> NSView
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.optionsMenu = optionsMenu
        self.defaultGroup = defaultGroup
        self.menuOrder = menuOrder
        self.helpSlug = helpSlug
        self.makeView = view
    }

    /// A panel whose body is SwiftUI, hosted in an `NSHostingView`.
    init<Body: View>(
        id: PanelID, title: String, icon: String = "square.dashed", defaultGroup: String, menuOrder: Int = 0, helpSlug: String? = nil,
        optionsMenu: @escaping @MainActor @Sendable () -> [PanelMenuItem] = { [] },
        body: @escaping @MainActor @Sendable () -> Body
    ) {
        self.init(id: id, title: title, icon: icon, defaultGroup: defaultGroup, menuOrder: menuOrder, helpSlug: helpSlug, optionsMenu: optionsMenu) {
            let hosting = NSHostingView(rootView: body())
            hosting.setAccessibilityIdentifier("panel.\(id.rawValue)")
            return hosting
        }
    }
}
