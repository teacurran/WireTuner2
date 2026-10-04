import AppKit
import Testing
import WTGeometry
import WTModel
import WTRender
@testable import WireTuner

/// Found in use (2026-10-02): clicks, right-clicks and scrolls on the panels and the Tools panel
/// reached the canvas under them.  AppKit hands a right-click (`menu(for:)`), a scroll and the
/// trackpad gestures that no view under the pointer takes to the view beneath -- the canvas,
/// which runs under the docks (D-077) -- so the canvas's context menu opened under a panel and a
/// swipe over the Tools panel panned the artboard.  These tests send real AppKit events through
/// the document window at points over the docked clusters, their handles and a floating cluster,
/// and over the canvas for contrast.
@Suite(.serialized) @MainActor struct PanelClickThroughTests {
    @MainActor
    final class World {
        let environment = TestEnvironment()
        let controller: DocumentWindowController
        let window: NSWindow
        var presses = 0
        /// Mouse-ups the canvas heard (a release it never saw pressed is as wrong as a press).
        var releases = 0
        var menus = 0
        var viewportChanges = 0
        var clusterDrags = 0

        init() {
            environment.panels.groupDefaults[PanelCatalog.Group.tools] = PanelCatalog.groupDefaults[PanelCatalog.Group.tools]
            environment.panels.registerIfAbsent(ToolsPanel.descriptor(model: ToolPaletteModel()))
            environment.layout.addRegisteredPanels()
            controller = DocumentWindowController(document: .memory(id: UUID().uuidString, title: "Click-through"), environment: environment.document)
            window = controller.window!
            window.setContentSize(NSSize(width: 1400, height: 900))
            window.orderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            let canvas = controller.canvas
            let press = canvas.onPress
            canvas.onPress = { [unowned self] down in
                if down { self.presses += 1 } else { self.releases += 1 }
                press?(down)
            }
            canvas.onContextMenu = { [unowned self] _, _ in
                self.menus += 1
                return nil
            }
            let viewport = canvas.onViewportChange
            canvas.onViewportChange = { [unowned self] next in
                self.viewportChanges += 1
                viewport?(next)
            }
            controller.panelInteraction.runClusterDrag = { [unowned self] drag in
                self.clusterDrags += 1
                drag.cancel()
            }
            // The page in the middle of the view, away from the scrollable extent's edges (the
            // pasteboard's, or D-093's page area), so a scroll that reaches the canvas moves it.
            let page = controller.documentHandle.pageList.pages[0].rect
            let size = canvas.viewport.size
            canvas.setViewport(Viewport(scrollOrigin: Point(x: page.midX - size.width / 2, y: page.midY - size.height / 2), zoom: 1, size: size))
            drain()
            reset()
        }

        func close() { controller.close() }

        func reset() {
            presses = 0
            releases = 0
            menus = 0
            viewportChanges = 0
        }

        var canvasHeard: Bool { presses > 0 || releases > 0 || menus > 0 || viewportChanges > 0 }
        /// What the canvas heard, for the failure messages.
        var heard: String { "presses \(presses), releases \(releases), menus \(menus), viewport changes \(viewportChanges)" }

        /// Mouse events another test (or an earlier gesture) left in the queue.
        func drain() {
            while NSApp.nextEvent(matching: Self.mouseMask, until: .distantPast, inMode: .eventTracking, dequeue: true) != nil {}
        }

        static let mouseMask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        ]

