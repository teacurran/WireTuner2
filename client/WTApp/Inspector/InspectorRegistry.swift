import SwiftUI
import WTModel

/// One section of the Object panel's lower half while the properties list's root row is selected
/// (object-panel.adoc, "Properties by kind"; APP-007): the kinds it edits and a view built from the
/// panel model, nil when the selection gives it nothing to show (the point section without exactly
/// one point).
struct InspectorSection: Identifiable {
    let id: String
    /// Sections show in ascending order: the kind's own attributes, then the common ones.
    let order: Int
    /// The node kinds the section edits; it shows only when every selected object is one of them
    /// ("Objects of different kinds show only the common attributes").  Nil: every kind.
    let kinds: Set<NodeKind>?
    let make: @MainActor (ObjectPanelModel) -> AnyView?

    init(id: String, order: Int, kinds: Set<NodeKind>?, make: @escaping @MainActor (ObjectPanelModel) -> AnyView?) {
        self.id = id
        self.order = order
        self.kinds = kinds
        self.make = make
    }

    /// Whether the section applies to objects of `kinds` (none selected: no section).
    func applies(to kinds: [NodeKind]) -> Bool {
        guard !kinds.isEmpty else { return false }
        guard let own = self.kinds else { return true }
        return kinds.allSatisfy(own.contains)
    }
}

/// What a stack row's editor is given besides the row: the preferences and pasteboard it reads.
struct InspectorRowEnvironment {
    var widthPresets: [String] = PreferenceCatalog.Object.defaultLineWeights.defaultValue
    var pasteboard: (any ObjectPasteboard)?
    /// The window's selection (a Corners effect's *Selected points*).
    var selection: Selection?
}

/// The Object panel's editor registry (APP-007): root-row sections per node kind and the editor of
/// each kind of stack row (fills, strokes, effects).  Feature tasks register theirs; the host asks
/// it what to show for the selection.  Registering an id again replaces the section.
@MainActor
final class InspectorRegistry {
    typealias RowEditor = @MainActor (AttributeEditorContext, InspectorRowEnvironment) -> AnyView

    private(set) var sections: [InspectorSection] = []
    private var rowEditors: [AppearanceList: RowEditor] = [:]
    /// Views that take the whole panel's place while they apply (the Output Area tool's editor).
    private(set) var replacements: [(id: String, make: @MainActor (ActiveSelection?) -> AnyView?)] = []

    init() {}

    func register(_ section: InspectorSection) {
        sections.removeAll { $0.id == section.id }
        sections.append(section)
        sections.sort { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    /// Registers a view shown in place of the selection whenever `make` returns one.
    func registerReplacement(id: String, _ make: @escaping @MainActor (ActiveSelection?) -> AnyView?) {
        replacements.removeAll { $0.id == id }
        replacements.append((id, make))
    }

    /// The first replacement that applies to `selection`.
    func replacement(for selection: ActiveSelection?) -> AnyView? {
        replacements.lazy.compactMap { $0.make(selection) }.first
    }

    func registerRowEditor(for list: AppearanceList, _ editor: @escaping RowEditor) {
        rowEditors[list] = editor
    }

    /// The sections `model`'s selection shows, in order, each with its view.
    func views(for model: ObjectPanelModel) -> [(id: String, view: AnyView)] {
        let kinds = model.objects.map(\.object.kind)
        return sections.filter { $0.applies(to: kinds) }.compactMap { section in section.make(model).map { (section.id, $0) } }
    }

    /// The editor of the stack row `context` edits.
    func rowEditor(_ context: AttributeEditorContext, environment: InspectorRowEnvironment) -> AnyView {
        rowEditors[context.item.list].map { $0(context, environment) }
            ?? AnyView(Text("\(context.item.summary) has no editor.").font(.caption).foregroundStyle(.secondary))
    }

    /// The sections and row editors WireTuner ships: point, path, rectangle, polygon, connector,
    /// text, blend and extrusion sections, the common attributes, and the stroke, fill and effect
    /// row editors.
    static let standard: InspectorRegistry = {
        let registry = InspectorRegistry()
        registry.register(InspectorSection(id: "point", order: 10, kinds: [.path]) { model in
            model.point.map { AnyView(PointSectionView(section: $0, model: model)) }
        })
        registry.register(InspectorSection(id: "path", order: 20, kinds: [.path]) { model in
            model.path.map { AnyView(PathSectionView(section: $0, model: model)) }
        })
        registry.register(InspectorSection(id: "rectangle", order: 30, kinds: [.rect]) { model in
            model.rectangle.map { AnyView(RectangleSectionView(section: $0, model: model)) }
        })
        registry.register(InspectorSection(id: "polygon", order: 40, kinds: [.polygon]) { model in
            model.polygon.map { AnyView(PolygonSectionView(section: $0, model: model)) }
        })
        registry.register(InspectorSection(id: "connector", order: 50, kinds: [.connector]) { model in
            model.connector.map { AnyView(ConnectorSectionView(section: $0, model: model)) }
        })
        registry.register(InspectorSection(id: "text", order: 60, kinds: [.text]) { model in
            model.text.map { AnyView(TextSectionView(section: $0, model: model)) }
        })
        registry.register(InspectorSection(id: "common", order: 100, kinds: nil) { model in
            model.common.map { AnyView(CommonSectionView(section: $0, model: model)) }
        })
        registry.registerRowEditor(for: .strokes) { context, environment in
            AnyView(StrokeEditorView(model: StrokeEditorModel(context: context, widthPresets: environment.widthPresets, pasteboard: environment.pasteboard)))
        }
        registry.registerRowEditor(for: .fills) { context, environment in
            AnyView(FillEditorView(model: FillEditorModel(context: context, pasteboard: environment.pasteboard)))
        }
        registry.registerRowEditor(for: .effects) { context, environment in
            AnyView(EffectEditorView(model: EffectEditorModel(context: context, selection: environment.selection)))
        }
        EffectSections.register(into: registry)
        DataSections.register(into: registry)
        TextSections.register(into: registry)
        WebSections.register(into: registry)
        return registry
    }()
}
