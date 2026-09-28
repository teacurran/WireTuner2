import AppKit
import SwiftUI
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

/// Mouse events for a window, for AppKit tracking loops fed from the event queue.
@MainActor
private func mouse(_ type: NSEvent.EventType, x: CGFloat, in window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(
        with: type, location: NSPoint(x: x, y: 5), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1
    )!
}

@Suite(.serialized) @MainActor struct AppWiringTests {
    @Test func helpPreferencesAndThePalettesHooksReachTheFrontWindow() async {
        let suite = TestDefaults()
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = delegate.activeDocumentWindow!

        // Help for <panel>, from a docked group and from a floating one.
        let object = delegate.panels.descriptor(for: "object")!
        window.panelInteraction.onHelp(object)
        #expect(delegate.helpModel.slug == "object-panel" && delegate.helpModel.topic == "Object")
        #expect(delegate.layout.isVisible("help"))
        delegate.floatingPanels.interaction.onHelp(delegate.panels.descriptor(for: "layers")!)
        #expect(delegate.helpModel.topic == "Layers")
        let help = NSHostingView(rootView: HelpPanelBody(model: delegate.helpModel))
        help.layoutSubtreeIfNeeded()
        #expect(help.fittingSize.width > 0)

        // A floating group attaches to the front window and follows the preferences.
        delegate.layout.update { $0.float(group: "layers", frame: LayoutRect(x: 100, y: 100, width: 260, height: 300)) }
        #expect(delegate.floatingPanels.windows["layers"]?.parent === window.window)
        #expect(delegate.floatingPanels.interaction.appearance() == .standard)
        delegate.preferences.set(false, for: PreferenceCatalog.Panels.showTooltips)
        #expect(!delegate.toolPalette.showsTooltips)
        delegate.preferences.set(true, for: PreferenceCatalog.General.smallerHandles)

        // The Tools panel's hooks: options, commands, flyout slots in the layout.
        delegate.toolPalette.showOptions(.pointer)
        #expect(window.window?.attachedSheet?.identifier?.rawValue == "tool-options.pointer")
        if let sheet = window.window?.attachedSheet { window.window?.endSheet(sheet) }
        let mode = window.viewMode
        delegate.toolPalette.perform(StandardCommands.ID.keyline)
        #expect(window.viewMode == mode.togglingKeyline && delegate.toolPalette.viewMode == window.viewMode)
        delegate.toolPalette.perform(ToolPanelCommands.snapCommandID(.grid))
        #expect(delegate.toolPalette.snap?.grid == true)
        delegate.toolPalette.choose("bezigon")
        #expect(delegate.layout.flyoutSlot("pen") == "bezigon" && window.toolManager.activeToolID == "bezigon")
        #expect(delegate.menuTarget?.perform(ToolRegistry.commandID(for: "bezigon")) == true)
        #expect(window.toolManager.activeToolID == "pen", "the visible member's key cycles the flyout")
        #expect(delegate.menuTarget?.perform(ToolPanelCommands.ID.swap) == true)

        // The selection's colours reach the wells.
        window.selection.model.set(Selection([SelectionID(NodeID(counter: 999, replica: 1))]))
        #expect(delegate.toolPalette.selectionWells == nil, "an id that names no object has no colours")
        let added = await window.documentHandle.addRectangles([Rect(x: 0, y: 0, width: 5, height: 5)])
        window.selection.model.set(Selection(added))
        #expect(delegate.toolPalette.selectionWells != nil)
        #expect(window.selectionWells == delegate.toolPalette.selectionWells)

        delegate.layout.update { $0.dock(group: "layers", at: .right) }
        for id in delegate.documents.documents.map(\.id) { delegate.documents.close(id) }
        suite.remove()
    }

    @Test func onlyTheFrontWindowsViewStateReachesThePanels() {
        let environment = TestEnvironment()
        let controller = DocumentController(environment: environment.document)
        var changes = 0
        controller.onChange = { changes += 1 }
        let back = controller.open(.memory(id: "back", title: "Back"), show: false)
        let front = controller.open(.memory(id: "front", title: "Front"), show: false)
        changes = 0
        front.toggleSnap(.point)
        #expect(changes == 1)
        back.toggleSnap(.point)
        back.setViewMode(.keyline)
        #expect(changes == 1)
        front.selection.model.set(Selection([SelectionID(NodeID(counter: 999, replica: 1))]))
        #expect(changes == 2)
        for id in ["back", "front"] { controller.close(id) }
    }