        func mouse(_ type: NSEvent.EventType, _ point: NSPoint, in target: NSWindow? = nil, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: (target ?? window).windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        /// A trackpad scroll at window point `point` (a Quartz scroll event, as the trackpad sends).
        /// It has no window, so its location is read as the point in the window it is sent to.
        func scroll(_ point: NSPoint, dx: Int32 = -40, dy: Int32 = 0) -> NSEvent {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
            // Quartz puts the origin at the top of the main display.
            event.location = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
            return NSEvent(cgEvent: event)!
        }

        /// `events` as AppKit delivers them: the first to the window, the rest queued so that a
        /// view's tracking loop (a button, a title bar) takes them, and whatever is left over
        /// dispatched afterwards.
        func deliver(_ events: [NSEvent], to target: NSWindow? = nil) {
            let target = target ?? window
            drain()
            guard let first = events.first else { return }
            for event in events.dropFirst() { target.postEvent(event, atStart: false) }
            target.sendEvent(first)
            while let event = NSApp.nextEvent(matching: Self.mouseMask, until: .distantPast, inMode: .default, dequeue: true) { target.sendEvent(event) }
        }

        /// The trackpad gestures, by the IOHID event type a Quartz gesture event carries.
        enum Gesture: Int64, CaseIterable {
            case rotate = 5, magnify = 8, swipe = 16, smartMagnify = 22, pressure = 32
        }

        /// A trackpad gesture at window point `point`, as the trackpad sends it: a Quartz gesture
        /// event (type 29) with its IOHID type (field 110), its magnification, rotation or swipe
        /// (fields 113 and 114; a swipe's in 115, which AppKit needs to deliver one and which zeroes a
        /// magnification) and its phase (field 132, a `CGScrollPhase`: 1 began, 2 changed,
        /// 4 ended).  Like a scroll it has no window: its location is the point in the window it
        /// is sent to.
        func gesture(_ kind: Gesture, _ point: NSPoint, value: Double = 0, phase: Int64 = 0) -> NSEvent {
            let event = CGEvent(source: nil)!
            event.type = CGEventType(rawValue: 29)!
            event.location = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
            event.setIntegerValueField(CGEventField(rawValue: 110)!, value: kind.rawValue)
            event.setDoubleValueField(CGEventField(rawValue: 113)!, value: value)
            event.setDoubleValueField(CGEventField(rawValue: 114)!, value: value)
            if kind == .swipe { event.setDoubleValueField(CGEventField(rawValue: 115)!, value: value) }
            event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
            return NSEvent(cgEvent: event)!
        }

        /// A window point where `view` itself, not one of its controls, is hit.
        func bare(_ view: NSView) -> NSPoint? {
            for y in stride(from: view.bounds.minY + 2, to: view.bounds.maxY - 1, by: 3) {
                for x in stride(from: view.bounds.maxX - 2, to: view.bounds.minX + 1, by: -3) {
                    let point = view.convert(NSPoint(x: x, y: y), to: nil)
                    if hit(point) === view { return point }
                }
            }
            return nil
        }

        func click(_ point: NSPoint, in target: NSWindow? = nil) {
            deliver([mouse(.leftMouseDown, point, in: target), mouse(.leftMouseUp, point, in: target)], to: target)
        }

        func rightClick(_ point: NSPoint, in target: NSWindow? = nil) {
            deliver([mouse(.rightMouseDown, point, in: target), mouse(.rightMouseUp, point, in: target)], to: target)
        }

        func otherClick(_ point: NSPoint, in target: NSWindow? = nil) {
            deliver([mouse(.otherMouseDown, point, in: target), mouse(.otherMouseUp, point, in: target)], to: target)
        }

        func controlClick(_ point: NSPoint, in target: NSWindow? = nil) {
            deliver([mouse(.leftMouseDown, point, in: target, flags: .control), mouse(.leftMouseUp, point, in: target, flags: .control)], to: target)
        }

        func sendScroll(_ point: NSPoint, in target: NSWindow? = nil, dx: Int32 = -40, dy: Int32 = 0) {
            drain()
            let event = scroll(point, dx: dx, dy: dy)
            #expect(event.locationInWindow == point && (event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0), "a scroll at \(point): \(event)")
            (target ?? window).sendEvent(event)
        }

        /// The window point at the middle of `rect` in `view`.
        func point(_ rect: NSRect, in view: NSView) -> NSPoint {
            view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        }

        /// The view the window hits at window point `point`.
        func hit(_ point: NSPoint, in target: NSWindow? = nil) -> NSView? {
            let frame = (target ?? window).contentView?.superview
            return frame?.hitTest(frame?.convert(point, from: nil) ?? point)
        }

        /// Window points over the Tools panel: a tool button, a gap between buttons, the body
        /// under the buttons, the title bar.
        func toolsPoints(in groupView: PanelGroupView) -> [String: NSPoint] {
            var points: [String: NSPoint] = [:]
            let target = groupView.window ?? window
            let bounds = groupView.bounds
            var previous: (NSPoint, Bool)?
            for y in stride(from: PanelGroupView.titleHeight + 4, to: bounds.height - 4, by: 2) {
                for x in stride(from: 4, to: bounds.width - 4, by: 2) {
                    let point = groupView.convert(NSPoint(x: x, y: y), to: nil)
                    let isButton = hit(point, in: target).map { String(describing: type(of: $0)).contains("Button") } ?? false
                    if isButton, points["button"] == nil { points["button"] = point }
                    if let previous, previous.1, !isButton, points["gap"] == nil { points["gap"] = point }
                    previous = (point, isButton)
                }
                previous = nil
            }
            points["body"] = groupView.convert(NSPoint(x: bounds.midX, y: bounds.height - 10), to: nil)
            points["title"] = point(groupView.titleBar.convert(groupView.titleBar.bounds, to: groupView), in: groupView)
            return points
        }
    }

