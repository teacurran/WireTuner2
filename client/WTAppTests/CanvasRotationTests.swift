import AppKit
import Foundation
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

/// The gesture bookkeeping and rotation arithmetic, without a trackpad.
@Suite struct CanvasGestureTrackerTests {
    @Test func pinchBracketsOneGesture() {
        var tracker = CanvasGestureTracker()
        #expect(tracker.update(.magnify, phase: .began) == .began)
        #expect(tracker.update(.magnify, phase: .changed) == nil)
        #expect(tracker.isActive)
        #expect(tracker.update(.magnify, phase: .ended) == .ended)
        #expect(!tracker.isActive)
    }

    @Test func overlappingInputsEndWithTheLast() {
        var tracker = CanvasGestureTracker()
        #expect(tracker.update(.magnify, phase: .began) == .began)
        #expect(tracker.update(.rotate, phase: .began) == nil)
        #expect(tracker.update(.magnify, phase: .cancelled) == nil)
        #expect(tracker.update(.rotate, phase: .ended) == .ended)
        #expect(tracker.set(.animation, running: true) == .began)
        #expect(tracker.set(.animation, running: false) == .ended)
    }

    @Test func scrollMomentumKeepsTheGestureOpen() {
        var tracker = CanvasGestureTracker()
        #expect(tracker.update(.scroll, phase: [], momentumPhase: []) == nil, "a wheel mouse's discrete scroll")
        #expect(tracker.update(.scroll, phase: .began) == .began)
        #expect(tracker.update(.scroll, phase: .ended, momentumPhase: .began) == nil, "momentum follows the fingers")
        #expect(tracker.update(.scroll, phase: [], momentumPhase: .changed) == nil)
        #expect(tracker.update(.scroll, phase: [], momentumPhase: .ended) == .ended)
        #expect(CanvasGestureTracker.isRunning(.mayBegin) && CanvasGestureTracker.isStopping(.cancelled))
    }
}

@Suite struct CanvasRotationArithmeticTests {
    @Test func gestureAnglesSnapWithShift() {
        #expect(CanvasRotation.gestureAngle(start: 10, accumulated: 12, snapping: false) == 22)
        #expect(CanvasRotation.gestureAngle(start: 10, accumulated: 12, snapping: true) == 15)
        #expect(CanvasRotation.gestureAngle(start: 170, accumulated: 20, snapping: false) == -170)
        #expect(CanvasRotation.gestureAngle(start: 0, accumulated: -38, snapping: true) == -45)
    }

    @Test func turnsTheShortWay() {
        #expect(CanvasRotation.shortestTurn(from: 170, to: -170) == 20)
        #expect(CanvasRotation.shortestTurn(from: -45, to: 0) == 45)
        let start = Viewport(scrollOrigin: Point(x: 100, y: 100), rotationDegrees: 170, zoom: 2, size: Size(width: 400, height: 300))
        let centre = start.toPasteboard(start.viewCenter)
        let half = CanvasRotation.interpolated(start, toDegrees: -170, fraction: 0.5)
        #expect(abs(half.rotationDegrees - 180) < 1e-9)
        #expect(half.toView(centre).isApproximatelyEqual(to: start.viewCenter, tolerance: 1e-6))
        #expect(CanvasRotation.interpolated(start, toDegrees: -170, fraction: 3).rotationDegrees == -170)
    }

    @Test func theCompassShowsTheSizeOfTheTurnAndHidesWhenStraight() {
        #expect(CanvasRotation.compassTitle(0) == nil)
        #expect(CanvasRotation.compassTitle(0.01) == nil)
        #expect(CanvasRotation.compassTitle(-45) == "45°")
        #expect(CanvasRotation.compassTitle(20) == "20°")
        #expect(CanvasRotation.compassTitle(12.34) == "12.3°")
    }

    @Test func smartZoomFitsThenReturns() {
        let navigation = CanvasNavigation()
        let start = navigation.clamped(Viewport(scrollOrigin: Point(x: 7000, y: 7000), zoom: 1, size: Size(width: 400, height: 300)))
        var state = SmartZoomState()
        #expect(state.toggle(from: start, target: nil, navigation: navigation) == start)
        let target = Rect(x: 7100, y: 7100, width: 50, height: 50)
        let zoomed = state.toggle(from: start, target: target, navigation: navigation)
        #expect(zoomed.zoom > 1)
        #expect(zoomed.toView(target.center).isApproximatelyEqual(to: zoomed.viewCenter, tolerance: 1e-6))
        #expect(state.toggle(from: zoomed, target: target, navigation: navigation) == start)
        _ = state.toggle(from: start, target: target, navigation: navigation)
        state.reset()
        #expect(state.returnViewport == nil)
    }

