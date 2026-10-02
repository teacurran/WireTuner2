import AppKit
import Testing
import WTGeometry
import WTModel
import WTRender
@testable import WireTuner

/// D-093: the canvas scrolls over its pages with half their size (at least an A4 side) around
/// them and any artwork beyond, and zooms out no further than the whole extent fits.
@Suite @MainActor struct CanvasExtentNavigationTests {
    private func window(_ environment: TestEnvironment) -> DocumentWindowController {
        DocumentWindowController(document: .memory(title: "Extent"), environment: environment.document)
    }

    /// The safe area's rectangle in pasteboard space (no rotation).
    private func shown(_ canvas: CanvasView) -> Rect { canvas.visiblePasteboardBounds }

    private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

    @Test func aNewDocumentScrollsOverItsPageAndMargins() {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let canvas = controller.canvas
        let extent = CanvasExtent.extent(pages: Pasteboard.letterPage)
        #expect(canvas.navigation.scroller.extent == extent)
        #expect(canvas.navigation.scroller.extent == Pasteboard.newDocumentExtent)
        controller.zoom(toPercent: 100)
        // Scrolled as far as it goes either way, the view stops at the extent's edge.
        controller.setViewport(controller.viewport.scrolled(byViewDelta: Vector(dx: 1e7, dy: 1e7)))
        #expect(close(shown(canvas).maxX, extent.maxX, 1e-3) && close(shown(canvas).maxY, extent.maxY, 1e-3))
        controller.setViewport(controller.viewport.scrolled(byViewDelta: Vector(dx: -1e7, dy: -1e7)))
        #expect(close(shown(canvas).minX, extent.minX, 1e-3) && close(shown(canvas).minY, extent.minY, 1e-3))
        // The page is never more than the margin away.
        #expect(shown(canvas).maxX >= Pasteboard.letterPage.minX - CanvasExtent.a4.width - 1e-3)
        // The scroll bars span the extent.
        let scroller = canvas.navigation.scroller
        #expect(scroller.horizontal(controller.viewport).value == 0 && scroller.vertical(controller.viewport).value == 0)
    }

    @Test func zoomingOutStopsWhenTheWholeExtentShows() {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let canvas = controller.canvas
        controller.zoom(toPercent: 6)
        let floor = canvas.navigation.scroller.minimumZoom(of: controller.viewport)
        #expect(floor > Viewport.zoomRange.lowerBound, "a Letter document's extent fits long before 6%")
        #expect(close(controller.viewport.zoom, floor))
        let extent = canvas.navigation.scroller.extent
        #expect(shown(canvas).insetBy(dx: -1e-3, dy: -1e-3).contains(extent), "the whole extent shows")
        controller.zoomOut()
        #expect(close(controller.viewport.zoom, floor))
        // Pinch and Option-scroll stop there too.
        canvas.magnify(by: -0.9, at: CGPoint(x: 10, y: 10))
        #expect(close(canvas.viewport.zoom, floor))
        canvas.scroll(deltaX: 0, deltaY: -500, precise: false, modifierFlags: .option, at: CGPoint(x: 10, y: 10))
        #expect(close(canvas.viewport.zoom, floor))
        // The Zoom tool's Control+Option-click asks for the minimum: the canvas gives the floor.
        let point = Point(x: 50, y: 50)
        let click = CanvasEvent(pasteboardPoint: controller.viewport.toPasteboard(point), viewPoint: point, modifiers: [.control, .option])
        controller.setViewport(ZoomTool.target(viewport: controller.viewport, start: click, end: click))
        #expect(close(controller.viewport.zoom, floor))
        // Covering more of the canvas (a wider dock) shrinks the safe area and raises the floor;
        // the view zooms in to it at once.
        canvas.safeInsets = CanvasInsets(top: 0, left: 0, bottom: 0, right: Double(canvas.bounds.width) / 2)
        let raised = canvas.navigation.scroller.minimumZoom(of: canvas.viewport)
        #expect(raised > floor && close(canvas.viewport.zoom, raised))
    }

