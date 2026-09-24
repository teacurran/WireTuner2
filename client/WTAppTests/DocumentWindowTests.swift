import AppKit
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

@Suite @MainActor struct WindowStateStoreTests {
    @Test func roundTripsPerDocumentAndKeepsOthers() throws {
        let store = WindowStateStore(url: TestEnvironment.temporaryDirectory().appending(path: "nested").appending(path: WindowStateStore.fileName))
        #expect(try store.loadAll().isEmpty)
        #expect(store.state(for: "a") == nil)
        let a = DocumentWindowState(frame: LayoutRect(x: 10, y: 20, width: 900, height: 700), zoom: 2.5, scrollX: 100, scrollY: 200, rotationDegrees: 15, viewMode: .fastKeyline)
        let b = DocumentWindowState(zoom: 0.5)
        try store.save(a, for: "a")
        try store.save(b, for: "b")
        #expect(store.state(for: "a") == a)
        #expect(store.state(for: "b") == b)
        #expect(try store.loadAll().count == 2)
        var changed = a
        changed.zoom = 4
        try store.save(changed, for: "a")
        #expect(store.state(for: "a")?.zoom == 4)
        #expect(store.state(for: "b") == b)
        try store.removeState(for: "b")
        try store.removeState(for: "missing")
        #expect(try store.loadAll().keys.sorted() == ["a"])
        let viewport = a.viewport(size: Size(width: 300, height: 200))
        #expect(viewport.zoom == 2.5 && viewport.scrollOrigin == Point(x: 100, y: 200) && viewport.rotationDegrees == 15)
        #expect(DocumentWindowState(frame: nil, viewport: viewport, viewMode: .keyline).scrollX == 100)
        #expect(WindowStateStore.defaultURL.lastPathComponent == "WindowState.json")
    }

    @Test func rejectsOtherVersionsAndReplacesGarbage() throws {
        let directory = TestEnvironment.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = WindowStateStore(url: directory.appending(path: WindowStateStore.fileName))
        try Data(#"{"version": 7, "documents": {}}"#.utf8).write(to: store.url)
        #expect(throws: WindowStateStore.Failure.unsupportedVersion(7)) { try store.loadAll() }
        #expect(store.state(for: "a") == nil)
        try Data("garbage".utf8).write(to: store.url)
        try store.save(DocumentWindowState(), for: "a")
        #expect(store.state(for: "a") == DocumentWindowState())
    }
}

@Suite @MainActor struct DocumentWindowTests {
    private func window(_ environment: TestEnvironment, title: String = "Doc", id: String = UUID().uuidString) -> DocumentWindowController {
        DocumentWindowController(document: .memory(id: id, title: title), environment: environment.document)
    }

    @Test func opensFittedToThePageWithRulersCanvasStatusBarAndDock() {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let window = controller.window!
        #expect(window.tabbingMode == .preferred)
        #expect(window.tabbingIdentifier == DocumentWindowController.tabbingIdentifier)
        window.contentView?.layoutSubtreeIfNeeded()
        controller.rulerHost.layoutSubtreeIfNeeded()
        let host = controller.rulerHost
        let thickness = RulerHostView.rulerThickness
        #expect(host.horizontalRuler.frame.height == thickness)
        #expect(host.verticalRuler.frame.width == thickness)
        #expect(host.horizontalRuler.frame.width == controller.canvas.frame.width)
        #expect(host.verticalRuler.frame.height == controller.canvas.frame.height)
        #expect(controller.canvas.frame.minX == thickness && controller.canvas.frame.minY == thickness)
        #expect(host.verticalScroller.frame.minX == controller.canvas.frame.maxX)
        #expect(host.horizontalScroller.frame.minY == controller.canvas.frame.maxY)
        #expect(controller.statusBar.frame.height == StatusBarView.height)
        #expect(host.horizontalRuler.accessibilityIdentifier() == "ruler.horizontal")
        #expect(host.verticalRuler.accessibilityRole() == .ruler)
        // No saved state: fitted to the page.
        let page = Pasteboard.letterPage
        let viewport = controller.viewport
        #expect(viewport.toView(page.center).isApproximatelyEqual(to: viewport.viewCenter, tolerance: 1e-6))
        #expect(controller.statusBar.magnification.stringValue == MagnificationFormat.string(for: viewport.zoom))
        #expect(controller.statusBar.viewMode.titleOfSelectedItem == "Preview")
        #expect(controller.toolManager.activeToolID == .pointer)
    }

