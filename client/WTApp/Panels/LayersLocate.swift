import AppKit
import WTCRDT
import WTGeometry
import WTModel

/// menu:Object[Locate Object] (layers.adoc, "Finding an object's row"; LIB-031): shows the
/// Layers panel, opens the layer and groups above the first selected object and scrolls its row
/// to the middle of the list; the canvas scrolls to the object when it is out of view.  Also in
/// every object's context menu and the panel's options menu.
@MainActor
enum LayersLocate {
    static let id = ContextMenuCatalog.ID.locateObject
    static let noDocument = ViewCommands.noDocument
    static let noObject = "Select an object"

    static func command(window: @escaping @MainActor () -> DocumentWindowController?, state: LayersPanelState,
                        showPanel: @escaping @MainActor (PanelID) -> Void) -> Command {
        Command(id: id, title: "Locate Object", menu: MenuPath(ContextMenuCatalog.Menu.object, section: 1), contexts: ContextMenuCatalog.objectContexts,
                keywords: ["layers", "find", "reveal", "show in layers"],
                validation: {
                    guard let front = window() else { return .disabled(noDocument) }
                    return front.objectEditing.selectedNodes.isEmpty ? .disabled(noObject) : .enabled
                },
                action: .perform {
                    guard let front = window(), !front.objectEditing.selectedNodes.isEmpty else { return }
                    showPanel("layers")
                    state.requestLocate()
                })
    }

    /// Scrolls `window`'s canvas to the first selected object when none of it is in view, on its
    /// page.  Whether it scrolled.
    @discardableResult
    static func revealOnCanvas(_ window: DocumentWindowController) -> Bool {
        let document = window.documentHandle
        guard let node = window.objectEditing.selectedNodes.first, let bounds = document.object(for: SelectionID(node))?.bounds else { return false }
        let canvas = window.canvas
        guard !canvas.viewport.visiblePasteboardBounds.intersects(bounds) else { return false }
        let center = Point(x: bounds.midX, y: bounds.midY)
        if let page = document.pageList.page(containing: center), page.id != document.activePage.id {
            document.selectPage(id: page.id)
        }
        canvas.setViewport(canvas.navigation.centring(canvas.viewport, on: center))
        return true
    }
}

extension AppDelegate {
    /// The Layers panel's command and hooks (LIB-031): *Locate Object*, the canvas half of
    /// locating, and the colour space a plain colour dropped on a row is read in.
    func installLayersPanelCommands() {
        let documents = documents!
        let window: @MainActor () -> DocumentWindowController? = { documents.activeWindowController }
        let layout = layout
        let preferences = preferences
        layersPanel.revealOnCanvas = { if let front = window() { LayersLocate.revealOnCanvas(front) } }
        layersPanel.defaultColorSpace = { preferences[PreferenceCatalog.Colors.defaultColorSpace] == "srgb" ? .sRGB : .displayP3 }
        commands.replace(LayersLocate.command(window: window, state: layersPanel) { layout.showPanel($0) })
    }
}