    @Test func clicksOnTheToolsPanelNeverReachTheCanvas() throws {
        let world = World()
        defer { world.close() }
        let tools = try #require(world.controller.leftDock.groupViews.first { $0.group.id == "tools" })
        let points = world.toolsPoints(in: tools)
        #expect(points["button"] != nil && points["gap"] != nil, "found a tool button and a gap: \(points)")
        for (name, point) in points.sorted(by: { $0.key < $1.key }) where name != "title" {
            world.click(point)
            #expect(!world.canvasHeard, "a click on the Tools panel's \(name) reached the canvas: \(world.heard)")
            world.reset()
        }
        // The title bar: a click collapses the group, a drag moves the cluster -- never the canvas.
        // (Its own tracking loop takes the rest of the gesture; called directly, as the test
        // window is not key and the bar does not take a first click.)
        let title = try #require(points["title"])
        world.drain()
        world.window.postEvent(world.mouse(.leftMouseUp, title), atStart: false)
        tools.titleBar.mouseDown(with: world.mouse(.leftMouseDown, title))
        #expect(world.environment.layout.layout.group("tools")?.collapsed == true, "the title bar took the click")
        world.environment.layout.update { $0.toggleCollapsed(group: "tools") }
        let bar = try #require(world.controller.leftDock.groupViews.first { $0.group.id == "tools" }?.titleBar)
        world.drain()
        for x in [title.x + 40, title.x + 400] { world.window.postEvent(world.mouse(.leftMouseDragged, NSPoint(x: x, y: title.y)), atStart: false) }
        world.window.postEvent(world.mouse(.leftMouseUp, NSPoint(x: title.x + 400, y: title.y)), atStart: false)
        bar.mouseDown(with: world.mouse(.leftMouseDown, title))
        world.deliver([])
        while let event = NSApp.nextEvent(matching: World.mouseMask, until: .distantPast, inMode: .default, dequeue: true) { world.window.sendEvent(event) }
        #expect(world.clusterDrags == 1 && !world.canvasHeard, "the title bar drag moved the cluster, the canvas heard nothing: \(world.heard)")
    }