    @Test func rulersCanBeHidden() {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        controller.rulerHost.rulersVisible = false
        controller.rulerHost.layoutSubtreeIfNeeded()
        #expect(controller.canvas.frame.minX == 0)
        #expect(controller.rulerHost.horizontalRuler.isHidden)
        #expect(RulerHostView.canvasFrame(in: CGSize(width: 10, height: 10), rulersVisible: true).width == 0)
    }

    @Test func zoomCommandsLandOnTheDocumentedMagnifications() {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        controller.zoom(toPercent: 100)
        #expect(controller.viewport.zoom == 1)
        let centre = controller.viewport.toPasteboard(controller.viewport.viewCenter)
        controller.zoomIn()
        #expect(controller.viewport.zoom == 2)
        #expect(controller.viewport.toPasteboard(controller.viewport.viewCenter).isApproximatelyEqual(to: centre, tolerance: 1e-6))
        controller.zoomOut()
        controller.zoomOut()
        #expect(controller.viewport.zoom == 0.5)
        controller.zoom(toPercent: 3200)
        #expect(controller.viewport.zoom == 32)
        controller.fitAll()
        let fitted = controller.viewport.zoom
        controller.fitPage()
        #expect(controller.viewport.zoom == fitted, "one page: Fit All is Fit to Page")
        controller.fit(selection: nil)
        #expect(controller.viewport.zoom == fitted)
        controller.fit(selection: Rect(x: 8000, y: 8000, width: 10, height: 10))
        #expect(controller.viewport.zoom > 10)
    }

