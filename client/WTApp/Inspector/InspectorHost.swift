import SwiftUI
import WTModel

/// The Object panel (object-panel.adoc; APP-007): the inspector host.  The upper half is the
/// selection summary and the properties list with its buttons (`AttributesListView`); the lower
/// half edits whichever row is selected there -- the stack row's editor, or for the root row every
/// section the registry has for the selection's kinds.  The body reads the active selection and the
/// front document's revision, so a local or remote change shows at once; the fields keep what the
/// user is typing (`FieldEditor`).
struct ObjectPanelBody: View {
    let selection: ActiveSelection?
    var registry: InspectorRegistry = .standard
    @State private var attributes = AttributesState()

    var body: some View {
        if let replacement = registry.replacement(for: selection) {
            replacement.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            selectionBody
        }
    }

    private var selectionBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            SelectionSummaryBody(selection: selection)
            if let line = selection?.editingLine {
                Text(line).font(.caption).italic().foregroundStyle(.secondary).padding(.horizontal).accessibilityIdentifier("object.editingBy")
            }
            if let list = Self.attributes(selection) {
                AttributesListView(model: list, state: attributes, selection: selection?.model)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Self.lowerHalf(selection, list: list, state: attributes, registry: registry)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .accessibilityIdentifier("object.attributes")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: InspectorRowRequest.shared.pending, initial: true) { InspectorRowRequest.shared.apply(to: attributes) }
    }

    /// The lower half: the selected stack row's editor (identified by the row, so a remote insert
    /// does not rebuild the editor that has focus), else the root row's sections.
    @ViewBuilder
    static func lowerHalf(_ selection: ActiveSelection?, list: AttributesListModel, state: AttributesState, registry: InspectorRegistry) -> some View {
        if let item = AttributesListView.selected(list, state) {
            registry.rowEditor(AttributeEditorContext(list: list, item: item), environment: environment(selection)).id(item.id)
        } else if let model = model(selection) {
            ForEach(registry.views(for: model), id: \.id) { $0.view }
        }
    }

    /// The Attributes list of the front window's selection (ATTR-003).
    static func attributes(_ selection: ActiveSelection?) -> AttributesListModel? {
        guard let document = selection?.document, let selectionModel = selection?.model else { return nil }
        _ = document.model?.revision
        return AttributesListModel(document: document, selection: selectionModel.selection)
    }

    /// The root row's panel model.
    static func model(_ selection: ActiveSelection?) -> ObjectPanelModel? {
        guard let document = selection?.document, let selectionModel = selection?.model else { return nil }
        _ = document.model?.revision
        return ObjectPanelModel(document: document, selection: selectionModel.selection, textSession: selection?.editing?.textSession)
    }

    /// What the row editors read: *Default line weights* from the app's preferences when the panel
    /// has them, and the window's pasteboard.
    static func environment(_ selection: ActiveSelection?) -> InspectorRowEnvironment {
        InspectorRowEnvironment(widthPresets: widthPresets(selection), pasteboard: selection?.editing?.pasteboard, selection: selection?.model?.selection)
    }

    static func widthPresets(_ selection: ActiveSelection?) -> [String] {
        selection?.preferences?[PreferenceCatalog.Object.defaultLineWeights] ?? PreferenceCatalog.Object.defaultLineWeights.defaultValue
    }

    /// The object's own sections show while its root row is selected (the lower half edits
    /// whichever row is selected in the list).
    static func showsObjectSections(_ selection: ActiveSelection?, _ state: AttributesState) -> Bool {
        guard let list = attributes(selection) else { return true }
        return AttributesListView.selected(list, state) == nil
    }
}
