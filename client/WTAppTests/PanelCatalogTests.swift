import AppKit
import SwiftUI
import Testing
@testable import WireTuner

@MainActor
private func catalogRegistry(tools: Bool = true) -> PanelRegistry {
    let registry = PanelRegistry()
    PanelCatalog.register(into: registry)
    if tools { registry.registerIfAbsent(ToolsPanel.descriptor(model: ToolPaletteModel())) }
    return registry
}

@Suite @MainActor struct PanelCatalogTests {
    @Test func fifteenPanelsInTheDocumentedOrder() {
        let registry = catalogRegistry(tools: false)
        #expect(registry.ids == ["object", "document", "layers", "swatches", "styles", "library", "colorMixer", "tints", "align", "transform", "halftones", "navigation", "findReplace", "select", "help"])
        #expect(PanelCatalog.ids == registry.ids)
        #expect(registry.descriptors.map(\.title) == [
            "Object", "Document", "Layers", "Swatches", "Styles", "Library", "Color Mixer", "Tints", "Align", "Transform", "Halftones", "Navigation",
            "Find & Replace Graphics", "Select", "Help",
        ])
        for descriptor in registry.descriptors {
            #expect(descriptor.helpSlug?.isEmpty == false)
            #expect(NSImage(systemSymbolName: descriptor.icon, accessibilityDescription: nil) != nil, "\(descriptor.icon)")
            #expect(descriptor.optionsMenu().isEmpty)
            #expect(descriptor.makeView().accessibilityIdentifier() == "panel.\(descriptor.id.rawValue)")
        }
        // The Window menu lists every panel once, in that order.
        let layout = PanelLayoutController(registry: registry)
        let commands = CommandRegistry()
        StandardCommands.register(into: commands)
        PanelCommands.sync(into: commands, panels: registry, layout: layout)
        let tree = MenuTreeBuilder.build(registry: commands, shortcuts: .builtInDefault(commands: commands.commands))
        let window = tree.menus.first { $0.title == "Window" }
        let titles = window?.commandIDs.filter { $0.rawValue.hasPrefix("panel.show.") }.map { String($0.rawValue.dropFirst("panel.show.".count)) }
        #expect(titles == registry.ids.map(\.rawValue))
    }

    @Test func firstLaunchShowsTheDefaultGroupsInTheirState() {
        let registry = catalogRegistry()
        let layout = PanelLayoutController(registry: registry)
        layout.load()
        let right = layout.layout.docks[.right] ?? []
        #expect(right.map(\.id) == ["properties", "assets", "mixer-and-tints", "layers", "help"])
        #expect(right.map(\.collapsed) == [false, true, true, false, true])
        #expect(right.map(\.name) == ["Properties", "Assets", nil, nil, nil])
        #expect(right[2].displayName(titles: registry.title(for:)) == "Color Mixer / Tints")
        #expect(layout.layout.docks[.left]?.map(\.panels) == [["tools"]])
        #expect(layout.layout.closedPanels == ["align", "transform", "findReplace", "select", "navigation", "halftones"])
        #expect(!layout.isVisible("halftones") && layout.isVisible("layers") && layout.isVisible("object") && !layout.isVisible("swatches"))

        // Reloading keeps closed groups closed; a panel registered later appears.
        layout.load()
        #expect(!layout.layout.contains("halftones"))
        registry.registerIfAbsent(PanelDescriptor(id: "stub", title: "Stub", defaultGroup: "Stubs") { NSView() })
        layout.addRegisteredPanels()
        #expect(layout.layout.group("stubs")?.panels == ["stub"])

        // Showing a closed panel brings back its default group's closed members.
        layout.showPanel("transform")
        #expect(layout.layout.group("align-and-transform")?.panels == ["transform", "align"])
        #expect(layout.layout.group("align-and-transform")?.activePanel == "transform")
        #expect(!layout.layout.closedPanels.contains("align"))
        #expect(layout.isVisible("transform"))

        // A group docked at its default edge: Tools docks left.
        #expect(layout.defaultEdge(for: PanelGroup(panels: ["tools"])) == .left)
        #expect(layout.defaultEdge(for: PanelGroup(panels: ["unknown"])) == .right)
    }

    @Test func closingAFloatingGroupKeepsItClosedUntilShown() {
        let registry = catalogRegistry()
        let layout = PanelLayoutController(registry: registry)
        layout.load()
        layout.update { $0.float(group: "layers", frame: LayoutRect(x: 0, y: 0, width: 200, height: 200)) }
        layout.togglePanel("layers")
        #expect(!layout.layout.contains("layers") && layout.layout.closedPanels.contains("layers"))
        layout.addRegisteredPanels()
        #expect(!layout.layout.contains("layers"))
        layout.togglePanel("layers")
        #expect(layout.isVisible("layers"))
        layout.update { $0.close(group: "missing") }
    }

    @Test func standardLayoutsWithoutDefaultsKeepEveryGroupOpen() {
        let a = PanelDescriptor(id: "a", title: "A", defaultGroup: "G") { NSView() }
        let b = PanelDescriptor(id: "b", title: "B", defaultGroup: "H") { NSView() }
        let layout = PanelLayout.standard(for: [a, b])
        #expect(layout.docks[.right]?.map(\.name) == ["G", "H"])
        let ordered = PanelLayout.standard(for: [a, b], groups: ["H": PanelGroupDefaults(position: 0, edge: .top), "G": PanelGroupDefaults(position: 1)])
        #expect(ordered.docks[.top]?.map(\.id) == ["h"] && ordered.docks[.right]?.map(\.name) == [nil])
        var added = PanelLayout()
        added.add(panels: [a], groups: ["G": PanelGroupDefaults(position: 0, isOpen: false)])
        #expect(added.closedPanels == ["a"] && added.groups.isEmpty)
        added.reopen([a])
        #expect(added.group("g")?.panels == ["a"])
        added.reopen([a])
        #expect(PanelLayout.groupName("X", settings: nil) == "X")
        #expect(DockEdge.top.isVertical == false && DockEdge.left.isVertical)
        var merged = PanelLayout.standard(for: [a, b])
        merged.merge(group: "h", into: "g")
        #expect(merged.group("g")?.panels == ["a", "b"] && merged.group("g")?.activePanel == "b")
        merged.merge(group: "g", into: "g")
        merged.merge(group: "missing", into: "g")
        #expect(merged.edge(of: "g") == .right)
        merged.prune(keeping: ["a"])
        #expect(merged.panelIDs == ["a"])
    }
}

