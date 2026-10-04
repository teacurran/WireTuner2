import AppKit
import Testing
import WTGeometry
import WTModel
import WTRender
@testable import WireTuner

/// Found in use (2026-10-02): "it will click underneath in a way that will cause the artboard to
/// quickly scroll ... infinitely".  A press the canvas heard without its mouse-up (a click on a
/// tool passed down to it) left a drag in progress; a drag over a dock auto-scrolls toward it,
/// and nothing stopped it.  Auto-scroll now runs only while the button is down, and a press whose
/// mouse-up is lost ends where it was -- when the button is found up, when a mouse-up goes
/// elsewhere, when the pointer moves with the button up, on the next press, and when the window
/// or the app loses focus; kbd:[Esc] stops auto-scroll too.
@Suite(.serialized) @MainActor struct CanvasLostReleaseTests {
    /// Whether the (imaginary) mouse button is held.
    @MainActor final class Held { var down = true }

    typealias World = PanelClickThroughTests.World

    /// A press in the middle of the canvas and a drag over the Tools panel (past the safe area's
    /// left edge, where auto-scroll runs), the button held as `button` says.
    private func pressAndDragOverTheTools(_ world: World, button: @escaping @MainActor () -> Bool) -> NSPoint {
        let canvas = world.controller.canvas
        canvas.mouseButtonIsDown = button
        let safe = canvas.appKitSafeRect
        let centre = canvas.convert(NSPoint(x: safe.midX, y: safe.midY), to: nil)
        let tools = world.controller.leftDock.view
        let overTools = tools.convert(NSPoint(x: tools.bounds.midX, y: tools.bounds.midY), to: nil)
        world.window.sendEvent(world.mouse(.leftMouseDown, centre))
        world.window.sendEvent(world.mouse(.leftMouseDragged, NSPoint(x: centre.x - 20, y: centre.y)))
        world.window.sendEvent(world.mouse(.leftMouseDragged, overTools))
        return overTools
    }

    @Test func aDragWhoseMouseUpIsLostStopsScrollingAndEnds() async throws {
        let world = World()
        defer { world.close() }
        let canvas = world.controller.canvas
        let held = Held()
        _ = pressAndDragOverTheTools(world) { held.down }
        #expect(world.presses == 1 && world.controller.toolManager.isPressed)
        #expect(canvas.autoscrollEvent != nil, "over the dock the drag auto-scrolls")
        let start = canvas.viewport.scrollOrigin
        #expect(canvas.autoscrollStep())
        #expect(canvas.viewport.scrollOrigin.x < start.x, "toward the Tools panel")
        #expect(start.x - canvas.viewport.scrollOrigin.x <= CanvasAutoscroll.maximumStep + 1e-9, "no more than the capped step")
        // The mouse-up goes to a panel: the canvas never hears it, the button is up.
        held.down = false
        try await Task.sleep(for: .milliseconds(120))
        #expect(canvas.autoscrollEvent == nil && !world.controller.toolManager.isPressed, "the press ended where it was")
        #expect(world.releases == 1)
        let settled = canvas.viewport
        try await Task.sleep(for: .milliseconds(80))
        #expect(canvas.viewport == settled, "and nothing scrolls on")
        #expect(!canvas.autoscrollStep())
    }

