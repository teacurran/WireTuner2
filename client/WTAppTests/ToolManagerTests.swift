import AppKit
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

@Suite @MainActor struct ToolManagerTests {
    /// A registry whose tools are recording stand-ins, keyed by id.
    @MainActor
    final class Fixture {
        let registry = ToolRegistry()
        let host = RecordingHost()
        let document = DocumentHandle.memory(title: "Tools")
        var tools: [ToolID: RecordingTool] = [:]
        var shortcuts: [KeyEquivalent] = []
        let manager: ToolManager

        init(base: ToolID = .rectangle) {
            var tools: [ToolID: RecordingTool] = [:]
            for id in [ToolID.pointer, .hand, .zoom, .rectangle] {
                let tool = RecordingTool(id: id)
                tools[id] = tool
                try! registry.register(ToolDescriptor(id: id, title: id.rawValue, symbolName: "circle", helpSlug: "x") { tool })
            }
            self.tools = tools
            manager = ToolManager(registry: registry, context: ToolContext(document: document, host: host), initialTool: base)
            manager.runShortcut = { [unowned self] key in
                self.shortcuts.append(key)
                return key == KeyEquivalent("v")
            }
        }

        func calls(_ id: ToolID) -> [String] { tools[id]!.calls }
    }

    @Test func startsWithTheInitialToolActive() {
        let fixture = Fixture()
        #expect(fixture.manager.activeToolID == .rectangle)
        #expect(fixture.manager.baseToolID == .rectangle)
        #expect(!fixture.manager.isTemporary)
        #expect(fixture.calls(.rectangle) == ["activate"])
        #expect(fixture.manager.cursor == NSCursor.pointingHand)
        let unknown = ToolManager(registry: fixture.registry, context: ToolContext(document: fixture.document, host: fixture.host), initialTool: "nope")
        #expect(unknown.activeToolID == .pointer, "an unknown initial tool falls back to the Pointer")
    }

    @Test func selectActivatesAndDeactivates() {
        let fixture = Fixture()
        var changes: [ToolID] = []
        fixture.manager.onToolChange = { changes.append($0) }
        fixture.manager.select(.zoom)
        fixture.manager.select("unknown")
        #expect(fixture.manager.activeToolID == .zoom)
        #expect(fixture.calls(.rectangle) == ["activate", "deactivate"])
        #expect(fixture.calls(.zoom) == ["activate"])
        #expect(changes == [.zoom])
        #expect(fixture.host.cursorChanges == 1)
    }

    @Test func spaceHeldPushesTheHandForADragThenRestores() {
        let fixture = Fixture()
        #expect(fixture.manager.keyDown(TestEvents.space))
        #expect(fixture.manager.activeToolID == .hand)
        #expect(fixture.manager.isTemporary)
        #expect(fixture.manager.keyDown(TestEvents.key(" ", keyCode: 49, repeat: true)))
        fixture.manager.mouseDown(TestEvents.point(0, 0))
        fixture.manager.mouseDragged(TestEvents.point(5, 5))
        fixture.manager.mouseUp(TestEvents.point(5, 5))
        #expect(fixture.manager.keyUp(TestEvents.spaceUp))
        #expect(fixture.manager.activeToolID == .rectangle)
        #expect(fixture.calls(.hand) == ["activate", "down", "drag", "up", "deactivate"])
        #expect(!fixture.manager.keyUp(TestEvents.key("a", keyCode: 0, up: true)))
    }

    @Test func releasingSpaceMidDragFinishesTheHandsDragAndSwallowsTheRest() {
        let fixture = Fixture()
        fixture.manager.keyDown(TestEvents.space)
        fixture.manager.mouseDown(TestEvents.point(0, 0))
        fixture.manager.mouseDragged(TestEvents.point(3, 3))
        fixture.manager.keyUp(TestEvents.spaceUp)
        #expect(fixture.manager.activeToolID == .rectangle)
        fixture.manager.mouseDragged(TestEvents.point(9, 9))
        fixture.manager.mouseUp(TestEvents.point(9, 9))
        #expect(fixture.calls(.hand) == ["activate", "down", "drag", "up", "deactivate"], "a synthesized mouse-up ends the Hand's drag")
        #expect(fixture.calls(.rectangle) == ["activate", "deactivate", "activate"], "the restored tool sees none of the old drag")
    }

