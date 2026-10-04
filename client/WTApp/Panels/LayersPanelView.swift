import AppKit
import SwiftUI
import WTCRDT
import WTModel

/// The Layers panel body (layers.adoc, "The Layers panel" and "Objects in the Layers panel"): the
/// hidden-active-layer warning, the search field and the options menu over the outline of layers
/// and their objects (`LayersOutline`), and the removal sheet.
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

/// The list with its header.
struct LayersList: View {
    let model: LayersPanelModel

    static func move(_ model: LayersPanelModel) -> (IndexSet, Int) -> Void {
        { source, destination in model.perform(model.move(fromOffsets: source, toOffset: destination)) }
    }

    static func cancelRemoval(_ model: LayersPanelModel) -> () -> Void { { model.cancelRemoval() } }
    static func confirmRemoval(_ model: LayersPanelModel) -> () -> Void { { model.confirmRemoval() } }

    /// The search field's binding to the panel state.
    static func filter(_ state: LayersPanelState) -> Binding<String> {
        Binding(get: { state.filter }, set: { state.filter = $0 })
    }

    /// The layers' frame marks, read here so the outline updates while the animation plays.
    static func marks(_ model: LayersPanelModel) -> [OpID: LayerFrameMarks] {
        Dictionary(uniqueKeysWithValues: model.layers.map { layer in
            let marks = LayerFrames.marks(layer.id, document: model.document, state: model.state)
            return (layer.id, LayerFrameMarks(number: marks.number, playing: marks.playing))
        })
    }

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
            TextField("Find objects by name", text: Self.filter(model.state))
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .padding(.horizontal, 6).padding(.bottom, 4)
                .accessibilityIdentifier("layers.search")
            // `revision` and the panel's selection are read so the layer rows' pen icon and
            // highlight follow; the outline itself follows the document and the canvas selection.
            let _ = (model.state.revision, model.state.selected, model.state.renaming, model.state.locateRequest)
            LayersOutline(model: model, filter: model.state.filter, marks: Self.marks(model))
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

/// What a layer row's controls do (`LayerRowCell` in `LayersOutline`).
@MainActor
enum LayerRow {
    static func modifiers() -> KeyModifiers { KeyEquivalentResolver.modifiers(NSEvent.modifierFlags) }

    /// A click (or a drag through the column) on a flag column ends `dy` points below where it
    /// started: one change.
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
}