    @Test func theMagnificationFieldParsesClampsAndBeeps() {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let state = CommandState()
        controller.beep = { state.count += 1 }
        controller.enterMagnification("4x")
        #expect(controller.viewport.zoom == 4)
        #expect(controller.statusBar.magnification.stringValue == "400%")
        controller.enterMagnification("99999")
        #expect(controller.viewport.zoom == 256)
        #expect(state.count == 1)
        controller.enterMagnification("nonsense")
        #expect(state.count == 2)
        #expect(controller.statusBar.magnification.stringValue == "25600%", "invalid input shows the current value again")
        controller.enterMagnification(StatusBarView.fitPageTitle)
        let fitted = controller.viewport.zoom
        controller.enterMagnification("100%")
        controller.enterMagnification(StatusBarView.fitAllTitle)
        #expect(controller.viewport.zoom == fitted)
        controller.enterMagnification(StatusBarView.fitSelectionTitle)
        #expect(state.count == 3, "no selection yet")

        // The status bar's controls report through the same path.
        controller.statusBar.magnification.stringValue = "200"
        controller.statusBar.magnificationEntered(controller.statusBar.magnification)
        #expect(controller.viewport.zoom == 2)
        controller.statusBar.magnification.selectItem(withObjectValue: "50%")
        controller.statusBar.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: controller.statusBar.magnification))
        #expect(controller.viewport.zoom == 0.5)
        controller.statusBar.magnification.deselectItem(at: controller.statusBar.magnification.indexOfSelectedItem)
        controller.statusBar.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: controller.statusBar.magnification))
        #expect(controller.viewport.zoom == 0.5)
    }

    @Test func viewModeFollowsThePopUpAndTheToggles() {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        controller.toggleKeyline()
        #expect(controller.viewMode == .keyline)
        #expect(controller.statusBar.viewMode.titleOfSelectedItem == "Keyline")
        controller.toggleFastMode()
        #expect(controller.viewMode == .fastKeyline)
        controller.statusBar.viewMode.selectItem(withTitle: "Fast Preview")
        controller.statusBar.viewModeChosen(controller.statusBar.viewMode)
        #expect(controller.viewMode == .fastPreview)
        controller.statusBar.show(message: "Hello")
        #expect(controller.statusBar.message.stringValue == "Hello")
    }

    @Test func scrollBarsDriveTheViewport() {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        controller.zoom(toPercent: 100)
        controller.scrollHorizontally(to: 0)
        controller.scrollVertically(to: 1)
        let scroller = controller.canvas.navigation.scroller
        #expect(scroller.horizontal(controller.viewport).value == 0)
        #expect(abs(scroller.vertical(controller.viewport).value - 1) < 1e-9)
        #expect(controller.rulerHost.verticalScroller.doubleValue == scroller.vertical(controller.viewport).value)
        let host = controller.rulerHost
        #expect(RulerHostView.value(after: .incrementPage, current: 0.5, knobProportion: 0.5) == 1)
        #expect(RulerHostView.value(after: .decrementPage, current: 0.5, knobProportion: 0.5) == 0)
        #expect(RulerHostView.value(after: .knob, current: 0.3, knobProportion: 0.5) == 0.3)
        host.horizontalScroller.doubleValue = 0.5
        host.scrollerMoved(host.horizontalScroller)
        #expect(abs(scroller.horizontal(controller.viewport).value - 0.5) < 1e-6)
        host.verticalScroller.doubleValue = 0.25
        host.scrollerMoved(host.verticalScroller)
        #expect(abs(scroller.vertical(controller.viewport).value - 0.25) < 1e-6)
    }

    @Test func stateIsSavedAndRestoredPerDocument() {
        let environment = TestEnvironment()
        let id = UUID().uuidString
        let first = window(environment, id: id)
        first.zoom(toPercent: 400)
        first.setViewMode(.keyline)
        first.window?.setFrame(NSRect(x: 40, y: 50, width: 900, height: 650), display: false)
        let saved = first.viewport
        first.close()
        let state = environment.windowStates.state(for: id)
        #expect(state?.zoom == 4)
        #expect(state?.viewMode == .keyline)
        #expect(state?.frame?.width == 900)

        let second = window(environment, id: id)
        #expect(second.viewport.zoom == 4)
        #expect(second.viewport.scrollOrigin.isApproximatelyEqual(to: saved.scrollOrigin, tolerance: 1e-6))
        #expect(second.viewMode == .keyline)
        #expect(second.window?.frame.width == 900)
        second.windowDidMove(Notification(name: NSWindow.didMoveNotification))
        second.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
        second.close()

        environment.preferences.set(false, for: PreferenceCatalog.Document.restoreView)
        environment.preferences.set(false, for: PreferenceCatalog.Document.rememberWindow)
        let third = window(environment, id: id)
        #expect(third.viewMode == .preview, "restore off: the page is fitted, the mode is Preview")
        #expect(third.window?.frame.width != 900)
        third.close()
        environment.suite.remove()
    }

    @Test func shortcutsTypedOnTheCanvasRunRegistryCommands() {
        let environment = TestEnvironment()
        let registry = environment.tools
        let commands = registry.commands(activate: { _ in }, activeTool: { nil })
        for command in commands { environment.commands.replace(command) }
        environment.shortcuts = .builtInDefault(commands: environment.commands.commands)
        let controller = window(environment)
        defer { controller.close() }
        // Rewire the tool commands onto this window.
        for command in registry.commands(
            activate: { [weak controller] id in controller?.toolManager.select(id) },
            activeTool: { [weak controller] in controller?.toolManager.activeToolID }
        ) {
            environment.commands.replace(command)
        }
        #expect(controller.toolManager.keyDown(TestEvents.key("r", keyCode: 15)))
        #expect(controller.toolManager.activeToolID == .rectangle)
        #expect(environment.performed == [ToolRegistry.commandID(for: .rectangle)])
        #expect(!controller.toolManager.keyDown(TestEvents.key("j", keyCode: 38)))
        #expect(environment.document.runShortcut(KeyEquivalent("h")))
        #expect(controller.toolManager.activeToolID == .hand)
    }
}

