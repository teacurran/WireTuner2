import SwiftUI

/// The Object panel's descriptor and a stand-in Layers panel (the LIB epic's `LayersPanel`
/// replaces it by id).
enum PlaceholderPanels {
    static let object = objectPanel(selection: nil)

    /// The Object panel: the APP-007 inspector host (`ObjectPanelBody`) over `selection`.
    static func objectPanel(selection: ActiveSelection?) -> PanelDescriptor {
        PanelDescriptor(id: "object", title: "Object", icon: "slider.horizontal.3", defaultGroup: "Properties", menuOrder: 10, helpSlug: "object-panel") {
            DocumentUnitsScope(selection: selection) { ObjectPanelBody(selection: selection) }
        }
    }

    static let layers = PanelDescriptor(
        id: "layers", title: "Layers", icon: "square.3.layers.3d", defaultGroup: "Layers", menuOrder: 20, helpSlug: "layers"
    ) {
        PlaceholderPanelBody(title: "Layers", detail: "The document's layers appear here.").panelContextMenu(.layer)
    }

    static var all: [PanelDescriptor] { [object, layers] }

    @MainActor
    static func register(into registry: PanelRegistry, selection: ActiveSelection? = nil) {
        for descriptor in [objectPanel(selection: selection), layers] { registry.registerIfAbsent(descriptor) }
    }
}

/// The Object panel's heading: the selection summary, observed live.
struct SelectionSummaryBody: View {
    let selection: ActiveSelection?

    static let detail = "The properties of the selection appear here."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Object").font(.headline)
            Text(selection?.summary ?? Self.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("object.selection-summary")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct PlaceholderPanelBody: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
