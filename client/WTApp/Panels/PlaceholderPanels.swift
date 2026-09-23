import SwiftUI

/// Two stand-in panels so the framework is exercised before APP-007 and the LIB epic deliver
/// the real Object and Layers panels (which replace these descriptors by id).
enum PlaceholderPanels {
    static let object = objectPanel(selection: nil)

    /// The Object panel stand-in; with `selection` it publishes the front window's selection
    /// ("3 objects selected"), which is what APP-007's inspector will observe.
    static func objectPanel(selection: ActiveSelection?) -> PanelDescriptor {
        PanelDescriptor(id: "object", title: "Object", icon: "slider.horizontal.3", defaultGroup: "Properties", menuOrder: 10, helpSlug: "object-panel") {
            SelectionSummaryBody(selection: selection)
        }
    }

    static let layers = PanelDescriptor(
        id: "layers", title: "Layers", icon: "square.3.layers.3d", defaultGroup: "Layers", menuOrder: 20, helpSlug: "layers"
    ) {
        PlaceholderPanelBody(title: "Layers", detail: "The document's layers appear here.")
    }

    static var all: [PanelDescriptor] { [object, layers] }

    @MainActor
    static func register(into registry: PanelRegistry, selection: ActiveSelection? = nil) {
        for descriptor in [objectPanel(selection: selection), layers] { registry.registerIfAbsent(descriptor) }
    }
}

/// The Object panel's placeholder body: the selection summary, observed live.
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
