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
            let row = row(node)
            return row >= 0 ? view.view(atColumn: 0, row: row, makeIfNecessary: true) as? ObjectRowCell : nil
        }

        func close() {
            window.close()
            outline.detach()
            controller.close()
        }

        /// The window point at the middle of row `row`.
        func point(row: Int) -> NSPoint {
            let rect = view.rect(ofRow: row)
            return view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        }

        /// A window point in the outline's empty space below its rows.
        var belowTheRows: NSPoint {
            view.convert(NSPoint(x: 40, y: view.rect(ofRow: view.numberOfRows - 1).maxY + 40), to: nil)
        }

        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        func layerCell(_ layer: OpID) -> LayerRowCell? {
            let row = row(layer)
            return row >= 0 ? view.view(atColumn: 0, row: row, makeIfNecessary: true) as? LayerRowCell : nil
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

    /// A right-click, as AppKit asks the outline for its menu: a row's menu over a row, none in
    /// the empty space below the rows.  A Shift-click from an object on one layer to one on
    /// another adds the object rows between, never the layer row between them.
    @Test func rightClicksAskForTheRowsMenuAndShiftClicksSpanLayers() async throws {
        let world = await World()
        defer { world.close() }
        world.expand(world.layers[1])
        #expect(world.view.menu(for: world.event(.rightMouseDown, world.point(row: world.row(world.rect))))?.items.first?.title == "Rename…")
        #expect(world.view.menu(for: world.event(.rightMouseDown, world.belowTheRows)) == nil)
        let selection = world.controller.selection.model
        let ellipse = try #require(await world.document.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5), layer: world.layers[2])).value?.createdObjects.first)
        world.expand(world.layers[2])
        world.outline.click(row: world.row(ellipse), modifiers: [])
        world.outline.click(row: world.row(world.text), modifiers: .shift)
        #expect(Set(selection.ids) == [SelectionID(ellipse), SelectionID(world.text)])
        // The double-click of the separator renames nothing.
        world.outline.beginRename(row: world.labels.firstIndex(of: "—")!)
        #expect(world.state.renamingObject == nil && world.state.renaming == nil)
    }

    /// A drag through a flag column, sent as real mouse events: the first row's new value goes to
    /// every layer row crossed -- ending on an object row counts its layer, ending above the list
    /// the top layer, ending in the space below it the bottom layer.
    @Test func dragsThroughAFlagColumnSetEveryLayerCrossed() async throws {
        let world = await World()
        defer { world.close() }
        world.window.orderFront(nil)
        world.expand(world.layers[1])
        func drag(_ flag: FlagControl, to end: NSPoint) async {
            let start = flag.convert(NSPoint(x: flag.bounds.midX, y: flag.bounds.midY), to: nil)
            world.window.postEvent(world.event(.leftMouseDragged, NSPoint(x: start.x, y: (start.y + end.y) / 2)), atStart: false)
            world.window.postEvent(world.event(.leftMouseUp, end), atStart: false)
            flag.mouseDown(with: world.event(.leftMouseDown, start))
            await world.document.settle()
        }
        let order = { LayerOrder(world.document.state) }
        let (background, art, top) = (world.layers[0], world.layers[1], world.layers[2])
        // Art's Preview circle into the space below the rows: Art and Background turn Keyline.
        await drag(try #require(world.layerCell(art)).keyline, to: world.belowTheRows)
        #expect(order().layer(art)?.keyline == true && order().layer(background)?.keyline == true && order().layer(top)?.keyline == false)
        #expect(world.layerCell(art)?.keyline.image?.accessibilityDescription == "Keyline")
        // Background's check mark up past the top of the list: every layer hides.
        await drag(try #require(world.layerCell(background)).visible, to: world.view.convert(NSPoint(x: 20, y: -30), to: nil))
        #expect(order().layers.allSatisfy { !$0.visible })
        // Top's padlock down onto an object row of Art: Top and Art lock.
        await drag(try #require(world.layerCell(top)).lock, to: world.point(row: world.row(world.rect)))
        #expect(order().layer(top)?.locked == true && order().layer(art)?.locked == true && order().layer(background)?.locked == false)
    }

    /// A search opens what it shows; a selected object the search leaves out stays shut away; and
    /// clearing the search reopens the rows that were open before it.
    @Test func clearingASearchReopensWhatWasOpen() async throws {
        let world = await World()
        defer { world.close() }
        world.expand(world.layers[1])
        world.expand(world.group)
        _ = await world.document.perform(SetNameOrNote([world.rect], .name, "Logo")).value
        world.outline.update(world.model, filter: "Logo", marks: [:])
        #expect(world.labels == ["Top", "Art", "  Logo", "—", "Background"])
        world.controller.selection.model.set(Selection([SelectionID(world.members[0])]))
        #expect(world.row(world.members[0]) < 0 && world.view.selectedRowIndexes.isEmpty, "a group the search hides is not opened")
        world.controller.selection.model.clear()
        world.outline.update(world.model, filter: "", marks: [:])
        let group = try #require(world.outline.existingItem(world.group))
        #expect(world.view.isItemExpanded(world.outline.existingItem(world.layers[1])) && world.view.isItemExpanded(group))
        #expect(!world.view.isItemExpanded(world.outline.existingItem(world.layers[2])))
    }

    /// The outline's drop target as AppKit asks it: a drop proposed on an object lands beside it
    /// (the outline is retargeted), one inside an object that holds nothing or a locked group is
    /// refused, and an accepted drop makes its one change and ends the drag.  Layer and separator
    /// rows write their keys.
    @Test func dropsAreValidatedAndAcceptedThroughTheDataSource() async throws {
        let world = await World()
        defer { world.close() }
        world.expand(world.layers[1])
        world.expand(world.group)
        let info = DraggingInfoStub(pasteboardName: "layers", panel: nil, location: .zero)
        let rectItem = try #require(world.outline.existingItem(world.rect))
        let groupItem = try #require(world.outline.existingItem(world.group))
        let textItem = try #require(world.outline.existingItem(world.text))
        let artItem = try #require(world.outline.existingItem(world.layers[1]))
        let separator = try #require(world.view.item(atRow: world.labels.firstIndex(of: "—")!))
        func key(_ item: Any) -> String? {
            (world.outline.outlineView(world.view, pasteboardWriterForItem: item) as? NSPasteboardItem)?.string(forType: LayersOutlineController.rowType)
        }
        #expect(key(artItem) == "layer:\(world.layers[1])" && key(separator) == LayersPanelModel.Row.separatorID && key(rectItem) == "object:\(world.rect)")
        world.outline.beginDrag([rectItem])
        #expect(world.outline.outlineView(world.view, validateDrop: info, proposedItem: textItem, proposedChildIndex: -1) == .move)
        #expect(world.outline.dropTarget(item: textItem, index: -1)?.container === artItem)
        #expect(world.outline.outlineView(world.view, validateDrop: info, proposedItem: groupItem, proposedChildIndex: 1) == .move)
        #expect(world.outline.outlineView(world.view, validateDrop: info, proposedItem: textItem, proposedChildIndex: 0) == [], "a text block holds no rows")
        _ = await world.document.perform(SetLocked([world.group], locked: true)).value
        #expect(world.outline.dropTarget(item: groupItem, index: 0) == nil && !world.outline.drop(item: groupItem, index: 0), "a locked group takes nothing")
        _ = await world.document.perform(SetLocked([world.group], locked: false)).value
        #expect(world.outline.outlineView(world.view, acceptDrop: info, item: groupItem, childIndex: 0))
        await world.document.settle()
        #expect(world.model.tree.children(of: world.group).first == world.rect)
        #expect(world.outline.dropTarget(item: groupItem, index: 0) == nil, "the drag is over")
        // A layer dragged and removed by a collaborator before the drop: nothing moves.
        let top = try #require(world.outline.existingItem(world.layers[2]))
        world.outline.beginDrag([top])
        _ = await world.document.perform(RemoveLayers([world.layers[2]])).value
        #expect(!world.outline.drop(item: nil, index: 0))
    }

    /// The data source answers for a container AppKit asks about before counting it, the
    /// same rows it would count.
    @Test func childrenAreListedEvenBeforeTheyAreCounted() async throws {
        let world = await World()
        defer { world.close() }
        let fresh = LayersOutlineController()
        defer { fresh.detach() }
        fresh.update(world.model, filter: "", marks: [:])
        let art = LayersTreeItem(.layer(world.layers[1]))
        let first = try #require(fresh.outlineView(fresh.outline, child: 0, ofItem: art) as? LayersTreeItem)
        #expect(first.node == world.text && fresh.outlineView(fresh.outline, numberOfChildrenOfItem: art) == 3)
    }

    /// Renames at the edges: the Guides layer is not renamed; kbd:[Esc] on an unnamed layer shows
    /// "Layer" again; a row menu that outlived its object renames nothing.  With a Guides layer, a
    /// drop between ordinary layers restacks.
    @Test func renamesAndDropsAtTheEdges() async throws {
        let world = await World()
        defer { world.close() }
        let guides = try #require(await world.document.perform(OpsCommand("Guides", ops: [{
            var props = Wiretuner_Doc_V1_NodeProps()
            props.layer.common.name = "Guides"
            props.layer.role = .guides
            props.layer.visible = true
            props.layer.printing = true
            return Ops.create(parent: WellKnown.layers, position: [0xF0], props: props)
        }()])).value?.createdNodes.first)
        world.outline.beginRename(row: world.row(guides))
        #expect(world.state.renaming == nil)
        let unnamed = try #require(await world.document.perform(CreateLayer(name: "", above: world.layers[2])).value?.createdNodes.first)
        world.outline.beginRename(row: world.row(unnamed))
        let cell = try #require(world.layerCell(unnamed))
        #expect(world.state.renaming == unnamed && cell.name.stringValue == "")
        #expect(world.outline.control(cell.name, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(cell.name.stringValue == "Layer" && world.state.renaming == nil)
        world.expand(world.layers[1])
        let menu = try #require(world.view.contextMenu?(world.row(world.text)))
        _ = await world.document.perform(DeleteNodes([world.text])).value
        (menu.items[0].representedObject as? LayerMenuAction)?.run(nil)
        #expect(world.state.renamingObject == nil)
        _ = await world.model.dropObjects([world.rect], into: world.layers[2], at: 0)?.value
        #expect(world.model.tree.children(of: world.layers[2]) == [world.rect])
    }

    /// Each kind of object has its own icon in its row (a hose set, which the panel does not know,
    /// is an "Object" with a square), and the row menus offer the opposite of each row's state.
    @Test func everyKindHasItsIconAndMenusOfferTheOppositeState() async throws {
        let world = await World()
        defer { world.close() }
        let art = world.layers[1]
        func make(_ fill: (inout Wiretuner_Doc_V1_NodeProps) -> Void) async throws -> OpID {
            var props = Wiretuner_Doc_V1_NodeProps()
            fill(&props)
            return try #require(await world.document.perform(OpsCommand("Kind", ops: [Ops.create(parent: art, position: [0x90], props: props)])).value?.createdNodes.first)
        }
        let expected: [(String, (inout Wiretuner_Doc_V1_NodeProps) -> Void)] = [
            ("pentagon", { $0.polygon = .init() }), ("chart.bar", { $0.chart = .init() }),
            ("point.3.connected.trianglepath.dotted", { $0.connector = .init() }), ("circle.lefthalf.filled", { $0.blend = .init() }),
            ("cube", { $0.extrude = .init() }), ("square.grid.3x3", { $0.envelope = .init() }), ("perspective", { $0.perspective = .init() }),
            ("seal", { $0.instance = .init() }), ("photo", { $0.image = .init() }), ("doc.richtext", { $0.placedFile = .init() }),
            ("play.rectangle", { $0.svgAnimation = .init() }), ("barcode", { $0.barcode = .init() }), ("square", { $0.hoseSet = .init() }),
        ]
        var nodes: [(String, OpID)] = []
        for (symbol, fill) in expected { nodes.append((symbol, try await make(fill))) }
        let compound = try #require(await world.document.perform(CreatePath(contours: [
            NewContour(closed: true, points: [VectorPoint(anchor: Point(x: 0, y: 0)), VectorPoint(anchor: Point(x: 10, y: 0)), VectorPoint(anchor: Point(x: 10, y: 10))]),
            NewContour(closed: true, points: [VectorPoint(anchor: Point(x: 2, y: 2)), VectorPoint(anchor: Point(x: 8, y: 2)), VectorPoint(anchor: Point(x: 8, y: 8))]),
        ], layer: art)).value?.createdObjects.first)
        nodes.append(("square.on.square.dashed", compound))
        let open = try #require(await world.document.perform(CreatePath(contours: [
            NewContour(points: [VectorPoint(anchor: Point(x: 0, y: 0)), VectorPoint(anchor: Point(x: 10, y: 5))]),
        ], layer: art)).value?.createdObjects.first)
        nodes.append(("scribble", open))
        // A clip group: the rectangle is its clip path.
        let clip = try await make {
            $0.group.kind = .clip
            $0.group.clipPath.id = world.rect.proto
        }
        _ = await world.document.perform(OpsCommand("Clip", ops: [Ops.move(world.rect, parent: clip, position: [0x80]), Ops.move(world.text, parent: clip, position: [0x40])])).value
        nodes += [("rectangle.dashed", clip), ("scissors", world.rect)]
        await world.document.settle()
        let tree = world.model.tree
        for (symbol, node) in nodes {
            #expect(LayersPanelModel.ObjectRow(node, tree: tree, hidden: []).symbol == symbol, "\(tree.state.nodeKind(node).map { "\($0)" } ?? "unknown")")
        }
        #expect(LayersPanelModel.ObjectRow(nodes.first { $0.0 == "square" }!.1, tree: tree, hidden: []).kindTitle == "Object")
        // The rows draw them (the outline asks for every row's cell).
        world.expand(art)
        world.expand(clip)
        // (A hose set is not an object: it has no row.)
        for (symbol, node) in nodes where symbol != "square" { #expect(world.objectCell(node)?.icon.image != nil, "\(symbol): row \(world.row(node)) of \(world.labels)") }
        #expect(world.row(nodes.first { $0.0 == "square" }!.1) < 0)

        // A named object hidden on this Mac draws dimmed; showing what is not hidden changes nothing.
        let polygon = nodes[0].1
        _ = await world.document.perform(SetNameOrNote([polygon], .name, "Star")).value
        world.document.hiding.hide([polygon])
        #expect(world.objectCell(polygon)?.name.textColor == .secondaryLabelColor)
        let hidden = world.document.locallyHidden
        world.document.hiding.show([world.members[0]])
        #expect(world.document.locallyHidden == hidden)
        // Menus: an unlocked, hidden object offers Lock and Show; a locked, non-printing layer
        // Unlock and Printing.
        let objectMenu = try #require(world.view.contextMenu?(world.row(polygon)))
        #expect(objectMenu.items.map(\.title) == ["Rename…", "Select", "Lock", "Show"])
        _ = await world.document.perform(SetLayerFlag([world.layers[0]], .locked, true)).value
        let layerMenu = try #require(world.view.contextMenu?(world.row(world.layers[0])))
        #expect(layerMenu.items.map(\.title).contains("Unlock") && layerMenu.items.map(\.title).contains("Printing"))
    }

    /// Edits the outline must follow and edits it must ignore: deleting two rows of an open layer
    /// at once removes both; editing an unnamed text block's text relabels its row; a change that
    /// touches no object (a preview ending) reloads nothing.
    @Test func multiRowDeletesTextEditsAndEmptyChanges() async throws {
        let world = await World()
        defer { world.close() }
        world.expand(world.layers[1])
        _ = await world.document.perform(DeleteNodes([world.rect, world.group])).value
        #expect(world.labels == ["Top", "Art", "  Headline", "—", "Background"])
        let text = try #require(world.document.state.textNode(world.text))
        _ = await world.document.perform(DeleteText(node: world.text, from: text.anchor(at: 0), to: text.anchor(at: 4))).value
        await world.document.settle()
        #expect(world.labels.contains("  line"), "\(world.labels)")
        _ = await world.document.perform(InsertText(node: world.text, text: "Bylines", at: .start)).value
        await world.document.settle()
        #expect(world.labels.contains("  Bylinesline"), "\(world.labels)")
        let counts = (world.outline.fullReloads, world.outline.containerUpdates, world.outline.rowReloads)
        world.document.preview(nil)
        #expect(world.outline.fullReloads == counts.0 && world.outline.containerUpdates == counts.1 && world.outline.rowReloads == counts.2)
    }

    /// The outline before the panel binds it to a document: nothing is listed, and clicks,
    /// renames, menus, edits and the selection do nothing.  Cells not yet given a row ignore
    /// their controls.
    @Test func anUnboundOutlineAndUnboundCellsDoNothing() {
        let outline = LayersOutlineController()
        let node = OpID(counter: 1, replica: 1)
        #expect(outline.childIDs(of: node).isEmpty)
        #expect(outline.outlineView(outline.outline, numberOfChildrenOfItem: nil) == 0)
        outline.click(row: 0, modifiers: [])
        outline.beginRename(row: 0)
        outline.syncSelection(reveal: true)
        #expect(outline.outline.contextMenu?(0) == nil)
        #expect(outline.layerIndex(at: .zero) == nil)
        #expect(outline.outlineView(outline.outline, viewFor: nil, item: LayersTreeItem(.object(node))) == nil)
        outline.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: NSTextField()))
        outline.documentDidChange(ContentChange(summary: ChangeSummary(origin: .local, isStructural: true), before: DisplayList(canvas: "c", items: []),
                                                after: DisplayList(canvas: "c", items: []), change: nil))
        #expect(outline.fullReloads == 0)
        // What AppKit may hand the data source and delegate that is not one of the outline's rows.
        let foreign = "not a row" as NSString
        #expect(outline.outlineView(outline.outline, pasteboardWriterForItem: foreign) == nil)
        #expect(!outline.outlineView(outline.outline, shouldSelectItem: foreign))
        #expect(outline.outlineView(outline.outline, numberOfChildrenOfItem: LayersTreeItem(.separator)) == 0)
        let layerCell = LayerRowCell()
        layerCell.colorChanged(layerCell.swatch)
        layerCell.beginEditing(outline)
        #expect(layerCell.name.stringValue == "" && layerCell.name.isEditable)
        let objectCell = ObjectRowCell()
        objectCell.eye.performClick(nil)
        objectCell.lock.performClick(nil)
        objectCell.beginEditing(outline)
        #expect(!objectCell.name.isEditable)
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