    @Test func windowHelpers() throws {
        #expect(DocumentWindowController.floatingFrame(near: nil) == LayoutRect(x: 200, y: 200, width: 260, height: 320))
        #expect(DocumentWindowController.floatingFrame(near: NSRect(x: 0, y: 0, width: 1000, height: 800)) == LayoutRect(x: 700, y: 380, width: 260, height: 320))
        let environment = TestEnvironment()
        try environment.windowStates.save(DocumentWindowState(zoom: 2), for: "old")
        let controller = DocumentWindowController(document: .memory(id: "old", title: "Old"), environment: environment.document)
        defer { controller.close() }
        #expect(controller.snap == SnapSettings(), "a state saved before the snap toggles restores the defaults")
        #expect(controller.panelInteraction.floatingFrame().width == 260)
        controller.goToPage(3)
        controller.showCurrentPage()
        #expect(controller.statusBar.pageField.stringValue == "1", "a document always has a page")
    }
}

@Suite(.serialized) @MainActor struct TrackingLoopTests {
    @Test func theDockHandleAndTabsReadTheirDragFromTheEventQueue() {
        let environment = TestEnvironment()
        let layout = environment.layout
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { window.close() }
        let handle = DockHandleView(edge: .right, layout: layout)
        window.contentView?.addSubview(handle)
        window.postEvent(mouse(.leftMouseDragged, x: 60, in: window), atStart: false)
        window.postEvent(mouse(.leftMouseUp, x: 60, in: window), atStart: false)
        handle.mouseDown(with: mouse(.leftMouseDown, x: 100, in: window))
        #expect(layout.layout.dockWidth[.right] == 320)
        window.postEvent(mouse(.leftMouseUp, x: 100, in: window), atStart: false)
        handle.mouseDown(with: mouse(.leftMouseDown, x: 100, in: window))
        #expect(layout.layout.hiddenDocks == [.right])
        DockHandleView(edge: .left, layout: layout).mouseDown(with: mouse(.leftMouseDown, x: 0, in: window))

        let tab = PanelTabButton(panelID: "object", title: "Object")
        window.contentView?.addSubview(tab)
        var clicks = 0, drags = 0
        final class Target: NSObject {
            var hit: () -> Void = {}
            @objc func act(_ sender: Any?) { hit() }
        }
        let target = Target()
        target.hit = { clicks += 1 }
        tab.target = target
        tab.action = #selector(Target.act(_:))
        tab.onDrag = { _, _ in drags += 1 }
        window.postEvent(mouse(.leftMouseUp, x: 5, in: window), atStart: false)
        tab.mouseDown(with: mouse(.leftMouseDown, x: 5, in: window))
        window.postEvent(mouse(.leftMouseDragged, x: 40, in: window), atStart: false)
        tab.mouseDown(with: mouse(.leftMouseDown, x: 5, in: window))
        #expect(clicks == 1 && drags == 1)
        PanelTabButton(panelID: "x", title: "X").mouseDown(with: mouse(.leftMouseDown, x: 0, in: window))
    }

