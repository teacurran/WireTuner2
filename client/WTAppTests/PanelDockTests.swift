import AppKit
import Foundation
import Testing
@testable import WireTuner

@Suite @MainActor struct PanelDockTests {
    private func makeDock(extraPanels: [PanelDescriptor] = []) -> (PanelRegistry, PanelLayoutController, PanelDockController) {
        let panels = PanelRegistry()
        PlaceholderPanels.register(into: panels)
        for descriptor in extraPanels { panels.registerIfAbsent(descriptor) }
        let layout = PanelLayoutController(registry: panels)
        layout.load()
        let dock = PanelDockController(panels: panels, layout: layout)
        dock.view.frame = NSRect(x: 0, y: 0, width: 280, height: 800)
        dock.view.layoutSubtreeIfNeeded()
        return (panels, layout, dock)
    }

    @Test func rendersGroupsTabsAndBodies() {
        let (_, layout, dock) = makeDock()
        #expect(dock.view.accessibilityIdentifier() == PanelDockController.accessibilityIdentifier)
        #expect(dock.groupViews.count == 2)
        #expect(dock.groupViews.map { $0.group.id } == ["properties", "layers"])
        #expect(dock.groupViews[0].titleLabel.stringValue == "Properties")
        #expect(dock.groupViews[0].tabButtons.map(\.panelID) == ["object"])
        #expect(dock.groupViews[0].tabButtons[0].state == .on)
        #expect(dock.groupViews[0].tabButtons[0].title == "Object")
        #expect(!dock.groupViews[0].isCollapsed)
        #expect(dock.groupViews[0].contentView.subviews.first?.accessibilityIdentifier() == "panel.object")
        #expect(dock.widthConstraint?.constant == 280)
        #expect(!dock.view.isHidden)

        let body = dock.body(for: "object")
        #expect(dock.body(for: "object") === body)
        #expect(dock.body(for: "unknown").subviews.isEmpty)

        layout.update { $0.setDockWidth(320, edge: .right) }
        #expect(dock.widthConstraint?.constant == 320)
        layout.update { $0.setDockHidden(true, edge: .right) }
        #expect(dock.view.isHidden)
        #expect(dock.widthConstraint?.constant == 0)
    }

    @Test func tabClicksAndDisclosureDriveTheLayout() {
        let (_, layout, dock) = makeDock()
        layout.update { $0.movePanel("layers", toGroup: "properties") }
        #expect(dock.groupViews.count == 1)
        #expect(dock.groupViews[0].tabButtons.map(\.panelID) == ["object", "layers"])
        #expect(dock.groupViews[0].tabButtons[1].state == .on)
        #expect(dock.groupViews[0].contentView.subviews.first?.accessibilityIdentifier() == "panel.layers")

        dock.groupViews[0].tabButtons[0].performClick(nil)
        #expect(layout.layout.group("properties")?.activePanel == "object")
        #expect(dock.groupViews[0].tabButtons[0].state == .on)
        #expect(dock.groupViews[0].contentView.subviews.first?.accessibilityIdentifier() == "panel.object")

        dock.groupViews[0].disclosure.performClick(nil)
        #expect(layout.layout.group("properties")?.collapsed == true)
        #expect(dock.groupViews[0].isCollapsed)
        #expect(dock.groupViews[0].disclosure.state == .off)
        dock.groupViews[0].disclosure.performClick(nil)
        #expect(!dock.groupViews[0].isCollapsed)
    }

    @Test func dropsRegroupAndSplit() {
        let document = PanelDescriptor(id: "document", title: "Document", defaultGroup: "Properties", menuOrder: 11) { NSView() }
        let (_, layout, dock) = makeDock(extraPanels: [document])
        #expect(layout.layout.group("properties")?.panels == ["object", "document"])

        dock.groupViews[1].onDrop?(.panel("document"), nil)
        #expect(layout.layout.group("layers")?.panels == ["layers", "document"])
        #expect(dock.groupViews.count == 2)

        dock.view.layoutSubtreeIfNeeded()
        dock.handleDrop(of: "document", atDockPoint: CGPoint(x: 10, y: 0))
        #expect(layout.layout.docks[.right]?.count == 3)
        #expect(layout.layout.docks[.right]?[2].panels == ["document"])

        dock.view.layoutSubtreeIfNeeded()
        dock.handleDrop(of: "layers", atDockPoint: CGPoint(x: 10, y: 799))
        #expect(layout.layout.docks[.right]?[0].panels == ["layers"])
        #expect(layout.layout.docks[.right]?.count == 3)

        #expect(PanelDockController.insertionIndex(forY: 500, groupFrames: [CGRect(x: 0, y: 700, width: 10, height: 100), CGRect(x: 0, y: 550, width: 10, height: 100), CGRect(x: 0, y: 400, width: 10, height: 100)]) == 2)
        #expect(PanelDockController.insertionIndex(forY: 900, groupFrames: [CGRect(x: 0, y: 700, width: 10, height: 100)]) == 0)
        #expect(PanelDockController.insertionIndex(forY: 0, groupFrames: []) == 0)
    }