@Suite @MainActor struct CanvasViewTests {
    private func canvas() -> (CanvasView, ToolManager) {
        let environment = TestEnvironment()
        let canvas = CanvasView(document: .memory(title: "Canvas"), frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let manager = ToolManager(registry: environment.tools, context: ToolContext(document: canvas.document, host: canvas))
        canvas.toolManager = manager
        canvas.setViewport(Viewport(scrollOrigin: Point(x: 7000, y: 7000), zoom: 1, size: Size(width: 400, height: 300)))
        return (canvas, manager)
    }

    @Test func scrollingPansAndOptionScrollZoomsAboutThePointer() {
        let (canvas, _) = canvas()
        var reported: [Viewport] = []
        canvas.onViewportChange = { reported.append($0) }
        canvas.scroll(deltaX: -10, deltaY: -20, precise: true, modifierFlags: [], at: .zero)
        #expect(canvas.viewport.scrollOrigin == Point(x: 7010, y: 7020))
        #expect(reported.count == 1)
        let pointer = CGPoint(x: 100, y: 200)
        let viewPoint = Point(x: 100, y: 100)
        let anchored = canvas.viewport.toPasteboard(viewPoint)
        canvas.scroll(deltaX: 0, deltaY: 1, precise: false, modifierFlags: .option, at: pointer)
        #expect(abs(canvas.viewport.zoom - 1.1) < 1e-9)
        #expect(canvas.viewport.toView(anchored).isApproximatelyEqual(to: viewPoint, tolerance: 1e-6))
        canvas.magnify(by: 1, at: pointer)
        #expect(abs(canvas.viewport.zoom - 2.2) < 1e-9)
        #expect(canvas.viewport.toView(anchored).isApproximatelyEqual(to: viewPoint, tolerance: 1e-6))
        let same = canvas.viewport
        canvas.setViewport(same)
        #expect(reported.count == 3, "an unchanged viewport reports nothing")
    }

    @Test func resizingKeepsTheViewportSizedAndClamped() {
        let (canvas, _) = canvas()
        canvas.setFrameSize(NSSize(width: 500, height: 350))
        #expect(canvas.viewport.size == Size(width: 500, height: 350))
        #expect(canvas.tiles.layer.bounds.size == CGSize(width: 500, height: 350))
        #expect(canvas.overlay.bounds.size == CGSize(width: 500, height: 350))
        canvas.viewDidChangeBackingProperties()
        #expect(canvas.acceptsFirstResponder)
        #expect(canvas.acceptsFirstMouse(for: nil))
    }

    @Test func pointerAndKeyEventsReachTheToolManager() async throws {
        let (canvas, manager) = canvas()
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = canvas
        defer { window.close() }
        manager.select(.rectangle)
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: y), modifierFlags: flags, timestamp: 1, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        canvas.mouseDown(with: mouse(.leftMouseDown, 10, 290))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, 60, 240))
        let flags = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
        canvas.flagsChanged(with: flags)
        canvas.mouseUp(with: mouse(.leftMouseUp, 60, 240, flags: .shift))
        await canvas.document.settle()
        let id = try #require(canvas.document.selectableIDs().first)
        let size = canvas.document.state.props(id.opID).rect.size
        #expect(canvas.document.selectableIDs().count == 1)
        #expect(abs(size.width - size.height) < 1e-9, "Shift made it square")

        canvas.keyDown(with: TestEvents.space)
        #expect(manager.activeToolID == .hand)
        canvas.keyUp(with: TestEvents.spaceUp)
        #expect(manager.activeToolID == .rectangle)
        canvas.keyDown(with: TestEvents.key("q", keyCode: 12))
        canvas.keyUp(with: TestEvents.key("q", keyCode: 12, up: true))
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -5, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)))
        let before = canvas.viewport
        canvas.scrollWheel(with: wheel)
        #expect(canvas.viewport != before)
        canvas.resetCursorRects()
        canvas.showStatusMessage("ignored without a listener")
        var messages: [String] = []
        canvas.onStatusMessage = { messages.append($0) }
        canvas.showStatusMessage("shown")
        #expect(messages == ["shown"])
        canvas.overlay.display()
    }
}

