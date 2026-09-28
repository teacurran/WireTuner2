import AppKit
import Foundation
import SwiftUI
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

/// BASIC-012: the zoom commands and the Zoom tool land where the page says, and none of them
/// writes a change.
@Suite(.serialized) @MainActor struct ZoomCommandTests {
    private func window(_ environment: TestEnvironment) -> DocumentWindowController {
        let controller = DocumentWindowController(document: .memory(title: "Zoom"), environment: environment.document)
        ViewCommands.install(into: environment.commands, target: { [weak controller] in controller }, newDocument: {})
        return controller
    }

    @Test(arguments: [1.0, 32.0])
    func everyCommandLandsOnItsMagnificationAboutTheCentre(start: Double) {
        let environment = TestEnvironment()
        StandardCommands.register(into: environment.commands)
        let controller = window(environment)
        defer { controller.close() }
        let registry = environment.commands
        let ids = StandardCommands.ID.self
        let changes = controller.documentHandle.changeCount
        func reset() { controller.zoom(toPercent: start * 100) }
        reset()
        // The centre of the part the dock leaves visible (D-077).
        let centre = controller.canvas.visibleCenter
        func expectCentred(_ label: String) {
            #expect(controller.viewport.toView(centre).isApproximatelyEqual(to: controller.canvas.navigation.safeCenter(controller.viewport), tolerance: 1e-6), "\(label) keeps the window centre")
        }
        #expect(registry.perform(ids.zoomIn))
        #expect(controller.viewport.zoom == ZoomLadder.zoomIn(from: start))
        expectCentred("Zoom In")
        reset()
        #expect(registry.perform(ids.zoomOut))
        #expect(controller.viewport.zoom == ZoomLadder.zoomOut(from: start))
        expectCentred("Zoom Out")
        for percent in ContextMenuCatalog.contextMagnifications {
            reset()
            #expect(registry.perform(ids.magnification(percent)))
            #expect(abs(controller.viewport.zoom * 100 - Double(percent)) < 1e-9)
            #expect(registry.validate(ids.magnification(percent))?.isChecked == true)
        }
        #expect(registry.perform(ids.fitPage))
        let page = controller.documentHandle.currentPage!
        #expect(controller.viewport.toView(page.center).isApproximatelyEqual(to: controller.canvas.navigation.safeCenter(controller.viewport), tolerance: 1e-6))
        #expect(registry.perform(ids.fitAll))
        #expect(controller.documentHandle.changeCount == changes, "no change reaches the outbox")
    }

    @Test func theZoomToolHonoursEveryModifier() {
        let navigation = CanvasNavigation()
        let size = Size(width: 400, height: 300)
        let viewport = navigation.clamped(Viewport(scrollOrigin: Point(x: 7000, y: 7000), zoom: 1, size: size))
        func event(_ viewPoint: Point, _ modifiers: KeyModifiers = []) -> CanvasEvent {
            CanvasEvent(pasteboardPoint: viewport.toPasteboard(viewPoint), viewPoint: viewPoint, modifiers: modifiers)
        }
        let click = Point(x: 100, y: 100)
        let clicked = viewport.toPasteboard(click)
        // Click: one step in about the click.
        var result = ZoomTool.target(viewport: viewport, start: event(click), end: event(click))
        #expect(result.zoom == 2 && result.toView(clicked).isApproximatelyEqual(to: click, tolerance: 1e-6))
        // Option-click: one step out.
        result = ZoomTool.target(viewport: viewport, start: event(click), end: event(click, .option))
        #expect(result.zoom == 0.5)
        // Control-click and Control+Option-click: the limits.
        #expect(ZoomTool.target(viewport: viewport, start: event(click), end: event(click, .control)).zoom == 256)
        #expect(ZoomTool.target(viewport: viewport, start: event(click), end: event(click, [.control, .option])).zoom == 0.06)
        // Drag: the area fills the window.
        let far = Point(x: 200, y: 175)
        result = ZoomTool.target(viewport: viewport, start: event(click), end: event(far))
        let area = Rect(clicked, viewport.toPasteboard(far))
        #expect(result.zoom > 1)
        #expect(result.toView(area.center).isApproximatelyEqual(to: result.viewCenter, tolerance: 1e-6))
        // Option-drag: the window's current view fits the dragged rectangle.
        result = ZoomTool.target(viewport: viewport, start: event(click), end: event(far, .option))
        #expect(abs(result.zoom - 0.25) < 1e-9, "a quarter-size rectangle shows the view at a quarter")
        let centre = viewport.toPasteboard(viewport.viewCenter)
        #expect(result.toView(centre).isApproximatelyEqual(to: Rect(click, far).center, tolerance: 1e-6))
        #expect(ZoomTool.shrink(viewport, into: Rect(x: 0, y: 0, width: 0, height: 10)) == viewport)
        // Shift-drag defines a named view; Shift-click and Option-Shift-drag do not.
        #expect(ZoomTool.definesNamedView(start: event(click), end: event(far, .shift)))
        #expect(!ZoomTool.definesNamedView(start: event(click), end: event(click, .shift)))
        #expect(!ZoomTool.definesNamedView(start: event(click), end: event(far, [.shift, .option])))
    }

