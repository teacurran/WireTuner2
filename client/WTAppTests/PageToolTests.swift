import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

@Suite @MainActor struct PageToolTests {
    /// A window with the Page tool active and two pages.
    @MainActor
    struct Fixture {
        let setup = SetupWindow()
        let tool = PageTool()

        static func make(pages: Int = 2) async -> Fixture {
            let fixture = Fixture()
            for _ in 1..<pages { await fixture.setup.document.addPage().value }
            var context = fixture.setup.window.toolManager.context
            context.snapping.suspended = { true }
            fixture.tool.activate(in: context)
            return fixture
        }

        var document: DocumentHandle { setup.document }
        var pages: [Page] { document.pageList.pages }

        func drag(_ from: Point, _ to: Point, _ modifiers: KeyModifiers = []) {
            tool.mouseDown(setup.event(from, modifiers))
            tool.mouseDragged(setup.event(Point(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), modifiers))
            tool.mouseDragged(setup.event(to, modifiers))
            tool.mouseUp(setup.event(to, modifiers))
        }

        func click(_ point: Point, _ modifiers: KeyModifiers = [], clicks: Int = 1) {
            tool.mouseDown(setup.event(point, modifiers, clicks: clicks))
            tool.mouseUp(setup.event(point, modifiers, clicks: clicks))
        }

        func close() { setup.close() }
    }

    @Test func clicksSelectPagesAndMarqueesSelectSeveral() async {
        let fixture = await Fixture.make()
        defer { fixture.close() }
        let (a, b) = (fixture.pages[0], fixture.pages[1])
        fixture.click(a.rect.center)
        #expect(fixture.document.selectedPages.map(\.id) == [a.id] && fixture.document.activePage.id == a.id)
        fixture.click(b.rect.center, .shift)
        #expect(fixture.document.selectedPages.map(\.id) == [a.id, b.id])
        fixture.click(b.rect.center, .shift)
        #expect(fixture.document.selectedPages.map(\.id) == [a.id])
        // A click on the pasteboard deselects; a marquee touching both selects both.
        fixture.click(Point(x: a.rect.minX - 100, y: a.rect.minY - 100))
        #expect(fixture.document.selectedPageIDs.isEmpty)
        fixture.drag(Point(x: a.rect.minX - 50, y: a.rect.minY - 50), Point(x: b.rect.minX + 10, y: b.rect.minY + 10))
        #expect(Set(fixture.document.selectedPageIDs) == [a.id, b.id])
        fixture.drag(Point(x: a.rect.minX - 50, y: a.rect.minY - 50), Point(x: a.rect.minX - 40, y: a.rect.minY - 40), .shift)
        #expect(Set(fixture.document.selectedPageIDs) == [a.id, b.id], "an empty Shift-marquee keeps the selection")
        #expect(fixture.tool.cursor == .arrow && !fixture.tool.hasSomethingToCancel)
    }

    @Test func draggingMovesPagesWithOrWithoutTheirObjects() async {
        let fixture = await Fixture.make()
        defer { fixture.close() }
        let document = fixture.document
        let a = fixture.pages[0]
        let squares = await document.addRectangles([Rect(x: a.rect.minX + 100, y: a.rect.minY + 100, width: 50, height: 50)])
        let top = document.object(for: squares[0])?.bounds?.minY ?? 0
        fixture.drag(a.rect.center, a.rect.center + Vector(dx: 0, dy: 100))
        await document.settle()
        #expect(document.pageList.pages[0].origin == a.origin + Vector(dx: 0, dy: 100))
        #expect(document.object(for: squares[0])?.bounds?.minY == top + 100)
        #expect(document.undoTitle == "Undo Move page")
        // Cmd: the frame alone.
        let moved = document.pageList.pages[0]
        fixture.drag(moved.rect.center, moved.rect.center + Vector(dx: 0, dy: 50), .command)
        await document.settle()
        #expect(document.pageList.pages[0].origin == moved.origin + Vector(dx: 0, dy: 50))
        #expect(document.object(for: squares[0])?.bounds?.minY == top + 100)
        // Shift, held once the drag has started, constrains to horizontal or vertical.
        let now = document.pageList.pages[0]
        fixture.tool.mouseDown(fixture.setup.event(now.rect.center))
        fixture.tool.flagsChanged(fixture.setup.event(now.rect.center, .shift))
        fixture.tool.mouseDragged(fixture.setup.event(now.rect.center + Vector(dx: 5, dy: 80), .shift))
        fixture.tool.drawOverlay(in: CGContext.test(), viewport: fixture.setup.window.viewport)
        fixture.tool.mouseUp(fixture.setup.event(now.rect.center + Vector(dx: 5, dy: 80), .shift))
        await document.settle()
        #expect(document.pageList.pages[0].origin == now.origin + Vector(dx: 0, dy: 80))
        // Several selected pages move together, one change.
        let pages = fixture.pages
        document.selectPages(pages.map(\.id))
        fixture.drag(pages[1].rect.center, pages[1].rect.center + Vector(dx: 10, dy: 0))
        await document.settle()
        #expect(document.undoTitle == "Undo Move 2 pages")
        // A tiny drag is a click.
        fixture.drag(pages[1].rect.center, pages[1].rect.center + Vector(dx: 1, dy: 0))
        // Pages stay on the pasteboard.
        document.selectPage(id: pages[0].id)
        let first = document.pageList.pages[0]
        fixture.drag(first.rect.center, first.rect.center + Vector(dx: -20_000, dy: 0))
        await document.settle()
        #expect(document.pageList.pages[0].origin.x == 0)
    }