    @Test func rightClicksScrollsAndOtherButtonsOnTheToolsPanelNeverReachTheCanvas() throws {
        let world = World()
        defer { world.close() }
        let tools = try #require(world.controller.leftDock.groupViews.first { $0.group.id == "tools" })
        var points = world.toolsPoints(in: tools)
        points["handle"] = world.point(world.controller.leftHandle.bounds, in: world.controller.leftHandle)
        for (name, point) in points.sorted(by: { $0.key < $1.key }) {
            world.rightClick(point)
            #expect(world.menus == 0 && world.presses == 0, "a right-click on the Tools panel's \(name) opened the canvas's menu: \(world.heard)")
            world.reset()
            world.controlClick(point)
            #expect(world.menus == 0 && world.presses == 0, "a Control-click on the Tools panel's \(name) reached the canvas: \(world.heard)")
            world.reset()
            world.otherClick(point)
            #expect(!world.canvasHeard, "a middle click on the Tools panel's \(name) reached the canvas: \(world.heard)")
            world.reset()
            let before = world.controller.canvas.viewport
            world.sendScroll(point)
            #expect(world.controller.canvas.viewport == before && world.viewportChanges == 0, "a scroll over the Tools panel's \(name) scrolled the canvas")
            world.reset()
        }
    }

    @Test func rightClicksAndScrollsOnTheDockedPanelsNeverReachTheCanvas() throws {
        let world = World()
        defer { world.close() }
        let dock = world.controller.dock
        let column = dock.column
        let groups = dock.groupViews
        #expect(groups.count >= 2)
        var points: [String: NSPoint] = [:]
        for group in groups {
            points["\(group.group.id).title"] = world.point(group.titleBar.convert(group.titleBar.bounds, to: group), in: group)
            points["\(group.group.id).gripper"] = world.point(group.gripper.bounds, in: group.gripper)
        }
        if let divider = column.dividers.first { points["divider"] = world.point(divider.bounds, in: divider) }
        let cluster = dock.clusterView
        points["cluster.bottom"] = cluster.convert(NSPoint(x: cluster.bounds.midX, y: cluster.bounds.height - 2), to: nil)
        points["handle"] = world.point(world.controller.rightHandle.bounds, in: world.controller.rightHandle)
        for (name, point) in points.sorted(by: { $0.key < $1.key }) {
            world.rightClick(point)
            #expect(world.menus == 0 && world.presses == 0, "a right-click on the dock's \(name) opened the canvas's menu: \(world.heard)")
            world.reset()
            world.otherClick(point)
            #expect(!world.canvasHeard, "a middle click on the dock's \(name) reached the canvas: \(world.heard)")
            world.reset()
            let before = world.controller.canvas.viewport
            world.sendScroll(point)
            world.sendScroll(point, dx: 0, dy: -40)
            #expect(world.controller.canvas.viewport == before && world.viewportChanges == 0, "a scroll over the dock's \(name) scrolled the canvas")
            world.reset()
        }
        // A click on a title bar's empty part, a gripper or the cluster's bottom edge: the
        // panels' own gestures, never the canvas's.
        for name in ["cluster.bottom"] + groups.map({ "\($0.group.id).title" }) {
            let point = try #require(points[name])
            world.click(point)
            world.click(point)
            #expect(world.presses == 0, "a click on the dock's \(name) reached the canvas: \(world.heard)")
            world.reset()
        }
    }