    @Test func aShiftDragOpensTheNewViewSheet() throws {
        let host = RecordingHost(viewport: CanvasNavigation().clamped(Viewport(scrollOrigin: Point(x: 7000, y: 7000), size: Size(width: 400, height: 300))))
        let tool = ZoomTool()
        let document = DocumentHandle.memory(title: "Zoom")
        tool.activate(in: ToolContext(document: document, host: host))
        tool.mouseDown(TestEvents.point(10, 10))
        tool.mouseDragged(TestEvents.point(110, 85))
        tool.flagsChanged(TestEvents.point(110, 85, .shift))
        tool.mouseUp(TestEvents.point(110, 85, .shift))
        #expect(host.namedViewRequests.count == 1)
        #expect(host.namedViewRequests.first == host.viewport)
        #expect(document.changeCount == 0)

        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let sheet = try #require(controller.presentNamedViewSheet(target: controller.viewport))
        #expect(sheet.identifier == NamedViewSheet.identifier)
        #expect(controller.presentNamedViewSheet(target: controller.viewport) == nil, "one sheet at a time")
        controller.endNamedViewSheet()
        #expect(controller.namedViewSheet == nil)
        controller.endNamedViewSheet()
        controller.canvas.requestNamedView(controller.viewport)
        #expect(controller.namedViewSheet != nil)
        controller.endNamedViewSheet()
        #expect(environment.commands.perform(StandardCommands.ID.customNew))
        #expect(controller.namedViewSheet != nil)
        controller.endNamedViewSheet()
        #expect(environment.commands.validate(StandardCommands.ID.customEdit) == .disabled(ViewCommands.namedViewsPending))
        #expect(NamedViewSheet.summary(of: Viewport(zoom: 4, size: Size(width: 1, height: 1))) == "View at 400%")
        let view = NSHostingView(rootView: NamedViewSheetView(summary: "View at 100%") { _ in })
        #expect(view.fittingSize.width > 0)
    }

    @Test func dragsAtTheEdgeScrollTheView() {
        let environment = TestEnvironment()
        let canvas = CanvasView(document: .memory(title: "Scroll"), frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let manager = ToolManager(registry: environment.tools, context: ToolContext(document: canvas.document, host: canvas))
        canvas.toolManager = manager
        canvas.setViewport(Viewport(scrollOrigin: Point(x: 7000, y: 7000), zoom: 1, size: Size(width: 400, height: 300)))
        #expect(!canvas.autoscrollStep(), "no drag in progress")
        let before = canvas.viewport
        let edge = CanvasEvent(pasteboardPoint: .zero, viewPoint: Point(x: 398, y: 150))
        canvas.autoscrolls = { false }
        canvas.mouseDragged(with: NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: 398, y: 150), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!)
        #expect(canvas.autoscrollEvent == nil)
        canvas.autoscrolls = { true }
        canvas.mouseDragged(with: NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: 398, y: 150), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!)
        #expect(canvas.autoscrollEvent != nil)
        #expect(canvas.autoscrollStep())
        #expect(canvas.viewport.scrollOrigin.x > before.scrollOrigin.x)
        #expect(canvas.autoscrollEvent?.viewPoint == edge.viewPoint)
        canvas.stopAutoscroll()
        #expect(canvas.autoscrollEvent == nil)
    }
}