    @Test func autoscrollRunsOnlyAtTheEdge() {
        let size = Size(width: 400, height: 300)
        #expect(CanvasAutoscroll.delta(viewPoint: Point(x: 200, y: 150), size: size) == nil)
        #expect(CanvasAutoscroll.delta(viewPoint: Point(x: 2, y: 150), size: size) == Vector(dx: -14, dy: 0))
        #expect(CanvasAutoscroll.delta(viewPoint: Point(x: 200, y: 400), size: size) == Vector(dx: 0, dy: 48))
        #expect(CanvasAutoscroll.axis(-500, length: 400) == -48)
    }
}

/// BASIC-034 on a real canvas view and window.
@Suite(.serialized) @MainActor struct CanvasRotationTests {
    private func window(_ environment: TestEnvironment) -> DocumentWindowController {
        let controller = DocumentWindowController(document: .memory(title: "Rotate"), environment: environment.document)
        controller.canvas.rotationAnimationDuration = 0
        return controller
    }

    /// An AppKit point (y up) at the canvas's centre.
    private func centre(of canvas: CanvasView) -> CGPoint {
        CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
    }

    @Test func aThirtyDegreeGestureThenResetLeavesThePasteboardWhereItWas() {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let canvas = controller.canvas
        let before = canvas.viewport
        let changes = controller.documentHandle.changeCount
        canvas.gesture(.rotate, phase: .began)
        #expect(canvas.tiles.isGesturing)
        canvas.rotate(byGestureDegrees: 10, phase: .began, snapping: false, at: centre(of: canvas))
        canvas.rotate(byGestureDegrees: 20, phase: .changed, snapping: false, at: centre(of: canvas))
        #expect(abs(canvas.viewport.rotationDegrees - 30) < 1e-9)
        canvas.rotate(byGestureDegrees: 0, phase: .ended, snapping: false, at: centre(of: canvas))
        canvas.gesture(.rotate, phase: .ended)
        #expect(!canvas.tiles.isGesturing)
        #expect(canvas.rotationGesture == nil)
        #expect(controller.statusBar.compass.title == "30°" && !controller.statusBar.compass.isHidden)
        controller.resetRotation()
        #expect(canvas.viewport.rotationDegrees == 0)
        #expect(canvas.viewport.scrollOrigin.isApproximatelyEqual(to: before.scrollOrigin, tolerance: 1e-6))
        #expect(controller.statusBar.compass.isHidden)
        #expect(controller.documentHandle.changeCount == changes, "rotation is view state: no change")
    }

    @Test func shiftLandsOnAMultipleOfFifteen() {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let canvas = controller.canvas
        canvas.rotate(byGestureDegrees: 11, phase: .began, snapping: true, at: centre(of: canvas))
        #expect(canvas.viewport.rotationDegrees == 15)
        canvas.rotate(byGestureDegrees: 12, phase: .changed, snapping: true, at: centre(of: canvas))
        #expect(canvas.viewport.rotationDegrees == 30)
        #expect(canvas.viewport.rotationDegrees.truncatingRemainder(dividingBy: 15) == 0)
    }

