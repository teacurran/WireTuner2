import AppKit
import Testing
import WTGeometry
import WTModel
import WTRender
@testable import WireTuner

/// D-077, revised after use: the canvas runs the full window width, beneath the docked panels;
/// Fit, zoom-to-fit, centring, the scroll bars and auto-scroll use the part the dock, rulers and
/// scroll bars leave uncovered (the safe area).
@Suite struct CanvasSafeAreaArithmeticTests {
    let size = Size(width: 1000, height: 600)
    let insets = CanvasInsets(top: 16, left: 16, bottom: 40, right: 300)

    private func navigation() -> CanvasNavigation {
        // The fixed 222-inch page area: arithmetic away from any page's extent (D-093).
        var navigation = CanvasNavigation(scroller: CanvasNavigationTests.pageArea)
        navigation.insets = insets
        return navigation
    }

    @Test func theSafeRectLeavesTheCoveredEdgesOut() {
        let safe = insets.safeRect(in: size)
        #expect(safe == Rect(x: 16, y: 16, width: 684, height: 544))
        #expect(CanvasInsets.zero.safeRect(in: size) == Rect(x: 0, y: 0, width: 1000, height: 600))
        // Covered past the view: still one point, inside the view.
        let crushed = CanvasInsets(top: 0, left: 900, bottom: 0, right: 300).safeRect(in: size)
        #expect(crushed.width == 1 && crushed.minX <= 999)
    }

    @Test func fitAndCentringUseTheSafeArea() {
        let navigation = navigation()
        let start = Viewport(scrollOrigin: Point(x: 7000, y: 7000), zoom: 1, size: size)
        let page = Rect(x: 7200, y: 7200, width: 612, height: 792)
        let fitted = navigation.fit(start, rect: page)
        let shown = page.applying(fitted.pasteboardToView)
        let safe = navigation.safeRect(fitted)
        #expect(shown.center.isApproximatelyEqual(to: safe.center, tolerance: 1e-6), "centred in the safe area, not the view")
        #expect(safe.insetBy(dx: -0.001, dy: -0.001).contains(shown), "nothing of the page lies under the dock")
        #expect(abs(shown.height - (safe.height - 2 * CanvasNavigation.fitMargin)) < 1e-6)
        // Without insets the same fit uses the whole view.
        let plain = CanvasNavigation(scroller: CanvasNavigationTests.pageArea).fit(start, rect: page)
        #expect(plain.zoom > fitted.zoom || abs(plain.zoom - fitted.zoom) < 1e-9)
        #expect(page.applying(plain.pasteboardToView).center.isApproximatelyEqual(to: plain.viewCenter, tolerance: 1e-6))
        // Zooming keeps the safe area's centre.
        let centre = start.toPasteboard(navigation.safeCenter(start))
        let zoomed = navigation.zoomIn(start)
        #expect(zoomed.toPasteboard(navigation.safeCenter(zoomed)).isApproximatelyEqual(to: centre, tolerance: 1e-6))
        let centred = navigation.centring(start, on: Point(x: 7500, y: 7400))
        #expect(centred.toView(Point(x: 7500, y: 7400)).isApproximatelyEqual(to: navigation.safeCenter(centred), tolerance: 1e-6))
    }

    @Test func thePasteboardEdgeCanBeScrolledOutFromUnderTheDock() {
        let navigation = navigation()
        let scroller = navigation.scroller
        let far = Viewport(scrollOrigin: Point(x: 1e7, y: 1e7), zoom: 1, size: size)
        let clamped = scroller.clamped(far)
        let content = scroller.contentBounds(of: clamped)
        let safe = scroller.safeArea(of: clamped)
        #expect(abs(safe.origin.x + safe.size.width - content.maxX) < 1e-6, "the pasteboard's right edge reaches the dock's edge")
        #expect(abs(safe.origin.y + safe.size.height - content.maxY) < 1e-6)
        let near = scroller.clamped(Viewport(scrollOrigin: Point(x: -1e7, y: -1e7), zoom: 1, size: size))
        #expect(abs(scroller.safeArea(of: near).origin.x - scroller.contentBounds(of: near).minX) < 1e-6)
        // The scroll bars measure the safe area.
        let middle = scroller.clamped(Viewport(scrollOrigin: Point(x: 7000, y: 7000), zoom: 1, size: size))
        let horizontal = scroller.horizontal(middle)
        #expect(abs(horizontal.knobProportion - 684 / scroller.contentBounds(of: middle).width) < 1e-9)
        let moved = scroller.scrolled(middle, horizontalValue: 1)
        #expect(abs(scroller.horizontal(moved).value - 1) < 1e-9)
        let top = scroller.scrolled(middle, verticalValue: 0)
        #expect(abs(scroller.vertical(top).value) < 1e-9)
    }

    @Test func autoScrollStartsAtTheSafeAreasEdges() {
        let safe = insets.safeRect(in: size)
        #expect(CanvasAutoscroll.delta(viewPoint: Point(x: 350, y: 300), in: safe) == nil)
        // Near the dock's edge (x 700), well inside the view: scrolls right.
        let dock = CanvasAutoscroll.delta(viewPoint: Point(x: 698, y: 300), in: safe)
        #expect((dock?.dx ?? 0) > 0 && dock?.dy == 0)
        #expect((CanvasAutoscroll.delta(viewPoint: Point(x: 18, y: 300), in: safe)?.dx ?? 0) < 0)
        #expect(CanvasAutoscroll.delta(viewPoint: Point(x: 698, y: 300), size: size) == nil, "the whole view has no edge there")
    }
}

