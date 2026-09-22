import AppKit
import SwiftUI

/// Everything the framework needs to show a panel.  Registering one is the only step a feature
/// performs; the framework adds the Window menu item, the tab and the layout entry.
struct PanelDescriptor: Identifiable, Sendable {
    let id: PanelID
    var title: String
    /// The group the panel joins in the default layout; groups are named after this.
    var defaultGroup: String
    /// Position in the Window menu (ties keep registration order).
    var menuOrder: Int
    /// The guide page the panel's help button opens.
    var helpSlug: String?
    /// Creates the panel's view.  Called once per panel per dock; the view is reused.
    var makeView: @MainActor @Sendable () -> NSView

    init(
        id: PanelID, title: String, defaultGroup: String, menuOrder: Int = 0, helpSlug: String? = nil,
        view: @escaping @MainActor @Sendable () -> NSView
    ) {
        self.id = id
        self.title = title
        self.defaultGroup = defaultGroup
        self.menuOrder = menuOrder
        self.helpSlug = helpSlug
        self.makeView = view
    }

    /// A panel whose body is SwiftUI, hosted in an `NSHostingView`.
    init<Body: View>(
        id: PanelID, title: String, defaultGroup: String, menuOrder: Int = 0, helpSlug: String? = nil,
        body: @escaping @MainActor @Sendable () -> Body
    ) {
        self.init(id: id, title: title, defaultGroup: defaultGroup, menuOrder: menuOrder, helpSlug: helpSlug) {
            let hosting = NSHostingView(rootView: body())
            hosting.setAccessibilityIdentifier("panel.\(id.rawValue)")
            return hosting
        }
    }
}
