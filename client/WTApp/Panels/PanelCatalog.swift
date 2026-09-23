import Observation
import SwiftUI

/// What the Help panel is showing: the guide page a *Help for <panel>* item asked for.
/// BASIC-007 replaces the placeholder body with the bundled guide.
@MainActor
@Observable
final class HelpPanelModel {
    private(set) var slug: String?
    private(set) var topic: String?

    init() {}

    func show(slug: String, topic: String) {
        self.slug = slug
        self.topic = topic
    }
}

/// Every panel WireTuner has (panels.adoc, "The panels"), with its default group, Window menu
/// order, tab icon and help page, and the default layout (panels.adoc, "The default layout").
/// Panels whose epic has not landed register a placeholder body; the epic replaces the
/// descriptor by id (`PanelRegistry.replace`).
enum PanelCatalog {
    enum Group {
        static let tools = "Tools"
        static let properties = "Properties"
        static let assets = "Assets"
        static let mixer = "Mixer and Tints"
        static let alignTransform = "Align and Transform"
        static let findSelect = "Find & Replace and Select"
        static let layers = "Layers"
        static let help = "Help"
        static let navigation = "Navigation"
        static let halftones = "Halftones"
    }

    /// Properties expanded, Assets and Mixer and Tints collapsed, Layers open, Help collapsed;
    /// Align and Transform, Find & Replace and Select, Navigation and Halftones closed; the
    /// Tools panel at the left edge.
    static let groupDefaults: [String: PanelGroupDefaults] = [
        Group.tools: PanelGroupDefaults(position: 0, keepsName: true, edge: .left),
        Group.properties: PanelGroupDefaults(position: 1, keepsName: true),
        Group.assets: PanelGroupDefaults(position: 2, isCollapsed: true, keepsName: true),
        Group.mixer: PanelGroupDefaults(position: 3, isCollapsed: true),
        Group.alignTransform: PanelGroupDefaults(position: 4, isOpen: false),
        Group.findSelect: PanelGroupDefaults(position: 5, isOpen: false),
        Group.layers: PanelGroupDefaults(position: 6),
        Group.help: PanelGroupDefaults(position: 7, isCollapsed: true),
        Group.navigation: PanelGroupDefaults(position: 8, isOpen: false),
        Group.halftones: PanelGroupDefaults(position: 9, isOpen: false),
    ]

    /// The fifteen panels in Window menu order (the order of panels.adoc's table).
    static func descriptors(selection: ActiveSelection?, help: HelpPanelModel) -> [PanelDescriptor] {
        [
            PlaceholderPanels.objectPanel(selection: selection),
            stub("document", "Document", "doc.on.doc", Group.properties, 11, "document-panel", "Page thumbnails, sizes and bleed appear here."),
            PlaceholderPanels.layers,
            stub("swatches", "Swatches", "square.grid.3x3.fill", Group.assets, 30, "swatches", "The document's colors appear here."),
            stub("styles", "Styles", "paintbrush", Group.assets, 31, "styles", "Graphic and text styles appear here."),
            stub("library", "Library", "books.vertical", Group.assets, 32, "library", "Symbols and team libraries appear here."),
            stub("colorMixer", "Color Mixer", "paintpalette", Group.mixer, 40, "color-mixer", "Mix colors here."),
            stub("tints", "Tints", "circle.lefthalf.filled", Group.mixer, 41, "tints", "Tints of the chosen color appear here."),
            stub("align", "Align", "align.horizontal.left", Group.alignTransform, 50, "arranging", "Align and distribute objects here."),
            TransformPanel.descriptor(selection: selection),
            stub("halftones", "Halftones", "circle.grid.3x3", Group.halftones, 60, "halftones", "Halftone screens appear here."),
            stub("navigation", "Navigation", "list.bullet.indent", Group.navigation, 70, "names-notes", "Object names, notes and URLs appear here."),
            stub("findReplace", "Find & Replace Graphics", "magnifyingglass", Group.findSelect, 80, "find-replace", "Find and replace attributes here."),
            stub("select", "Select", "checklist", Group.findSelect, 81, "selecting", "Select by attributes here."),
            helpPanel(help),
        ]
    }

    @MainActor
    static var ids: [PanelID] { descriptors(selection: nil, help: HelpPanelModel()).map(\.id) }

    private static func stub(_ id: PanelID, _ title: String, _ icon: String, _ group: String, _ order: Int, _ slug: String, _ detail: String) -> PanelDescriptor {
        PanelDescriptor(id: id, title: title, icon: icon, defaultGroup: group, menuOrder: order, helpSlug: slug) {
            PlaceholderPanelBody(title: title, detail: detail).panelContextMenu(PanelContextMenus.bodyContexts[id])
        }
    }

    static func helpPanel(_ help: HelpPanelModel) -> PanelDescriptor {
        PanelDescriptor(id: "help", title: "Help", icon: "questionmark.circle", defaultGroup: Group.help, menuOrder: 90, helpSlug: "panels") {
            HelpPanelBody(model: help)
        }
    }

    /// Registers every panel not registered yet, and the default layout's group settings.
    @MainActor
    static func register(into registry: PanelRegistry, selection: ActiveSelection? = nil, help: HelpPanelModel = HelpPanelModel()) {
        registry.groupDefaults.merge(groupDefaults) { current, _ in current }
        for descriptor in descriptors(selection: selection, help: help) { registry.registerIfAbsent(descriptor) }
    }
}

/// The Help panel's placeholder: names the page a *Help for <panel>* item asked for.
struct HelpPanelBody: View {
    let model: HelpPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Help").font(.headline)
            if let slug = model.slug, let topic = model.topic {
                Text("Help for \(topic)").font(.callout)
                Text(slug).font(.caption.monospaced()).foregroundStyle(.secondary).accessibilityIdentifier("help.slug")
            } else {
                Text("Search the guide, or hover over a tool to learn about it.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