    @Test func rotateClockwiseThreeTimesReadsFortyFiveAndThePreferenceGatesOnlyTheGesture() async {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        ViewCommands.install(into: environment.commands, target: { [weak controller] in controller }, newDocument: {})
        for _ in 0..<3 { #expect(environment.commands.perform(StandardCommands.ID.rotateClockwise)) }
        #expect(controller.viewport.rotationDegrees == -45)
        #expect(controller.statusBar.compass.title == "45°")
        #expect(environment.commands.perform(StandardCommands.ID.rotateCounterClockwise))
        #expect(controller.viewport.rotationDegrees == -30)

        environment.preferences.set(false, for: PreferenceCatalog.General.trackpadRotate)
        let angle = controller.viewport.rotationDegrees
        controller.canvas.rotate(byGestureDegrees: 20, snapping: false, at: centre(of: controller.canvas))
        #expect(controller.viewport.rotationDegrees == angle, "the gesture does nothing with the preference off")
        #expect(environment.commands.perform(StandardCommands.ID.rotateReset))
        #expect(controller.viewport.rotationDegrees == 0, "the menu still works")

        // The compass straightens the canvas.
        #expect(environment.commands.perform(StandardCommands.ID.rotateClockwise))
        controller.statusBar.compassClicked(nil)
        #expect(controller.viewport.rotationDegrees == 0)
    }

    @Test func menuRotationsAnimateThroughAGesture() async {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let canvas = controller.canvas
        canvas.rotationAnimationDuration = 0.05
        let centreBefore = canvas.viewport.toPasteboard(canvas.viewport.viewCenter)
        let task = controller.rotateCanvas(steps: 1)
        #expect(task != nil)
        #expect(canvas.gestures.active.contains(.animation))
        #expect(canvas.tiles.isGesturing)
        _ = await task?.value
        #expect(abs(canvas.viewport.rotationDegrees - 15) < 1e-9)
        #expect(!canvas.tiles.isGesturing, "the settled angle is rasterised once at the end")
        #expect(canvas.viewport.toView(centreBefore).isApproximatelyEqual(to: canvas.viewport.viewCenter, tolerance: 1e-6))
        // A second rotation cancels a running one.
        let first = controller.rotateCanvas(steps: 1)
        let second = controller.resetRotation()
        _ = await first?.value
        _ = await second?.value
        #expect(abs(canvas.viewport.rotationDegrees) < 1e-9)
    }

    @Test func atFortyFiveDegreesAClickSelectsTheObjectUnderIt() async throws {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let document = controller.documentHandle
        let rect = Rect(x: 7500, y: 7500, width: 100, height: 60)
        await document.addRectangles([rect])
        controller.setViewport(Viewport(scrollOrigin: .zero, rotationDegrees: 45, zoom: 1, size: controller.viewport.size))
        controller.canvas.setViewport(controller.viewport.scrolled(byViewDelta: controller.viewport.toView(rect.center) - controller.viewport.viewCenter))
        let viewport = controller.viewport
        #expect(viewport.rotationDegrees == 45)
        let point = viewport.toView(rect.center)
        controller.selection.click(at: point, viewport: viewport, modifiers: [], subselect: false)
        #expect(controller.selection.model.count == 1)
        // Pasteboard coordinates of a drag along the page's x axis stay horizontal on the page
        // whatever the screen angle (constraints are computed in pasteboard space).
        let along = viewport.toView(rect.center + Vector(dx: 50, dy: 0))
        #expect(abs(viewport.toPasteboard(along).y - rect.center.y) < 1e-6)
    }

    @Test func smartZoomAndForceClickReachTheCanvas() async throws {
        let environment = TestEnvironment()
        SelectionCommands.install(commands: environment.commands, tools: environment.tools)
        let controller = window(environment)
        defer { controller.close() }
        let canvas = controller.canvas
        let document = controller.documentHandle
        let rect = Rect(x: 7500, y: 7500, width: 40, height: 40)
        await document.addRectangles([rect])
        canvas.setViewport(canvas.viewport.scrolled(byViewDelta: canvas.viewport.toView(rect.center) - canvas.viewport.viewCenter))
        let start = canvas.viewport
        let over = canvas.viewport.toView(rect.center)
        let appKit = CGPoint(x: over.x, y: Double(canvas.bounds.height) - over.y)
        #expect(canvas.smartZoomTarget(at: over) != nil)
        canvas.smartMagnify(at: appKit)
        #expect(canvas.viewport.zoom > start.zoom)
        canvas.smartMagnify(at: appKit)
        #expect(canvas.viewport == start, "double-tap again to go back")
        // Over a page but no object: the page.
        let page = try #require(document.currentPage)
        let pagePoint = canvas.viewport.toView(Point(x: page.minX + 5, y: page.minY + 5))
        #expect(canvas.smartZoomTarget(at: pagePoint) == page)
        // Off every page and object: nothing.
        #expect(canvas.smartZoomTarget(at: canvas.viewport.toView(Point(x: 10, y: 10))) == nil)

        // A Force click subselects with the Pointer.
        let event = CanvasEvent(pasteboardPoint: rect.center, viewPoint: over)
        canvas.pressureChanged(stage: 1, event: event)
        #expect(controller.selection.model.isEmpty)
        canvas.pressureChanged(stage: 2, event: event)
        #expect(controller.selection.model.count == 1)
    }

    @Test func theAngleIsSavedAndRestoredWithTheViewState() {
        let environment = TestEnvironment()
        let id = UUID().uuidString
        let first = DocumentWindowController(document: .memory(id: id, title: "A"), environment: environment.document)
        first.canvas.rotationAnimationDuration = 0
        first.rotateCanvas(steps: 2)
        first.saveState()
        first.close()
        #expect(environment.windowStates.state(for: id)?.rotationDegrees == 30)
        let again = DocumentWindowController(document: .memory(id: id, title: "A"), environment: environment.document)
        defer { again.close() }
        #expect(again.viewport.rotationDegrees == 30)
        #expect(again.statusBar.compass.title == "30°")
    }

    @Test func compassButtonDrawsItsNeedle() {
        let compass = CompassButton()
        #expect(compass.isHidden)
        compass.degrees = 90
        #expect(!compass.isHidden && compass.accessibilityValue() as? String == "90°")
        let image = CompassButton.needle(rotatedBy: 30)
        #expect(image?.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
    }
}