    @Test func aFloatingToolsPanelKeepsItsEventsFromTheCanvas() throws {
        let world = World()
        let floating = FloatingPanelsController(panels: world.environment.panels, layout: world.environment.layout, interaction: world.controller.panelInteraction)
        floating.parentWindow = { [weak world] in world?.window }
        defer {
            for window in floating.windows.values { window.close() }
            world.close()
        }
        let frame = world.window.frame
        world.environment.layout.update { $0.undock(cluster: "left", frame: LayoutRect(x: frame.minX + 30, y: frame.minY + 200, width: 84, height: 600)) }
        let panel = try #require(floating.windows["left"])
        panel.contentView?.layoutSubtreeIfNeeded()
        world.window.contentView?.layoutSubtreeIfNeeded()
        // The dock left the window: the canvas's safe area grew (a viewport change of its own).
        world.reset()
        let tools = try #require(panel.groupViews.first { $0.group.id == "tools" })
        let points = world.toolsPoints(in: tools)
        #expect(points["button"] != nil)
        for (name, point) in points.sorted(by: { $0.key < $1.key }) where name != "title" {
            world.click(point, in: panel)
            world.rightClick(point, in: panel)
            world.otherClick(point, in: panel)
            world.sendScroll(point, in: panel)
            #expect(!world.canvasHeard, "an event on the floating Tools panel's \(name) reached the canvas: \(world.heard)")
            world.reset()
        }
    }

    /// Right and middle drags and every trackpad gesture, sent through the window over the status
    /// bar and a dock handle where nothing inside them takes the event: the barrier ends each one,
    /// and the canvas beneath hears none.  (A left press in this window, which is never key in
    /// the test host, is a first click AppKit keeps for itself, and AppKit dispatches pressure
    /// only during a real Force Touch press: those two are checked on the responder chain below.)
    @Test func dragsAndTrackpadGesturesOnThePanelsEndAtTheirBarrier() throws {
        let world = World()
        defer { world.close() }
        let canvas = world.controller.canvas
        let barriers: [(String, PanelEventBarrierView)] = [("status bar", world.controller.statusBar), ("dock handle", world.controller.rightHandle)]
        for (name, barrier) in barriers {
            let point = try #require(world.bare(barrier), "a point on the \(name) where none of its controls is")
            let viewport = canvas.viewport
            /// Sends `events` as AppKit delivers them and expects the barrier to stop every one.
            func expectStopped(_ what: String, _ events: [NSEvent]) {
                let before = barrier.stoppedEvents
                world.deliver(events.filter(Self.isMouse))
                for event in events where !Self.isMouse(event) { world.window.sendEvent(event) }
                #expect(barrier.stoppedEvents - before == events.count, "the \(name) stopped \(barrier.stoppedEvents - before) of the \(events.count) events of a \(what)")
            }
            let away = NSPoint(x: point.x - 300, y: point.y)
            expectStopped("right drag", [world.mouse(.rightMouseDown, point), world.mouse(.rightMouseDragged, away), world.mouse(.rightMouseUp, away)])
            expectStopped("middle drag", [world.mouse(.otherMouseDown, point), world.mouse(.otherMouseDragged, away), world.mouse(.otherMouseUp, away)])
            expectStopped("pinch", [world.gesture(.magnify, point, value: 0.5, phase: 1), world.gesture(.magnify, point, value: 0.5, phase: 2),
                                    world.gesture(.magnify, point, phase: 4)])
            expectStopped("two-finger rotation", [world.gesture(.rotate, point, value: 30, phase: 1), world.gesture(.rotate, point, value: 30, phase: 2),
                                                  world.gesture(.rotate, point, phase: 4)])
            expectStopped("smart zoom", [world.gesture(.smartMagnify, point)])
            expectStopped("swipe", [world.gesture(.swipe, point, value: 1)])
            #expect(!world.canvasHeard && canvas.viewport == viewport, "the canvas under the \(name) heard: \(world.heard)")
            world.reset()
        }
    }