/// BASIC-013: the drawing-mode toggles and the Redraw preferences.
@Suite(.serialized) @MainActor struct DrawingModeTests {
    @Test func keylineFromFastKeylineYieldsFastPreviewAndCheckMarksFollow() {
        let environment = TestEnvironment()
        let controller = DocumentWindowController(document: .memory(title: "Modes"), environment: environment.document)
        defer { controller.close() }
        ViewCommands.install(into: environment.commands, target: { [weak controller] in controller }, newDocument: {})
        let registry = environment.commands
        let ids = StandardCommands.ID.self
        for mode in ViewMode.allCases {
            controller.setViewMode(mode)
            #expect(registry.validate(ids.keyline)?.isChecked == mode.isKeyline)
            #expect(registry.validate(ids.fastMode)?.isChecked == mode.isFast)
            #expect(controller.statusBar.viewMode.titleOfSelectedItem == mode.title)
        }
        controller.setViewMode(.fastKeyline)
        #expect(registry.perform(ids.keyline))
        #expect(controller.viewMode == .fastPreview)
        // The status bar pop-up drives the same state.
        controller.statusBar.viewMode.selectItem(at: 2)
        controller.statusBar.viewModeChosen(controller.statusBar.viewMode)
        #expect(controller.viewMode == .keyline)
    }

    @Test func dragPreviewFollowsThePreferences() {
        var settings = RedrawSettings()
        settings.previewDrag = 3
        #expect(settings.dragPreview(count: 3, optionHeld: false, optionDragCopies: true) == .full)
        #expect(settings.dragPreview(count: 4, optionHeld: false, optionDragCopies: true) == .outlines)
        #expect(settings.dragPreview(count: 4, optionHeld: true, optionDragCopies: true) == .outlines, "Option-drag copies instead")
        #expect(settings.dragPreview(count: 400, optionHeld: true, optionDragCopies: false) == .full)
        #expect(settings.greeks(pixelHeight: 5, selected: false))
        #expect(!settings.greeks(pixelHeight: 5, selected: true))
        #expect(!settings.greeks(pixelHeight: 9, selected: false))
    }

    @Test func redrawSettingsReadTheStoreAndReachTheTools() {
        let environment = TestEnvironment()
        let keys = PreferenceCatalog.Redraw.self
        environment.preferences.set(10, for: keys.previewDrag)
        environment.preferences.set(false, for: keys.textEffects)
        environment.preferences.set(12, for: keys.greekBelow)
        environment.preferences.set("gray", for: keys.imageDisplay)
        environment.preferences.set("draft", for: keys.rasterEffectPreview)
        let settings = RedrawSettings(preferences: environment.preferences)
        #expect(settings.previewDrag == 10 && !settings.displaysTextEffects && settings.greekBelowPixels == 12)
        #expect(settings.imageDisplay == .gray && settings.rasterEffectPreview == "draft")
        #expect(RedrawSettings.isRedrawPreference(keys.previewDrag.id))
        #expect(!RedrawSettings.isRedrawPreference(PreferenceCatalog.General.pickDistance.id))
        let controller = DocumentWindowController(document: .memory(title: "Redraw"), environment: environment.document)
        defer { controller.close() }
        #expect(controller.redraw == settings)
        #expect(controller.toolManager.context.redraw() == settings)
        environment.preferences.set(false, for: PreferenceCatalog.Object.optionDragCopies)
        #expect(!controller.toolManager.context.optionDragCopies())
        #expect(ToolContext(document: controller.documentHandle, host: RecordingHost()).redraw() == RedrawSettings())
    }
}