    @Test func optionDragDuplicatesWhereReleased() async {
        let fixture = await Fixture.make(pages: 1)
        defer { fixture.close() }
        let document = fixture.document
        let a = fixture.pages[0]
        _ = await document.addRectangles([Rect(x: a.rect.minX + 10, y: a.rect.minY + 10, width: 20, height: 20)])
        let target = a.rect.center + Vector(dx: 0, dy: 1000)
        fixture.drag(a.rect.center, target, .option)
        #expect(await eventually { document.pageList.pages.count == 2 && document.pageList.pages[1].origin == a.origin + Vector(dx: 0, dy: 1000) })
        await document.settle()
        _ = document.undo()
        await document.settle()
        #expect(document.pageList.pages.count == 1, "the duplicate and its move are one undo step")
    }

    @Test func handlesResizeAndTheRotateZoneTurnsThePage() async {
        let fixture = await Fixture.make(pages: 1)
        defer { fixture.close() }
        let document = fixture.document
        let a = fixture.pages[0]
        fixture.click(a.rect.center)
        // The bottom-right handle: wider and taller, top-left fixed; the preset becomes Custom.
        fixture.drag(Point(x: a.rect.maxX, y: a.rect.maxY), Point(x: a.rect.maxX + 100, y: a.rect.maxY + 50))
        await document.settle()
        var page = document.pageList.pages[0]
        #expect(page.rect == Rect(x: a.rect.minX, y: a.rect.minY, width: 712, height: 842) && page.geometry.preset.isEmpty)
        #expect(document.undoTitle == "Undo Change page size")
        // The left handle moves the origin too, one change.
        fixture.drag(Point(x: page.rect.minX, y: page.rect.midY), Point(x: page.rect.minX + 12, y: page.rect.midY))
        await document.settle()
        page = document.pageList.pages[0]
        #expect(page.rect.minX == a.rect.minX + 12 && page.rect.width == 700)
        // Rotating a quarter turn in the zone outside a corner swaps width and height.
        let outside = Point(x: page.rect.maxX + 8, y: page.rect.maxY + 8)
        let viewCorner = fixture.setup.window.viewport.toView(outside)
        #expect(fixture.tool.rotateZone(at: viewCorner, viewport: fixture.setup.window.viewport, document: document)?.id == page.id)
        let center = page.rect.center
        let turned = Point(x: center.x - (outside.y - center.y), y: center.y + (outside.x - center.x))
        fixture.tool.mouseDown(fixture.setup.event(outside))
        fixture.tool.mouseDragged(fixture.setup.event(turned))
        fixture.tool.drawOverlay(in: CGContext.test(), viewport: fixture.setup.window.viewport)
        fixture.tool.mouseUp(fixture.setup.event(turned))
        await document.settle()
        #expect(document.pageList.pages[0].geometry.width == page.rect.height && document.undoTitle == "Undo Rotate page")
        #expect(!PageTool.rotates(.zero, from: Point(x: 1, y: 0), to: Point(x: 1, y: 0.1)))
        #expect(!PageTool.rotates(.zero, from: Point(x: 1, y: 0), to: Point(x: -1, y: -0.2)), "a half turn is not a quarter turn")
        // Shift keeps the proportions; Option resizes about the centre; degenerate sizes are refused.
        let rect = Rect(x: 0, y: 0, width: 100, height: 200)
        #expect(PageTool.resize(rect, anchor: .bottomRight, to: Point(x: 200, y: 250), proportional: true, fromCenter: false) == Rect(x: 0, y: 0, width: 200, height: 400))
        #expect(PageTool.resize(rect, anchor: .right, to: Point(x: 150, y: 0), proportional: false, fromCenter: true) == Rect(x: -50, y: 0, width: 200, height: 200))
        #expect(PageTool.resize(rect, anchor: .top, to: Point(x: 0, y: 50), proportional: true, fromCenter: true) == Rect(x: 25, y: 50, width: 50, height: 100))
        #expect(PageTool.resize(rect, anchor: .left, to: Point(x: 100, y: 0), proportional: false, fromCenter: false) == nil)
        #expect(PageTool.resize(rect, anchor: .topLeft, to: Point(x: -100, y: -100), proportional: true, fromCenter: false) == Rect(x: -100, y: -200, width: 200, height: 400))
        #expect(HandleAnchor.allCases.map(\.opposite.opposite) == HandleAnchor.allCases)
    }

