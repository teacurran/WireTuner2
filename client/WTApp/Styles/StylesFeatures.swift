import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// A style dropped on the canvas (styles.adoc, "Applying styles": "Drag the style's preview from
/// the Styles panel onto an object on the canvas"): the object under the pointer takes the style,
/// one change.  A style from another document, or a drop on empty pasteboard, does nothing.
@MainActor
final class StyleCanvasDrop {
    let document: DocumentHandle
    let selection: SelectionController

    init(document: DocumentHandle, selection: SelectionController) {
        self.document = document
        self.selection = selection
    }

    /// Whether `pasteboard` carries a style.
    static func carriesStyle(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [StyleDrag.type]) != nil
    }

    /// The top-level object under `viewPoint`.
    func target(at viewPoint: Point, viewport: Viewport) -> OpID? {
        for hit in selection.hitTester(viewport: viewport, subselect: false).hitTest(viewPoint: viewPoint) {
            if let id = document.selectionID(atItemPath: hit.itemPath) { return id.opID }
        }
        return nil
    }

    /// Applies the dragged style to the object under `viewPoint`; nil when nothing takes it.
    @discardableResult
    func drop(_ pasteboard: NSPasteboard, at viewPoint: Point, viewport: Viewport) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let payload = StyleDrag.read(from: pasteboard), payload.document == document.id, let node = target(at: viewPoint, viewport: viewport) else { return nil }
        return document.perform(ApplyGraphicStyle(payload.style, to: [node], in: document.state))
    }
}

/// The Styles panel in place of the catalog's placeholder (LIB-020).
@MainActor
enum StylesFeatures {
    static func descriptor(model: StylesPanelModel) -> PanelDescriptor {
        PanelDescriptor(id: "styles", title: "Styles", icon: "paintbrush", defaultGroup: PanelCatalog.Group.assets, menuOrder: 31, helpSlug: "styles",
                        optionsMenu: { model.optionsMenu() }) {
            StylesPanelBody(model: model)
        }
    }

    static func install(panels: PanelRegistry, model: StylesPanelModel) {
        _ = panels.registerIfAbsent(descriptor(model: model))
    }
}

extension AppDelegate {
    /// The Styles panel (before `PanelCatalog.register`).
    func installStyles() {
        let model = StylesPanelModel(selection: activeSelection)
        let preferences = preferences
        model.autoApply = { preferences[PreferenceCatalog.Object.autoApplyStyles] }
        StylesFeatures.install(panels: panels, model: model)
    }
}