    @Test func commandHeldBeforePressingUsesThePointer() {
        let fixture = Fixture()
        fixture.manager.flagsChanged(.command)
        #expect(fixture.manager.activeToolID == .pointer)
        fixture.manager.flagsChanged([])
        #expect(fixture.manager.activeToolID == .rectangle)
        #expect(fixture.calls(.rectangle).contains("flags:\(KeyModifiers.command.rawValue)"), "the tool hears the change before it goes")
    }

    @Test func modifierChangesMidDragReachTheToolWithTheLastPointer() {
        let fixture = Fixture()
        fixture.manager.mouseDown(TestEvents.point(1, 1))
        fixture.manager.mouseDragged(TestEvents.point(4, 4))
        fixture.manager.flagsChanged(.shift, timestamp: 2)
        fixture.manager.flagsChanged([.shift, .command], timestamp: 3)
        #expect(fixture.manager.activeToolID == .rectangle, "Command mid-drag does not switch")
        fixture.manager.mouseUp(TestEvents.point(4, 4, [.shift, .command]))
        #expect(fixture.manager.activeToolID == .pointer, "it applies after mouse-up")
        #expect(fixture.calls(.rectangle).filter { $0.hasPrefix("flags") } == ["flags:2", "flags:3"])
    }

    @Test func escapeCancelsAndSwallowsTheDrag() {
        let fixture = Fixture()
        fixture.manager.mouseDown(TestEvents.point(0, 0))
        #expect(fixture.manager.keyDown(TestEvents.escape))
        fixture.manager.mouseDragged(TestEvents.point(2, 2))
        fixture.manager.mouseUp(TestEvents.point(2, 2))
        #expect(fixture.calls(.rectangle) == ["activate", "down", "cancel"])
    }

    @Test func unconsumedKeysRunShortcutsExceptMidDrag() {
        let fixture = Fixture()
        #expect(fixture.manager.keyDown(TestEvents.key("v", keyCode: 9)))
        #expect(!fixture.manager.keyDown(TestEvents.key("q", keyCode: 12)))
        #expect(fixture.shortcuts == [KeyEquivalent("v"), KeyEquivalent("q")])
        fixture.manager.mouseDown(TestEvents.point(0, 0))
        #expect(!fixture.manager.keyDown(TestEvents.key("v", keyCode: 9)))
        #expect(fixture.shortcuts.count == 2)
        fixture.manager.mouseUp(TestEvents.point(0, 0))
        fixture.tools[.rectangle]!.consumesKeys = true
        #expect(fixture.manager.keyDown(TestEvents.key("x", keyCode: 7)))
        #expect(fixture.shortcuts.count == 2)
    }

    @Test func overlayDrawingGoesToTheActiveTool() {
        let fixture = Fixture()
        let surface = BitmapSurface(width: 4, height: 4)!
        fixture.manager.drawOverlay(in: surface.context, viewport: fixture.host.viewport)
        #expect(fixture.calls(.rectangle).last == "overlay")
        #expect(fixture.host.overlayRequests == 0)
        fixture.manager.flagsChanged([])
        #expect(fixture.host.overlayRequests == 1)
    }

