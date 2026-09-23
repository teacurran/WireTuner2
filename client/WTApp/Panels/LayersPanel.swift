import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Layers panel's own state, app-wide like the panel (layers.adoc, "The Layers panel";
/// LIB-004): which layers are selected in the panel (for merging and removing), the row being
/// renamed, the removal waiting for confirmation, and the preference the name click reads.
@MainActor
@Observable
final class LayersPanelState {
    /// Layers selected in the panel, in the order they were picked.
    var selected: [OpID] = []
    /// The row a Shift-click extends from.
    var anchor: OpID?
    /// The layer whose name is being edited.
    var renaming: OpID?
    /// Layers *Remove* is about to delete, while the sheet asks.
    var pendingRemoval: [OpID] = []
    /// Bumped when the active layer changes, so the pen icon follows.
    private(set) var revision = 0
    /// *Clicking a layer name moves selected objects* (Panels).
    @ObservationIgnored var clickMoves: @MainActor () -> Bool = { true }

    init() {}

    func touch() { revision += 1 }
}

/// What the Layers panel shows for the front window's document and what its controls do: rows
/// frontmost first with the derived separator, and one command per gesture (layers.adoc; the
/// commands are LIB-002/003's `LayerCommands`).  A value computed on every read, so a remote
/// change shows at once and an in-progress name edit keeps its own text.
@MainActor
struct LayersPanelModel {
    /// One row: a layer, or the separator between printing and background layers.
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case layer(LayerInfo)
            case separator
        }

        let kind: Kind
        var id: String {
            switch kind {
            case .layer(let info): "layer:\(info.id)"
            case .separator: Self.separatorID
            }
        }

        static let separatorID = "separator"

        var layer: LayerInfo? {
            if case .layer(let info) = kind { return info }
            return nil
        }
    }

    let document: DocumentHandle
    let editing: ObjectEditing
    let state: LayersPanelState

    var order: LayerOrder { LayerOrder(document.state) }

    /// The layers frontmost first, the separator between the printing and the background ones.
    var rows: [Row] {
        let layers = order.layers.reversed()
        let printing = layers.filter(\.printing).map { Row(kind: .layer($0)) }
        let background = layers.filter { !$0.printing }.map { Row(kind: .layer($0)) }
        return printing + [Row(kind: .separator)] + background
    }

    /// The layers alone, frontmost first.
    var layers: [LayerInfo] { rows.compactMap(\.layer) }

    /// The active layer (the pen icon): the window's choice while it is live, else the drawing
    /// layer.
    var activeLayer: OpID? {
        _ = state.revision
        if let active = editing.activeLayer, order.isLive(active) { return active }
        return order.drawingLayer
    }

    /// The layers of the selected objects (their names are highlighted).
    var selectionLayers: Set<OpID> {
        let state = document.state
        let order = self.order
        return Set(editing.selectedNodes.compactMap { order.layer(of: $0, in: state) })
    }

    /// Whether the layer holds no live objects.
    func isEmpty(_ layer: OpID) -> Bool { order.objects(on: layer, in: document.state).isEmpty }

    /// "Show the active layer to see what you draw" while the active layer is hidden.
    var hiddenActiveWarning: String? {
        guard let active = activeLayer, order.layer(active)?.visible == false else { return nil }
        return "The active layer is hidden: objects you draw there are invisible until you show it"
    }

    @discardableResult
    func perform(_ command: (any WTModel.Command)?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        command.map { editing.perform($0) }
    }

    // MARK: Columns

    static func value(_ flag: SetLayerFlag.Flag, of layer: LayerInfo) -> Bool {
        switch flag {
        case .visible: layer.visible
        case .locked: layer.locked
        case .printing: layer.printing
        case .keyline: layer.keyline
        }
    }

    /// A click in a column: that layer's flag flips; with kbd:[Option] every layer takes the
    /// clicked one's new value.
    func toggle(_ flag: SetLayerFlag.Flag, layer: OpID, allLayers: Bool = false) -> SetLayerFlag? {
        guard let info = order.layer(layer) else { return nil }
        let value = !Self.value(flag, of: info)
        return SetLayerFlag(allLayers ? layers.map(\.id) : [layer], flag, value)
    }

    /// Drag-through toggling: the rows from `from` through `through` (layer indices, frontmost
    /// first) take the first row's new value, as one change ("Hide 4 layers").
    func dragToggle(_ flag: SetLayerFlag.Flag, from: Int, through: Int) -> SetLayerFlag? {
        let layers = self.layers
        guard layers.indices.contains(from) else { return nil }
        let end = min(max(through, 0), layers.count - 1)
        let range = min(from, end)...max(from, end)
        let value = !Self.value(flag, of: layers[from])
        return SetLayerFlag(layers[range].map(\.id), flag, value)
    }

    // MARK: Names

    /// A click on a layer name (layers.adoc, "Selecting layers"): kbd:[Cmd] adds or removes the
    /// layer from the panel's selection, kbd:[Shift] selects the range, kbd:[Option] selects every
    /// object on the layer; a plain click makes it active -- and, with *Clicking a layer name
    /// moves selected objects*, moves the selected objects onto it.  A locked layer cannot be made
    /// active.  Returns the move performed, if any.
    @discardableResult
    func click(_ layer: OpID, modifiers: KeyModifiers) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        if modifiers.contains(.command) {
            if let index = state.selected.firstIndex(of: layer) { state.selected.remove(at: index) } else { state.selected.append(layer) }
            state.anchor = layer
            return nil
        }
        if modifiers.contains(.shift), let anchor = state.anchor, let from = layers.firstIndex(where: { $0.id == anchor }),
           let to = layers.firstIndex(where: { $0.id == layer }) {
            state.selected = layers[min(from, to)...max(from, to)].map(\.id)
            return nil
        }
        if modifiers.contains(.option) {
            let objects = order.objects(on: layer, in: document.state)
            editing.selection.model.set(Selection(objects.map(SelectionID.init)))
            return nil
        }
        state.selected = [layer]
        state.anchor = layer
        guard let info = order.layer(layer), !info.locked else { return nil }
        let nodes = editing.selectedNodes
        editing.activeLayer = layer
        state.touch()
        guard state.clickMoves(), !nodes.isEmpty, !selectionLayers.allSatisfy({ $0 == layer }) else { return nil }
        return perform(MoveObjectsToLayer(nodes, to: layer))
    }

    /// Double-click: rename (not the Guides layer).
    func beginRename(_ layer: OpID) {
        guard order.layer(layer)?.role == .ordinary else { return }
        state.renaming = layer
    }

    /// kbd:[Return] in the name field; an empty or unchanged name renames nothing.
    @discardableResult
    func commitRename(_ layer: OpID, to name: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        state.renaming = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, order.layer(layer)?.name != trimmed else { return nil }
        return perform(RenameLayer(layer, to: trimmed))
    }

    /// kbd:[Esc] keeps the old name.
    func cancelRename() { state.renaming = nil }

    // MARK: Reordering

    /// A drag in the list (SwiftUI's move offsets over `rows`): a layer moves -- across the
    /// separator it changes `printing` -- or the separator moves, flipping `printing` on the layers
    /// it crossed.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) -> (any WTModel.Command)? {
        let before = rows
        guard source.count == 1, let from = source.first, before.indices.contains(from) else { return nil }
        var after = before
        after.move(fromOffsets: source, toOffset: destination)
        guard after != before, let separator = after.firstIndex(where: { $0.kind == .separator }) else { return nil }
        switch before[from].kind {
        case .layer(let info):
            let layers = after.compactMap(\.layer)
            guard let index = Array(layers.reversed()).firstIndex(where: { $0.id == info.id }),
                  let position = after.firstIndex(where: { $0.id == before[from].id }) else { return nil }
            return ReorderLayer(info.id, to: index, printing: position < separator)
        case .separator:
            let nowPrinting = Set(after[..<separator].compactMap(\.layer?.id))
            let crossed = before.compactMap(\.layer).filter { nowPrinting.contains($0.id) != $0.printing }
            guard let first = crossed.first else { return nil }
            return SetLayerFlag(crossed.map(\.id), .printing, !first.printing)
        }
    }

    // MARK: Options and row menus

    /// The layers the options menu acts on: the panel's selection, else the active layer.
    var targets: [OpID] {
        let live = state.selected.filter { order.isLive($0) }
        return live.isEmpty ? activeLayer.map { [$0] } ?? [] : live
    }

    /// *New*: above the active layer, made active.
    @discardableResult
    func newLayer() -> Task<Void, Never> {
        let task = perform(CreateLayer(name: "Layer \(layers.count + 1)", above: activeLayer))
        let editing = self.editing
        let state = self.state
        return Task { @MainActor in
            guard let created = await task?.value?.createdNodes.first else { return }
            editing.activeLayer = created
            state.selected = [created]
            state.touch()
        }
    }

    @discardableResult
    func duplicate() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        targets.first.flatMap { perform(DuplicateLayer($0)) }
    }

    /// *Remove*: asks first when any of the layers holds objects; returns the change when it was
    /// removed at once.
    @discardableResult
    func remove(_ layers: [OpID]? = nil) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let chosen = layers ?? targets
        guard !chosen.isEmpty else { return nil }
        if chosen.contains(where: { !isEmpty($0) }) {
            state.pendingRemoval = chosen
            return nil
        }
        return perform(RemoveLayers.named(chosen, in: document.state))
    }

    /// The sheet's *Remove*.
    @discardableResult
    func confirmRemoval() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let chosen = state.pendingRemoval
        state.pendingRemoval = []
        guard !chosen.isEmpty else { return nil }
        state.selected.removeAll(where: chosen.contains)
        return perform(RemoveLayers.named(chosen, in: document.state))
    }

    func cancelRemoval() { state.pendingRemoval = [] }

    /// "Remove 2 layers and everything on them?"
    var removalQuestion: String {
        let count = state.pendingRemoval.count
        return count == 1 ? "Remove the layer and everything on it?" : "Remove \(count) layers and everything on them?"
    }

    @discardableResult
    func mergeSelected() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let chosen = state.selected.filter { order.isLive($0) }
        guard chosen.count > 1 else { return nil }
        return perform(MergeLayers(chosen))
    }

    @discardableResult
    func mergeForeground() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        perform(MergeLayers.foreground(in: document.state))
    }

    /// *Move Objects to Current Layer*.
    @discardableResult
    func moveObjectsToCurrent() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let active = activeLayer else { return nil }
        return moveSelection(to: active)
    }

    /// *Move Selection to This Layer*.
    @discardableResult
    func moveSelection(to layer: OpID) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let nodes = editing.selectedNodes
        guard !nodes.isEmpty else { return nil }
        return perform(MoveObjectsToLayer(nodes, to: layer))
    }

    /// *All On* / *All Off*.
    @discardableResult
    func setAll(visible: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        perform(SetLayerFlag(layers.map(\.id), .visible, visible))
    }

    /// The swatch's colour panel.
    @discardableResult
    func setHighlight(_ layer: OpID, color: NSColor) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        perform(SetLayerHighlight(layer, color: Self.color(color)))
    }

    static func color(_ color: NSColor) -> Wiretuner_Doc_V1_Color {
        // A colour with no sRGB form (a pattern) reads as black; `.black` itself is a gray colour.
        let rgb = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        var result = Wiretuner_Doc_V1_Color()
        result.rgb.r = Double(rgb.redComponent)
        result.rgb.g = Double(rgb.greenComponent)
        result.rgb.b = Double(rgb.blueComponent)
        return result
    }

    /// A layer's highlight colour for its swatch; the accent colour when it has none.
    static func swatch(_ layer: LayerInfo) -> NSColor {
        guard case .rgb(let rgb)? = layer.highlight?.components else { return .controlAccentColor }
        return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }

    /// The row's tooltip.  Who locked the layer comes from History, which is not delivered yet:
    /// the tooltip says only that it is locked.
    static func tooltip(_ layer: LayerInfo) -> String {
        var parts = [layer.name.isEmpty ? "Layer" : layer.name]
        if layer.role == .guides { parts.append("Guides") }
        if layer.locked { parts.append("Locked") }
        if !layer.visible { parts.append("Hidden") }
        if !layer.printing { parts.append("Background (does not print)") }
        return parts.joined(separator: " · ")
    }
}

