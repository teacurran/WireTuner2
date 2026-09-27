import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// DOC-012's rest: with a master page's tab in front, the Document panel, the rulers, guides and
/// the Page tool act on the master (master-pages.adoc, "Client").
@Suite(.serialized) @MainActor struct MasterTabPageControlsTests {
    func event(_ point: Point, in window: DocumentWindowController, _ modifiers: KeyModifiers = [], clicks: Int = 1) -> CanvasEvent {
        CanvasEvent(pasteboardPoint: point, viewPoint: window.viewport.toView(point), modifiers: modifiers, clickCount: clicks)
    }

    @Test func theDocumentPanelAndTheRulersReadAndWriteTheMaster() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let master = try await MasterTabTests.childPage(world)
        let child = world.document.activePage.id
        let tabs = MasterTabs()
        let tab = try #require(tabs.open(master, from: world.window))
        defer { tab.window?.close() }
        let handle = tab.documentHandle
        #expect(handle.pageList.isMasterCanvas && !world.document.pageList.isMasterCanvas)
        #expect(handle.activePage.id == master && handle.activePage.origin == .zero && handle.selectedPages.map(\.id) == [master])
        // The rulers' zero point: the master's bottom-left corner on its canvas.
        #expect(handle.activePage.zeroPoint == Point(x: 0, y: 792))
        let model = DocumentPanelModel(window: tab)
        #expect(model.isMasterTab && !model.followsMaster && model.targets == [master] && model.master == .some(nil))
        #expect(!DocumentPanelModel(window: world.window).isMasterTab)
        Render.view(DocumentPanelControls(model: model, state: DocumentPanelState()))
        model.setBleed(12)
        await handle.settle()
        model.setOrientation(.landscape)
        await handle.settle()
        let edited = try #require(PageList(world.state).master(master))
        #expect(edited.bleed == 12 && edited.geometry.orientation == .landscape && edited.geometry.width == 792)
        let page = try #require(PageList(world.state)[child])
        #expect(page.bleed == 12 && page.geometry.width == 792, "the child follows")
        #expect(handle.activePage.rect == Rect(x: 0, y: 0, width: 792, height: 612) && handle.activePage.zeroPoint == Point(x: 0, y: 612))
        model.choosePageSize("Legal")
        await handle.settle()
        #expect(PageList(world.state).master(master)?.geometry.preset == "Legal" && PageList(world.state).master(master)?.geometry.width == 1008)
        // The master follows no master, and the page commands do not apply to it.
        model.chooseMaster(nil)
        model.chooseMaster(master)
        await handle.settle()
        #expect(PageList(world.state)[child]?.master == master)
        #expect(model.optionsMenu().allSatisfy { !$0.isEnabled } && model.optionsMenu().count == 7)
        model.optionsMenu()[0].action()
    }

    @Test func guidesDraggedFromTheRulersLandOnTheMaster() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let master = try await MasterTabTests.childPage(world)
        let tab = try #require(MasterTabs().open(master, from: world.window))
        defer { tab.window?.close() }
        let pages = tab.documentHandle.pageList
        var drag = GuideDrag(source: .ruler, axis: .vertical, point: Point(x: 100, y: 100))
        drag.move(to: Point(x: 144, y: 200), modifiers: [], pages: pages)
        #expect(drag.readout(in: pages, units: tab.documentHandle.unitConverter) != nil)
        let command = try #require(drag.command(in: pages, option: false))
        _ = await tab.documentHandle.perform(command).value
        await world.document.settle()
        let guides = try #require(PageList(world.state).master(master)?.guides)
        #expect(guides.map(\.position) == [144] && guides.map(\.axis) == [.vertical])
        #expect(tab.documentHandle.activePage.guides.map(\.position) == [144], "the tab reads the master's guides")
        // Moved on the master's tab.
        var move = GuideDrag(source: .guide(page: master, ids: guides[0].ids), axis: .vertical, point: Point(x: 144, y: 100))
        move.move(to: Point(x: 200, y: 100), modifiers: [], pages: tab.documentHandle.pageList)
        _ = await tab.documentHandle.perform(try #require(move.command(in: tab.documentHandle.pageList, option: false))).value
        await world.document.settle()
        #expect(PageList(world.state).master(master)?.guides.map(\.position) == [200])
    }

    @Test func thePageToolResizesAndTurnsTheMasterButDoesNotMoveIt() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let master = try await MasterTabTests.childPage(world)
        let tab = try #require(MasterTabs().open(master, from: world.window))
        defer { tab.window?.close() }
        let handle = tab.documentHandle
        let tool = PageTool()
        var context = tab.toolManager.context
        context.snapping.suspended = { true }
        tool.activate(in: context)
        defer { tool.deactivate() }
        // A click selects the master; a drag on it moves nothing.
        tool.mouseDown(event(Point(x: 300, y: 300), in: tab))
        #expect(tool.gesture == nil && handle.selectedPages.map(\.id) == [master])
        tool.mouseUp(event(Point(x: 300, y: 300), in: tab))
        // The top-left handle resizes the master from its bottom-right corner: size only.
        let from = Point(x: 0, y: 0)
        tool.mouseDown(event(from, in: tab))
        #expect(tool.gesture == .resize(page: master, handle: .topLeft))
        tool.mouseDragged(event(Point(x: 50, y: 60), in: tab))
        tool.mouseUp(event(Point(x: 100, y: 92), in: tab))
        await handle.settle()
        let resized = try #require(PageList(world.state).master(master))
        #expect(resized.geometry.width == 512 && resized.geometry.height == 700)
        #expect(handle.activePage.origin == .zero)
        #expect(PageTool.resizeCommand(handle.activePage, to: Rect(x: 10, y: 10, width: 100, height: 100), isMaster: true) is SetPageGeometry)
        // Just outside a corner, a quarter turn swaps the master's orientation in place.
        let corner = Point(x: resized.geometry.width, y: resized.geometry.height)
        let zone = tab.viewport.toPasteboard(tab.viewport.toView(corner) + Vector(dx: 10, dy: 10))
        tool.mouseDown(event(zone, in: tab))
        #expect(tool.gesture == .rotate(page: master))
        let center = handle.activePage.rect.center
        let turned = Point(x: center.x - (zone.y - center.y), y: center.y + (zone.x - center.x))
        tool.mouseDragged(event(turned, in: tab))
        tool.mouseUp(event(turned, in: tab))
        await handle.settle()
        #expect(PageList(world.state).master(master)?.geometry.orientation == .landscape)
        // Delete keeps it: a master is removed from the Library panel.
        tool.removeSelected(in: context)
        await handle.settle()
        #expect(PageList(world.state).master(master) != nil)
    }
}