/// BASIC-016: several views of one document, and the primary view's state.
@Suite(.serialized) @MainActor struct MultipleViewTests {
    @Test func eightViewsOpenTheNinthBeepsAndEditsReachEveryView() async throws {
        let environment = TestEnvironment()
        let documents = DocumentController(environment: environment.document)
        let beeps = SnapSoundTests.Speaker()
        documents.beep = { beeps.played.append("beep") }
        let first = documents.open(.memory(id: "multi", title: "Multi"), show: false)
        ViewCommands.install(into: environment.commands, target: { documents.activeWindowController }, hooks: ViewCommands.Hooks(documents: documents))
        first.setViewMode(.keyline)
        for _ in 1..<DocumentController.maximumViews {
            #expect(documents.newView(of: first, show: false) != nil)
        }
        let views = documents.views(of: "multi")
        #expect(views.count == 8)
        #expect(views[1].viewMode == .keyline, "a new view starts as a copy of its source")
        #expect(views.filter(\.isPrimaryView).count == 1 && views[0] === first)
        #expect(documents.newView(of: first, show: false) == nil)
        #expect(beeps.played.count == 1)
        #expect(environment.commands.validate(StandardCommands.ID.newWindow) == .disabled(DocumentController.tooManyViews))
        #expect(documents.allWindowControllers.count == 8)
        #expect(documents.documents.count == 1)

        // An edit in one view appears in all of them.
        await first.documentHandle.addRectangles([Rect(x: 7000, y: 7000, width: 10, height: 10)])
        for view in views { #expect(view.canvas.tiles.displayList == first.documentHandle.displayList) }

        // Closing the primary view promotes the next one.
        first.close()
        #expect(documents.views(of: "multi").count == 7)
        #expect(documents.views(of: "multi").first?.isPrimaryView == true)
        #expect(documents.windowControllers["multi"] === views[1])
        // Option-click on a close button closes every view.
        views[3].closesAllViews = { true }
        #expect(views[3].windowShouldClose(views[3].window!) == false)
        #expect(documents.views(of: "multi").isEmpty)
        #expect(documents.documents.isEmpty)
        #expect(documents.newView() == nil, "no window to copy")
        #expect(views[3].windowShouldClose(views[3].window!) == false, "Option held: the close is handled by closing every view")
    }

    @Test func newWindowCommandOpensAnotherView() {
        let environment = TestEnvironment()
        let documents = DocumentController(environment: environment.document)
        let first = documents.open(.memory(id: "cmd", title: "Cmd"), show: false)
        defer { documents.close("cmd") }
        ViewCommands.install(into: environment.commands, target: { first }, hooks: ViewCommands.Hooks(documents: documents))
        #expect(environment.commands.validate(StandardCommands.ID.newWindow)?.isEnabled == true)
        #expect(environment.commands.perform(StandardCommands.ID.newWindow))
        #expect(documents.views(of: "cmd").count == 2)
        #expect(!documents.views(of: "cmd")[1].isPrimaryView)
        let single = DocumentWindowController(document: .memory(title: "Lone"), environment: environment.document)
        defer { single.close() }
        #expect(single.windowShouldClose(single.window!), "a plain close closes one view")
    }

    @Test func onlyThePrimaryViewPersistsAndReopeningRestoresTheView() async throws {
        let environment = TestEnvironment()
        let id = UUID().uuidString
        let documents = DocumentController(environment: environment.document)
        let document = DocumentHandle.memory(id: id, title: "Persist")
        await document.addPage().value
        let primary = documents.open(document, show: false)
        primary.goToPage(1)
        primary.setViewMode(.fastPreview)
        primary.zoom(toPercent: 300)
        primary.togglePageRulers()
        let secondary = try #require(documents.newView(of: primary, show: false))
        secondary.zoom(toPercent: 50)
        secondary.saveState()
        #expect(environment.windowStates.state(for: id) == nil, "an additional view's state is not saved")
        primary.saveState()
        let saved = try #require(environment.windowStates.state(for: id))
        #expect(saved.zoom == 3 && saved.viewMode == .fastPreview && saved.pageRulers == false)
        documents.close(id)

        // Reopened with the preference on: zoom, scroll, mode and current page come back.
        let reopenedDocument = DocumentHandle.memory(id: id, title: "Persist")
        await reopenedDocument.addPage().value
        let reopened = DocumentWindowController(document: reopenedDocument, environment: environment.document)
        #expect(reopened.viewport.zoom == 3 && reopened.viewMode == .fastPreview)
        #expect(reopened.documentHandle.currentPageIndex == 1)
        #expect(!reopened.pageRulersVisible)
        reopened.close()

        // The saved page was deleted meanwhile: the nearest remaining page.
        let shrunk = DocumentHandle.memory(id: id, title: "Persist")
        let fallback = DocumentWindowController(document: shrunk, environment: environment.document)
        #expect(fallback.documentHandle.currentPageIndex == 0)
        fallback.close()

        // With the preference off: Fit to Page on page 1.
        environment.preferences.set(false, for: PreferenceCatalog.Document.restoreView)
        let fresh = DocumentHandle.memory(id: id, title: "Persist")
        await fresh.addPage().value
        fresh.selectPage(1)
        let unrestored = DocumentWindowController(document: fresh, environment: environment.document)
        defer { unrestored.close() }
        #expect(unrestored.documentHandle.currentPageIndex == 0)
        #expect(unrestored.viewport.toView(fresh.pages[0].center).isApproximatelyEqual(to: unrestored.canvas.navigation.safeCenter(unrestored.viewport), tolerance: 1e-6))
    }

    @Test func theNearestPageIsChosenByDistance() {
        let pages = [Rect(x: 0, y: 0, width: 100, height: 100), Rect(x: 500, y: 0, width: 100, height: 100)]
        var state = DocumentWindowState()
        #expect(state.currentPageIndex(among: pages) == nil)
        state.currentPageFrame = LayoutRect(x: 380, y: 0, width: 100, height: 100)
        #expect(state.currentPageIndex(among: pages) == 1)
        #expect(state.currentPageIndex(among: []) == nil)
    }

    @Test func aSessionWithTwoViewsOfADocumentReopensBoth() {
        let environment = TestEnvironment()
        let documents = DocumentController(environment: environment.document)
        let states = [
            WindowState(documentID: "s", title: "S", frame: nil, tabGroup: 0, tabIndex: 0, key: false),
            WindowState(documentID: "s", title: "S", frame: nil, tabGroup: 0, tabIndex: 1, key: true),
        ]
        let opened = documents.restore(states) { _ in true }
        defer { documents.close("s") }
        #expect(opened.count == 2)
        #expect(documents.views(of: "s").count == 2)
        #expect(documents.sessionState().count == 2)
    }
}

/// BASIC-017: Preview in Browser is disabled until the exporter lands; with one it exports
/// locally and cleans up at quit.
@Suite(.serialized) @MainActor struct BrowserPreviewTests {
    final class StubExporter: BrowserPreviewExporter {
        private(set) var exported: [(String, Int)] = []
        func exportPreview(of document: DocumentHandle, pageIndex: Int, into directory: URL) throws -> URL {
            exported.append((document.id, pageIndex))
            let file = directory.appending(path: "index.html")
            try Data("<html></html>".utf8).write(to: file)
            return file
        }
    }