    @Test func aMouseUpThatGoesElsewhereReleasesThePress() async throws {
        let world = World()
        defer { world.close() }
        let canvas = world.controller.canvas
        let overTools = pressAndDragOverTheTools(world) { false }
        #expect(world.controller.toolManager.isPressed)
        // Dispatched to another window: the canvas does not get it.
        let other = TestWindow.make()
        defer { other.close() }
        NSApp.sendEvent(world.mouse(.leftMouseUp, overTools, in: other))
        canvas.heardMouseUp()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!world.controller.toolManager.isPressed && canvas.autoscrollEvent == nil && world.releases == 1)
        // Between presses a mouse-up changes nothing.
        canvas.mouseUpWasDispatched()
        #expect(world.releases == 1)
    }

    /// A drag well inside the canvas (no auto-scroll to notice the button), whose mouse-up AppKit
    /// dispatches to another window: the canvas's monitor hears it, and once it has gone by the
    /// press is released -- but only when the button really is up.
    @Test func aMouseUpDispatchedElsewhereReleasesThePressOnlyWithTheButtonUp() async throws {
        let world = World()
        defer { world.close() }
        let canvas = world.controller.canvas
        let held = Held()
        canvas.mouseButtonIsDown = { held.down }
        let safe = canvas.appKitSafeRect
        let centre = canvas.convert(NSPoint(x: safe.midX, y: safe.midY), to: nil)
        world.window.sendEvent(world.mouse(.leftMouseDown, centre))
        world.window.sendEvent(world.mouse(.leftMouseDragged, NSPoint(x: centre.x + 20, y: centre.y)))
        #expect(world.controller.toolManager.isPressed && canvas.autoscrollEvent == nil)
        let other = TestWindow.make()
        defer { other.close() }
        /// A mouse-up for `other` taken from the queue and dispatched, as the run loop does.
        func dispatchMouseUpElsewhere() async throws {
            world.drain()
            other.postEvent(world.mouse(.leftMouseUp, NSPoint(x: 10, y: 10), in: other), atStart: false)
            while let event = NSApp.nextEvent(matching: World.mouseMask, until: .distantPast, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            try await Task.sleep(for: .milliseconds(30))
        }
        // The button is still held (that mouse-up was not this press's): the drag goes on.
        try await dispatchMouseUpElsewhere()
        #expect(world.controller.toolManager.isPressed && world.releases == 0)
        // The button is up: the press missed its mouse-up and ends where it was.
        held.down = false
        try await dispatchMouseUpElsewhere()
        #expect(!world.controller.toolManager.isPressed && world.releases == 1)
        // The watch ended with the press: later mouse-ups change nothing.
        try await dispatchMouseUpElsewhere()
        #expect(world.releases == 1)
    }

    /// Pinch, two-finger rotation and smart zoom sent through the window over the canvas move
    /// the view; the same gestures and a click that began over the dock, should AppKit pass them
    /// on to the canvas, do nothing.
    @Test func trackpadGesturesNavigateOnlyWhenTheyBeginOverTheCanvas() throws {
        let world = World()
        defer { world.close() }
        let canvas = world.controller.canvas
        canvas.rotatesWithTrackpad = { true }
        let safe = canvas.appKitSafeRect
        let centre = canvas.convert(NSPoint(x: safe.midX, y: safe.midY), to: nil)
        let dock = world.controller.dock.view
        let overDock = dock.convert(NSPoint(x: dock.bounds.midX, y: dock.bounds.midY), to: nil)

        // Over the dock, handed to the canvas directly: nothing moves, nothing is pressed.
        let start = canvas.viewport
        canvas.magnify(with: world.gesture(.magnify, overDock, value: 0.5, phase: 1))
        canvas.magnify(with: world.gesture(.magnify, centre, value: 0.5, phase: 2))
        canvas.magnify(with: world.gesture(.magnify, centre, phase: 4))
        canvas.rotate(with: world.gesture(.rotate, overDock, value: 30, phase: 1))
        canvas.rotate(with: world.gesture(.rotate, centre, value: 30, phase: 2))
        canvas.rotate(with: world.gesture(.rotate, centre, phase: 4))
        canvas.smartMagnify(with: world.gesture(.smartMagnify, overDock))
        canvas.mouseDown(with: world.mouse(.leftMouseDown, overDock))
        #expect(canvas.viewport == start && world.presses == 0 && !world.controller.toolManager.isPressed)

        // Over the canvas, through the window.
        world.window.sendEvent(world.gesture(.magnify, centre, value: 0.5, phase: 1))
        world.window.sendEvent(world.gesture(.magnify, centre, value: 0.5, phase: 2))
        world.window.sendEvent(world.gesture(.magnify, centre, phase: 4))
        #expect(canvas.viewport.zoom > start.zoom, "the pinch zoomed in: \(canvas.viewport.zoom)")
        let zoomed = canvas.viewport
        world.window.sendEvent(world.gesture(.rotate, centre, value: 30, phase: 1))
        world.window.sendEvent(world.gesture(.rotate, centre, value: 30, phase: 2))
        world.window.sendEvent(world.gesture(.rotate, centre, phase: 4))
        #expect(canvas.viewport.rotationDegrees != zoomed.rotationDegrees, "the rotation turned the canvas")
        let turned = canvas.viewport
        world.window.sendEvent(world.gesture(.smartMagnify, centre))
        #expect(canvas.viewport != turned, "smart zoom fitted what is under the pointer")
    }

    /// A canvas moved to another window hears only that window's focus: the window it left
    /// resigning key no longer stops its auto-scroll; the one it is in does.
    @Test func aCanvasHearsTheFocusOfTheWindowItIsIn() throws {
        let environment = TestEnvironment()
        let first = TestWindow.make(NSRect(x: 0, y: 0, width: 400, height: 300))
        let second = TestWindow.make(NSRect(x: 0, y: 0, width: 400, height: 300))
        defer {
            first.close()
            second.close()
        }
        let canvas = CanvasView(document: .memory(title: "Move"), frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        canvas.toolManager = ToolManager(registry: environment.tools, context: ToolContext(document: canvas.document, host: canvas))
        canvas.mouseButtonIsDown = { true }
        first.contentView?.addSubview(canvas)
        second.contentView?.addSubview(canvas)
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: second.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 200, y: 150)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 396, y: 150)))
        #expect(canvas.autoscrollEvent != nil, "at the edge the drag auto-scrolls")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: first)
        #expect(canvas.autoscrollEvent != nil, "the window the canvas left is not its focus")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: second)
        #expect(canvas.autoscrollEvent == nil && canvas.toolManager?.isPressed == true, "its own window's focus stops auto-scroll; the held press goes on")
        canvas.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 396, y: 150)))
    }

    @Test func theCanvasHearingItsMouseUpEndsThePressOnce() async throws {
        let world = World()
        defer { world.close() }
        let canvas = world.controller.canvas
        let overTools = pressAndDragOverTheTools(world) { true }
        world.window.sendEvent(world.mouse(.leftMouseUp, overTools))
        canvas.heardMouseUp()
        try await Task.sleep(for: .milliseconds(30))
        #expect(world.releases == 1 && !world.controller.toolManager.isPressed && canvas.autoscrollEvent == nil)
    }

    @Test func movingWithTheButtonUpOrPressingAgainEndsAStalePress() throws {
        let world = World()
        defer { world.close() }
        let canvas = world.controller.canvas
        let overTools = pressAndDragOverTheTools(world) { false }
        canvas.mouseMoved(with: world.mouse(.mouseMoved, overTools))
        #expect(!world.controller.toolManager.isPressed && world.releases == 1 && canvas.autoscrollEvent == nil)
        // A press with no mouse-up, then another: the first ends before the second begins.
        world.reset()
        let safe = canvas.appKitSafeRect
        let centre = canvas.convert(NSPoint(x: safe.midX, y: safe.midY), to: nil)
        world.window.sendEvent(world.mouse(.leftMouseDown, centre))
        world.window.sendEvent(world.mouse(.leftMouseDown, NSPoint(x: centre.x + 30, y: centre.y)))
        #expect(world.presses == 2 && world.releases == 1 && world.controller.toolManager.isPressed)
        world.window.sendEvent(world.mouse(.leftMouseUp, NSPoint(x: centre.x + 30, y: centre.y)))
        #expect(world.releases == 2 && !world.controller.toolManager.isPressed)
    }

    @Test func losingFocusStopsAutoscrollAndReleasesAPressWithTheButtonUp() throws {
        let world = World()
        defer { world.close() }
        let canvas = world.controller.canvas
        let held = Held()
        _ = pressAndDragOverTheTools(world) { held.down }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: world.window)
        #expect(canvas.autoscrollEvent == nil, "no auto-scroll in a window that is not key")
        #expect(world.controller.toolManager.isPressed, "the button is still down: the press goes on")
        held.down = false
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(!world.controller.toolManager.isPressed && world.releases == 1)
    }

    @Test func escapeStopsAutoscroll() throws {
        let world = World()
        defer { world.close() }
        let canvas = world.controller.canvas
        _ = pressAndDragOverTheTools(world) { true }
        #expect(canvas.autoscrollEvent != nil)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: world.window.windowNumber, context: nil,
                                      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: CanvasEventTranslator.escapeKeyCode)!
        canvas.keyDown(with: escape)
        #expect(canvas.autoscrollEvent == nil && !canvas.autoscrollStep())
    }

    @Test func aCanvasLeavingItsWindowReleasesItsPress() throws {
        let environment = TestEnvironment()
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 400, height: 300))
        defer { window.close() }
        let canvas = CanvasView(document: .memory(title: "Leave"), frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        canvas.toolManager = ToolManager(registry: environment.tools, context: ToolContext(document: canvas.document, host: canvas))
        window.contentView?.addSubview(canvas)
        var releases = 0
        canvas.onPress = { down in if !down { releases += 1 } }
        canvas.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 200, y: 150), modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        #expect(canvas.toolManager?.isPressed == true)
        canvas.removeFromSuperview()
        #expect(canvas.toolManager?.isPressed == false && releases == 1)
    }

    /// A Quartz scroll at window point `point` with gesture phases (`CGScrollPhase` and
    /// `CGMomentumScrollPhase` values).
    private func scroll(_ point: NSPoint, phase: Int64 = 0, momentum: Int64 = 0) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -40, wheel3: 0)!
        event.location = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return NSEvent(cgEvent: event)!
    }

    @Test func aGestureIsTheCanvassWhenItBeginsOverIt() {
        let world = World()
        defer { world.close() }
        let canvas = world.controller.canvas
        let safe = canvas.appKitSafeRect
        let centre = canvas.convert(NSPoint(x: safe.midX, y: safe.midY), to: nil)
        let dock = world.controller.dock.view
        let overDock = dock.convert(NSPoint(x: dock.bounds.midX, y: dock.bounds.midY), to: nil)
        // Began over the dock: the whole gesture and its momentum are not the canvas's, even
        // as the pointer crosses onto it.
        #expect(!canvas.ownsGesture(scroll(overDock, phase: 1)))
        #expect(!canvas.ownsGesture(scroll(centre, phase: 2)))
        #expect(!canvas.ownsGesture(scroll(centre, momentum: 2)))
        // Began over the canvas: all of it is, even over the dock.
        #expect(canvas.ownsGesture(scroll(centre, phase: 1)))
        #expect(canvas.ownsGesture(scroll(overDock, phase: 2)))
        #expect(canvas.ownsGesture(scroll(overDock, momentum: 2)))
        // A wheel's clicks, one by one.
        #expect(canvas.ownsGesture(scroll(centre)) && !canvas.ownsGesture(scroll(overDock)))
        // Another window's events never are; a canvas outside a window takes whatever it is sent.
        let other = TestWindow.make()
        defer { other.close() }
        #expect(!canvas.owns(world.mouse(.leftMouseDown, centre, in: other)))
        let loose = CanvasView(document: .memory(title: "Loose"))
        #expect(loose.owns(world.mouse(.leftMouseDown, centre)))
        // Gestures over the dock do nothing to the canvas when they reach it.
        let before = canvas.viewport
        canvas.scrollWheel(with: scroll(overDock, phase: 1))
        canvas.smartMagnify(with: world.mouse(.leftMouseDown, overDock))
        #expect(canvas.viewport == before)
        #expect(canvas.menu(for: world.mouse(.rightMouseDown, overDock)) == nil && world.menus == 0)
    }
}
