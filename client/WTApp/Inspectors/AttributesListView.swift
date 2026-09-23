import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTModel
import WTProto
import WTRender

extension AttributesListModel {
    /// Performs an add and returns the row it added to the first target (to select it).
    func performAdding(_ command: (any WTModel.Command)?) async -> AppearanceRow? {
        guard let first = targets.first, let command else { return nil }
        let before = Set(AppearanceEditing.stack(first, in: document.state))
        _ = await document.perform(command).value
        return AppearanceEditing.stack(first, in: document.state).first { !before.contains($0) }
    }
}

/// The Attributes list (ATTR-003): the root row, one row per stack element top first with its
/// kind icon, description and visibility checkbox, btn:[Add Stroke], btn:[Add Fill],
/// btn:[Add Effect], btn:[Remove Item] and the action menu; rows reorder by dragging (a copy with
/// kbd:[Option]) and take dropped colours.  Below it, the selected row's editor.  Rows are
/// identified by element, so a remote insert neither moves the selection nor rebuilds the editor
/// that has focus.
struct AttributesListView: View {
    let model: AttributesListModel
    let state: AttributesState
    var pasteboard: (any ObjectPasteboard)?
    var widthPresets: [String] = PreferenceCatalog.Object.defaultLineWeights.defaultValue
    /// Whether kbd:[Option] is down (a drag duplicates).
    var optionHeld: @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.option) }

    /// The list's selection: the root row or a stack row.
    enum ListSelection: Hashable {
        case root
        case row(AppearanceRow)
    }

    /// The selected row, when the selection is one of the current rows.
    static func selected(_ model: AttributesListModel, _ state: AttributesState) -> AttributeRowItem? {
        model.item(state.selection(for: model.targets))
    }

    static func selection(_ model: AttributesListModel, _ state: AttributesState) -> Binding<ListSelection?> {
        Binding(get: { selected(model, state).map { .row($0.id) } ?? .root }, set: { value in
            if case .row(let row)? = value { state.select(row, targets: model.targets) } else { state.select(nil, targets: model.targets) }
        })
    }

    /// btn:[Add Stroke] / btn:[Add Fill] / an btn:[Add Effect] item: adds above the selected
    /// row and selects the new one.
    @discardableResult
    static func add(_ command: (any WTModel.Command)?, model: AttributesListModel, state: AttributesState) -> Task<Void, Never> {
        Task {
            if let row = await model.performAdding(command) { state.select(row, targets: model.targets) }
        }
    }

    /// btn:[Remove Item]: removes the selected row and selects the object's own row.
    static func remove(_ model: AttributesListModel, _ state: AttributesState) {
        guard let item = selected(model, state) else { return }
        model.perform(model.remove(item))
        state.select(nil, targets: model.targets)
    }

    static func duplicate(_ model: AttributesListModel, _ state: AttributesState) {
        guard let item = selected(model, state) else { return }
        model.perform(model.duplicate(item))
    }

    /// The visibility checkbox of `item`: checked is visible.
    static func visibility(_ item: AttributeRowItem, _ model: AttributesListModel) -> Binding<Bool> {
        Binding(get: { item.hidden == .off }, set: { model.perform(model.setHidden(item, !$0)) })
    }

    /// Colours a drag can carry: the `ColorRef` payload of the colour panels and wells
    /// (COLOR-008), or an `NSColor` from another application or the Colors panel.
    static let colorTypes: [UTType] = ColorDrag.dropTypes

    /// A colour dropped on `item`, read from the drag pasteboard: applied to that row only (a
    /// swatch from another document is created here first, `ColorDrop`).  False when the drag
    /// carries no colour or the row takes none.
    @discardableResult
    static func drop(from pasteboard: NSPasteboard, on item: AttributeRowItem, model: AttributesListModel,
                     defaultSpace: RenderColor.Space = .displayP3) -> Bool {
        guard let payload = ColorDrag.read(from: pasteboard, defaultSpace: defaultSpace), model.drop(ColorBridge.none, on: item) != nil else { return false }
        let document = model.document
        guard ColorDrop.needsImport(payload, into: document.id) else {
            model.perform(model.drop(payload.reference(in: document.state, document: document.id), on: item))
            return true
        }
        Task { @MainActor in model.perform(model.drop(await ColorDrop.reference(for: payload, in: document), on: item)) }
        return true
    }

    // Actions of the controls, as closures the tests can call.

    static func adding(_ command: (any WTModel.Command)?, model: AttributesListModel, state: AttributesState) -> () -> Void {
        { add(command, model: model, state: state) }
    }

    static func removing(_ model: AttributesListModel, _ state: AttributesState) -> () -> Void {
        { remove(model, state) }
    }

    static func duplicating(_ model: AttributesListModel, _ state: AttributesState) -> () -> Void {
        { duplicate(model, state) }
    }

    static func dropping(on item: AttributeRowItem, model: AttributesListModel, pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> ([NSItemProvider]) -> Bool {
        { _ in drop(from: pasteboard, on: item, model: model) }
    }

    static func moving(_ model: AttributesListModel, optionHeld: @escaping @MainActor () -> Bool) -> (IndexSet, Int) -> Void {
        { move($0, to: $1, model: model, duplicate: optionHeld()) }
    }

    /// A row drag onto the insertion point `destination` (top first).
    static func move(_ source: IndexSet, to destination: Int, model: AttributesListModel, duplicate: Bool) {
        guard let from = source.first else { return }
        model.perform(model.move(fromDisplay: from, toDisplay: destination, duplicate: duplicate))
    }

    var body: some View {
        let selectedItem = Self.selected(model, state)
        VStack(alignment: .leading, spacing: 6) {
            toolbar(selectedItem)
            List(selection: Self.selection(model, state)) {
                Text(model.rootTitle).bold().tag(ListSelection.root).accessibilityIdentifier("attributes.root")
                ForEach(model.displayRows) { item in
                    AttributeRowView(item: item, visible: Self.visibility(item, model))
                        .tag(ListSelection.row(item.id))
                        .onDrop(of: Self.colorTypes, isTargeted: nil, perform: Self.dropping(on: item, model: model))
                }
                .onMove(perform: Self.moving(model, optionHeld: optionHeld))
            }
            .frame(minHeight: 90, idealHeight: 130)
            .onDeleteCommand(perform: Self.removing(model, state))
            .accessibilityIdentifier("attributes.list")
            if model.rows.isEmpty && model.targets.count > 1 {
                Text("The selected objects' attributes differ.").font(.caption).foregroundStyle(.secondary)
            }
            if let selectedItem {
                editor(selectedItem).id(selectedItem.id)
            }
        }
        .padding(.horizontal)
    }

    private func toolbar(_ selectedItem: AttributeRowItem?) -> some View {
        HStack(spacing: 4) {
            Button("Add Stroke", action: Self.adding(model.add(.strokes, above: selectedItem), model: model, state: state))
                .accessibilityIdentifier("attributes.add-stroke")
            Button("Add Fill", action: Self.adding(model.add(.fills, above: selectedItem), model: model, state: state))
                .accessibilityIdentifier("attributes.add-fill")
            Menu("Add Effect") {
                ForEach(AttributeNames.effectKinds, id: \.0) { kind, name in
                    Button(name, action: Self.adding(model.addEffect(kind, above: selectedItem), model: model, state: state))
                }
            }
            .fixedSize()
            .accessibilityIdentifier("attributes.add-effect")
            Button(action: Self.removing(model, state)) { Image(systemName: "minus") }
                .disabled(selectedItem == nil)
                .help("Remove Item")
                .accessibilityIdentifier("attributes.remove")
            Menu {
                Button("Add Stroke", action: Self.adding(model.add(.strokes, above: selectedItem), model: model, state: state))
                Button("Add Fill", action: Self.adding(model.add(.fills, above: selectedItem), model: model, state: state))
                Button("Remove", action: Self.removing(model, state)).disabled(selectedItem == nil)
                Button("Duplicate", action: Self.duplicating(model, state)).disabled(selectedItem == nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .fixedSize()
            .accessibilityIdentifier("attributes.actions")
        }
        .disabled(model.targets.isEmpty)
    }

    @ViewBuilder private func editor(_ item: AttributeRowItem) -> some View {
        let context = AttributeEditorContext(list: model, item: item)
        switch item.list {
        case .strokes:
            StrokeEditorView(model: StrokeEditorModel(context: context, widthPresets: widthPresets, pasteboard: pasteboard))
        case .fills:
            FillEditorView(model: FillEditorModel(context: context, pasteboard: pasteboard))
        case .effects:
            Text("\(item.summary) is edited with the effect editors.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One row: kind icon, description and the visibility checkbox; hidden rows are dimmed.
struct AttributeRowView: View {
    let item: AttributeRowItem
    let visible: Binding<Bool>

    var body: some View {
        HStack {
            Image(systemName: item.icon).frame(width: 16)
            Text(item.summary)
            Spacer()
            Toggle("Visible", isOn: visible)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("attributes.visible.\(item.index)")
                .accessibilityValue(PathSectionView.accessibilityValue(item.hidden == .on ? .off : item.hidden == .off ? .on : .mixed))
        }
        .opacity(item.hidden == .on ? 0.5 : 1)
        .accessibilityIdentifier("attributes.row.\(item.index)")
    }
}
