import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// A document window over a new document (Letter centred on the pasteboard), for the DOC epic's
/// window tests.
@MainActor
struct SetupWindow {
    let environment = TestEnvironment()
    let window: DocumentWindowController

    /// A window whose registry has `tools` delivered first (the Pointer tool, for instance).
    init(tools: [ToolDescriptor] = []) {
        for tool in tools { environment.tools.replace(tool) }
        window = DocumentWindowController(document: .memory(title: "Setup"), environment: environment.document)
        window.confirm = { _, _ in true }
    }

    var document: DocumentHandle { window.documentHandle }
    var page: Page { document.pageList.pages[0] }

    /// An event at pasteboard `point` through the window's viewport.
    func event(_ point: Point, _ modifiers: KeyModifiers = [], clicks: Int = 1) -> CanvasEvent {
        CanvasEvent(pasteboardPoint: point, viewPoint: window.viewport.toView(point), modifiers: modifiers, clickCount: clicks)
    }

    /// The window point over pasteboard `point`.
    func windowPoint(_ point: Point) -> NSPoint {
        let view = window.viewport.toView(point)
        return window.canvas.convert(NSPoint(x: view.x, y: Double(window.canvas.bounds.height) - view.y), to: nil)
    }

    func close() { window.close() }
}

@Suite @MainActor struct GridGuidesTests {
    @Test func theFurnitureDrawsGridGuidesAndThePageEmphasis() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        let page = setup.page
        _ = await document.perform(AddGuides(on: [page.id], axis: .horizontal, at: [100])).value
        _ = await document.perform(AddGuides(on: [page.id], axis: .vertical, at: [50])).value
        await document.addPage().value
        let furniture = setup.window.furniture
        #expect(!furniture.showsGrid && furniture.showsGuides)
        setup.window.showsGrid = true
        let context = try #require(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let viewport = Viewport(scrollOrigin: Point(x: page.rect.minX - 20, y: page.rect.minY - 20), zoom: 1, size: Size(width: 400, height: 300))
        furniture.draw(in: context, viewport: viewport)
        furniture.drag = GuideDrag(source: .ruler, axis: .horizontal, point: page.rect.center)
        furniture.draw(in: context, viewport: viewport)
        furniture.drag = nil
        // A guide line runs bleed to bleed across its page.
        let line = CanvasFurniture.line(PageGuide(ids: [], axis: .horizontal, position: 100), on: page)
        #expect(line.0.y == page.origin.y + 100 && line.0.x == page.bleedRect.minX && line.1.x == page.bleedRect.maxX)
        let vertical = CanvasFurniture.line(PageGuide(ids: [], axis: .vertical, position: 50), on: page)
        #expect(vertical.0.x == page.origin.x + 50 && vertical.1.y == page.bleedRect.maxY)
        // Hit testing finds the nearest own guide within the tolerance, none when hidden.
        let near = viewport.toView(Point(x: page.rect.midX, y: page.origin.y + 101))
        #expect(furniture.guide(at: near, viewport: viewport, tolerance: 3)?.guide.position == 100)
        #expect(furniture.guide(at: viewport.toView(page.rect.center), viewport: viewport, tolerance: 3) == nil)
        setup.window.showsGuides = false
        #expect(furniture.guide(at: near, viewport: viewport, tolerance: 3) == nil)
        setup.window.showsGuides = true
        // The window's drawer draws the zero-point crosshairs too.
        setup.window.zeroPointDrag = page.rect.center
        setup.window.drawFurniture(in: context)
        setup.window.zeroPointDrag = nil
        // Grid and guide colours come from the preferences.
        setup.environment.preferences.set(PreferenceColor(red: 1, green: 0, blue: 0), for: PreferenceCatalog.Colors.guideColor)
        #expect(furniture.style().guide == Color(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(CanvasFurniture.Style().grid == Color(white: 0.8))
    }

    @Test func collaboratorsShowOnTheirPages() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let page = setup.page
        var priya = RemoteParticipant.test(id: "p", name: "Priya")
        priya.viewport = page.rect
        var tom = RemoteParticipant.test(id: "t", name: "Tom")
        tom.page = SelectionID(page.id)
        var away = RemoteParticipant.test(id: "a", name: "Away")
        away.viewport = Rect(x: 0, y: 0, width: 10, height: 10)
        #expect(CanvasFurniture.page(of: priya, in: setup.document.pageList)?.id == page.id)
        #expect(CanvasFurniture.page(of: tom, in: setup.document.pageList)?.id == page.id)
        #expect(CanvasFurniture.page(of: away, in: setup.document.pageList) == nil)
        setup.window.furniture.participants = { [priya, tom, away] }
        let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        setup.window.furniture.draw(in: context, viewport: setup.window.viewport)
    }

    @Test func guideDragsMoveDeleteAndAddGuides() async {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        let page = setup.page
        _ = await document.perform(AddGuides(on: [page.id], axis: .horizontal, at: [100])).value
        let guide = document.pageList.pages[0].guides[0]
        var drag = GuideDrag(source: .guide(page: page.id, ids: guide.ids), axis: .horizontal, point: Point(x: page.rect.midX, y: page.origin.y + 100))
        #expect(drag.hides == Set(guide.ids))
        drag.move(to: Point(x: page.rect.midX, y: page.origin.y + 205), modifiers: [], pages: document.pageList)
        let move = drag.command(in: document.pageList, option: false) as? MoveGuide
        #expect(move?.position == 205)
        // Shift snaps to the grid (12 pt from the zero point, the bottom-left corner).
        drag.move(to: Point(x: page.rect.midX, y: page.origin.y + 205), modifiers: .shift, pages: document.pageList)
        #expect((drag.command(in: document.pageList, option: false) as? MoveGuide)?.position == 204, "whole picas up from the bottom edge")
        #expect(drag.readout(in: document.pageList, units: Units()) != nil)
        // Dropped on the pasteboard: deleted.
        drag.move(to: Point(x: page.rect.maxX + 200, y: page.origin.y + 205), modifiers: [], pages: document.pageList)
        #expect(drag.command(in: document.pageList, option: false) is DeleteGuides)
        #expect(drag.previewLine(in: document.pageList) != nil, "shown across its page until dropped")
        // A guide of a page that is gone does nothing.
        let gone = GuideDrag(source: .guide(page: OpID(counter: 9, replica: 9), ids: []), axis: .vertical, point: .zero)
        #expect(gone.command(in: document.pageList, option: false) == nil && gone.page(in: document.pageList) == nil)

        // Out of a ruler: over a page it adds, over the pasteboard nothing; Option adds on every page crossed.
        await document.addPage().value
        let second = document.pageList.pages[1]
        var ruler = GuideDrag(source: .ruler, axis: .vertical, point: Point(x: page.origin.x + 30, y: page.rect.midY))
        ruler.move(to: Point(x: page.origin.x + 30, y: page.rect.midY), modifiers: .option, pages: document.pageList)
        ruler.move(to: Point(x: second.origin.x + 30, y: second.rect.midY), modifiers: .option, pages: document.pageList)
        let across = ruler.command(in: document.pageList, option: true) as? AddGuides
        #expect(across?.pages == [page.id, second.id] && across?.positions == [30] && across?.axis == .vertical)
        let single = ruler.command(in: document.pageList, option: false) as? AddGuides
        #expect(single?.pages == [second.id])
        #expect(ruler.previewLine(in: document.pageList) != nil)
        ruler.point = Point(x: 1, y: 1)
        #expect(ruler.command(in: document.pageList, option: false) == nil)
        #expect(ruler.readout(in: document.pageList, units: Units()) == nil)
    }

    @Test func thePointerDragsGuidesAndDeleteRemovesTheClickedOne() async {
        let setup = SetupWindow()
        defer { setup.close() }
        let window = setup.window
        let document = setup.document
        let page = setup.page
        _ = await document.perform(AddGuides(on: [page.id], axis: .horizontal, at: [100, 300])).value
        let handles = window.guideHandles
        let context = window.toolManager.context
        let on = Point(x: page.rect.midX, y: page.origin.y + 100)
        // A miss leaves the press to the tool.
        #expect(!handles.press(setup.event(page.rect.center), context: context))
        #expect(handles.press(setup.event(on), context: context))
        handles.drag(setup.event(Point(x: on.x, y: on.y + 50)), context: context)
        #expect(window.furniture.drag != nil)
        handles.release(setup.event(Point(x: on.x, y: on.y + 50)), context: context)
        await document.settle()
        #expect(document.pageList.pages[0].guides.map(\.position).sorted() == [150, 300])
        #expect(document.undoTitle == "Undo Move guide")
        // Esc during a drag writes nothing.
        #expect(handles.press(setup.event(Point(x: on.x, y: page.origin.y + 300)), context: context))
        handles.cancel(context: context)
        #expect(window.furniture.drag == nil)
        handles.drag(setup.event(on), context: context)
        handles.release(setup.event(on), context: context)
        // Delete removes the clicked guide while nothing is selected.
        #expect(window.validate(selector: #selector(DocumentWindowController.delete(_:))))
        window.delete(nil)
        await document.settle()
        #expect(document.pageList.pages[0].guides.map(\.position) == [150])
        #expect(handles.deletionCommand() == nil)
        // A double-click opens the Guides sheet.
        var edited: [OpID] = []
        handles.editGuides = { edited.append($0) }
        let at150 = Point(x: on.x, y: page.origin.y + 150)
        #expect(handles.press(setup.event(at150, clicks: 2), context: context))
        #expect(edited == [page.id])
        // Locked guides do not move.
        _ = await window.toggleGuidesLocked().value
        #expect(document.settings.guidesLocked)
        #expect(handles.press(setup.event(at150), context: context))
        #expect(window.furniture.drag == nil && handles.deletionCommand() == nil)
        _ = await window.toggleGuidesLocked().value
        // A guide removed by someone else mid-drag ends the drag with a message.
        #expect(handles.press(setup.event(at150), context: context))
        let ids = document.pageList.pages[0].guides[0].ids
        await document.receiveRemote(DeleteGuides(on: page.id, ids))
        handles.drag(setup.event(Point(x: at150.x, y: at150.y + 10)), context: context)
        #expect(window.furniture.drag == nil)
        #expect(handles.press(setup.event(page.rect.center), context: context) == false)
        window.furniture.drag = GuideDrag(source: .guide(page: page.id, ids: ids), axis: .horizontal, point: at150)
        handles.release(setup.event(at150), context: context)
        #expect(window.furniture.drag == nil)
        handles.draw(in: CGContext.test(), viewport: window.viewport, context: context)
        handles.deselect()
    }

    @Test func rulersDragOutGuidesAndTheZeroPointMoves() async {
        let setup = SetupWindow()
        defer { setup.close() }
        let window = setup.window
        let document = setup.document
        let page = setup.page
        window.setViewport(window.canvas.navigation.centring(window.viewport, on: page.rect.center))
        // Out of the top ruler onto the page: a horizontal guide there.
        let target = Point(x: page.rect.midX, y: page.origin.y + 200)
        window.rulerDrag(.horizontal, .began, at: setup.windowPoint(page.rect.center), modifiers: [])
        window.rulerDrag(.horizontal, .moved, at: setup.windowPoint(target), modifiers: [])
        #expect(window.furniture.drag != nil)
        window.rulerDrag(.horizontal, .ended, at: setup.windowPoint(target), modifiers: [])
        await document.settle()
        let guide = document.pageList.pages[0].guides.first
        #expect(guide?.axis == .horizontal && abs((guide?.position ?? 0) - 200) < 0.01)
        window.rulerDrag(.vertical, .ended, at: setup.windowPoint(target), modifiers: [])
        // The rulers' views forward their drags.
        var phases: [RulerStripView.DragPhase] = []
        window.rulerHost.horizontalRuler.onDrag = { phase, _, _ in phases.append(phase) }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!
        window.rulerHost.horizontalRuler.mouseDown(with: event)
        window.rulerHost.horizontalRuler.mouseDragged(with: event)
        window.rulerHost.horizontalRuler.mouseUp(with: event)
        #expect(phases == [.began, .moved, .ended])

        // The zero point: dragged with Shift onto the page's centre, then reset by a double-click.
        let corner = window.rulerHost.corner
        var cornerPhases: [RulerStripView.DragPhase] = []
        var resets = 0
        let dragZero = corner.onDrag, reset = corner.onReset
        corner.onDrag = { phase, _, _ in cornerPhases.append(phase) }
        corner.onReset = { resets += 1 }
        corner.mouseDown(with: event)
        corner.mouseDragged(with: event)
        corner.mouseUp(with: event)
        let double = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                        eventNumber: 0, clickCount: 2, pressure: 1)!
        corner.mouseDown(with: double)
        corner.mouseUp(with: double)
        #expect(cornerPhases == [.began, .moved, .ended] && resets == 1)
        corner.onDrag = dragZero
        corner.onReset = reset
        window.zeroPointDragged(.began, at: setup.windowPoint(page.rect.center), modifiers: .shift)
        #expect(window.zeroPointDrag == page.rect.center)
        window.zeroPointDragged(.ended, at: setup.windowPoint(Point(x: page.rect.midX + 3, y: page.rect.midY)), modifiers: .shift)
        await document.settle()
        #expect(window.zeroPointDrag == nil)
        #expect(document.activePage.zeroPoint == page.rect.center && document.undoTitle == "Undo Move zero point")
        #expect(window.rulerHost.horizontalRuler.frameOfReference.zero == page.rect.center)
        window.zeroPointDragged(.moved, at: setup.windowPoint(page.rect.center), modifiers: [])
        _ = await window.resetZeroPoint().value
        #expect(document.activePage.rulerOrigin == Point(x: 0, y: page.rect.height) && document.undoTitle == "Undo Reset zero point")
        #expect(ZeroPointDrop.point(Point(x: 1, y: 2), on: page, shift: false) == Point(x: 1, y: 2))
        #expect(ZeroPointDrop.targets(on: page).count == 5)
        corner.draw(corner.bounds)
    }

    @Test func showGridGuidesAndLockAreViewCommandsKeptPerWindow() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let window = setup.window
        let features = DocumentSetupFeatures(preferences: setup.environment.preferences, device: "mac")
        features.install(commands: setup.environment.commands, panels: setup.environment.panels, tools: setup.environment.tools) { [weak window] in window }
        let registry = setup.environment.commands
        let ids = StandardCommands.ID.self
        #expect(registry.validate(ids.showGrid)?.isChecked == false)
        #expect(registry.perform(ids.showGrid))
        #expect(window.showsGrid && registry.validate(ids.showGrid)?.isChecked == true)
        #expect(registry.validate(ids.showGuides)?.isChecked == true)
        #expect(registry.perform(ids.showGuides))
        #expect(!window.showsGuides)
        #expect(registry.perform(ids.lockGuides))
        await setup.document.settle()
        #expect(registry.validate(ids.lockGuides)?.isChecked == true)
        #expect(setup.document.changeCount == 1, "showing never writes; locking is one change")
        // The toggles persist with the window's view state.
        let state = window.currentState
        #expect(state.showGrid == true && state.showGuides == false && state.documentPanelScale == 0)
        window.apply(DocumentWindowState())
        #expect(!window.showsGrid && window.showsGuides)
        window.apply(state)
        #expect(window.showsGrid && !window.showsGuides)
        // The sheets open on the window.
        for id in [ids.editGrid, ids.editGuides, ids.pageRulerUnits] {
            #expect(registry.perform(id))
            #expect(window.window?.attachedSheet != nil)
            if let sheet = window.window?.attachedSheet { window.window?.endSheet(sheet) }
        }
        let none = DocumentSetupFeatures(preferences: setup.environment.preferences, device: "mac")
        #expect(none.commands().allSatisfy { $0.validation() == .disabled(DocumentSetupFeatures.noDocument) })
        #expect(none.showLinks() == nil)
    }

    @Test func snappingResolvesAgainstGridGuidesAndObjects() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let window = setup.window
        let document = setup.document
        let page = setup.page
        _ = await document.perform(AddGuides(on: [page.id], axis: .vertical, at: [100])).value
        let squares = await document.addRectangles([Rect(x: page.origin.x + 300, y: page.origin.y + 300, width: 40, height: 40)])
        let (sources, toggles) = window.snapSources()
        #expect(sources.guides.contains(.vertical(x: page.origin.x + 100)) && toggles.guides && !toggles.grid)
        var snapping = window.toolManager.context.snapping
        snapping.suspended = { false }
        var sounds: [WireTuner.SnapKind] = []
        snapping.didSnap = { sounds.append($0) }
        let viewport = Viewport(zoom: 1, size: Size(width: 400, height: 300))
        // Near the guide: onto it, once sounded.
        let near = Point(x: page.origin.x + 101.5, y: page.origin.y + 50)
        #expect(snapping.snap(near, viewport: viewport).x == page.origin.x + 100)
        #expect(snapping.snap(near, viewport: viewport).x == page.origin.x + 100)
        #expect(sounds == [.guide])
        // Near a corner of the square: a point wins.
        let corner = Point(x: page.origin.x + 301, y: page.origin.y + 301)
        #expect(snapping.resolve(corner, viewport: viewport)?.point == Point(x: page.origin.x + 300, y: page.origin.y + 300))
        #expect(sounds.last == .point)
        // Selected objects are not snapped to (they are what is dragged).
        window.selection.model.set(Selection(squares))
        #expect(window.snapSources().sources.excludedItems.count == 1)
        // A drag snaps by the pressed point; Control suspends.
        let delta = snapping.snapDrag(of: Point(x: page.origin.x + 90, y: page.origin.y + 50), by: Vector(dx: 11, dy: 0), viewport: viewport)
        #expect(delta.dx == 10)
        snapping.suspended = { true }
        #expect(snapping.snap(near, viewport: viewport) == near)
        #expect(snapping.snapDrag(of: near, by: Vector(dx: 1, dy: 1), viewport: viewport) == Vector(dx: 1, dy: 1))
        // No sources (a tool outside a window): unchanged.
        let bare = SnappingContext()
        #expect(bare.snap(near, viewport: viewport) == near && bare.snapDrag(of: near, by: Vector(dx: 2, dy: 0), viewport: viewport) == Vector(dx: 2, dy: 0))
        #expect(WireTuner.SnapKind(WTGeometry.SnapKind.path) == .object && WireTuner.SnapKind(.smartGuide) == .guide && WireTuner.SnapKind(.grid) == .grid)
    }

    @Test func thePointerSnapsMovesAndTheActivePageFollowsTools() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let window = setup.window
        let document = setup.document
        let page = setup.page
        _ = await document.perform(AddGuides(on: [page.id], axis: .vertical, at: [100])).value
        let squares = await document.addRectangles([Rect(x: page.origin.x + 50, y: page.origin.y + 50, width: 40, height: 40)])
        window.selection.model.set(Selection(squares))
        let manager = window.toolManager!
        var snapping = manager.context.snapping
        snapping.suspended = { false }
        let tool = PointerTool()
        var context = manager.context
        context.snapping = snapping
        tool.activate(in: context)
        let start = Point(x: page.origin.x + 88, y: page.origin.y + 60)
        tool.mouseDown(setup.event(start))
        tool.mouseDragged(setup.event(Point(x: page.origin.x + 101, y: page.origin.y + 60)))
        #expect(tool.moveDelta == Vector(dx: 12, dy: 0), "the pressed point lands on the guide")
        tool.mouseUp(setup.event(Point(x: page.origin.x + 101, y: page.origin.y + 60)))
        await document.settle()

        // Using tools sets the active page (on by default); changing view does too, after 200 ms.
        await document.addPage().value
        let second = document.pageList.pages[1]
        window.toolPressed(at: page.rect.center)
        #expect(document.activePage.id == page.id)
        window.toolPressed(at: Point(x: 1, y: 1))
        #expect(document.activePage.id == page.id)
        window.setViewport(window.canvas.navigation.fit(window.viewport, rect: second.rect))
        #expect(await eventually { document.activePage.id == second.id })
        #expect(DocumentWindowController.page(coveringMostOf: Rect(x: 0, y: 0, width: 1, height: 1), in: document.pageList) == nil)
        setup.environment.preferences.set(false, for: PreferenceCatalog.Document.viewSetsPage)
        setup.environment.preferences.set(false, for: PreferenceCatalog.Document.toolsSetPage)
        window.viewDidMove()
        window.toolPressed(at: page.rect.center)
        #expect(document.activePage.id == second.id)
    }
}

extension RemoteParticipant {
    /// A participant with nothing selected.
    static func test(id: String, name: String, colorIndex: Int = 0) -> RemoteParticipant {
        RemoteParticipant(id: id, name: name, colorIndex: colorIndex, tool: "pointer")
    }
}

extension CGContext {
    /// A small bitmap context to draw into.
    static func test(width: Int = 64, height: Int = 64) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
}