    @Test func toolShortcutsAreCommandsInTheRegistry() {
        let registry = ToolRegistry()
        registry.registerBuiltIn()
        registry.registerBuiltIn()
        #expect(registry.ids.count == ToolCatalog.all.count)
        #expect(Array(registry.ids.suffix(2)) == [.zoom, .hand])
        #expect(throws: ToolRegistry.Failure.duplicateID(.hand)) {
            try registry.register(ToolDescriptor(id: .hand, title: "Hand", symbolName: "hand", helpSlug: "x") { PanTool() })
        }
        let state = CommandState()
        let all = registry.commands(activate: { state.activated.append($0) }, activeTool: { state.active })
        let commands = [ToolID.pointer, .rectangle, .zoom, .hand].map { id in all.first { $0.id == ToolRegistry.commandID(for: id) }! }
        #expect(commands.map(\.id.rawValue) == ["tool.pointer", "tool.rectangle", "tool.zoom", "tool.hand"])
        #expect(commands.map(\.defaultKey) == [KeyEquivalent("v"), KeyEquivalent("r"), KeyEquivalent("z"), KeyEquivalent("h")])
        #expect(commands[0].alternateKeys == [KeyEquivalent("0")] && commands[1].alternateKeys == [KeyEquivalent("2")])
        #expect(all.allSatisfy { $0.menuPath == nil })
        #expect(commands[0].validation() == .disabled("No document is open"))
        state.active = .zoom
        #expect(commands[2].validation() == .checked(true))
        #expect(commands[0].validation() == .checked(false))
        if case let .perform(run) = commands[1].action { run() }
        #expect(state.activated == [.rectangle])
        #expect(registry.makeTool("missing").toolID == "missing")
        #expect(registry.makeTool(.zoom) is ZoomTool)
        #expect(registry.descriptor(for: .hand)?.section == .view)
        var changes = 0
        registry.onChange = { changes += 1 }
        registry.replace(ToolDescriptor(id: "new", title: "New", symbolName: "star", helpSlug: "x") { PanTool() })
        registry.replace(ToolDescriptor(id: "new", title: "Newer", symbolName: "star", helpSlug: "x") { PanTool() })
        #expect(registry.descriptor(for: "new")?.title == "Newer")
        #expect(changes == 2)
    }
}

/// Mutable state captured by `@Sendable` command closures.
@MainActor
final class CommandState {
    var activated: [ToolID] = []
    var active: ToolID?
    var count = 0
}

@Suite struct CanvasEventTranslatorTests {
    @Test func flipsAppKitPointsAndMapsThroughTheViewport() {
        let viewport = Viewport(scrollOrigin: Point(x: 100, y: 200), zoom: 2, size: Size(width: 400, height: 300))
        let event = CanvasEventTranslator.event(
            appKitPoint: CGPoint(x: 40, y: 280), viewHeight: 300, viewport: viewport,
            modifierFlags: [.shift, .option, .capsLock], pressure: 0.4, clickCount: 2, timestamp: 12.5
        )
        #expect(event.viewPoint == Point(x: 40, y: 20))
        #expect(event.pasteboardPoint.isApproximatelyEqual(to: Point(x: 120, y: 210)))
        #expect(event.modifiers == [.shift, .option])
        #expect(abs(event.pressure - 0.4) < 1e-6)
        #expect(event.clickCount == 2)
        #expect(event.timestamp == 12.5)
        let rotated = Viewport(scrollOrigin: .zero, rotationDegrees: 90, zoom: 1, size: Size(width: 400, height: 300))
        let turned = CanvasEventTranslator.event(appKitPoint: CGPoint(x: 10, y: 300), viewHeight: 300, viewport: rotated, modifierFlags: [], pressure: 0, clickCount: 0, timestamp: 0)
        #expect(turned.pasteboardPoint.isApproximatelyEqual(to: rotated.toPasteboard(Point(x: 10, y: 0))))
        #expect(turned.clickCount == 1)
        #expect(turned.pressure == 1, "a mouse reports full pressure")
    }

    @Test func normalizesPressure() {
        #expect(CanvasEventTranslator.normalizedPressure(0, isTablet: false) == 1)
        #expect(CanvasEventTranslator.normalizedPressure(0, isTablet: true) == 0)
        #expect(CanvasEventTranslator.normalizedPressure(1.7, isTablet: true) == 1)
        #expect(CanvasEventTranslator.normalizedPressure(2, isTablet: false) == 1)
        #expect(CanvasEventTranslator.normalizedPressure(.nan, isTablet: true) == 1)
    }

