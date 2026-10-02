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