/// A menu item of the options menu or a row's context menu; an empty title is a divider.
struct LayerMenuItem: Identifiable {
    let id: Int
    let title: String
    let run: @MainActor () -> Void
}

extension LayersPanelModel {
    /// The options menu (layers.adoc's table).
    var optionItems: [LayerMenuItem] {
        let entries: [(String, @MainActor () -> Void)] = [
            ("New", { newLayer() }), ("Duplicate", { duplicate() }), ("Remove", { remove() }), ("", {}),
            ("Merge Selected Layers", { mergeSelected() }), ("Merge Foreground Layers", { mergeForeground() }),
            ("Move Objects to Current Layer", { moveObjectsToCurrent() }), ("", {}),
            ("All On", { setAll(visible: true) }), ("All Off", { setAll(visible: false) }),
        ]
        return entries.enumerated().map { LayerMenuItem(id: $0.offset, title: $0.element.0, run: $0.element.1) }
    }

    /// A row's context menu (context-menus.adoc, "Panel menus": the layer items).
    func contextItems(_ layer: LayerInfo) -> [LayerMenuItem] {
        let entries: [(String, @MainActor () -> Void)] = [
            ("New Layer", { newLayer() }), ("Duplicate Layer", { perform(DuplicateLayer(layer.id)) }),
            ("Remove Layer", { remove([layer.id]) }), ("Rename", { beginRename(layer.id) }),
            ("Move Selection to This Layer", { moveSelection(to: layer.id) }),
            (layer.locked ? "Unlock" : "Lock", { perform(toggle(.locked, layer: layer.id)) }),
            (layer.visible ? "Hide" : "Show", { perform(toggle(.visible, layer: layer.id)) }),
            (layer.printing ? "Non-printing" : "Printing", { perform(toggle(.printing, layer: layer.id)) }),
            ("All Layers Visible", { setAll(visible: true) }), ("Merge Selected Layers", { mergeSelected() }),
        ]
        return entries.enumerated().map { LayerMenuItem(id: $0.offset, title: $0.element.0, run: $0.element.1) }
    }
}

/// The Layers panel (`layers`).
enum LayersPanel {
    static func descriptor(selection: ActiveSelection?, state: LayersPanelState) -> PanelDescriptor {
        PanelDescriptor(id: "layers", title: "Layers", icon: "square.3.layers.3d", defaultGroup: PanelCatalog.Group.layers, menuOrder: 20, helpSlug: "layers") {
            LayersPanelBody(selection: selection, state: state)
        }
    }
}