    @Test func scrollDeltasAndZoomFactors() {
        #expect(CanvasEventTranslator.scrollDelta(deltaX: 3, deltaY: -4, hasPreciseDeltas: true, shift: false) == Vector(dx: -3, dy: 4))
        #expect(CanvasEventTranslator.scrollDelta(deltaX: 0, deltaY: 1, hasPreciseDeltas: false, shift: false) == Vector(dx: 0, dy: -10))
        #expect(CanvasEventTranslator.scrollDelta(deltaX: 0, deltaY: 1, hasPreciseDeltas: false, shift: true) == Vector(dx: -10, dy: 0))
        #expect(CanvasEventTranslator.scrollDelta(deltaX: 2, deltaY: 1, hasPreciseDeltas: false, shift: true) == Vector(dx: -20, dy: -10))
        #expect(abs(CanvasEventTranslator.scrollZoomFactor(deltaY: 1, hasPreciseDeltas: false) - 1.1) < 1e-9)
        #expect(abs(CanvasEventTranslator.scrollZoomFactor(deltaY: 10, hasPreciseDeltas: true) - 1.1) < 1e-9)
        #expect(CanvasEventTranslator.pinchFactor(magnification: 0.25) == 1.25)
        #expect(CanvasEventTranslator.pinchFactor(magnification: -5) == 0.01)
        #expect(CanvasEventTranslator.shortcut(charactersIgnoringModifiers: nil, modifierFlags: []) == nil)
        #expect(CanvasEventTranslator.shortcut(charactersIgnoringModifiers: "R", modifierFlags: [.shift]) == KeyEquivalent("r", .shift))
    }

    @Test func toolIDsAndTheOverlayLayerCopy() {
        #expect(ToolID(rawValue: "pen") == ToolID("pen"))
        #expect(ToolID("pen").description == "pen")
        #expect(ToolID.rectangle.rawValue == "rectangle")
        let overlay = CanvasOverlayLayer()
        #expect(overlay.needsDisplayOnBoundsChange)
        let copy = CanvasOverlayLayer(layer: overlay)
        #expect(copy.drawer == nil)
        copy.draw(in: BitmapSurface(width: 2, height: 2)!.context)
    }

    @MainActor @Test func theOverlayLayerAskedToDrawOffTheMainThreadDrawsLaterOnIt() async {
        let overlay = CanvasOverlayLayer()
        overlay.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
        let counter = DrawCounter()
        overlay.drawer = { _ in counter.draws += 1 }
        overlay.draw(in: BitmapSurface(width: 4, height: 4)!.context)
        #expect(counter.draws == 1)
        overlay.setNeedsDisplay()
        overlay.displayIfNeeded()
        let drawn = counter.draws
        #expect(!overlay.needsDisplay())
        nonisolated(unsafe) let layer = overlay
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                // Before the fix this trapped in MainActor.assumeIsolated.
                layer.draw(in: BitmapSurface(width: 4, height: 4)!.context)
                done.resume()
            }
        }
        await Task.yield()
        #expect(counter.draws == drawn && overlay.needsDisplay())
        overlay.displayIfNeeded()
        #expect(counter.draws == drawn + 1)
    }

    @Test func canvasEventsCarryModifiersForward() {
        let event = CanvasEvent(pasteboardPoint: Point(x: 1, y: 2), viewPoint: Point(x: 3, y: 4), pressure: 0.5, clickCount: 2, timestamp: 1)
        let changed = event.with(modifiers: .shift)
        #expect(changed.modifiers == .shift)
        #expect(changed.pasteboardPoint == event.pasteboardPoint)
        #expect(changed.timestamp == 1)
        #expect(event.with(modifiers: [], timestamp: 9).timestamp == 9)
    }
}

/// Counts an overlay's draws (only ever touched on the main thread).
final class DrawCounter: @unchecked Sendable {
    var draws = 0
}