    @Test func dropTargetsAcceptPanelPasteboards() {
        let document = PanelDescriptor(id: "document", title: "Document", defaultGroup: "Properties", menuOrder: 11) { NSView() }
        let (_, layout, dock) = makeDock(extraPanels: [document])
        let dockView = dock.view as! DockDropView
        let empty = DraggingInfoStub(pasteboardName: "empty", panel: nil, location: .zero)
        #expect(dockView.draggingEntered(empty) == [])
        #expect(!dockView.performDragOperation(empty))
        #expect(dock.groupViews[0].draggingEntered(empty) == [])
        #expect(!dock.groupViews[0].performDragOperation(empty))

        let drop = DraggingInfoStub(pasteboardName: "drop", panel: "document", location: CGPoint(x: 10, y: 0))
        #expect(dockView.draggingEntered(drop) == .move)
        #expect(dockView.performDragOperation(drop))
        #expect(layout.layout.docks[.right]?.count == 3)
        #expect(layout.layout.docks[.right]?[2].panels == ["document"])

        // On the Properties title bar (a drop on a docked body docks between groups instead).
        let header = DraggingInfoStub(pasteboardName: "header", panel: "document", location: CGPoint(x: 260, y: 800 - PanelDockController.inset - 10))
        #expect(dock.groupViews[0].draggingEntered(header) == .move)
        #expect(dock.groupViews[0].performDragOperation(header))
        header.release()
        #expect(layout.layout.group("properties")?.panels == ["object", "document"])
        #expect(layout.layout.docks[.right]?.count == 2)

        let orphan = DockDropView()
        #expect(!orphan.performDragOperation(drop))
        empty.release()
        drop.release()
        #expect(PanelID("x").rawValue == "x")
        Command.noop()
    }

