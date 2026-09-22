import SwiftUI

/// Two stand-in panels so the framework is exercised before APP-007 and the LIB epic deliver
/// the real Object and Layers panels (which replace these descriptors by id).
enum PlaceholderPanels {
    static let object = PanelDescriptor(
        id: "object", title: "Object", defaultGroup: "Properties", menuOrder: 10, helpSlug: "object-panel"
    ) {
        PlaceholderPanelBody(title: "Object", detail: "The properties of the selection appear here.")
    }

    static let layers = PanelDescriptor(
        id: "layers", title: "Layers", defaultGroup: "Layers", menuOrder: 20, helpSlug: "layers"
    ) {
        PlaceholderPanelBody(title: "Layers", detail: "The document's layers appear here.")
    }

    static var all: [PanelDescriptor] { [object, layers] }

    @MainActor
    static func register(into registry: PanelRegistry) {
        for descriptor in all { registry.registerIfAbsent(descriptor) }
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
