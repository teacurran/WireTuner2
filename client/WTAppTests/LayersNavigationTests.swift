import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The Layers panel's keys, *Locate Object*, row pictures and colour drops (layers.adoc,
/// "Objects in the Layers panel"; LIB-031), over `LayersOutlineTests.World`: Top, Art (a text
/// block, a group of two rectangles, a rectangle, frontmost first), the separator, Background.
@Suite(.serialized) @MainActor struct LayersNavigationTests {
    typealias World = LayersOutlineTests.World

    /// A key as the keyboard sends it, handed to the outline as first responder.
    static func press(_ world: World, _ keyCode: UInt16, _ characters: String = "", _ flags: NSEvent.ModifierFlags = []) {
        let scalar: Int? = switch keyCode {
        case 123: NSLeftArrowFunctionKey
        case 124: NSRightArrowFunctionKey
        case 125: NSDownArrowFunctionKey
        case 126: NSUpArrowFunctionKey
        default: nil
        }
        let text = scalar.map { String(UnicodeScalar($0)!) } ?? characters
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: scalar == nil ? flags : flags.union([.function, .numericPad]),
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: world.window.windowNumber, context: nil,
                                     characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: keyCode)!
        #expect(world.window.makeFirstResponder(world.view))
        world.view.keyDown(with: event)
    }

    static let up: UInt16 = 126, down: UInt16 = 125, left: UInt16 = 123, right: UInt16 = 124, returnKey: UInt16 = 36

    /// The node of the one selected row.
    static func selectedNode(_ world: World) -> OpID? {
        guard world.view.selectedRowIndexes.count == 1, let row = world.view.selectedRowIndexes.first else { return nil }
        return (world.view.item(atRow: row) as? LayersTreeItem)?.node
    }

    @Test func arrowKeysWalkEveryRowOfTheNestedTreeAndSelectOnTheCanvas() async {
        let world = await World()
        defer { world.close() }
        let selection = world.controller.selection.model
        let art = world.layers[1]
        world.view.selectRowIndexes([0], byExtendingSelection: false)
        // Down to Art: the panel selects the layer, the canvas nothing; Right opens it, Right
        // again goes to its first row.
        Self.press(world, Self.down)
        #expect(Self.selectedNode(world) == art && world.state.selected == [art] && selection.ids.isEmpty)
        Self.press(world, Self.right)
        #expect(world.view.isItemExpanded(world.outline.existingItem(art)))
        Self.press(world, Self.right)
        #expect(Self.selectedNode(world) == world.text && selection.ids == [SelectionID(world.text)] && world.state.selected.isEmpty)
        Self.press(world, Self.down)
        #expect(selection.ids == [SelectionID(world.group)])
        Self.press(world, Self.right)
        Self.press(world, Self.right)
        // Every row in turn, frontmost first, each selected on the canvas as the keys reach it.
        var reached: [OpID] = []
        for _ in 0..<3 {
            if let node = Self.selectedNode(world) { reached.append(node) }
            #expect(selection.ids == Self.selectedNode(world).map { [SelectionID($0)] })
            Self.press(world, Self.down)
        }
        #expect(reached == [world.members[1], world.members[0], world.rect])
        // Past the separator (never selected) to Background.
        #expect(Self.selectedNode(world) == world.layers[0] && selection.ids.isEmpty)
        Self.press(world, Self.up)
        #expect(Self.selectedNode(world) == world.rect)
        // Shift extends: two objects selected together.
        Self.press(world, Self.up, "", .shift)
        #expect(Set(selection.ids) == [SelectionID(world.rect), SelectionID(world.members[0])])
        // Left from a member goes to its group, then closes it; Option-Right opens everything.
        world.view.selectRowIndexes([world.row(world.members[0])], byExtendingSelection: false)
        Self.press(world, Self.left)
        #expect(Self.selectedNode(world) == world.group && selection.ids == [SelectionID(world.group)])
        Self.press(world, Self.left)
        #expect(!world.view.isItemExpanded(world.outline.existingItem(world.group)))
        Self.press(world, Self.left)
        #expect(Self.selectedNode(world) == art)
        Self.press(world, Self.left)
        #expect(!world.view.isItemExpanded(world.outline.existingItem(art)))
        Self.press(world, Self.right, "", .option)
        #expect(world.view.isItemExpanded(world.outline.existingItem(world.group)), "Option opens everything under the row")
        Self.press(world, Self.left, "", .option)
        #expect(!world.view.isItemExpanded(world.outline.existingItem(art)))
        // Keys the panel does not take stay the outline's; Cmd-arrows are the menus'.
        #expect(!world.outline.key(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                                    characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: Self.right)!))
        #expect(!world.outline.key(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                                    characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: Self.left)!))
    }

    @Test func anObjectTheCanvasCannotSelectKeepsItsRowWhileTheKeysAreOnIt() async {
        let world = await World()
        defer { world.close() }
        world.expand(world.layers[1])
        world.document.hiding.hide([world.rect])
        world.view.selectRowIndexes([world.row(world.group)], byExtendingSelection: false)
        Self.press(world, Self.down)
        #expect(Self.selectedNode(world) == world.rect && world.controller.selection.model.ids.isEmpty)
        // The panel's own refresh keeps the row; the next key goes on from it.
        world.outline.update(world.model, filter: "", marks: [:])
        #expect(Self.selectedNode(world) == world.rect)
        Self.press(world, Self.up)
        #expect(world.controller.selection.model.ids == [SelectionID(world.group)])
        // A canvas selection takes over again.
        world.controller.selection.model.set(Selection([SelectionID(world.text)]))
        #expect(Self.selectedNode(world) == world.text)
    }

    @Test func returnRenamesTheSelectedRowAndTypingSelectsByName() async throws {
        let world = await World()
        defer { world.close() }
        world.expand(world.layers[1])
        world.view.selectRowIndexes([world.row(world.rect)], byExtendingSelection: false)
        Self.press(world, Self.returnKey, "\r")
        #expect(world.state.renamingObject == world.rect)
        let cell = try #require(world.objectCell(world.rect))
        cell.name.stringValue = "Badge"
        world.outline.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: cell.name,
                                                            userInfo: ["NSTextMovement": NSTextMovement.return.rawValue]))
        await world.document.settle()
        #expect(world.document.state.name(of: world.rect) == "Badge")
        #expect(world.window.firstResponder === world.view, "Return leaves the keys with the rows")
        // Enter on a layer row renames the layer; Return with two rows selected does nothing.
        world.view.selectRowIndexes([world.row(world.layers[2])], byExtendingSelection: false)
        Self.press(world, 76, "\u{3}")
        #expect(world.state.renaming == world.layers[2])
        world.model.cancelRename()
        world.view.selectRowIndexes([world.row(world.rect), world.row(world.text)], byExtendingSelection: false)
        Self.press(world, Self.returnKey, "\r")
        #expect(world.state.renamingObject == nil)
        // Typing the start of a name selects its row, on the canvas too.
        let artItem = try #require(world.outline.existingItem(world.layers[1]))
        #expect(world.outline.outlineView(world.view, typeSelectStringFor: nil, item: artItem) == "Art")
        #expect(world.outline.outlineView(world.view, typeSelectStringFor: nil, item: world.outline.existingItem(world.rect)!) == "Badge")
        #expect(world.outline.outlineView(world.view, typeSelectStringFor: nil, item: world.view.item(atRow: world.labels.firstIndex(of: "—")!)!) == nil)
        world.view.selectRowIndexes([0], byExtendingSelection: false)
        Self.press(world, 11, "b")
        Self.press(world, 0, "a")
        Self.press(world, 2, "d")
        #expect(Self.selectedNode(world) == world.rect && world.controller.selection.model.ids == [SelectionID(world.rect)])
    }

    @Test func locateObjectOpensTheRowsContainersAndScrollsTheCanvasToTheObject() async throws {
        let world = await World()
        defer { world.close() }
        let selection = world.controller.selection.model
        selection.set(Selection([SelectionID(world.members[0])]))
        world.view.collapseItem(world.outline.existingItem(world.layers[1]), collapseChildren: true)
        #expect(world.row(world.members[0]) < 0)
        // The command: disabled with nothing selected; it shows the panel and asks the outline.
        var shown: [PanelID] = []
        let command = LayersLocate.command(window: { world.controller }, state: world.state) { shown.append($0) }
        #expect(command.title == "Locate Object" && command.validation() == .enabled)
        #expect(LayersLocate.command(window: { nil }, state: world.state) { _ in }.validation() == .disabled(LayersLocate.noDocument))
        if case .perform(let run) = command.action { run() }
        #expect(shown == ["layers"] && world.state.locateRequest == 1)
        world.outline.update(world.model, filter: "", marks: [:])
        #expect(world.row(world.members[0]) >= 0 && world.view.selectedRowIndexes == [world.row(world.members[0])])
        world.outline.update(world.model, filter: "", marks: [:])
        #expect(world.state.locateAnswered == 1, "a request is answered once")
        // A search hiding the row is cleared.
        world.state.filter = "Headline"
        world.outline.update(world.model, filter: "Headline", marks: [:])
        #expect(world.row(world.members[0]) < 0)
        #expect(world.outline.locate() && world.state.filter.isEmpty && world.row(world.members[0]) >= 0)
        // The panel's options menu has it too.
        world.model.optionItems.first { $0.title == "Locate Object" }?.run()
        #expect(world.state.locateRequest == 2)
        // Nothing selected: nothing located, and the command is disabled.
        selection.clear()
        #expect(!world.outline.locate() && command.validation() == .disabled(LayersLocate.noObject))
        // The canvas: scrolled to the object when it is out of view, left alone when it shows.
        selection.set(Selection([SelectionID(world.rect)]))
        let canvas = world.controller.canvas
        canvas.setViewport(Viewport(scrollOrigin: Point(x: 5_000, y: 5_000), zoom: 1, size: Size(width: 400, height: 300)))
        #expect(LayersLocate.revealOnCanvas(world.controller))
        let bounds = try #require(world.document.object(for: SelectionID(world.rect))?.bounds)
        #expect(canvas.viewport.visiblePasteboardBounds.intersects(bounds))
        #expect(!LayersLocate.revealOnCanvas(world.controller))
        selection.clear()
        #expect(!LayersLocate.revealOnCanvas(world.controller))
    }

    @Test func aColourDroppedOnAnObjectRowFillsItAndCmdStrokesIt() async throws {
        let world = await World()
        defer { world.close() }
        world.expand(world.layers[1])
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wiretuner.test.layersdrop.\(UUID().uuidString)"))
        let red = RenderColor(red: 1, green: 0, blue: 0)
        ColorDrag.write(ColorRefPasteboard(ref: ColorResolver.inline(red), color: red, name: ""), to: pasteboard)
        let rectItem = try #require(world.outline.existingItem(world.rect))
        let on = NSOutlineViewDropOnItemIndex
        func paint(_ kind: AttributeKind) -> RenderColor? {
            let state = world.document.state
            let entry = AppearanceEditing.entries(world.rect, in: state).last { $0.kind == kind }
            return entry.flatMap(AttributeFields.color).flatMap { SwatchList(state).resolver.color($0) }
        }
        // Over a row: copy; between rows, on a layer row or on the separator: refused.
        let info = PasteboardDragging(pasteboard, at: .zero)
        #expect(LayersOutlineController.carriesColor(pasteboard))
        world.outline.dropModifiers = { [] }
        #expect(world.outline.outlineView(world.view, validateDrop: info, proposedItem: rectItem, proposedChildIndex: on) == .copy)
        #expect(world.outline.outlineView(world.view, validateDrop: info, proposedItem: world.outline.existingItem(world.layers[1]), proposedChildIndex: 0) == [])
        #expect(world.outline.colorTarget(item: world.outline.existingItem(world.layers[1]), index: on, modifiers: []) == nil)
        #expect(world.outline.colorTarget(item: nil, index: on, modifiers: []) == nil)
        // The drop: the fill, one change; Cmd the stroke (Shift with it the fill, as on the canvas).
        #expect(world.outline.outlineView(world.view, acceptDrop: info, item: rectItem, childIndex: on))
        await world.document.settle()
        #expect(paint(.fill(.basic)) == red)
        #expect(world.document.undoTitle == "Undo Apply color")
        let blue = RenderColor(red: 0, green: 0, blue: 1)
        ColorDrag.write(ColorRefPasteboard(ref: ColorResolver.inline(blue), color: blue, name: ""), to: pasteboard)
        _ = await world.outline.dropColor(pasteboard, on: rectItem, index: on, modifiers: .command)?.value
        #expect(paint(.stroke(.basic)) == blue && paint(.fill(.basic)) == red)
        #expect(world.outline.colorTarget(item: rectItem, index: on, modifiers: [.command, .shift])?.target == .fill)
        // A locked object or a locked layer refuses.
        _ = await world.document.perform(SetLocked([world.rect], locked: true)).value
        #expect(world.outline.colorTarget(item: rectItem, index: on, modifiers: []) == nil)
        _ = await world.document.perform(SetLocked([world.rect], locked: false)).value
        _ = await world.document.perform(SetLayerFlag([world.layers[1]], .locked, true)).value
        #expect(world.outline.dropColor(pasteboard, on: rectItem, index: on, modifiers: []) == nil)
        world.outline.dropModifiers = { [] }
        #expect(world.outline.outlineView(world.view, validateDrop: info, proposedItem: rectItem, proposedChildIndex: on) == [])
        // A row drag is not a colour drop.
        let rows = NSPasteboard(name: NSPasteboard.Name("wiretuner.test.layersrows.\(UUID().uuidString)"))
        rows.declareTypes([LayersOutlineController.rowType], owner: nil)
        rows.setString("object:x", forType: LayersOutlineController.rowType)
        #expect(!LayersOutlineController.carriesColor(rows))
        #expect(!world.outline.outlineView(world.view, acceptDrop: PasteboardDragging(rows, at: .zero), item: rectItem, childIndex: on))
    }

    @Test func rowsShowAPictureOfTheirObjectDrawnOnceAndAgainOnlyWhenItChanges() async throws {
        let world = await World()
        defer { world.close() }
        let thumbnails = world.outline.thumbnails
        world.expand(world.layers[1])
        world.expand(world.group)
        world.view.layoutSubtreeIfNeeded()
        _ = world.labels
        await Self.settle(thumbnails)
        let objects = [world.text, world.group, world.members[1], world.members[0], world.rect]
        #expect(objects.allSatisfy(thumbnails.isCurrent))
        let cell = try #require(world.objectCell(world.rect))
        #expect(cell.thumbnail.image != nil)
        #expect(LayersThumbnails.picture(nil) == nil)
        // A rename changes no drawing: nothing drawn.  A move redraws the rectangle's row alone.
        var draws = thumbnails.draws
        _ = await world.document.perform(SetNameOrNote([world.rect], .name, "Badge")).value
        await world.document.settle()
        await Self.settle(thumbnails)
        #expect(thumbnails.draws == draws)
        _ = await world.document.perform(MoveObjects([world.rect], by: Vector(dx: 5, dy: 0))).value
        await world.document.settle()
        await Self.settle(thumbnails)
        #expect(Self.redrawn(since: draws, thumbnails) == [world.rect] && thumbnails.isCurrent(world.rect))
        // A member's change redraws it and its group.
        draws = thumbnails.draws
        _ = await world.document.perform(MoveObjects([world.members[0]], by: Vector(dx: 0, dy: 5))).value
        await world.document.settle()
        await Self.settle(thumbnails)
        #expect(Self.redrawn(since: draws, thumbnails) == [world.members[0], world.group])
        // An object no longer drawn (its layer hidden) shows no picture; another document starts over.
        _ = await world.document.perform(SetLayerFlag([world.layers[1]], .visible, false)).value
        #expect(thumbnails.image(for: world.rect) == nil && !thumbnails.isCurrent(world.rect))
        thumbnails.forget(world.rect)
        thumbnails.reset()
        #expect(thumbnails.count == 0 && !thumbnails.isBusy)
    }

    /// The objects whose pictures were drawn since `draws`.
    static func redrawn(since draws: [OpID: Int], _ thumbnails: LayersThumbnails) -> Set<OpID> {
        Set(thumbnails.draws.filter { draws[$0.key] != $0.value }.keys)
    }

    /// Waits for the pictures being drawn.
    static func settle(_ thumbnails: LayersThumbnails) async {
        for _ in 0..<2_000 where thumbnails.isBusy {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The 50,000-object document (LayersOutlineTests' fixture): with the layer open, only the
    /// rows on screen are drawn, off the main thread, and a change to one object draws one row.
    @Test func fiftyThousandObjectsDrawOnlyTheRowsOnScreen() async throws {
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
        let start = clock.now
        await Self.settle(outline.thumbnails)
        let first = clock.now - start
        let visible = outline.visibleObjectRows
        #expect(!visible.isEmpty && visible.count < 100)
        #expect(outline.thumbnails.drawn <= visible.count + LayersThumbnails.batch, "\(outline.thumbnails.drawn) drawn for \(visible.count) rows")
        #expect(visible.allSatisfy { outline.thumbnails.isCurrent($0.node) })
        // One object moved: its row alone is drawn again.
        let draws = outline.thumbnails.draws
        let moved = visible[0].node
        // (The move itself rebuilds the canvas's display list over 50,000 objects, seconds in a Debug
        // build: not the panel's.  The panel's share is each row on screen checking its picture.)
        _ = await document.perform(MoveObjects([moved], by: Vector(dx: 3, dy: 0))).value
        await document.settle()
        await Self.settle(outline.thumbnails)
        let change = clock.measure { outline.refreshVisibleThumbnails() }
        #expect(Self.redrawn(since: draws, outline.thumbnails) == [moved])
        // Scrolling far down draws the rows that come into view, not the ones passed.
        let before = outline.thumbnails.drawn
        outline.outline.scrollRowToVisible(outline.outline.numberOfRows - 1)
        outline.outline.layoutSubtreeIfNeeded()
        await Self.settle(outline.thumbnails)
        #expect(outline.thumbnails.drawn - before <= outline.visibleObjectRows.count + LayersThumbnails.batch)
        print("LIB-031 Layers thumbnails, 50,000 objects: open \(open), first pictures \(first), one change \(change), \(visible.count) rows")
        PerfBudget.expect(open, within: .milliseconds(250), "open a layer of 50,000 objects with pictures")
        PerfBudget.expect(first, within: .milliseconds(500), "draw the pictures of the rows on screen")
        PerfBudget.expect(change, within: .milliseconds(16), "the rows on screen check their pictures after a change")
    }
}