    @Test func pasteboardCarriesPanelIDs() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("WireTunerTests.\(UUID().uuidString)"))
        #expect(PanelDockController.panelID(on: pasteboard) == nil)
        pasteboard.clearContents()
        pasteboard.setString("layers", forType: PanelDockController.pasteboardType)
        #expect(PanelDockController.panelID(on: pasteboard) == "layers")
        pasteboard.releaseGlobally()
    }

    @Test func groupViewsWorkWithoutADock() {
        let group = PanelGroup(id: "g", panels: ["a", "b"], activePanel: "b", collapsed: true, height: 120)
        let view = PanelGroupView(group: group, title: { $0.rawValue.uppercased() }, body: { _ in NSView() })
        #expect(view.titleLabel.stringValue == "A / B")
        #expect(view.isCollapsed)
        #expect(view.disclosure.state == .off)
        #expect(view.tabButtons.map(\.state) == [.off, .on])
        #expect(view.accessibilityIdentifier() == "panel-group.g")
        #expect(view.tabButtons[0].accessibilityIdentifier() == "panel-tab.a")
        view.selectTab(view.tabButtons[0])
        view.toggleCollapse(nil)
        view.tabButtons[0].onDrag?(view.tabButtons[0], NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)

        let empty = PanelGroupView(group: PanelGroup(id: "e", panels: []), title: { $0.rawValue }, body: { _ in NSView() })
        #expect(empty.tabButtons.isEmpty)
        #expect(empty.contentView.subviews.isEmpty)
    }

    @Test func documentWindowHostsCanvasAndDock() {
        let environment = TestEnvironment()
        let controller = DocumentWindowController(document: .memory(title: "Dock"), environment: environment.document)
        let window = controller.window!
        #expect(window.title == "Dock")
        #expect(window.identifier == DocumentWindowController.windowIdentifier)
        #expect(window.accessibilityIdentifier() == "main-window")
        let content = window.contentView!
        content.layoutSubtreeIfNeeded()
        #expect(content.subviews.contains { $0 === controller.rulerHost })
        #expect(controller.rulerHost.subviews.contains { $0.accessibilityIdentifier() == CanvasView.accessibilityIdentifier })
        #expect(content.subviews.contains { $0 === controller.dock.view })
        #expect(controller.dock.view.frame.width == 280)
        #expect(controller.dock.view.frame.maxX == content.bounds.maxX)
        window.close()
    }

    @Test func appDelegateWiresRegistriesMenusAndWindow() {
        // The hosted test process has no NSApp.delegate (XCTest's host injection), so launch a
        // fresh delegate with in-memory stores and check the wiring on it.
        let suite = TestDefaults()
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = delegate.activeDocumentWindow
        #expect(window?.window?.identifier == DocumentWindowController.windowIdentifier)
        #expect(window?.dock.groupViews.map(\.group.id) == ["properties", "assets", "mixer-and-tints", "layers", "help"])
        #expect(window?.leftDock.groupViews.map(\.group.id) == ["tools"])
        #expect(delegate.commands.contains(PanelCommands.ID.show("layers")))
        #expect(delegate.commands.contains(PanelCommands.ID.show("tools")))
        #expect(delegate.commands.contains(PanelCommands.ID.resetLayout))
        #expect(delegate.commands.validate(StandardCommands.ID.checkForUpdates)?.isEnabled == false)
        #expect(delegate.commands.validate(StandardCommands.ID.zoomIn)?.isEnabled == true)
        #expect(delegate.commands.validate(StandardCommands.ID.settings)?.isEnabled == true)
        #expect(delegate.shortcuts.keyEquivalent(for: StandardCommands.ID.quit) == KeyEquivalent("q", .command))
        #expect(delegate.shortcuts.keyEquivalent(for: ToolRegistry.commandID(for: .rectangle)) == KeyEquivalent("r"))
        #expect(delegate.menuTarget?.registry === delegate.commands)
        let windowMenu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu
        #expect(windowMenu?.item(withTitle: "Layers")?.identifier?.rawValue == "menu.panel.show.layers")

        // A panel registered later lands in the layout, the dock and the Window menu.
        delegate.panels.registerIfAbsent(PanelDescriptor(id: "extra", title: "Extra", defaultGroup: "Extras") { NSView() })
        #expect(delegate.layout.layout.group("extras")?.panels == ["extra"])
        #expect(window?.dock.groupViews.count == 6)
        #expect(NSApp.mainMenu?.item(withTitle: "Window")?.submenu?.item(withTitle: "Extra") != nil)

        // Tool shortcuts reach the key window's tool manager through the registry.
        #expect(delegate.menuTarget?.perform(ToolRegistry.commandID(for: .hand)) == true)
        #expect(window?.toolManager.activeToolID == .hand)
        #expect(delegate.toolPalette.activeToolID == .hand)
        delegate.toolPalette.select(.rectangle)
        #expect(window?.toolManager.activeToolID == .rectangle)

        // File > New opens a second document; Settings opens the Preferences window once.
        #expect(delegate.menuTarget?.perform(StandardCommands.ID.new) == true)
        #expect(delegate.documents.documents.count == 2)
        #expect(delegate.menuTarget?.perform(StandardCommands.ID.settings) == true)
        let preferences = delegate.preferencesWindowController
        #expect(preferences?.window?.isVisible == true)
        delegate.showPreferences()
        #expect(delegate.preferencesWindowController === preferences)
        preferences?.model.onRestoreAll()
        preferences?.close()

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        for id in delegate.documents.documents.map(\.id) { delegate.documents.close(id) }
        #expect(delegate.documents.documents.isEmpty)
        suite.remove()

        #expect(AppDelegate().layout.store?.url == PanelLayoutStore.defaultURL)
    }
}

/// The parts of `NSDraggingInfo` the dock's drop targets read: the pasteboard and the location.
/// Not main-actor bound because `NSDraggingInfo` is a nonisolated protocol.
final class DraggingInfoStub: NSObject, NSDraggingInfo, @unchecked Sendable {
    let pasteboard: NSPasteboard
    let location: NSPoint

    init(pasteboardName: String, panel: PanelID?, location: NSPoint) {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("WireTunerTests.\(pasteboardName).\(UUID().uuidString)"))
        pasteboard.clearContents()
        if let panel { pasteboard.setString(panel.rawValue, forType: PanelDockController.pasteboardType) }
        self.location = location
        super.init()
    }

    func release() { pasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var numberOfValidItemsForDrop: Int = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