    @Test func childPagesRefuseResizeAndRotate() async throws {
        let fixture = await Fixture.make(pages: 1)
        defer { fixture.close() }
        let document = fixture.document
        let a = fixture.pages[0]
        _ = await document.perform(ConvertToMasterPage(a.id)).value
        fixture.click(a.rect.center)
        fixture.tool.drawOverlay(in: CGContext.test(), viewport: fixture.setup.window.viewport)
        fixture.drag(Point(x: a.rect.maxX, y: a.rect.maxY), Point(x: a.rect.maxX + 100, y: a.rect.maxY + 50))
        let outside = Point(x: a.rect.maxX + 8, y: a.rect.maxY + 8)
        fixture.drag(outside, Point(x: a.rect.minX - 8, y: a.rect.maxY + 400))
        await document.settle()
        #expect(document.pageList.pages[0].rect == a.rect)
    }

    @Test func deleteRemovesSelectedPagesAndOptionDoubleClickModifiesOne() async {
        let fixture = await Fixture.make(pages: 3)
        defer { fixture.close() }
        let document = fixture.document
        let pages = fixture.pages
        _ = await document.addRectangles([Rect(x: pages[2].rect.minX + 10, y: pages[2].rect.minY + 10, width: 20, height: 20)])
        let asked = ValueLog<String>()
        let answer = ValueLog<Bool>()
        var context = fixture.setup.window.toolManager.context
        context.confirm = { message, _ in asked.values.append(message); return answer.values.last ?? false }
        let modified = ValueLog<OpID>()
        context.modifyPage = { modified.values.append($0) }
        fixture.tool.activate(in: context)
        document.selectPage(id: pages[2].id)
        #expect(fixture.tool.keyDown(TestEvents.key("\u{7F}", keyCode: 51)))
        #expect(asked.values == ["Remove the page and the object on it?"] && document.pageList.pages.count == 3)
        answer.values.append(true)
        _ = fixture.tool.keyDown(TestEvents.key("\u{7F}", keyCode: 51))
        await document.settle()
        #expect(document.pageList.pages.count == 2 && document.undoTitle == "Undo Remove page 3")
        #expect(!fixture.tool.keyDown(TestEvents.key("a", keyCode: 0)))
        // The only page is kept.
        document.selectPages(document.pageList.pages.map(\.id))
        _ = fixture.tool.keyDown(TestEvents.key("\u{7F}", keyCode: 51))
        #expect(document.pageList.pages.count == 2)
        fixture.click(pages[0].rect.center, .option, clicks: 2)
        #expect(modified.values == [pages[0].id])
        fixture.tool.cancel()
        fixture.tool.flagsChanged(fixture.setup.event(.zero))
        fixture.tool.mouseDragged(fixture.setup.event(.zero))
        fixture.tool.mouseUp(fixture.setup.event(.zero))
        fixture.tool.deactivate()
        #expect(PageTool.descriptor.id == PageTool.id)
    }
}

/// Values a closure records.
@MainActor
final class ValueLog<Value> {
    var values: [Value] = []
}
