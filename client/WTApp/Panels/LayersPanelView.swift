import AppKit
import SwiftUI
import WTCRDT
import WTModel

/// The Layers panel body (layers.adoc, "The Layers panel"): a row per layer, frontmost first --
/// check mark, Preview/Keyline circle, padlock, highlight swatch, name, pen icon on the active
/// layer -- with the separator row between printing and background layers, the options menu, the
/// row context menu and the removal sheet.
struct LayersPanelBody: View {
    let selection: ActiveSelection?
    let state: LayersPanelState

    static let rowHeight: CGFloat = 22

    var body: some View {
        if let model = Self.model(selection, state) {
            LayersList(model: model)
        } else {
            Text("No document").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func model(_ selection: ActiveSelection?, _ state: LayersPanelState) -> LayersPanelModel? {
        guard let document = selection?.document, let editing = selection?.editing else { return nil }
        _ = document.model?.revision
        _ = selection?.model?.selection
        return LayersPanelModel(document: document, editing: editing, state: state)
    }
}

/// The list with its header menu.
struct LayersList: View {
    let model: LayersPanelModel

    static func move(_ model: LayersPanelModel) -> (IndexSet, Int) -> Void {
        { source, destination in model.perform(model.move(fromOffsets: source, toOffset: destination)) }
    }

    static func cancelRemoval(_ model: LayersPanelModel) -> () -> Void { { model.cancelRemoval() } }
    static func confirmRemoval(_ model: LayersPanelModel) -> () -> Void { { model.confirmRemoval() } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let warning = model.hiddenActiveWarning {
                    Label(warning, systemImage: "eye.slash").font(.caption).lineLimit(2).accessibilityIdentifier("layers.hiddenWarning")
                }
                Spacer()
                Menu {
                    ForEach(model.optionItems) { item in
                        if item.title.isEmpty { Divider() } else { Button(item.title, action: item.run) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityIdentifier("layers.options")
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            List {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    if let layer = row.layer {
                        LayerRow(model: model, layer: layer, index: model.layers.firstIndex { $0.id == layer.id } ?? index)
                    } else {
                        SeparatorRow()
                    }
                }
                .onMove(perform: Self.move(model))
            }
            .listStyle(.plain)
            // The group's frosted card shows through (D-077, revised).
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("layers.list")
        }
        .sheet(isPresented: Binding(get: { !model.state.pendingRemoval.isEmpty }, set: { if !$0 { model.cancelRemoval() } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.removalQuestion).font(.headline)
                Text("Removing a layer is undoable.").foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", action: Self.cancelRemoval(model)).keyboardShortcut(.cancelAction)
                    Button("Remove", action: Self.confirmRemoval(model)).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("layers.remove.confirm")
                }
            }
            .padding(20)
            .frame(width: 320)
        }
    }
}

/// The separator between printing and background layers: draggable, not selectable.
struct SeparatorRow: View {
    var body: some View {
        Rectangle().fill(SwiftUI.Color.secondary).frame(height: 2).frame(maxWidth: .infinity)
            .help("Layers below this line are background layers: they never print and draw dimmed")
            .accessibilityIdentifier("layers.separator")
    }
}

/// One layer row.
struct LayerRow: View {
    let model: LayersPanelModel
    let layer: LayerInfo
    /// The row's index among the layers, frontmost first (drag-through toggling).
    let index: Int

    static func modifiers() -> KeyModifiers { KeyEquivalentResolver.modifiers(NSEvent.modifierFlags) }

    /// A click (or a drag through the column) on a flag column ends: one change.
    static func column(_ model: LayersPanelModel, _ flag: SetLayerFlag.Flag, _ layer: LayerInfo, _ index: Int) -> (CGFloat) -> Void {
        { dy in
            let rows = Int((dy / LayersPanelBody.rowHeight).rounded())
            if rows == 0, !modifiers().contains(.option), let guides = GuidesLayer.toggle(flag, layer: layer) {
                // The Guides layer's check mark and padlock drive the guides too (DOC-018).
                model.perform(guides)
            } else if rows == 0 {
                model.perform(model.toggle(flag, layer: layer.id, allLayers: modifiers().contains(.option)))
            } else {
                model.perform(model.dragToggle(flag, from: index, through: index + rows))
            }
        }
    }

    static func click(_ model: LayersPanelModel, _ layer: LayerInfo) -> () -> Void {
        { model.click(layer.id, modifiers: modifiers()) }
    }

    static func rename(_ model: LayersPanelModel, _ layer: LayerInfo) -> () -> Void {
        { model.beginRename(layer.id) }
    }

    static func highlight(_ model: LayersPanelModel, _ layer: LayerInfo) -> Binding<CGColor> {
        // The colour panel streams changes while its colour is dragged: previewed, written once it
        // settles (D-076).
        Binding(get: { LayersPanelModel.swatch(layer).cgColor }, set: { color in
            ContinuousInput.settle { model.setHighlight(layer.id, color: NSColor(cgColor: color) ?? .black) }
        })
    }

    var body: some View {
        HStack(spacing: 6) {
            FlagCell(symbol: layer.visible ? "checkmark" : "", identifier: "visible", end: Self.column(model, .visible, layer, index))
            FlagCell(symbol: layer.keyline ? "circle" : "circle.fill", identifier: "keyline", end: Self.column(model, .keyline, layer, index))
            FlagCell(symbol: layer.locked ? "lock.fill" : "lock.open", identifier: "locked", end: Self.column(model, .locked, layer, index))
            ColorPicker("", selection: Self.highlight(model, layer), supportsOpacity: false).labelsHidden().frame(width: 20)
                .accessibilityIdentifier("layers.swatch.\(layer.id)")
            if model.state.renaming == layer.id {
                RenameField(model: model, layer: layer)
            } else {
                Text(layer.name.isEmpty ? "Layer" : layer.name)
                    .fontWeight(model.selectionLayers.contains(layer.id) ? .bold : .regular)
                    .foregroundStyle(layer.printing ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: Self.rename(model, layer))
                    .onTapGesture(perform: Self.click(model, layer))
            }
            let frame = LayerFrames.marks(layer.id, document: model.document, state: model.state)
            LayerFrameNumber(number: frame.number)
            if model.activeLayer == layer.id { Image(systemName: "pencil").accessibilityIdentifier("layers.active") }
        }
        .frame(height: LayersPanelBody.rowHeight)
        .listRowBackground(LayerFrames.background(playing: LayerFrames.marks(layer.id, document: model.document, state: model.state).playing,
                                                  selected: model.state.selected.contains(layer.id)))
        .help(LayersPanelModel.tooltip(layer))
        .contextMenu { LayerContextMenu(model: model, layer: layer) }
        .accessibilityIdentifier("layers.row.\(layer.id)")
    }
}

/// A flag column: a click toggles; a drag through the column applies the first row's new value
/// to every row crossed (layers.adoc, "Showing and hiding layers").
struct FlagCell: View {
    let symbol: String
    let identifier: String
    let end: (CGFloat) -> Void

    var body: some View {
        Image(systemName: symbol.isEmpty ? "square" : symbol)
            .opacity(symbol.isEmpty ? 0.15 : 1)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { end($0.translation.height) })
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("layers.\(identifier)")
    }
}

/// The name field while renaming: kbd:[Return] commits, kbd:[Esc] keeps the old name.  It keeps
/// its own text, so a remote rename arriving meanwhile does not lose keystrokes.
struct RenameField: View {
    let model: LayersPanelModel
    let layer: LayerInfo
    @State private var text = ""

    var body: some View {
        TextField("Name", text: $text)
            .onAppear { text = layer.name }
            .onSubmit { model.commitRename(layer.id, to: text) }
            .onExitCommand { model.cancelRename() }
            .accessibilityIdentifier("layers.rename")
    }
}

/// The row's context menu (context-menus.adoc, "Panel menus": the layer items).
struct LayerContextMenu: View {
    let model: LayersPanelModel
    let layer: LayerInfo

    var body: some View {
        ForEach(model.contextItems(layer)) { item in Button(item.title, action: item.run) }
    }
}