@Suite @MainActor struct PanelOptionsTests {
    private func setup() -> (PanelRegistry, PanelLayoutController, PanelDockController) {
        let registry = catalogRegistry()
        let layout = PanelLayoutController(registry: registry)
        layout.load()
        let dock = PanelDockController(panels: registry, layout: layout)
        dock.view.frame = NSRect(x: 0, y: 0, width: 280, height: 900)
        dock.view.layoutSubtreeIfNeeded()
        return (registry, layout, dock)
    }

    private func groupView(_ dock: PanelDockController, _ id: String) -> PanelGroupView {
        dock.groupViews.first { $0.group.id == id }!
    }

    @Test func theMenuTailIsTheSameForEveryPanel() {
        let (registry, layout, dock) = setup()
        let menu = PanelOption.menu(for: "swatches", layout: layout.layout, registry: registry)
        #expect(menu.custom.isEmpty)
        #expect(menu.groupWith.contains(.groupWith("layers", title: "Layers")))
        #expect(menu.groupWith.last == .newGroup)
        #expect(!menu.groupWith.contains { if case let .groupWith(id, _) = $0 { return id == "assets" } else { return false } })
        #expect(menu.tail == [.rename, .float, .collapse, .help(slug: "swatches")])
        #expect(PanelOption.menu(for: "halftones", layout: layout.layout, registry: registry).tail.isEmpty)
        #expect(PanelOption.groupWithTitle("Swatches") == "Group Swatches With")
        #expect(PanelOption.helpTitle("Swatches") == "Help for Swatches")
        #expect([PanelOption.newGroup, .rename, .float, .dock, .close, .collapse, .help(slug: "x"), .custom(index: 0, title: "New Swatch", isEnabled: true)].map(\.title) == [
            "New Panel Group", "Rename Panel Group…", "Float Group", "Dock Group", "Close Group", "Collapse Group", "Help", "New Swatch",
        ])

        let built = dock.interaction.optionsMenu(for: "swatches", in: groupView(dock, "assets"))
        #expect(built.items.map(\.title) == ["Group Swatches With", "Rename Panel Group…", "Float Group", "Collapse Group", "Help for Swatches"])
        #expect(built.items[0].submenu?.items.last?.title == "New Panel Group")
        #expect(built.items.allSatisfy { $0.identifier?.rawValue.hasPrefix("panel-options.") == true })
        #expect(dock.interaction.validateMenuItem(built.items[1]))
        #expect(!dock.interaction.validateMenuItem(NSMenuItem()))
    }

    @Test func panelSpecificItemsComeFirst() {
        let registry = PanelRegistry()
        var ran = 0
        registry.registerIfAbsent(PanelDescriptor(id: "sw", title: "Swatches", defaultGroup: "Assets", optionsMenu: {
            [PanelMenuItem(title: "New Swatch") { ran += 1 }, PanelMenuItem(title: "Disabled", isEnabled: false) {}]
        }) { NSView() })
        let layout = PanelLayoutController(registry: registry)
        layout.load()
        let dock = PanelDockController(panels: registry, layout: layout)
        dock.view.layoutSubtreeIfNeeded()
        let menu = dock.interaction.optionsMenu(for: "sw", in: dock.groupViews[0])
        #expect(menu.items.map(\.title).prefix(3) == ["New Swatch", "Disabled", ""])
        #expect(dock.interaction.validateMenuItem(menu.items[0]) && !dock.interaction.validateMenuItem(menu.items[1]))
        dock.interaction.performOption(menu.items[0])
        dock.interaction.perform(.custom(index: 7, title: "", isEnabled: true), panel: "sw", groupView: nil)
        dock.interaction.performOption(NSMenuItem())
        #expect(ran == 1)
        #expect(!menu.items.contains { $0.title.hasPrefix("Help") }, "no help slug, no Help item")
    }

    @Test func groupWithSplitRenameFloatDockCloseCollapseAndHelp() async {
        let (registry, layout, dock) = setup()
        var helped: [String] = []
        dock.interaction.onHelp = { helped.append($0.title) }
        let interaction = dock.interaction
        // Group Swatches With Layers, via the menu.
        interaction.perform(.groupWith("layers", title: "Layers"), panel: "swatches", groupView: nil)
        #expect(layout.layout.group("layers")?.panels == ["layers", "swatches"])
        // Split it out again.
        interaction.perform(.newGroup, panel: "swatches", groupView: nil)
        #expect(layout.layout.group(containing: "swatches")?.panels == ["swatches"])
        #expect(layout.layout.edge(of: layout.layout.group(containing: "swatches")!.id) == .right)
        // Rename: Return commits, Esc and empty cancel.
        let layers = groupView(dock, "layers")
        interaction.perform(.rename, panel: "layers", groupView: layers)
        #expect(layers.renameField != nil)
        layers.beginRename()
        layers.renameField?.stringValue = "Stacking"
        _ = layers.control(layers.renameField!, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(layout.layout.group("layers")?.name == "Stacking")
        let renamed = groupView(dock, "layers")
        #expect(renamed.titleLabel.stringValue == "Stacking")
        renamed.beginRename()
        renamed.renameField?.stringValue = "Nope"
        _ = renamed.control(renamed.renameField!, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(layout.layout.group("layers")?.name == "Stacking")
        renamed.beginRename()
        renamed.renameField?.stringValue = "   "
        _ = renamed.control(renamed.renameField!, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(layout.layout.group("layers")?.name == "Stacking")
        renamed.beginRename()
        #expect(!renamed.control(renamed.renameField!, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveLeft(_:))))
        renamed.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(renamed.renameField == nil)
        renamed.endRename(committed: true)
        #expect(GroupRename.outcome(text: " A ", committed: true) == .commit("A"))
        #expect(GroupRename.outcome(text: "A", committed: false) == .cancel)

        // Float, then dock back; close a floating group; collapse a docked one; help.
        interaction.perform(.float, panel: "layers", groupView: nil)
        #expect(layout.layout.edge(of: "layers") == nil && layout.layout.floating.count == 1)
        interaction.perform(.dock, panel: "layers", groupView: nil)
        #expect(layout.layout.edge(of: "layers") == .right)
        interaction.perform(.float, panel: "layers", groupView: nil)
        interaction.perform(.close, panel: "layers", groupView: nil)
        #expect(!layout.layout.contains("layers"))
        interaction.perform(.collapse, panel: "object", groupView: nil)
        #expect(layout.layout.group("properties")?.collapsed == true)
        interaction.perform(.help(slug: "object-panel"), panel: "object", groupView: nil)
        #expect(helped == ["Object"])
        interaction.perform(.rename, panel: "missing", groupView: nil)
        _ = registry

        // Each round-trips through layout persistence.
        let store = PanelLayoutStore(url: TestEnvironment.temporaryDirectory().appending(path: PanelLayoutStore.fileName))
        let saved = PanelLayoutController(registry: registry, store: store, debounce: .milliseconds(1))
        saved.load()
        saved.update { $0 = layout.layout }
        await saved.flushPendingSave()
        let reloaded = PanelLayoutController(registry: registry, store: store)
        reloaded.load()
        #expect(reloaded.layout == layout.layout)
    }

    @Test func dragsReorderJoinSplitMergeAndFloat() {
        let (_, layout, dock) = setup()
        let interaction = dock.interaction
        // Drag Swatches onto the Layers strip, then reorder it within the group.
        interaction.drop(.panel("swatches"), onGroup: "layers", at: 0)
        #expect(layout.layout.group("layers")?.panels == ["swatches", "layers"])
        interaction.drop(.panel("swatches"), onGroup: "layers", at: 2)
        #expect(layout.layout.group("layers")?.panels == ["layers", "swatches"])
        interaction.drop(.panel("swatches"), onGroup: "layers", at: nil)
        // Drag out onto the dock: a new group.
        interaction.drop(.panel("swatches"), onDock: .right, at: 0)
        #expect(layout.layout.docks[.right]?.first?.panels == ["swatches"])
        // A group dragged onto another merges; onto a dock, docks there.
        interaction.drop(.group("help"), onGroup: "layers", at: nil)
        #expect(layout.layout.group("layers")?.panels == ["layers", "help"])
        interaction.drop(.group("layers"), onDock: .left, at: 0)
        #expect(layout.layout.edge(of: "layers") == .left)
        // Released outside every target: floats at the point.
        interaction.beginTracking(.panel("tints"))
        interaction.dragEnded(at: NSPoint(x: 400, y: 700), operation: [])
        #expect(layout.layout.floating.last?.group.panels == ["tints"])
        #expect(layout.layout.floating.last?.frame.maxY == 700)
        interaction.beginTracking(.group("layers"))
        interaction.dragEnded(at: NSPoint(x: 10, y: 500), operation: [])
        #expect(layout.layout.edge(of: "layers") == nil)
        let floatingGroup = layout.layout.floating.last!.group.id
        interaction.beginTracking(.group(floatingGroup))
        interaction.dragEnded(at: NSPoint(x: 50, y: 600), operation: [])
        #expect(layout.layout.floating.last?.frame.x == 50)
        interaction.beginTracking(.panel("object"))
        interaction.dragEnded(at: .zero, operation: .move)
        #expect(layout.layout.group(containing: "object")?.id == "properties", "a drop a target took changes nothing more")
        #expect(interaction.currentDrag == nil)

        // The drop targets read both payloads.
        let dockView = dock.view as! DockDropView
        let group = DraggingInfoStub(pasteboardName: "group", panel: nil, location: CGPoint(x: 10, y: 10))
        group.pasteboard.clearContents()
        group.pasteboard.setString(floatingGroup, forType: PanelDragPayload.groupType)
        #expect(dockView.draggingEntered(group) == .move)
        #expect(dockView.performDragOperation(group))
        #expect(layout.layout.edge(of: floatingGroup) == .right)
        group.release()
        #expect(PanelDockController.tabIndex(forX: 50, frames: [CGRect(x: 0, y: 0, width: 40, height: 10), CGRect(x: 40, y: 0, width: 40, height: 10)]) == 1)
        #expect(groupView(dock, "properties").tabIndex(at: CGPoint(x: 1000, y: 0)) == groupView(dock, "properties").tabButtons.count)
        #expect(PanelDragPayload.panel("x").pasteboardItem.string(forType: PanelDragPayload.panelType) == "x")
        #expect(PanelDragPayload.group("g").pasteboardItem.string(forType: PanelDragPayload.groupType) == "g")
    }

    @Test func groupViewsReportTheirGestures() {
        let group = PanelGroup(id: "g", name: "G", panels: ["a"])
        let view = PanelGroupView(group: group, title: { $0.rawValue }, body: { _ in NSView() }, isFloating: true)
        var events: [String] = []
        view.onClose = { events.append("close") }
        view.onOptions = { _ in events.append("options") }
        view.onDragGroup = { _ in events.append("drag") }
        view.closeGroup(nil)
        view.showOptions(view.optionsButton)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.gripper.mouseDown(with: down)
        #expect(events == ["close", "options", "drag"])
        #expect(view.closeButton?.accessibilityIdentifier() == "panel-group.g.close")
        #expect(PanelGroupView(group: group, title: { $0.rawValue }, body: { _ in NSView() }).closeButton == nil)
    }
}

@Suite @MainActor struct PanelAppearanceTests {
    @Test func labelStylesAndTooltipsApplyLiveWithoutClosingPanels() {
        let environment = TestEnvironment()
        let controller = DocumentWindowController(document: .memory(title: "Look"), environment: environment.document)
        defer { controller.close() }
        let preferences = environment.preferences
        let body = controller.dock.body(for: "object")
        #expect(controller.dock.groupViews[0].tabButtons[0].title == "Object")
        #expect(controller.dock.groupViews[0].tabButtons[0].image != nil)
        preferences.set("icon", for: PreferenceCatalog.Panels.labelStyle)
        #expect(controller.dock.groupViews[0].tabButtons[0].title == "")
        #expect(controller.dock.groupViews[0].tabButtons[0].imagePosition == .imageOnly)
        preferences.set("text", for: PreferenceCatalog.Panels.labelStyle)
        #expect(controller.dock.groupViews[0].tabButtons[0].image == nil)
        #expect(controller.dock.groupViews[0].tabButtons[0].toolTip == "Object")
        preferences.set(false, for: PreferenceCatalog.Panels.showTooltips)
        #expect(controller.dock.groupViews[0].tabButtons[0].toolTip == nil)
        #expect(controller.dock.body(for: "object") === body, "no panel closed")
        preferences.set(3, for: PreferenceCatalog.General.pickDistance)
        #expect(PanelAppearance(preferences: preferences) == PanelAppearance(labelStyle: .text, showsTooltips: false))
        #expect(PanelAppearance.isAppearancePreference("panels.label_style") && !PanelAppearance.isAppearancePreference("x"))
    }

    @Test func resetRestoresTheDefaultLayoutAndNothingElse() {
        let environment = TestEnvironment()
        let preferences = environment.preferences
        preferences.set(true, for: PreferenceCatalog.General.smallerHandles)
        preferences.set("icon", for: PreferenceCatalog.Panels.labelStyle)
        let snapshot = PreferenceCatalog.all.map { preferences.value(for: $0) }
        let layout = environment.layout
        layout.update { $0.movePanel("layers", toGroup: "properties") }
        layout.update { $0.setDockHidden(true, edge: .right) }
        let registry = CommandRegistry()
        PanelCommands.sync(into: registry, panels: environment.panels, layout: layout)
        #expect(registry.perform(PanelCommands.ID.resetLayout))
        #expect(layout.layout == layout.defaultLayout)
        #expect(PreferenceCatalog.all.map { preferences.value(for: $0) } == snapshot)
    }

    @Test func theDockHandleHidesOnClickAndResizesOnDrag() {
        let environment = TestEnvironment()
        let layout = environment.layout
        let handle = DockHandleView(edge: .right, layout: layout)
        handle.finish(totalDelta: 1)
        #expect(layout.layout.hiddenDocks == [.right])
        handle.finish(totalDelta: 0)
        #expect(layout.layout.hiddenDocks.isEmpty)
        handle.drag(startWidth: 280, by: -40)
        #expect(layout.layout.dockWidth[.right] == 320)
        handle.drag(startWidth: 280, by: 1)
        #expect(layout.layout.dockWidth[.right] == 320, "a click-sized move does not resize")
        handle.finish(totalDelta: 10)
        #expect(layout.layout.hiddenDocks.isEmpty)
        #expect(DockHandleView.width(from: 84, draggedBy: 20, edge: .left) == 104)
        #expect(DockHandleView.width(from: 84, draggedBy: -200, edge: .left) == PanelLayout.minimumDockWidth)
        handle.frame = NSRect(x: 0, y: 0, width: 6, height: 100)
        handle.resetCursorRects()
        #expect(handle.accessibilityIdentifier() == "dock-handle.right")
    }

    @Test func theWindowHasFourDocksAndTwoHandles() {
        let environment = TestEnvironment()
        environment.layout.update { layout in
            layout.movePanel("layers", toNewGroupAt: .top)
        }
        let controller = DocumentWindowController(document: .memory(title: "Docks"), environment: environment.document)
        defer { controller.close() }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(controller.docks.count == 4)
        #expect(controller.topDock.groupViews.count == 1 && !controller.topDock.view.isHidden)
        #expect(controller.topDock.view.frame.height > 0 && controller.topDock.widthConstraint == nil)
        #expect(controller.bottomDock.view.isHidden)
        #expect(controller.leftHandle.frame.width == DockHandleView.thickness)
        #expect(controller.rightHandle.frame.maxX == controller.dock.view.frame.minX)
        #expect(PanelDockController.stripHeight(for: [PanelGroup(panels: ["a"], collapsed: true)]) == Double(PanelGroupView.titleHeight))
        #expect(PanelDockController.stripHeight(for: []) == 0)
        controller.topDock.view.layoutSubtreeIfNeeded()
        controller.topDock.handleDrop(.panel("object"), atDockPoint: CGPoint(x: 1000, y: 10))
        #expect(environment.layout.layout.docks[.top]?.count == 2)
    }
}

@Suite @MainActor struct FloatingPanelTests {
    @Test func floatingGroupsAreChildPanelsThatWriteTheirFrames() {
        let registry = catalogRegistry()
        let layout = PanelLayoutController(registry: registry)
        layout.load()
        let floating = FloatingPanelsController(panels: registry, layout: layout)
        let parent = TestWindow.make(NSRect(x: 0, y: 0, width: 400, height: 300))
        floating.parentWindow = { parent }
        layout.update { $0.float(group: "layers", frame: LayoutRect(x: 100, y: 100, width: 260, height: 320)) }
        let window = floating.windows["layers"]
        #expect(window?.parent === parent)
        #expect(window?.frame.origin == NSPoint(x: 100, y: 100))
        #expect((window?.contentView as? PanelGroupView)?.isFloating == true)
        window?.setFrameOrigin(NSPoint(x: 150, y: 120))
        window?.frameDidChange()
        #expect(layout.layout.floating.first?.frame.x == 150)
        window?.windowDidMove(Notification(name: NSWindow.didMoveNotification))
        window?.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
        let other = TestWindow.make(.zero)
        floating.parentWindow = { other }
        floating.reattach()
        #expect(window?.parent === other)
        floating.appearanceDidChange()
        #expect(floating.windows["layers"] != nil && floating.windows["layers"] !== window)
        #expect(floating.body(for: "layers") === floating.body(for: "layers"))
        layout.update { $0.dock(group: "layers", at: .right) }
        #expect(floating.windows.isEmpty)
        parent.close()
        other.close()
    }
}