    /// What NSView does with an event it does not handle -- pass it to its next responder, on up
    /// to the window -- a barrier does not: every mouse, scroll and gesture event ends at it.
    @Test func aBarrierPassesNoEventOnUpTheResponderChain() {
        let world = World()
        defer { world.close() }
        @MainActor final class Spy: NSResponder {
            var heard: [NSEvent.EventType] = []
            override func mouseDown(with event: NSEvent) { heard.append(event.type) }
            override func mouseDragged(with event: NSEvent) { heard.append(event.type) }
            override func mouseUp(with event: NSEvent) { heard.append(event.type) }
            override func rightMouseDown(with event: NSEvent) { heard.append(event.type) }
            override func rightMouseDragged(with event: NSEvent) { heard.append(event.type) }
            override func rightMouseUp(with event: NSEvent) { heard.append(event.type) }
            override func otherMouseDown(with event: NSEvent) { heard.append(event.type) }
            override func otherMouseDragged(with event: NSEvent) { heard.append(event.type) }
            override func otherMouseUp(with event: NSEvent) { heard.append(event.type) }
            override func scrollWheel(with event: NSEvent) { heard.append(event.type) }
            override func magnify(with event: NSEvent) { heard.append(event.type) }
            override func rotate(with event: NSEvent) { heard.append(event.type) }
            override func smartMagnify(with event: NSEvent) { heard.append(event.type) }
            override func swipe(with event: NSEvent) { heard.append(event.type) }
            override func pressureChange(with event: NSEvent) { heard.append(event.type) }
        }
        let point = NSPoint(x: 20, y: 20)
        let sends: [(NSResponder) -> Void] = [
            { $0.mouseDown(with: world.mouse(.leftMouseDown, point)) }, { $0.mouseDragged(with: world.mouse(.leftMouseDragged, point)) },
            { $0.mouseUp(with: world.mouse(.leftMouseUp, point)) }, { $0.rightMouseDown(with: world.mouse(.rightMouseDown, point)) },
            { $0.rightMouseDragged(with: world.mouse(.rightMouseDragged, point)) }, { $0.rightMouseUp(with: world.mouse(.rightMouseUp, point)) },
            { $0.otherMouseDown(with: world.mouse(.otherMouseDown, point)) }, { $0.otherMouseDragged(with: world.mouse(.otherMouseDragged, point)) },
            { $0.otherMouseUp(with: world.mouse(.otherMouseUp, point)) }, { $0.scrollWheel(with: world.scroll(point)) },
            { $0.magnify(with: world.gesture(.magnify, point, value: 0.5, phase: 1)) }, { $0.rotate(with: world.gesture(.rotate, point, value: 30, phase: 1)) },
            { $0.smartMagnify(with: world.gesture(.smartMagnify, point)) }, { $0.swipe(with: world.gesture(.swipe, point, value: 1)) },
            { $0.pressureChange(with: world.gesture(.pressure, point)) },
        ]
        // A plain view passes every one on.
        let plain = NSView()
        let passed = Spy()
        plain.nextResponder = passed
        for send in sends { send(plain) }
        #expect(passed.heard.count == sends.count, "NSView passed on \(passed.heard)")
        // A barrier -- a bare one and the status bar in its window -- keeps every one.
        for barrier in [PanelEventBarrierView(), world.controller.statusBar] {
            let next = barrier.nextResponder
            let spy = Spy()
            barrier.nextResponder = spy
            let before = barrier.stoppedEvents
            for send in sends { send(barrier) }
            barrier.nextResponder = next
            #expect(spy.heard.isEmpty && barrier.stoppedEvents - before == sends.count, "passed on \(spy.heard)")
        }
        #expect(!world.canvasHeard, "\(world.heard)")
    }

    static func isMouse(_ event: NSEvent) -> Bool {
        World.mouseMask.contains(NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue))
    }

    @Test func overTheCanvasTheSameEventsDoReachIt() throws {
        let world = World()
        defer { world.close() }
        let canvas = world.controller.canvas
        let safe = canvas.appKitSafeRect
        let point = canvas.convert(NSPoint(x: safe.midX, y: safe.midY), to: nil)
        world.rightClick(point)
        #expect(world.menus == 1, "the canvas's context menu")
        world.reset()
        let before = canvas.viewport
        world.sendScroll(point)
        #expect(canvas.viewport != before, "the canvas scrolls")
        world.reset()
        world.click(point)
        #expect(world.presses == 1)
    }
}