@Suite @MainActor struct DocumentControllerTests {
    @Test func opensNewDocumentsAsTabsAndForgetsClosedOnes() {
        let environment = TestEnvironment()
        let controller = DocumentController(environment: environment.document)
        var changes = 0
        controller.onChange = { changes += 1 }
        let first = controller.newDocument()
        let second = controller.newDocument()
        #expect(controller.documents.map(\.title) == ["Untitled", "Untitled 2"])
        #expect(first.window?.tabbedWindows?.contains(second.window!) == true, "the second document joined the first window's tabs")
        #expect(controller.activeWindowController === second)
        #expect(controller.document(id: first.documentHandle.id) === first.documentHandle)
        #expect(controller.open(first.documentHandle) === first, "opening an open document brings its window forward")
        #expect(controller.activeDocumentID == first.documentHandle.id)

        first.toolManager.select(.zoom)
        #expect(controller.lastToolID == .zoom)
        let third = controller.newDocument(show: false)
        #expect(third.toolManager.activeToolID == .zoom, "a new window starts with the last tool")
        #expect(controller.open(third.documentHandle, show: false) === third)

        second.windowDidBecomeMain(Notification(name: NSWindow.didBecomeMainNotification))
        #expect(controller.activeDocumentID == second.documentHandle.id)
        controller.saveAllStates()
        #expect(environment.windowStates.state(for: second.documentHandle.id) != nil)

        controller.close(second.documentHandle.id)
        controller.close("unknown")
        #expect(controller.documents.count == 2)
        first.close()
        #expect(controller.documents.map(\.title) == ["Untitled 3"])
        controller.close(third.documentHandle.id)
        #expect(controller.documents.isEmpty)
        #expect(controller.activeDocumentID == nil)
        #expect(changes > 5)
        environment.suite.remove()
    }

    @Test func viewCommandsActOnTheTargetWindow() {
        let environment = TestEnvironment()
        StandardCommands.register(into: environment.commands)
        let window = DocumentWindowController(document: .memory(title: "Commands"), environment: environment.document)
        defer { window.close() }
        let target = TargetBox()
        let created = CommandState()
        ViewCommands.install(into: environment.commands, target: { target.window }, newDocument: { created.count += 1 })
        let ids = StandardCommands.ID.self
        let registry = environment.commands
        #expect(registry.validate(ids.zoomIn) == .disabled(ViewCommands.noDocument))
        #expect(registry.validate(ids.fitSelection) == .disabled(ViewCommands.noDocument))
        #expect(registry.validate(ids.magnification(100)) == .disabled(ViewCommands.noDocument))
        #expect(registry.validate(ids.keyline) == .disabled(ViewCommands.noDocument))
        #expect(registry.validate(ids.fastMode) == .disabled(ViewCommands.noDocument))
        #expect(!registry.perform(ids.zoomIn))

        target.window = window
        #expect(registry.perform(ids.magnification(100)))
        #expect(window.viewport.zoom == 1)
        #expect(registry.validate(ids.magnification(100))?.isChecked == true)
        #expect(registry.validate(ids.magnification(200))?.isChecked == false)
        #expect(registry.perform(ids.zoomIn))
        #expect(window.viewport.zoom == 2)
        #expect(registry.perform(ids.zoomOut))
        #expect(registry.perform(ids.fitPage))
        let fitted = window.viewport.zoom
        #expect(registry.perform(ids.fitAll))
        #expect(window.viewport.zoom == fitted)
        #expect(registry.validate(ids.fitSelection) == .disabled(ViewCommands.nothingSelected))
        #expect(!registry.perform(ids.fitSelection))
        #expect(registry.perform(ids.keyline))
        #expect(registry.validate(ids.keyline)?.isChecked == true)
        #expect(registry.perform(ids.fastMode))
        #expect(registry.validate(ids.fastMode)?.isChecked == true)
        #expect(window.viewMode == .fastKeyline)
        #expect(registry.perform(ids.new))
        #expect(created.count == 1)
        // Placeholders were replaced in place: the View menu keeps its order.
        let view = registry.commands(inMenu: "View").map(\.id)
        #expect(Array(view.prefix(3)) == [ids.fitSelection, ids.fitPage, ids.fitAll])
        #expect(registry.command(ids.zoomIn)?.defaultKey == KeyEquivalent("=", .command))

        // Performing with no target is a no-op for the closure-based actions.
        target.window = nil
        for id in [ids.zoomIn, ids.zoomOut, ids.fitPage, ids.fitAll, ids.keyline, ids.fastMode, ids.magnification(50)] {
            if case let .perform(run)? = registry.command(id)?.action { run() }
        }
        if case let .perform(run)? = registry.command(ids.fitSelection)?.action { run() }
    }