    @Test func farAwayArtworkStaysReachable() async {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let canvas = controller.canvas
        let document = controller.documentHandle
        let far = Rect(x: 100, y: 200, width: 50, height: 40)
        let ids = await document.addRectangles([far])
        let extent = canvas.navigation.scroller.extent
        #expect(extent.contains(far.insetBy(dx: -CanvasExtent.a4.width, dy: -CanvasExtent.a4.height)), "the extent grew to the artwork")
        #expect(extent.contains(CanvasExtent.extent(pages: Pasteboard.letterPage)))
        controller.zoom(toPercent: 100)
        controller.setViewport(canvas.navigation.centring(controller.viewport, on: far.center))
        #expect(shown(canvas).contains(far), "scrolled to the artwork")
        // Deleting it shrinks the extent and brings the view back within reach of the page.
        controller.selection.model.set(Selection(ids))
        controller.delete(nil)
        await document.settle()
        #expect(canvas.navigation.scroller.extent == CanvasExtent.extent(pages: Pasteboard.letterPage))
        #expect(canvas.navigation.scroller.extent.contains(shown(canvas).insetBy(dx: 1e-3, dy: 1e-3)))
        controller.fitAll()
        #expect(shown(canvas).contains(Pasteboard.letterPage), "Fit All brings the pages back")
    }

    @Test func theExtentFollowsThePages() async {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let canvas = controller.canvas
        let document = controller.documentHandle
        var updates = 0
        let previous = canvas.onViewportChange
        canvas.onViewportChange = { previous?($0); updates += 1 }
        let second = Pasteboard.letterPage.offset(by: Vector(dx: 648, dy: 0))
        document.pages = [Pasteboard.letterPage, second]
        await document.settle()
        let union = Pasteboard.letterPage.union(second)
        #expect(canvas.navigation.scroller.extent == CanvasExtent.extent(pages: union))
        #expect(updates > 0, "the scroll bars hear of the new extent")
        // An unchanged extent costs nothing: a change that leaves it alone sends no update.
        updates = 0
        canvas.refreshExtent()
        #expect(updates == 0)
    }

    @Test func aViewSavedFarAwayOpensWithinReach() {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let canvas = controller.canvas
        // The old 222-inch pasteboard's corner, at 6%: where an old document's view could be.
        controller.setViewport(Viewport(scrollOrigin: .zero, zoom: 0.06, size: canvas.viewport.size))
        let extent = canvas.navigation.scroller.extent
        #expect(shown(canvas).insetBy(dx: -1e-3, dy: -1e-3).contains(extent))
        #expect(shown(canvas).contains(Pasteboard.letterPage))
        // The Hand tool's drag goes through the same clamp.
        controller.zoom(toPercent: 400)
        let hand = PanTool()
        let context = ToolContext(document: controller.documentHandle, host: canvas, selection: controller.selection)
        hand.activate(in: context)
        hand.mouseDown(CanvasEvent(pasteboardPoint: .zero, viewPoint: Point(x: 0, y: 0)))
        hand.mouseDragged(CanvasEvent(pasteboardPoint: .zero, viewPoint: Point(x: 1e7, y: 1e7)))
        hand.mouseUp(CanvasEvent(pasteboardPoint: .zero, viewPoint: Point(x: 1e7, y: 1e7)))
        #expect(close(shown(canvas).minX, extent.minX, 1e-3) && close(shown(canvas).minY, extent.minY, 1e-3))
    }

    @Test func aTurnedCanvasKeepsTheExtentReachable() {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let canvas = controller.canvas
        canvas.rotationAnimationDuration = 0
        canvas.animateRotation(toDegrees: 45)
        controller.zoom(toPercent: 6)
        let floor = canvas.navigation.scroller.minimumZoom(of: canvas.viewport)
        #expect(close(canvas.viewport.zoom, floor))
        let content = canvas.navigation.scroller.contentBounds(of: canvas.viewport)
        let safe = canvas.navigation.scroller.safeArea(of: canvas.viewport)
        #expect(content.width <= safe.size.width + 1e-6 && content.height <= safe.size.height + 1e-6)
    }

    @Test func toolsAndOffscreenFitsDoNotClampToADefaultExtent() {
        let far = Viewport(scrollOrigin: Point(x: 100, y: 100), zoom: 0.01, size: Size(width: 800, height: 600))
        #expect(CanvasNavigation.unbounded.clamped(far).scrollOrigin == far.scrollOrigin)
        #expect(CanvasNavigation.unbounded.scroller.minimumZoom(of: far) == Viewport.zoomRange.lowerBound)
    }
}
