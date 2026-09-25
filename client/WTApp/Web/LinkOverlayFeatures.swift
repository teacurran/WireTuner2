import AppKit
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTRender

/// menu:View[Show Links] (urls.adoc, "Showing links"; WEB-004's app half): per window, a tint over
/// every linked object and an underline under every linked run of text, drawn in the window's
/// furniture layer from `LinkOverlayReading` -- never in the display list, so toggling it redraws
/// no tile and it cannot reach print or an export -- and, while it is on, a tooltip with the URL
/// under the pointer.  Window state, not the document's.
@MainActor
final class LinkOverlayFeatures {
    static let id: CommandID = "view.showLinks"
    static let noDocument = "No document is open"

    /// One window's overlay.
    final class WindowLinks {
        weak var window: DocumentWindowController?
        var shown = false
        /// The overlay as last read; nil when the document changed since.
        var overlay: LinkOverlay?
        var observation: DocumentHandle.ObservationToken?

        init(window: DocumentWindowController) {
            self.window = window
        }
    }

    let window: @MainActor () -> DocumentWindowController?
    /// The window's link index (the web features keep it up to date).
    var index: @MainActor (DocumentWindowController) -> LinkIndex = { LinkIndex($0.documentHandle.state) }
    private var windows: [ObjectIdentifier: WindowLinks] = [:]

    init(window: @escaping @MainActor () -> DocumentWindowController?) {
        self.window = window
    }

    func links(_ window: DocumentWindowController) -> WindowLinks? { windows[ObjectIdentifier(window)] }

    func isShown(_ window: DocumentWindowController) -> Bool { links(window)?.shown ?? false }

    /// Hooks `window`'s furniture layer and pointer; nothing shows until it is turned on.
    @discardableResult
    func attach(_ window: DocumentWindowController) -> WindowLinks {
        if let existing = links(window) { return existing }
        let entry = WindowLinks(window: window)
        windows[ObjectIdentifier(window)] = entry
        let canvas = window.canvas
        let previousDrawer = canvas.furnitureDrawer
        canvas.furnitureDrawer = { [weak self, weak window] ctx in
            previousDrawer?(ctx)
            if let window { self?.draw(in: ctx, window: window) }
        }
        let previousPointer = canvas.onPointer
        canvas.onPointer = { [weak self, weak window] point in
            previousPointer?(point)
            if let window { self?.hover(point, window: window) }
        }
        entry.observation = window.documentHandle.observe { [weak self, weak entry] _ in
            guard let entry, entry.shown, let window = entry.window else { return }
            self?.refresh(window)
        }
        return entry
    }

    /// The window's overlay now (read again after a change).
    func overlay(_ window: DocumentWindowController) -> LinkOverlay {
        let entry = attach(window)
        if let overlay = entry.overlay { return overlay }
        let document = window.documentHandle
        let overlay = LinkOverlayReading.overlay(scene: document.scene, index: index(window),
                                                 textLinks: ExportSnapshot.textLinks(document.state, engine: document.textEngine))
        entry.overlay = overlay
        return overlay
    }

    /// The document changed: the marks are read again, and the layer repaints when they moved.
    func refresh(_ window: DocumentWindowController) {
        guard let entry = links(window) else { return }
        let old = entry.overlay
        entry.overlay = nil
        let new = overlay(window)
        if old != new { window.canvas.setNeedsFurnitureDisplay() }
    }

    /// menu:View[Show Links].
    func toggle(_ window: DocumentWindowController) {
        let entry = attach(window)
        entry.shown.toggle()
        entry.overlay = nil
        if !entry.shown { window.canvas.toolTip = nil }
        window.canvas.setNeedsFurnitureDisplay()
    }

    func draw(in ctx: CGContext, window: DocumentWindowController) {
        guard isShown(window) else { return }
        overlay(window).draw(in: ctx, viewport: window.canvas.viewport)
    }

    /// The tooltip: the URL under the pointer while the overlay is on.
    func hover(_ point: Point?, window: DocumentWindowController) {
        guard isShown(window) else { return }
        let tolerance = 3 / max(window.canvas.viewport.zoom, 0.0001)
        let url = point.flatMap { overlay(window).url(at: $0, tolerance: tolerance) }
        if window.canvas.toolTip != url { window.canvas.toolTip = url }
    }

    func command() -> Command {
        let window = window
        return Command(id: Self.id, title: "Show Links", menu: MenuPath(StandardCommands.Menu.view, section: StandardCommands.Section.viewBrowser),
                       keywords: ["links", "url", "web", "overlay"],
                       validation: { window().map { .checked(self.isShown($0)) } ?? .disabled(Self.noDocument) },
                       action: .perform { if let window = window() { self.toggle(window) } })
    }

    func install(commands registry: CommandRegistry) {
        registry.replace(command())
    }
}