    @Test func replaceRegistersUnknownCommandsAndNotifies() {
        let registry = CommandRegistry()
        var changes = 0
        registry.onChange = { changes += 1 }
        registry.replace(Command(id: "x.one", title: "One", action: .perform(Command.noop)))
        registry.replace(Command(id: "x.one", title: "Uno", action: .perform(Command.noop)))
        #expect(registry.command("x.one")?.title == "Uno")
        #expect(registry.ids == ["x.one"])
        #expect(changes == 2)
    }
}

@MainActor
final class TargetBox {
    var window: DocumentWindowController?
}

@Suite @MainActor struct DocumentContentTests {
    @Test func aMemoryDocumentDrawsItsChangesAndNotifies() async throws {
        let document = DocumentHandle.memory(title: "T")
        #expect(document.displayList.count == 1, "every page is in one group")
        var seen: [ContentChange] = []
        let token = document.observe { seen.append($0) }
        let ids = await document.addRectangles([Rect(x: 0, y: 0, width: 5, height: 5)])
        #expect(document.displayList.count == 2, "the pages group plus the rectangle")
        #expect(document.displayList.nodeIDs.last == ids.first?.node)
        #expect(seen.count == 1)
        #expect(seen[0].summary.touchedNodes.contains(try #require(ids.first).node))
        #expect(seen[0].summary.isStructural)
        #expect(seen[0].before.count == 1 && seen[0].after.count == 2)
        #expect(document.changeCount == 1)
        document.stopObserving(token)
        _ = await document.undo().value
        #expect(seen.count == 1)
        #expect(document.displayList.count == 1)
        #expect(document.allPagesBounds == Pasteboard.letterPage)
        #expect(document.currentPage == Pasteboard.letterPage)
        #expect(Pasteboard.side == 15_984)
        #expect(Pasteboard.letterPage.center.isApproximatelyEqual(to: Pasteboard.bounds.center))
    }

    @Test func geometryBridgesToCoreGraphics() {
        #expect(Point(CGPoint(x: 1, y: 2)).cgPoint == CGPoint(x: 1, y: 2))
        #expect(Rect(CGRect(x: 1, y: 2, width: 3, height: 4)).cgRect == CGRect(x: 1, y: 2, width: 3, height: 4))
        #expect(Size(CGSize(width: 3, height: 4)).cgSize == CGSize(width: 3, height: 4))
        #expect(Vector(CGSize(width: 3, height: 4)) == Vector(dx: 3, dy: 4))
        #expect(WTGeometry.AffineTransform.translation(x: 2, y: 3).cgAffineTransform == CGAffineTransform(translationX: 2, y: 3))
        #expect(Color.black.cgColor.components == [0, 0, 0, 1])
    }
}