    @MainActor
    final class OpenRecorder {
        var opened: [(URL, URL?)] = []
    }

    @Test func disabledWithAReasonUntilTheExporterExists() throws {
        let environment = TestEnvironment()
        let controller = DocumentWindowController(document: .memory(title: "Web"), environment: environment.document)
        defer { controller.close() }
        ViewCommands.install(into: environment.commands, target: { [weak controller] in controller }, newDocument: {})
        let id = StandardCommands.ID.previewInBrowser
        #expect(environment.commands.validate(id) == .disabled(BrowserPreview.unavailableReason))
        #expect(environment.commands.command(id)?.defaultKey == KeyEquivalent("return", .command))
        let preview = BrowserPreview(root: TestEnvironment.temporaryDirectory())
        #expect(preview.validation(hasDocument: true) == .disabled(BrowserPreview.unavailableReason))
        #expect(try preview.preview(controller.documentHandle, pageIndex: 0) == nil)
    }

    @Test func exportsIntoTheTemporaryFolderOpensAndCleansUp() throws {
        let environment = TestEnvironment()
        let controller = DocumentWindowController(document: .memory(id: "web", title: "Web"), environment: environment.document)
        defer { controller.close() }
        let exporter = StubExporter()
        let root = TestEnvironment.temporaryDirectory()
        let preview = BrowserPreview(exporter: exporter, root: root)
        let recorder = OpenRecorder()
        preview.open = { recorder.opened.append(($0, $1)) }
        let browser = URL(filePath: "/Applications/Safari.app")
        ViewCommands.install(
            into: environment.commands, target: { [weak controller] in controller },
            hooks: ViewCommands.Hooks(browserPreview: preview, previewBrowser: { browser })
        )
        #expect(preview.validation(hasDocument: false) == .disabled(ViewCommands.noDocument))
        #expect(environment.commands.validate(StandardCommands.ID.previewInBrowser) == .enabled)
        #expect(environment.commands.perform(StandardCommands.ID.previewInBrowser))
        #expect(exporter.exported.first?.0 == "web")
        let opened = recorder.opened
        #expect(opened.first?.0.path.hasPrefix(root.appending(path: "web").path) == true)
        #expect(opened.first?.1 == browser)
        #expect(FileManager.default.fileExists(atPath: opened[0].0.path))
        preview.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(BrowserPreview.defaultRoot.lastPathComponent == "Preview")
    }
}

/// View > Page Rulers > Show, Lock and Unlock, Add Page and the tab commands.
@Suite(.serialized) @MainActor struct ViewMenuCommandTests {
    @Test func rulersLockAndPageCommands() async {
        let environment = TestEnvironment()
        let controller = DocumentWindowController(document: .memory(title: "Menu"), environment: environment.document)
        defer { controller.close() }
        ViewCommands.install(into: environment.commands, target: { [weak controller] in controller }, newDocument: {})
        let registry = environment.commands
        #expect(registry.validate(StandardCommands.ID.pageRulers)?.isChecked == true)
        #expect(registry.perform(StandardCommands.ID.pageRulers))
        #expect(!controller.pageRulersVisible && registry.validate(StandardCommands.ID.pageRulers)?.isChecked == false)
        #expect(registry.validate(ContextMenuCatalog.ID.lock) == .disabled(ViewCommands.nothingSelected))
        controller.selection.model.set(Selection([SelectionID(NodeID(counter: 999, replica: 1))]))
        #expect(registry.validate(ContextMenuCatalog.ID.unlock) == .disabled(ViewCommands.lockPending))
        let pages = controller.documentHandle.pages.count
        #expect(registry.perform(ContextMenuCatalog.ID.addPage))
        await controller.documentHandle.settle()
        #expect(controller.documentHandle.pages.count == pages + 1)
        #expect(registry.perform(ContextMenuCatalog.ID.closeOtherTabs))

        ViewCommands.install(into: registry, target: { nil }, newDocument: {})
        for id in [StandardCommands.ID.pageRulers, StandardCommands.ID.rotateReset, ContextMenuCatalog.ID.lock, StandardCommands.ID.keyline] {
            #expect(registry.validate(id) == .disabled(ViewCommands.noDocument))
        }
        #expect(!registry.perform(StandardCommands.ID.previewInBrowser))
        #expect(Command.placeholder(id: "x", title: "X").disabled("why").validation() == .disabled("why"))
    }

    @Test func closeOtherTabsClosesTheOtherTabsOfTheWindow() {
        let environment = TestEnvironment()
        let documents = DocumentController(environment: environment.document)
        let a = documents.open(.memory(id: "tab-a", title: "A"))
        let b = documents.open(.memory(id: "tab-b", title: "B"))
        let c = documents.open(.memory(id: "tab-c", title: "C"))
        defer { for id in ["tab-a", "tab-b", "tab-c"] { documents.close(id) } }
        #expect(b.window?.tabbedWindows?.count == 3)
        b.closeOtherTabs()
        #expect(documents.documents.map(\.id) == ["tab-b"])
        #expect(a.window?.isVisible == false && c.window?.isVisible == false)
    }
}
