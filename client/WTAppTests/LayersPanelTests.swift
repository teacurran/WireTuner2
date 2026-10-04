import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

@Suite(.serialized) @MainActor struct LayersPanelTests {
    /// A window over a document with three layers (bottom to top: Background (non-printing),
    /// Art, Top) and a rectangle on Art.
    func setUp() async -> (DocumentWindowController, LayersPanelModel, [OpID], SelectionID) {
        let environment = TestEnvironment()
        let document = DocumentHandle.memory(title: "Layers")
        let controller = DocumentWindowController(document: document, environment: environment.document)
        let art = await document.perform(CreateLayer(name: "Art")).value!.createdNodes[0]
        let top = await document.perform(CreateLayer(name: "Top", above: art)).value!.createdNodes[0]
        let background = await document.perform(CreateLayer(name: "Background", above: nil)).value!.createdNodes[0]
        _ = await document.perform(ReorderLayer(background, to: 0, printing: false)).value
        controller.objectEditing.activeLayer = art
        let shape = CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 20), transform: .translation(x: 10, y: 10),
                                appearance: TestAppearance.filled, layer: art)
        let rect = SelectionID(await document.perform(shape).value!.createdObjects[0])
        await document.settle()
        let state = LayersPanelState()
        let model = LayersPanelModel(document: document, editing: controller.objectEditing, state: state)
        return (controller, model, [background, art, top], rect)
    }

    @Test func rowsListLayersFrontmostFirstWithTheSeparator() async {
        let (controller, model, layers, rect) = await setUp()
        defer { controller.close() }
        #expect(model.rows.map(\.layer?.name) == ["Top", "Art", nil, "Background"])
        #expect(model.rows[2].id == LayersPanelModel.Row.separatorID && model.rows[0].id.hasPrefix("layer:"))
        #expect(model.layers.map(\.id) == [layers[2], layers[1], layers[0]])
        #expect(model.activeLayer == layers[1])
        #expect(!model.isEmpty(layers[1]) && model.isEmpty(layers[2]))
        controller.selection.model.set(Selection([rect]))
        #expect(model.selectionLayers == [layers[1]])
        #expect(model.hiddenActiveWarning == nil)
        #expect(LayersPanelModel.tooltip(model.layers[2]).contains("Background (does not print)"))
        #expect(LayersPanelModel.swatch(model.layers[0]) == .controlAccentColor)
        let body = NSHostingView(rootView: LayersPanelBody(selection: ActiveSelection(model: controller.selection.model, document: controller.documentHandle, editing: controller.objectEditing), state: model.state))
        body.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        body.layoutSubtreeIfNeeded()
        let empty = NSHostingView(rootView: LayersPanelBody(selection: nil, state: model.state))
        empty.layoutSubtreeIfNeeded()
        #expect(LayersPanelBody.model(nil, model.state) == nil)
        #expect(LayersPanel.descriptor(selection: nil, state: model.state).id == "layers")
    }

    @Test func columnsToggleOneLayerAllLayersOrARun() async {
        let (controller, model, layers, _) = await setUp()
        defer { controller.close() }
        let document = controller.documentHandle
        _ = await model.perform(model.toggle(.visible, layer: layers[2]))?.value
        #expect(LayerOrder(document.state).layer(layers[2])?.visible == false)
        #expect(model.toggle(.visible, layer: OpID(counter: 999, replica: 9)) == nil)
        let all = model.toggle(.locked, layer: layers[1], allLayers: true)
        #expect(all?.layers.count == 3 && all?.value == true)
        // Drag-through over the three layers is one change.
        let run = model.dragToggle(.keyline, from: 0, through: 5)
        #expect(run?.layers == model.layers.map(\.id) && run?.label == "Keyline 3 layers")
        #expect(model.dragToggle(.keyline, from: 9, through: 0) == nil)
        _ = await model.perform(run)?.value
        #expect(model.layers.allSatisfy { $0.keyline })
        #expect(model.dragToggle(.printing, from: 1, through: -3)?.layers == [layers[2], layers[1]])
        // The hidden active layer warns.
        _ = await model.perform(model.toggle(.visible, layer: layers[1]))?.value
        #expect(model.hiddenActiveWarning != nil)
        for flag in SetLayerFlag.Flag.allCases { _ = LayersPanelModel.value(flag, of: model.layers[0]) }
        // The row's column closures: a click and a drag.
        LayerRow.column(model, .locked, model.layers[0], 0)(0)
        #expect(LayerOrder(document.state).layer(layers[2])?.locked == true, "the click locks the top row, applied at once (D-076)")
        // The drag starts on the row the click just locked: the run takes the opposite, unlocked.
        LayerRow.column(model, .locked, model.layers[0], 0)(LayersPanelBody.rowHeight * 2)
        await document.settle()
        #expect(LayerOrder(document.state).layer(layers[0])?.locked == false)
    }

    @Test func clickingANameSelectsActivatesAndMoves() async {
        let (controller, model, layers, rect) = await setUp()
        defer { controller.close() }
        let document = controller.documentHandle
        let state = model.state
        // Cmd toggles the panel selection; Shift extends it.
        model.click(layers[2], modifiers: .command)
        model.click(layers[0], modifiers: .command)
        #expect(state.selected == [layers[2], layers[0]])
        model.click(layers[0], modifiers: .command)
        #expect(state.selected == [layers[2]])
        model.click(layers[1], modifiers: .command)
        model.click(layers[0], modifiers: .shift)
        #expect(state.selected == [layers[1], layers[0]])
        // Option selects every object on the layer.
        model.click(layers[1], modifiers: .option)
        #expect(controller.selection.model.ids == [rect])
        // A plain click activates and moves the selection there (the preference).
        _ = await model.click(layers[2], modifiers: [])?.value
        #expect(model.activeLayer == layers[2] && state.selected == [layers[2]])
        #expect(LayerOrder(document.state).layer(of: rect.opID, in: document.state) == layers[2])
        state.clickMoves = { false }
        #expect(model.click(layers[1], modifiers: []) == nil && model.activeLayer == layers[1])
        // A locked layer cannot be made active.
        _ = await model.perform(SetLayerFlag([layers[0]], .locked, true))?.value
        #expect(model.click(layers[0], modifiers: []) == nil && model.activeLayer == layers[1])
        LayerRow.click(model, model.layers[0])()
        LayerRow.rename(model, model.layers[0])()
    }

    @Test func renameReorderAndMenus() async throws {
        let (controller, model, layers, rect) = await setUp()
        defer { controller.close() }
        let document = controller.documentHandle
        let state = model.state
        model.beginRename(layers[1])
        #expect(state.renaming == layers[1])
        #expect(model.commitRename(layers[1], to: "  ") == nil && state.renaming == nil)
        #expect(model.commitRename(layers[1], to: "Art") == nil)
        _ = await model.commitRename(layers[1], to: "Artwork")?.value
        #expect(LayerOrder(document.state).layer(layers[1])?.name == "Artwork")
        model.beginRename(layers[1])
        model.cancelRename()
        #expect(state.renaming == nil)

        // Dragging a layer below the separator makes it a background layer; dragging the separator
        // up flips the layers it crosses.
        let move = try #require(model.move(fromOffsets: [0], toOffset: 4) as? ReorderLayer)
        #expect(move.layer == layers[2] && move.printing == false)
        #expect(model.move(fromOffsets: [0], toOffset: 0) == nil)
        #expect(model.move(fromOffsets: [0, 1], toOffset: 3) == nil)
        #expect(model.move(fromOffsets: [9], toOffset: 0) == nil)
        let flip = try #require(model.move(fromOffsets: [2], toOffset: 1) as? SetLayerFlag)
        #expect(flip.layers == [layers[1]] && flip.flag == .printing && flip.value == false)
        let down = try #require(model.move(fromOffsets: [2], toOffset: 4) as? SetLayerFlag)
        #expect(down.layers == [layers[0]] && down.value == true)
        LayersList.move(model)([0], 4)
        await document.settle()
        #expect(LayerOrder(document.state).layer(layers[2])?.printing == false)

        // The options menu and the row menu.
        #expect(model.optionItems.map(\.title) == ["New", "Duplicate", "Remove", "", "Merge Selected Layers", "Merge Foreground Layers",
                                                   "Move Objects to Current Layer", "", "All On", "All Off", "", "Locate Object", "", "Show Frame Numbers"])
        let before = LayerOrder(document.state).layers.count
        _ = await model.newLayer().value
        #expect(LayerOrder(document.state).layers.count == before + 1 && state.selected.count == 1)
        _ = await model.duplicate()?.value
        #expect(LayerOrder(document.state).layers.count == before + 2)
        _ = await model.setAll(visible: false)?.value
        #expect(LayerOrder(document.state).layers.allSatisfy { !$0.visible })
        for item in model.optionItems where item.title.isEmpty || item.title.hasPrefix("All") { item.run() }
        let rows = model.contextItems(model.layers[0])
        #expect(rows.map(\.title).contains("Move Selection to This Layer"))
        for item in rows where ["Lock", "Unlock", "Hide", "Show", "Non-printing", "Printing", "Rename", "All Layers Visible"].contains(item.title) { item.run() }
        await document.settle()
        controller.selection.model.set(Selection([rect]))
        _ = await model.moveSelection(to: layers[1])?.value
        #expect(LayerOrder(document.state).layer(of: rect.opID, in: document.state) == layers[1])
        controller.objectEditing.activeLayer = layers[0]
        _ = await model.perform(SetLayerFlag([layers[0]], .locked, false))?.value
        _ = await model.moveObjectsToCurrent()?.value
        controller.selection.model.set(.empty)
        #expect(model.moveSelection(to: layers[1]) == nil)
        _ = await model.setHighlight(layers[1], color: .red)?.value
        #expect(LayersPanelModel.swatch(LayerOrder(document.state).layer(layers[1])!).redComponent > 0.9)
        #expect(LayerRow.highlight(model, model.layers[0]).wrappedValue.numberOfComponents > 0)
        LayerRow.highlight(model, model.layers[0]).wrappedValue = NSColor.blue.cgColor
        await document.settle()
    }

    @Test func mergingAndRemoving() async {
        let (controller, model, layers, _) = await setUp()
        defer { controller.close() }
        let document = controller.documentHandle
        let state = model.state
        state.selected = [layers[2]]
        #expect(model.mergeSelected() == nil)
        state.selected = [layers[2], layers[1]]
        _ = await model.mergeSelected()?.value
        #expect(!LayerOrder(document.state).isLive(layers[2]))
        _ = await model.mergeForeground()?.value
        // Removing a layer with objects asks first.
        state.selected = [layers[1]]
        #expect(model.remove() == nil && state.pendingRemoval == [layers[1]])
        #expect(model.removalQuestion == "Remove the layer and everything on it?")
        model.cancelRemoval()
        #expect(state.pendingRemoval.isEmpty && model.confirmRemoval() == nil)
        let empty = await document.perform(CreateLayer(name: "Empty")).value!.createdNodes[0]
        _ = await model.remove([empty])?.value
        #expect(!LayerOrder(document.state).isLive(empty))
        model.remove([layers[1], layers[0]])
        #expect(model.removalQuestion == "Remove 2 layers and everything on them?")
        LayersList.cancelRemoval(model)()
        _ = await model.remove([layers[0]])?.value
        #expect(!LayerOrder(document.state).isLive(layers[0]), "an empty layer goes at once")
        let busy = await document.perform(CreateLayer(name: "Busy")).value!.createdNodes[0]
        _ = await document.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5), layer: busy)).value
        state.selected = [busy]
        #expect(model.remove() == nil)
        _ = await model.confirmRemoval()?.value
        #expect(!LayerOrder(document.state).isLive(busy) && state.selected.isEmpty)
        LayersList.confirmRemoval(model)()
        state.selected = []
        controller.objectEditing.activeLayer = nil
        #expect(model.remove([]) == nil)
        #expect(model.targets == model.activeLayer.map { [$0] } ?? [])
        let host = NSHostingView(rootView: LayersList(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 300)
        host.layoutSubtreeIfNeeded()
    }
}
