import AppKit
import SwiftUI

/// *What's here* (panels.adoc, "The Help panel"; BASIC-007): when the pointer rests for a second
/// over a tool or a panel, the Help panel names it with a link to its page.  The view under the
/// pointer is found through accessibility (`accessibilityHitTest`), and its identifier -- the
/// conventions of the tool buttons (`tool.<id>`) and panels (`panel.<id>`) -- maps to the help
/// slug their descriptors carry.
@MainActor
final class HelpHover {
    static let delay: Duration = .seconds(1)

    let tools: ToolRegistry
    let panels: PanelRegistry
    let model: HelpBrowserModel
    var delay: Duration = HelpHover.delay
    private var pending: Task<Void, Never>?
    private var monitor: Any?

    init(tools: ToolRegistry, panels: PanelRegistry, model: HelpBrowserModel) {
        self.tools = tools
        self.panels = panels
        self.model = model
    }

    /// The name and page an accessibility identifier stands for.
    func resolve(_ identifier: String) -> (title: String, slug: String)? {
        if identifier.hasPrefix("panel."), let descriptor = panels.descriptor(for: PanelID(String(identifier.dropFirst(6)))), let slug = descriptor.helpSlug {
            return (descriptor.title, slug)
        }
        let base = identifier.hasSuffix(".flyout") ? String(identifier.dropLast(7)) : identifier
        if let tool = tools.descriptors.first(where: { $0.commandID.rawValue == base }) {
            return (tool.title, tool.helpSlug)
        }
        return nil
    }

    /// The first identifier that resolves, from the element under `point` (window coordinates)
    /// up through its accessibility parents.
    func identify(at point: NSPoint, in window: NSWindow) -> (title: String, slug: String)? {
        // AppKit views first (their identifiers are on the views), then accessibility (SwiftUI's).
        var view = window.contentView.flatMap { $0.hitTest($0.convert(point, from: nil)) }
        while let current = view {
            if let found = resolve(current.accessibilityIdentifier()) { return found }
            view = current.superview
        }
        var element: Any? = window.contentView?.accessibilityHitTest(window.convertPoint(toScreen: point))
        var depth = 0
        while let current = element as? NSAccessibilityElementProtocol & NSObjectProtocol, depth < 20 {
            if let identifier = (current as? NSAccessibilityProtocol)?.accessibilityIdentifier(), !identifier.isEmpty, let found = resolve(identifier) {
                return found
            }
            element = (current as? NSAccessibilityProtocol)?.accessibilityParent()
            depth += 1
        }
        return nil
    }

    /// The pointer moved in `window` to `point`: after the delay without another move, what is
    /// there is named.
    func pointerMoved(to point: NSPoint, in window: NSWindow?) {
        pending?.cancel()
        guard let window else { return }
        let delay = delay
        pending = Task { [weak self, weak window] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let window, let found = self.identify(at: point, in: window) else { return }
            self.model.setHover(found.title, slug: found.slug)
        }
    }

    /// Waits for the hover in flight (tests).
    func settle() async { await pending?.value }

    /// Watches mouse moves in the app's windows.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.pointerMoved(to: event.locationInWindow, in: event.window)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pending?.cancel()
    }
}

/// The Help panel's registration, replacing the catalog's placeholder body.
@MainActor
enum HelpFeatures {
    /// Each app delegate's hover watcher.
    static var hovers: [ObjectIdentifier: HelpHover] = [:]

    static func descriptor(help: HelpPanelModel, browser: HelpBrowserModel) -> PanelDescriptor {
        PanelDescriptor(id: "help", title: "Help", icon: "questionmark.circle", defaultGroup: PanelCatalog.Group.help, menuOrder: 90, helpSlug: "panels") {
            HelpBrowserView(model: browser, help: help)
        }
    }
}
