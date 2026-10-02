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

/// The Layers panel's object tree (layers.adoc, "Objects in the Layers panel"; D-092): the outline
/// of layers and their objects, its clicks, renames, toggles, drags and search, and that a model
/// change updates only what it touched.
@Suite(.serialized) @MainActor struct LayersOutlineTests {
    @MainActor struct World {
        let environment = TestEnvironment()
        let controller: DocumentWindowController
        let document: DocumentHandle
        let state = LayersPanelState()
        let outline = LayersOutlineController()
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 320, height: 600))
        /// Bottom to top: Background (non-printing), Art, Top.
        var layers: [OpID] = []
        /// On Art, bottom first: a rectangle, a group of two rectangles, a text block.
        var rect = OpID.zero, group = OpID.zero, members: [OpID] = [], text = OpID.zero

        init() async {
            document = DocumentHandle.memory(title: "Objects")
            controller = DocumentWindowController(document: document, environment: environment.document)
            let art = await document.perform(CreateLayer(name: "Art")).value!.createdNodes[0]
            let top = await document.perform(CreateLayer(name: "Top", above: art)).value!.createdNodes[0]
            let background = await document.perform(CreateLayer(name: "Background", above: nil)).value!.createdNodes[0]
            _ = await document.perform(ReorderLayer(background, to: 0, printing: false)).value
            layers = [background, art, top]
            controller.objectEditing.activeLayer = art
            func rectangle(_ x: Double) async -> OpID {
                await document.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 20), transform: .translation(x: x, y: 10),
                                                   appearance: TestAppearance.filled, layer: art)).value!.createdObjects[0]
            }
            rect = await rectangle(10)
            members = [await rectangle(40), await rectangle(70)]
            group = await document.perform(GroupObjects(members, layer: art)).value!.createdNodes[0]
            text = await document.perform(CreateTextBlock(.area(Rect(x: 0, y: 100, width: 100, height: 30)), text: "Headline", layer: art)).value!.createdObjects[0]
            await document.settle()
            window.contentView = outline.scrollView
            outline.scrollView.frame = window.contentView?.bounds ?? .zero
            outline.update(model, filter: "", marks: [:])
        }

        var model: LayersPanelModel { LayersPanelModel(document: document, editing: controller.objectEditing, state: state) }
        var view: LayersOutlineView { outline.outline }

        func row(_ node: OpID) -> Int { outline.existingItem(node).map(view.row(forItem:)) ?? -1 }

        func expand(_ node: OpID) {
            if let item = outline.existingItem(node) { view.expandItem(item) }
        }

        /// The labels of the rows shown, top first.
        var labels: [String] {
            (0..<view.numberOfRows).map { index in
                switch view.view(atColumn: 0, row: index, makeIfNecessary: true) {
                case let cell as LayerRowCell: cell.name.stringValue
                case let cell as ObjectRowCell: "  " + cell.name.stringValue
                default: "—"
                }
            }
        }

        func objectCell(_ node: OpID) -> ObjectRowCell? {
            view.view(atColumn: 0, row: row(node), makeIfNecessary: true) as? ObjectRowCell
        }

        func close() {
            window.close()
            outline.detach()
            controller.close()
        }
    }

    @Test func layersOpenToTheirObjectsFrontmostFirstAndGroupsToTheirMembers() async {
        let world = await World()
        defer { world.close() }
        #expect(world.labels == ["Top", "Art", "—", "Background"])
        #expect(world.view.isExpandable(world.outline.existingItem(world.layers[1])))
        #expect(!world.view.isExpandable(world.outline.existingItem(world.layers[2])), "an empty layer has no triangle")
        world.expand(world.layers[1])
        #expect(world.labels == ["Top", "Art", "  Headline", "  Group", "  Rectangle", "—", "Background"])
        world.expand(world.group)
        #expect(world.labels == ["Top", "Art", "  Headline", "  Group", "  Rectangle", "  Rectangle", "  Rectangle", "—", "Background"])
        #expect(world.view.level(forRow: world.row(world.members[0])) == 2)
        // The cells: an unnamed row is italic and dimmed; its icon is its kind's.
        let cell = try! #require(world.objectCell(world.rect))
        #expect(cell.name.textColor == .secondaryLabelColor && cell.icon.image != nil)
        #expect(cell.toolTip == "Rectangle")
        let row = LayersPanelModel.ObjectRow(world.group, tree: world.model.tree, hidden: [])
        #expect(row.symbol == "folder" && !row.isNamed && row.kindTitle == "Group")
        // The row views and the separator.
        #expect(world.view.rowView(atRow: 0, makeIfNecessary: true) is LayersRowView)
        #expect(world.view.view(atColumn: 0, row: world.labels.firstIndex(of: "—")!, makeIfNecessary: true) is SeparatorCell)
        #expect(!world.outline.outlineView(world.view, shouldSelectItem: world.view.item(atRow: world.labels.firstIndex(of: "—")!)!))
        #expect(!world.outline.outlineView(world.view, shouldEdit: nil, item: world.view.item(atRow: 0)!))
    }

    @Test func clickingRowsSelectsOnTheCanvasAndTheCanvasRevealsRows() async {
        let world = await World()
        defer { world.close() }
        let selection = world.controller.selection.model
        // A canvas selection inside a group opens the layer and the group and selects the row.
        selection.set(Selection([SelectionID(world.members[1])]))
        #expect(world.row(world.members[1]) >= 0)
        #expect(world.view.selectedRowIndexes == [world.row(world.members[1])])
        // A click on a row selects its object alone; Cmd adds; Shift adds the rows between.
        world.outline.click(row: world.row(world.rect), modifiers: [])
        #expect(selection.ids == [SelectionID(world.rect)])
        world.outline.click(row: world.row(world.text), modifiers: .command)
        #expect(Set(selection.ids) == [SelectionID(world.rect), SelectionID(world.text)])
        world.outline.click(row: world.row(world.text), modifiers: .command)
        #expect(selection.ids == [SelectionID(world.rect)])
        world.outline.click(row: world.row(world.group), modifiers: .command)
        world.outline.click(row: world.row(world.text), modifiers: .shift)
        #expect(Set(selection.ids) == [SelectionID(world.rect), SelectionID(world.group), SelectionID(world.text)])
        #expect(world.view.selectedRowIndexes.count == 3)
        // A layer row still makes its layer active (and, by default, moves the selection there).
        world.controller.selection.model.clear()
        world.outline.click(row: world.row(world.layers[2]), modifiers: [])
        #expect(world.model.activeLayer == world.layers[2] && world.state.selected == [world.layers[2]])
        #expect(world.view.selectedRowIndexes == [world.row(world.layers[2])])
        // The separator selects nothing.
        world.outline.click(row: world.labels.firstIndex(of: "—")!, modifiers: [])
        // Objects hidden on this Mac or on a locked layer are not selected.
        world.document.hiding.hide([world.rect])
        world.outline.click(row: world.row(world.rect), modifiers: [])
        #expect(selection.ids.isEmpty)
        world.document.hiding.show([world.rect])
        _ = await world.document.perform(SetLayerFlag([world.layers[1]], .locked, true)).value
        world.outline.click(row: world.row(world.text), modifiers: [])
        #expect(selection.ids.isEmpty && !world.model.canSelect(world.text))
        world.outline.clicked(nil)
        world.outline.doubleClicked(nil)
    }

    @Test func aRowsNameRenamesItsObjectInPlace() async throws {
        let world = await World()
        defer { world.close() }
        world.expand(world.layers[1])
        let row = world.row(world.rect)
        world.outline.beginRename(row: row)
        #expect(world.state.renamingObject == world.rect)
        let cell = try #require(world.objectCell(world.rect))
        #expect(cell.name.isEditable && cell.name.placeholderString == "Rectangle")
        cell.name.stringValue = "  Logo mark "
        world.outline.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: cell.name))
        await world.document.settle()
        #expect(world.document.state.name(of: world.rect) == "Logo mark")
        #expect(world.objectCell(world.rect)?.name.stringValue == "Logo mark")
        #expect(world.objectCell(world.rect)?.name.textColor == .labelColor)
        // Esc keeps the name; an unchanged name writes nothing; an empty one clears it.
        world.outline.beginRename(row: world.row(world.rect))
        #expect(world.outline.control(cell.name, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(world.state.renamingObject == nil)
        #expect(!world.outline.control(cell.name, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        world.model.beginObjectRename(world.rect)
        #expect(world.model.commitObjectRename(world.rect, to: "Logo mark") == nil)
        _ = await world.model.commitObjectRename(world.rect, to: "")?.value
        #expect(world.document.state.name(of: world.rect) == nil)
        world.model.beginObjectRename(OpID(counter: 999, replica: 9))
        #expect(world.state.renamingObject == nil)
        // A layer row renames its layer.
        world.outline.beginRename(row: world.row(world.layers[2]))
        #expect(world.state.renaming == world.layers[2])
        let layerCell = try #require(world.view.view(atColumn: 0, row: world.row(world.layers[2]), makeIfNecessary: true) as? LayerRowCell)
        layerCell.name.stringValue = "Front"
        world.outline.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: layerCell.name))
        await world.document.settle()
        #expect(LayerOrder(world.document.state).layer(world.layers[2])?.name == "Front")
        world.outline.beginRename(row: world.row(world.layers[2]))
        #expect(world.outline.control(layerCell.name, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(world.state.renaming == nil)
    }

    @Test func anEditUpdatesOnlyTheRowsItTouched() async {
        let world = await World()
        defer { world.close() }
        world.expand(world.layers[1])
        world.expand(world.group)
        let reloads = world.outline.fullReloads
        // A rename: one row redrawn, no container re-listed.
        let lists = world.outline.containerUpdates
        _ = await world.document.perform(SetNameOrNote([world.members[0]], .name, "Eye")).value
        #expect(world.outline.fullReloads == reloads && world.outline.containerUpdates == lists)
        #expect(world.labels.contains("  Eye"))
        // A new object: its layer's rows gain one, in place.
        let created = await world.document.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5), layer: world.layers[1])).value!.createdObjects[0]
        #expect(world.outline.containerUpdates == lists + 1 && world.row(created) == world.row(world.layers[1]) + 1)
        #expect(world.view.isItemExpanded(world.outline.existingItem(world.group)), "an open group stays open")
        // Deleted, undone, regrouped, moved by a remote change: rows follow, still incrementally.
        _ = await world.document.perform(DeleteNodes([created])).value
        #expect(world.row(created) < 0)
        _ = await world.document.undo().value
        #expect(world.row(created) >= 0)
        _ = await world.document.perform(Ungroup([world.group])).value
        #expect(world.row(world.group) < 0 && world.view.level(forRow: world.row(world.members[0])) == 1)
        _ = await world.document.perform(SetLayerFlag([world.layers[2]], .locked, true)).value
        #expect(world.outline.fullReloads == reloads)
        // Hiding on this Mac redraws the row's eye.
        world.document.hiding.hide([world.rect])
        #expect(world.objectCell(world.rect)?.eye.image?.accessibilityDescription == "Hidden on this Mac")
    }

    @Test func togglesInObjectRowsHideOnThisMacAndLock() async throws {
        let world = await World()
        defer { world.close() }
        world.expand(world.layers[1])
        let cell = try #require(world.objectCell(world.rect))
        cell.eye.performClick(nil)
        #expect(world.document.locallyHidden.contains(world.rect))
        try #require(world.objectCell(world.rect)).eye.performClick(nil)
        #expect(!world.document.locallyHidden.contains(world.rect))
        try #require(world.objectCell(world.rect)).lock.performClick(nil)
        await world.document.settle()
        #expect(Objects.isLocked(world.rect, in: world.document.state))
        #expect(world.objectCell(world.rect)?.lock.image?.accessibilityDescription == "Locked")
        #expect(LayersPanelModel.ObjectRow(world.rect, tree: world.model.tree, hidden: [world.rect]).tooltip == "Rectangle · Locked · Hidden on this Mac")
        // The row menu.
        let menu = try #require(world.view.contextMenu?(world.row(world.rect)))
        #expect(menu.items.map(\.title) == ["Rename…", "Select", "Unlock", "Hide"])
        for item in menu.items where item.title != "Rename…" { (item.representedObject as? LayerMenuAction)?.run(nil) }
        await world.document.settle()
        #expect(!Objects.isLocked(world.rect, in: world.document.state) && world.document.locallyHidden.contains(world.rect))
        (menu.items[0].representedObject as? LayerMenuAction)?.run(nil)
        #expect(world.state.renamingObject == world.rect)
        let layerMenu = try #require(world.view.contextMenu?(world.row(world.layers[1])))
        #expect(layerMenu.items.map(\.title).contains("Move Selection to This Layer"))
        #expect(world.view.contextMenu?(world.labels.firstIndex(of: "—")!) == nil)
        // A layer row's flag columns: a click toggles that layer.
        let layerCell = try #require(world.view.view(atColumn: 0, row: world.row(world.layers[2]), makeIfNecessary: true) as? LayerRowCell)
        layerCell.visible.end?(layerCell.visible.convert(NSPoint(x: 4, y: 4), to: nil))
        await world.document.settle()
        #expect(LayerOrder(world.document.state).layer(world.layers[2])?.visible == false)
        #expect(layerCell.lock.accessibilityPerformPress())
        await world.document.settle()
        #expect(LayerOrder(world.document.state).layer(world.layers[2])?.locked == true)
        layerCell.swatch.color = .red
        layerCell.colorChanged(layerCell.swatch)
    }

    @Test func draggingRowsRestacksRegroupsAndReordersLayersInOneChange() async throws {
        let world = await World()
        defer { world.close() }
        world.expand(world.layers[1])
        world.expand(world.group)
        let tree = { world.model.tree }
        let rectItem = try #require(world.outline.existingItem(world.rect))
        let groupItem = try #require(world.outline.existingItem(world.group))
        let artItem = try #require(world.outline.existingItem(world.layers[1]))
        let topItem = try #require(world.outline.existingItem(world.layers[2]))
        #expect(world.outline.outlineView(world.view, pasteboardWriterForItem: rectItem) != nil)
        // Into the group, between its members.
        world.outline.beginDrag([rectItem])
        #expect(world.outline.dropTarget(item: groupItem, index: 1)?.index == 1)
        #expect(world.outline.drop(item: groupItem, index: 1))
        await world.document.settle()
        #expect(tree().children(of: world.group) == [world.members[1], world.rect, world.members[0]])
        #expect(world.view.level(forRow: world.row(world.rect)) == 2)
        _ = await world.document.undo().value
        #expect(tree().children(of: world.layers[1]).last == world.rect, "one undo step")
        // Dropped on an object: beside it.  Dropped on a layer: at its top.
        world.outline.beginDrag([rectItem])
        let textItem = try #require(world.outline.existingItem(world.text))
        #expect(world.outline.dropTarget(item: textItem, index: -1)?.container === artItem)
        #expect(world.outline.drop(item: topItem, index: -1))
        await world.document.settle()
        #expect(tree().children(of: world.layers[2]) == [world.rect])
        // Refused: a group into its own member, objects between layers at the root, a locked layer.
        world.outline.beginDrag([groupItem])
        #expect(world.outline.dropTarget(item: world.outline.existingItem(world.members[0]), index: -1) == nil)
        #expect(world.outline.dropTarget(item: nil, index: 0) == nil)
        _ = await world.document.perform(SetLayerFlag([world.layers[2]], .locked, true)).value
        #expect(world.outline.dropTarget(item: topItem, index: 0) == nil)
        // A layer row moves among the layers.
        _ = await world.document.perform(SetLayerFlag([world.layers[2]], .locked, false)).value
        world.outline.beginDrag([topItem])
        #expect(world.outline.dropTarget(item: artItem, index: 0) == nil)
        #expect(world.outline.drop(item: nil, index: 4))
        await world.document.settle()
        #expect(LayerOrder(world.document.state).layer(world.layers[2])?.printing == false)
        world.outline.beginDrag([])
        #expect(world.outline.dropTarget(item: nil, index: 0) == nil)
        // Onto the Guides layer: the guides command.
        let guides = await world.document.perform(OpsCommand("Guides", ops: [{
            var props = Wiretuner_Doc_V1_NodeProps()
            props.layer.common.name = "Guides"
            props.layer.role = .guides
            props.layer.visible = true
            props.layer.printing = true
            return Ops.create(parent: WellKnown.layers, position: [0xF0], props: props)
        }()])).value!.createdNodes[0]
        _ = await world.model.dropObjects([world.text], into: guides, at: 0)?.value
        #expect(LayerOrder(world.document.state).layer(of: world.text, in: world.document.state) == guides)
        _ = await world.model.dropObjects([world.text], into: world.layers[1], at: 0)?.value
        #expect(LayerOrder(world.document.state).layer(of: world.text, in: world.document.state) == world.layers[1])
    }

    @Test func searchShowsMatchingObjectsWithTheirContainersOpen() async {
        let world = await World()
        defer { world.close() }
        _ = await world.document.perform(SetNameOrNote([world.members[0]], .name, "Left eye")).value
        world.state.filter = "eye"
        world.outline.update(world.model, filter: "eye", marks: [:])
        #expect(world.labels == ["Top", "Art", "  Group", "  Left eye", "—", "Background"])
        #expect(world.outline.outlineView(world.view, pasteboardWriterForItem: world.outline.existingItem(world.members[0])!) == nil, "no dragging while searching")
        // A rename that stops matching drops the row.
        _ = await world.document.perform(SetNameOrNote([world.members[0]], .name, "Left")).value
        #expect(!world.labels.contains("  Left"))
        world.outline.update(world.model, filter: "", marks: [:])
        #expect(world.outline.shown == nil && world.labels.count == 4, "\(world.labels)")
        // The SwiftUI host shows the field and the outline.
        let active = ActiveSelection(model: world.controller.selection.model, document: world.document, editing: world.controller.objectEditing)
        PanelRendering.host(LayersPanelBody(selection: active, state: world.state))
        LayersList.filter(world.state).wrappedValue = "x"
        #expect(world.state.filter == "x")
        #expect(LayersList.marks(world.model).count == 3)
    }

    @Test func frameMarksAndPlayingTintFollowTheAnimation() async {
        let world = await World()
        defer { world.close() }
        world.outline.update(world.model, filter: "", marks: [world.layers[2]: LayerFrameMarks(number: 2, playing: true)])
        let row = world.row(world.layers[2])
        #expect((world.view.rowView(atRow: row, makeIfNecessary: true) as? LayersRowView)?.playing == true)
        let cell = world.view.view(atColumn: 0, row: row, makeIfNecessary: true) as? LayerRowCell
        #expect(cell?.frameNumber.stringValue == "2" && cell?.frameNumber.isHidden == false)
        let rowView = LayersRowView()
        rowView.playing = true
        rowView.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        rowView.display()
        SeparatorCell(frame: NSRect(x: 0, y: 0, width: 10, height: 10)).display()
        // Another document rebinds the outline.
        let other = await World()
        defer { other.close() }
        world.outline.update(other.model, filter: "", marks: [:])
        #expect(world.outline.model?.document === other.document && world.labels == ["Top", "Art", "—", "Background"])
    }

    /// The outline over the 50,000-rectangle design-point document (D-092, "Performance"): opening
    /// the layer lists its rows without making a view per row, and a rename, a move and a new
    /// object each update the outline without reloading it.  Timed against a frame in the perf run.
    @Test func fiftyThousandObjectsOpenAndUpdateWithinAFrame() async throws {
        let environment = TestEnvironment()
        let document = CanvasPerformanceTests.denseDocument()
        let controller = DocumentWindowController(document: document, environment: environment.document)
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 320, height: 600))
        let outline = LayersOutlineController()
        window.contentView = outline.scrollView
        defer {
            window.close()
            outline.detach()
            controller.close()
        }
        let model = LayersPanelModel(document: document, editing: controller.objectEditing, state: LayersPanelState())
        outline.update(model, filter: "", marks: [:])
        let layer = try #require(LayerOrder(document.state).layers.first { !outline.childIDs(of: $0.id).isEmpty }?.id)
        let clock = ContinuousClock()
        let open = clock.measure {
            outline.outline.expandItem(outline.existingItem(layer))
            outline.outline.layoutSubtreeIfNeeded()
        }
        #expect(outline.outline.numberOfRows >= CanvasPerformanceTests.objectCount)
        let objects = outline.childIDs(of: layer)
        let reloads = outline.fullReloads
        var renames: [Double] = []
        // Three renames: each one also rebuilds the canvas's display list over all 50,000 objects,
        // which in a Debug build takes seconds (DocumentDisplayListBuilder, not the panel).
        for index in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = await document.perform(SetNameOrNote([objects[index]], .name, "Tile \(index)")).value
            renames.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        let move = clock.measure { _ = document.perform(RestackObjects([objects[5]], into: layer, at: 0)) }
        await document.settle()
        #expect(outline.childIDs(of: layer).first == objects[5])
        #expect(outline.fullReloads == reloads, "edits update the outline in place")
        // A large canvas selection is found by one pass over the rows.
        controller.selection.model.set(Selection(objects.prefix(300).map(SelectionID.init)))
        #expect(outline.outline.selectedRowIndexes.count == 300)
        let stats = CanvasPerformanceTests.Stats(samples: renames)
        print("D-092 Layers panel, 50,000 objects: open \(open), rename \(stats), move \(move)")
        PerfBudget.expect(open, within: .milliseconds(250), "open a layer of 50,000 objects")
        PerfBudget.expect(.seconds(stats.p95), within: .milliseconds(16), "rename with 50,000 rows")
        PerfBudget.expect(move, within: .milliseconds(100), "restack with 50,000 rows")
    }
}