    @Test func dragsAndTheOptionsMenuGoThroughTheirHooks() async {
        let registry = PanelRegistry()
        PanelCatalog.register(into: registry)
        let layout = PanelLayoutController(registry: registry)
        layout.load()
        let dock = PanelDockController(panels: registry, layout: layout)
        dock.view.layoutSubtreeIfNeeded()
        var sessions: [PanelDragPayload?] = []
        var menus: [String] = []
        dock.interaction.startDragSession = { _, _, _, source in sessions.append((source as? PanelInteraction)?.currentDrag) }
        dock.interaction.presentMenu = { menu, _ in menus.append(menu.title) }
        // A group's drag moves its cluster (D-077, magnetic panels) through the cluster drag hook.
        var clusterDrags: [PanelGroup.ID] = []
        dock.interaction.runClusterDrag = { drag in
            clusterDrags.append(drag.groupID)
            drag.cancel()
        }
        let group = dock.groupViews[0]
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        group.onDragTab?(group.tabButtons[0], event)
        let before = layout.layout
        group.onDragGroup?(event)
        #expect(clusterDrags == ["properties"] && layout.layout == before)
        // Without a mouse button down, the real loop cancels at once instead of waiting.
        dock.interaction.runClusterDrag = { PanelClusterDrag.track($0, buttonIsDown: { false }) }
        group.onDragGroup?(event)
        #expect(dock.interaction.clusterDrag?.wasCancelled == true && layout.layout == before)
        dock.beginDrag(of: "layers", from: group, event: event)
        #expect(sessions == [.panel("object"), .panel("layers")])
        group.showOptions(group.optionsButton)
        #expect(menus == ["Object"])
        group.closeGroup(nil)
        #expect(!layout.layout.contains("object"))

        for option in [PanelOption.custom(index: 0, title: "", isEnabled: true), .groupWith("g", title: ""), .newGroup, .rename, .float, .dock, .close, .collapse, .help(slug: "")] {
            #expect(PanelInteraction.identifier(of: option).isEmpty == false)
        }
        // New Panel Group from a floating group lands at the group's default edge.
        layout.showPanel("object")
        layout.update { $0.movePanel("layers", toGroup: "properties") }
        layout.update { $0.float(group: "properties", frame: LayoutRect(x: 0, y: 0, width: 10, height: 10)) }
        dock.interaction.perform(.newGroup, panel: "layers", groupView: nil)
        #expect(layout.layout.edge(of: layout.layout.group(containing: "layers")!.id) == .right)
        dock.interaction.perform(.custom(index: 0, title: "", isEnabled: true), panel: "ghost", groupView: nil)
        // A group listing a panel nobody registered still renders.
        let orphan = dock.interaction.makeGroupView(PanelGroup(id: "o", panels: ["ghost"]), floating: false) { _ in NSView() }
        #expect(orphan.tabButtons.count == 1)
        layout.update { $0.dockWidth[.right] = nil }
        #expect(dock.widthConstraint?.constant == PanelDockController.defaultWidth)
    }
}

@Suite @MainActor struct LibraryViewStateTests {
    private func render<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        host.layoutSubtreeIfNeeded()
        return host
    }

    @Test func everyStateRenders() async {
        let server = FakeLibraryServer()
        let me = server.accountID
        let hash = server.putBlob(TestPNG.data)
        server.put(LibraryDocument(id: "d1", spaceID: me, name: "Spring flyer", thumbnail: hash))
        server.put(LibraryDocument(id: "s1", spaceID: "x", name: "Shared", role: .viewer, isSharedWithMe: true))
        server.put(LibraryFolder(id: "f1", spaceID: me, parentID: nil, name: "Clients"))
        server.setPageSize(1)
        server.put(LibraryDocument(id: "d2", spaceID: me, name: "Second"))
        let model = LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil), debounce: .milliseconds(1))
        await model.refresh()
        #expect(model.nextCursor != nil)
        model.selection = ["d1"]
        _ = render(LibraryView(model: model))
        server.offline = true
        await model.refresh()
        model.open([LibraryDocument(id: "zz", spaceID: me, name: "Nowhere")])
        model.searchText = "Spring"
        #expect(model.errorMessage != nil && model.searchHint != nil)
        _ = render(LibraryView(model: model))
        server.offline = false
        await model.show(.sharedWithMe)
        _ = render(LibraryView(model: model))
        server.setHits([LibrarySearchHit(documentID: "d1", snippets: [SearchSnippet(field: .text, highlighted: "<b>Spring</b> Sale")])])
        await model.show(.folder(nil))
        model.searchText = "Spring"
        _ = await model.pendingSearch?.value
        _ = render(LibraryView(model: model))
        let pending = model.createDocument()
        _ = render(LibraryDocumentTile(model: model, row: LibraryRow(document: pending), renaming: .constant(nil)))
        _ = render(LibraryFolderTile(model: model, folder: LibraryFolder(id: "f1", spaceID: me, parentID: nil, name: "Clients")))
        _ = render(LibrarySidebar(model: model))
    }
}