@Suite @MainActor struct CanvasUnderTheDockTests {
    private func window(_ environment: TestEnvironment) -> DocumentWindowController {
        let controller = DocumentWindowController(document: .memory(id: UUID().uuidString, title: "Doc"), environment: environment.document)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    @Test func theCanvasRunsTheFullWidthBeneathTheDock() throws {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let content = try #require(controller.window?.contentView)
        let canvas = controller.canvas
        let canvasFrame = content.convert(canvas.bounds, from: canvas)
        #expect(abs(canvasFrame.width - content.bounds.width) < 0.5, "the canvas spans the window")
        let dockFrame = controller.dock.view.frame
        #expect(dockFrame.width > 0 && canvasFrame.intersects(dockFrame), "the dock floats over the canvas")
        // The dock is later in the view order: it is in front.
        let order = content.subviews
        #expect(order.firstIndex(of: controller.rulerHost)! < order.firstIndex(of: controller.dock.view)!)
        // The safe area stops at the dock's handle; rulers and scroll bars sit inside it.
        let insets = canvas.safeInsets
        let handle = content.convert(controller.rightHandle.bounds, from: controller.rightHandle)
        #expect(abs(insets.right - (canvasFrame.maxX - handle.minX + RulerHostView.scrollerWidth)) < 0.5)
        let host = controller.rulerHost
        let verticalScroller = content.convert(host.verticalScroller.bounds, from: host.verticalScroller)
        #expect(abs(verticalScroller.maxX - handle.minX) < 0.5)
        let ruler = content.convert(host.horizontalRuler.bounds, from: host.horizontalRuler)
        #expect(ruler.maxX <= handle.minX + 0.5 && abs(host.horizontalRuler.canvasOrigin - Double(host.horizontalRuler.frame.minX)) < 0.001)
        #expect(insets.bottom >= Double(StatusBarView.height + RulerHostView.scrollerWidth) - 0.5, "the status bar is laid over the canvas")
        #expect(!host.scrollerCorner.isHidden)
        // The dock is clear around its glass (the canvas shows beside it) and the handle too.
        #expect(controller.dock.view.layer?.backgroundColor == nil && controller.rightHandle.layer?.backgroundColor == nil)
        // Cursor and pointer tracking are the safe area's.
        #expect(canvas.appKitSafeRect.width < canvas.bounds.width)
        #expect(canvas.trackingAreas.contains { $0.rect == canvas.appKitSafeRect })
    }

    @Test func fitInWindowUsesTheUnobscuredRect() throws {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        controller.fitPage()
        let page = try #require(controller.documentHandle.currentPage)
        let viewport = controller.viewport
        let shown = page.applying(viewport.pasteboardToView)
        let safe = controller.canvas.safeRect
        #expect(shown.center.isApproximatelyEqual(to: safe.center, tolerance: 0.5), "Fit to Page centres in the unobscured rect")
        #expect(safe.insetBy(dx: -0.5, dy: -0.5).contains(shown), "no part of the page is under the dock")
        #expect(shown.maxX < Double(controller.canvas.bounds.width) - controller.canvas.safeInsets.right + 0.5)
        // Paste lands in the middle of what is visible.
        #expect(controller.canvas.visibleCenter.isApproximatelyEqual(to: viewport.toPasteboard(safe.center), tolerance: 1e-6))
        #expect(controller.objectEditing.visibleCenter()?.isApproximatelyEqual(to: controller.canvas.visibleCenter, tolerance: 1e-6) == true)
        #expect(controller.handoffPlace.center.isApproximatelyEqual(to: controller.canvas.visibleCenter, tolerance: 1e-6))
    }

    @Test func hidingTheDockGivesTheCanvasTheFullWidth() throws {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let content = try #require(controller.window?.contentView)
        let docked = controller.canvas.safeInsets.right
        environment.layout.update { $0.setDockHidden(true, edge: .right) }
        content.layoutSubtreeIfNeeded()
        let hidden = controller.canvas.safeInsets.right
        #expect(abs(hidden - Double(DockHandleView.thickness + RulerHostView.scrollerWidth)) < 0.5, "only the handle and the scroll bar remain")
        #expect(docked - hidden > 100)
        controller.fitPage()
        let wide = controller.viewport.zoom
        environment.layout.update { $0.setDockHidden(false, edge: .right) }
        content.layoutSubtreeIfNeeded()
        #expect(abs(controller.canvas.safeInsets.right - docked) < 0.5)
        controller.fitPage()
        #expect(controller.viewport.zoom <= wide + 1e-9)
    }

    @Test func aPointerOverTheDockIsNotOverTheCanvas() throws {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let canvas = controller.canvas
        var pointers: [Point?] = []
        canvas.onPointer = { pointers.append($0) }
        let window = try #require(controller.window)
        func moved(to point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: .mouseMoved, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        }
        let safe = canvas.appKitSafeRect
        canvas.mouseMoved(with: moved(to: CGPoint(x: safe.midX, y: safe.midY)))
        canvas.mouseMoved(with: moved(to: CGPoint(x: canvas.bounds.maxX - 20, y: safe.midY)))
        #expect(pointers.count == 2 && pointers[0] != nil && pointers[1] == nil)
        canvas.resetCursorRects()
        // The HUD centres in the safe area.
        canvas.showHUD("Hello")
        #expect(abs(canvas.hud.frame.midX - safe.midX) < 1)
    }
}
