import AppKit
import SwiftUI
import Testing
import WTGeometry
import WTModel
@testable import WireTuner

/// D-077: our tab strip (revised after use), docked groups sharing the dock's height, bodies that
/// scroll instead of overlapping, and drags between strips.
@Suite @MainActor struct PanelTabStripTests {
    private func strip(selected: PanelID? = "b") -> PanelTabStrip {
        let star = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        let strip = PanelTabStrip(
            items: [.init(id: "a", title: "Alpha"), .init(id: "b", title: "", image: star, toolTip: "Beta", accessibilityLabel: "Beta"), .init(id: "c", title: "Gamma")],
            selected: selected, accessibilityLabel: "Group"
        )
        strip.frame = NSRect(x: 0, y: 0, width: 242, height: PanelTabStrip.height)
        strip.layoutSubtreeIfNeeded()
        return strip
    }

    @Test func theStripIsAnAccessibleTabGroup() throws {
        let strip = strip()
        #expect(strip.accessibilityRole() == .tabGroup)
        #expect(strip.accessibilityLabel() == "Group")
        #expect((strip.accessibilityTabs() as? [PanelTabButton]) == strip.buttons)
        let buttons = strip.buttons
        #expect(buttons.map { $0.accessibilityIdentifier() } == ["panel-tab.a", "panel-tab.b", "panel-tab.c"])
        #expect(buttons.allSatisfy { $0.accessibilityRole() == .radioButton && $0.accessibilitySubrole() == PanelTabButton.tabSubrole })
        #expect(buttons.map { $0.accessibilityValue() as? NSNumber } == [0, 1, 0])
        #expect(buttons.map { $0.isAccessibilitySelected() } == [false, true, false])
        #expect(buttons[1].accessibilityLabel() == "Beta" && buttons[1].toolTip == "Beta" && buttons[1].imagePosition == .imageOnly)
        #expect(buttons[0].accessibilityRoleDescription() == "tab")
        #expect(!buttons[0].isBordered, "no system bezel: the tab draws itself")
        #expect(buttons[1].contentTintColor == .labelColor && buttons[0].contentTintColor == PanelTabButton.unselectedColor)
        #expect(strip.intrinsicContentSize.height == PanelTabStrip.height)
    }

    @Test func tabsTakeTheirOwnWidthsFromTheLeadingEdge() {
        let strip = strip()
        let frames = strip.buttons.map(\.frame)
        #expect(frames[0].minX == 0 && frames[1].minX == frames[0].maxX + TabStripLayout.spacing)
        #expect(frames[1].width == PanelTabButton.iconSize + 2 * PanelTabButton.padding, "an icon-only tab")
        #expect(frames[2].maxX < 242, "folder tabs do not stretch across the strip")
        #expect(strip.selectedTabFrame == frames[1])
        #expect(strip.selectedIndex == 1 && strip.selectedID == "b")
        #expect(PanelTabStrip(items: [], selected: nil).selectedTabFrame == nil)
        #expect(strip.tabIndex(atX: 0) == 0 && strip.tabIndex(atX: frames[1].midX + 1) == 2 && strip.tabIndex(atX: 240) == 3)
    }

    @Test func clicksAndArrowKeysSelectTabs() {
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 300, height: 100))
        defer { window.close() }
        let strip = strip()
        window.contentView?.addSubview(strip)
        var chosen: [PanelID] = []
        strip.onSelect = { chosen.append($0) }
        strip.buttons[0].performClick(nil)
        #expect(chosen == ["a"] && strip.selectedID == "a")
        #expect(strip.buttons.map(\.state) == [.on, .off, .off])
        strip.buttons[0].performClick(nil)
        #expect(strip.buttons[0].state == .on, "clicking the front tab keeps it in front")

        let right = TestEvents.key(String(UnicodeScalar(NSRightArrowFunctionKey)!), keyCode: 124)
        let left = TestEvents.key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), keyCode: 123)
        let home = TestEvents.key(String(UnicodeScalar(NSHomeFunctionKey)!), keyCode: 115)
        let end = TestEvents.key(String(UnicodeScalar(NSEndFunctionKey)!), keyCode: 119)
        window.makeFirstResponder(strip.buttons[0])
        strip.buttons[0].keyDown(with: right)
        #expect(strip.selectedID == "b" && window.firstResponder === strip.buttons[1])
        strip.buttons[1].keyDown(with: left)
        strip.buttons[0].keyDown(with: left)
        #expect(strip.selectedID == "c", "the arrows wrap")
        strip.buttons[2].keyDown(with: home)
        #expect(strip.selectedID == "a")
        strip.buttons[0].keyDown(with: end)
        #expect(strip.selectedID == "c" && window.firstResponder === strip.buttons[2])
        #expect(chosen == ["a", "a", "b", "a", "c", "a", "c"])
        strip.buttons[2].keyDown(with: TestEvents.key("x", keyCode: 7))
        #expect(strip.selectedID == "c")
        // A tab outside a strip passes keys on.
        PanelTabButton(panelID: "lone", title: "Lone").keyDown(with: right)
    }

    @Test func itemsUpdateInPlaceAndUnknownSelectionsFallBack() {
        let strip = strip(selected: "zzz")
        #expect(strip.selectedID == "a")
        let buttons = strip.buttons
        strip.setItems(strip.items, selected: "c")
        #expect(strip.buttons == buttons && strip.selectedID == "c", "the same items keep their buttons")
        strip.setItems([.init(id: "a", title: "Alpha")], selected: "c")
        #expect(strip.buttons.count == 1 && strip.buttons[0] !== buttons[0] && strip.selectedID == "a")
        strip.setItems([], selected: nil)
        #expect(strip.buttons.isEmpty && strip.selectedID == nil && strip.selectedTabFrame == nil)
        strip.moveSelection(toEnd: true)
    }

    @Test func aDragOverTheStripHighlightsItAndShowsTheCaret() {
        let strip = strip()
        #expect(strip.caret.isHidden && strip.accessibilityValue() == nil)
        strip.isDropTarget = true
        strip.insertionIndex = 1
        strip.layoutSubtreeIfNeeded()
        #expect(!strip.caret.isHidden && abs(strip.caret.frame.midX - strip.buttons[1].frame.minX) < 0.5)
        #expect(strip.accessibilityValue() as? String == "Drop target")
        strip.insertionIndex = 3
        strip.layoutSubtreeIfNeeded()
        #expect(abs(strip.caret.frame.midX - strip.buttons[2].frame.maxX) < 1.5)
        strip.isDropTarget = false
        strip.insertionIndex = nil
        strip.layoutSubtreeIfNeeded()
        #expect(strip.caret.isHidden)
    }

    @Test func sectionTabsBindASelection() throws {
        final class Box {
            var tab = TransformPanelModel.Tab.move
        }
        let box = Box()
        let binding = Binding(get: { box.tab }, set: { box.tab = $0 })
        let tabs = PanelSectionTabs(label: "Transform", options: TransformPanelModel.Tab.allCases.map { ($0, $0.id, $0.title) }, selection: binding, identifier: "transform.tab")
        #expect(tabs.items().map(\.id.rawValue) == ["move", "rotate", "scale", "skew", "reflect"])
        #expect(tabs.selectedID() == "move")
        let hosting = NSHostingView(rootView: tabs.frame(width: 300))
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        hosting.layoutSubtreeIfNeeded()
        let strip = try #require(Self.find(PanelTabStrip.self, in: hosting))
        #expect(strip.accessibilityIdentifier() == "transform.tab")
        #expect(strip.buttons.first?.accessibilityIdentifier() == "transform.tab.move")
        strip.buttons[3].performClick(nil)
        #expect(box.tab == .skew)
        #expect(strip.buttons[3].onDrag == nil, "section tabs do not drag")
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }
}

@Suite @MainActor struct DockSizingTests {
    @Test func expandedGroupsShareTheHeightInProportion() {
        #expect(DockSizing.share(600, preferred: [400, 200]) == [400, 200])
        #expect(DockSizing.share(300, preferred: [400, 200]) == [200, 100])
        #expect(DockSizing.share(100, preferred: []) == [])
        // A group that would get less than the minimum is held at it.
        let shares = DockSizing.share(300, preferred: [1000, 10])
        #expect(shares[1] == DockSizing.minimumContentHeight && abs(shares.reduce(0, +) - 300) < 0.001)
        // No room for every minimum: equal parts.
        #expect(DockSizing.share(60, preferred: [500, 100, 100]) == [20, 20, 20])
        #expect(DockSizing.share(-10, preferred: [1]) == [0])
        #expect(DockSizing.share(200, preferred: [0, 0]) == [100, 100])
    }

    @Test func aDividerMovesHeightBetweenItsExpandedNeighbours() {
        let heights: [Double] = [300, 0, 0, 200, 0]
        let expanded = [true, false, false, true, false]
        #expect(DockSizing.drag(heights, expanded: expanded, divider: 0, by: 50) == [350, 0, 0, 150, 0])
        #expect(DockSizing.drag(heights, expanded: expanded, divider: 2, by: -100) == [200, 0, 0, 300, 0])
        #expect(DockSizing.drag(heights, expanded: expanded, divider: 0, by: 1000)?[3] == DockSizing.minimumContentHeight)
        #expect(DockSizing.drag(heights, expanded: expanded, divider: 0, by: -1000)?[0] == DockSizing.minimumContentHeight)
        #expect(DockSizing.drag(heights, expanded: expanded, divider: 3, by: 10) == nil, "nothing expanded below")
        #expect(DockSizing.drag(heights, expanded: expanded, divider: 9, by: 10) == nil)
        #expect(DockSizing.drag([20, 20], expanded: [true, true], divider: 0, by: 5) == nil, "no room")
        #expect(DockSizing.drag([20], expanded: [true, true], divider: 0, by: 5) == nil)
    }
}

/// A dock over the full catalog with a layout file, as the app has.
@MainActor
private final class DockFixture {
    let registry = PanelRegistry()
    let url = FileManager.default.temporaryDirectory.appending(path: "WireTunerTests.panels.\(UUID().uuidString).json")
    let layout: PanelLayoutController
    let dock: PanelDockController

    init(height: CGFloat = DocumentWindowController.defaultContentSize.height, selection: ActiveSelection? = nil, extra: [PanelDescriptor] = []) {
        PanelCatalog.register(into: registry, selection: selection)
        for descriptor in extra { registry.registerIfAbsent(descriptor) }
        layout = PanelLayoutController(registry: registry, store: PanelLayoutStore(url: url), debounce: .milliseconds(1))
        layout.load()
        dock = PanelDockController(panels: registry, layout: layout)
        dock.view.frame = NSRect(x: 0, y: 0, width: PanelDockController.defaultWidth, height: height)
        dock.view.layoutSubtreeIfNeeded()
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func group(_ id: PanelGroup.ID) -> PanelGroupView {
        dock.groupViews.first { $0.group.id == id }!
    }

    /// A point on a group's title bar, in the dock view (where a drag's location lands without
    /// a window).
    func headerPoint(_ id: PanelGroup.ID) -> CGPoint {
        let frame = dock.view.convert(group(id).bounds, from: group(id))
        return CGPoint(x: frame.midX, y: frame.maxY - 10)
    }

    /// A point on a group's body, in the dock view.
    func bodyPoint(_ id: PanelGroup.ID, fromBottom: CGFloat = 20) -> CGPoint {
        let frame = dock.view.convert(group(id).bounds, from: group(id))
        return CGPoint(x: frame.midX, y: frame.minY + fromBottom)
    }

    func reloaded() async throws -> PanelLayout? {
        await layout.flushPendingSave()
        return try PanelLayoutStore(url: url).load()
    }
}

@Suite @MainActor struct DockColumnTests {
    @Test func groupsFillTheDockWithoutOverlapping() {
        let fixture = DockFixture()
        let views = fixture.dock.groupViews
        #expect(views.map(\.group.id) == ["properties", "assets", "mixer-and-tints", "layers", "help"])
        let column = fixture.dock.column
        #expect(column.dividers.count == views.count - 1)
        for (upper, lower) in zip(views, views.dropFirst()) {
            #expect(upper.frame.maxY <= lower.frame.minY, "\(upper.group.id) ends above \(lower.group.id)")
        }
        #expect(abs((views.last?.frame.maxY ?? 0) - column.bounds.height) < 1, "the groups use the dock's height")
        // Collapsed groups take their title bar's height only.
        for view in views where view.group.collapsed {
            #expect(view.frame.height == PanelGroupView.titleHeight && view.isCollapsed && view.tabStrip.isHidden)
        }
        // Properties asks for more than Layers.
        #expect(fixture.group("properties").bodyCard.frame.height > fixture.group("layers").bodyCard.frame.height * 2)
        #expect(fixture.dock.preferredHeight(for: PanelGroup(id: "properties", panels: [])) == 600)
        #expect(fixture.dock.preferredHeight(for: PanelGroup(id: "x", panels: [], height: 99)) == 99)
        #expect(fixture.dock.preferredHeight(for: PanelGroup(id: "x", panels: [])) == PanelLayout.defaultGroupHeight)
        #expect(!column.dividers[3].isResizable && column.dividers[0].isResizable)
    }

    @Test func noPartOfAGroupExtendsPastItsFrame() {
        let tall = PanelDescriptor(id: "tall", title: "Tall", defaultGroup: "Layers", menuOrder: 21) {
            VStack(spacing: 0) { Color.red.frame(height: 900) }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        let fixture = DockFixture(extra: [tall])
        fixture.layout.update { $0.activate("tall") }
        fixture.dock.view.layoutSubtreeIfNeeded()
        let layers = fixture.group("layers")
        layers.layoutSubtreeIfNeeded()
        for view in fixture.dock.groupViews {
            for part in view.subviews where !part.isHidden {
                #expect(view.bounds.contains(part.frame), "\(part) inside \(view.group.id)")
            }
        }
        // The tall body scrolls in its group instead of drawing over the next title.
        let scroll = layers.bodyScroll
        #expect(layers.contentView.frame.height >= 900)
        #expect(scroll.contentView.bounds.height < layers.contentView.frame.height)
        #expect(scroll.hasVerticalScroller && layers.bodyScroll.layer?.masksToBounds == true)
        let help = fixture.group("help")
        #expect(fixture.dock.view.convert(layers.bounds, from: layers).minY >= fixture.dock.view.convert(help.bounds, from: help).maxY)
        // A short body fills its group.
        let properties = fixture.group("properties")
        properties.layoutSubtreeIfNeeded()
        #expect(abs(properties.contentView.frame.height - properties.bodyScroll.contentView.bounds.height) < 1)
    }

    @Test func dividersResizeAndPersistInTheLayout() async throws {
        let fixture = DockFixture()
        let column = fixture.dock.column
        let before = column.contentHeights
        column.dividers[0].move(by: -40)
        #expect(fixture.layout.layout.group("properties")?.height == (before[0] - 40).rounded())
        #expect(fixture.layout.layout.group("layers")?.height == (before[3] + 40).rounded())
        fixture.dock.view.layoutSubtreeIfNeeded()
        #expect(abs(column.contentHeights[0] - (before[0] - 40)) < 1.5)
        #expect(column.dividers[1].accessibilityPerformIncrement())
        #expect(column.dividers[1].accessibilityPerformDecrement())
        #expect(column.dividers[1].accessibilityRole() == .splitter && column.dividers[1].accessibilityIdentifier() == "panel-divider.right.1")
        let saved = try await fixture.reloaded()
        #expect(saved?.group("properties")?.height == fixture.layout.layout.group("properties")?.height)
        #expect(saved?.group("layers")?.height == fixture.layout.layout.group("layers")?.height)
        // A divider with nothing expanded below it does not move anything.
        let layout = fixture.layout.layout
        column.dividers[3].move(by: 30)
        #expect(fixture.layout.layout == layout)
        let divider = column.dividers[0]
        divider.resetCursorRects()
        let rep = try #require(divider.bitmapImageRepForCachingDisplay(in: divider.bounds))
        divider.cacheDisplay(in: divider.bounds, to: rep)
    }

    @Test func aDividerFollowsTheMouse() throws {
        let fixture = DockFixture()
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 300, height: 800))
        defer { window.close() }
        window.contentView?.addSubview(fixture.dock.view)
        fixture.dock.view.translatesAutoresizingMaskIntoConstraints = true
        fixture.dock.view.frame = NSRect(x: 0, y: 0, width: 280, height: 800)
        func mouse(_ type: NSEvent.EventType, y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Mouse events another test left in the queue would move the divider first.
        while NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast, inMode: .eventTracking, dequeue: true) != nil {}
        fixture.dock.view.layoutSubtreeIfNeeded()
        let before = fixture.dock.column.contentHeights
        window.postEvent(mouse(.leftMouseDragged, y: 380), atStart: false)
        window.postEvent(mouse(.leftMouseUp, y: 380), atStart: false)
        fixture.dock.column.dividers[0].mouseDown(with: mouse(.leftMouseDown, y: 400))
        // Dragged down: Properties grows by what Layers gives up (a posted event's location is not
        // exactly the one given, so only the direction and the sum are checked).
        let properties = try #require(fixture.layout.layout.group("properties")?.height)
        let layers = try #require(fixture.layout.layout.group("layers")?.height)
        #expect(properties > before[0] && layers >= DockSizing.minimumContentHeight)
        #expect(abs(properties + layers - (before[0] + before[3])) <= 1)
    }

    @Test func collapsingAnimatesInPlaceAndKeepsTheViews() {
        let fixture = DockFixture()
        let views = fixture.dock.groupViews
        fixture.group("assets").disclosure.performClick(nil)
        #expect(fixture.dock.groupViews.elementsEqual(views, by: ===), "the same group views, updated")
        fixture.dock.view.layoutSubtreeIfNeeded()
        #expect(!fixture.group("assets").isCollapsed && fixture.group("assets").frame.height > PanelGroupView.titleHeight)
        // A click on the title collapses it again.
        fixture.group("assets").titleBar.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        #expect(fixture.layout.layout.group("assets")?.collapsed == true)
        // A tab chosen in place: the strip's selection moves, the body changes.
        let assets = fixture.group("assets")
        fixture.layout.update { $0.activate("styles") }
        #expect(fixture.group("assets") === assets && assets.tabStrip.selectedID == "styles")
        #expect(assets.contentView.subviews.first === fixture.dock.body(for: "styles"))
        // Renaming keeps the view; a new member rebuilds it.
        fixture.layout.update { $0.rename(group: "assets", to: "Things") }
        #expect(fixture.group("assets") === assets && assets.titleLabel.stringValue == "Things")
        fixture.layout.update { $0.movePanel("help", toGroup: "assets") }
        #expect(fixture.group("assets") !== assets)
    }
}

@Suite @MainActor struct PanelDragTests {
    @Test func aTabDraggedOntoAnotherStripJoinsItWhereItLands() {
        let fixture = DockFixture()
        let interaction = fixture.dock.interaction
        var sessions: [PanelDragPayload?] = []
        interaction.startDragSession = { _, _, _, source in sessions.append((source as? PanelInteraction)?.currentDrag) }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        fixture.layout.update { $0.setCollapsed(false, group: "assets") }
        let assets = fixture.group("assets")
        assets.onDragTab?(assets.tabButtons[1], event)
        #expect(sessions == [.panel("styles")])

        // Over the Layers title bar: Layers has no strip (one panel), so its title highlights.
        let layers = fixture.group("layers")
        let drag = DraggingInfoStub(pasteboardName: "tab", panel: "styles", location: fixture.headerPoint("layers"))
        defer { drag.release() }
        #expect(layers.draggingEntered(drag) == .move)
        #expect(layers.isDropTarget && !layers.showsTabs && layers.tabStrip.insertionIndex == nil)
        #expect(layers.titleBar.layer?.backgroundColor != nil)
        #expect(fixture.dock.column.insertionIndex == nil)
        layers.draggingExited(drag)
        #expect(!layers.isDropTarget && layers.titleBar.layer?.backgroundColor == nil)
        #expect(layers.performDragOperation(drag))
        interaction.dragEnded(at: .zero, operation: .move)
        #expect(fixture.layout.layout.group("layers")?.panels.contains("styles") == true)
        #expect(fixture.layout.layout.group("layers")?.activePanel == "styles")
        #expect(fixture.layout.layout.group("assets")?.panels == ["swatches", "library"])
        #expect(interaction.currentDrag == nil)
    }

    @Test func tabsReorderByDraggingWithinTheirStrip() {
        let fixture = DockFixture()
        fixture.layout.update { $0.setCollapsed(false, group: "assets") }
        let assets = fixture.group("assets")
        let frame = fixture.dock.view.convert(assets.tabStrip.bounds, from: assets.tabStrip)
        let drag = DraggingInfoStub(pasteboardName: "reorder", panel: "swatches", location: CGPoint(x: frame.maxX - 2, y: frame.midY))
        defer { drag.release() }
        #expect(assets.performDragOperation(drag))
        #expect(fixture.layout.layout.group("assets")?.panels == ["styles", "library", "swatches"])
    }

    @Test func aGroupDraggedOverADockedBodyDocksBetweenGroups() throws {
        let fixture = DockFixture()
        fixture.layout.update { $0.float(group: "help", frame: LayoutRect(x: 10, y: 10, width: 200, height: 200)) }
        let floatingID = "help"
        let properties = fixture.group("properties")
        let drag = DraggingInfoStub(pasteboardName: "group", panel: nil, location: fixture.bodyPoint("properties"))
        defer { drag.release() }
        drag.pasteboard.setString(floatingID, forType: PanelDragPayload.groupType)
        #expect(properties.draggingUpdated(drag) == .move)
        #expect(!properties.tabStrip.isDropTarget, "over the body the group does not join")
        #expect(fixture.dock.column.insertionIndex == 1, "the line shows under Properties")
        fixture.dock.view.layoutSubtreeIfNeeded()
        #expect(!fixture.dock.column.insertionLine.isHidden)
        #expect(properties.performDragOperation(drag))
        #expect(fixture.dock.column.insertionIndex == nil)
        #expect(fixture.layout.layout.docks[.right]?.map(\.id) == ["properties", "help", "assets", "mixer-and-tints", "layers"])

        // The dock background shows the line too, and hides it when the drag leaves.
        let dockView = try #require(fixture.dock.view as? DockDropView)
        let top = DraggingInfoStub(pasteboardName: "top", panel: "layers", location: CGPoint(x: 20, y: fixture.dock.view.bounds.height - 1))
        defer { top.release() }
        #expect(dockView.draggingEntered(top) == .move)
        #expect(fixture.dock.column.insertionIndex == 0)
        fixture.dock.view.layoutSubtreeIfNeeded()
        dockView.draggingExited(top)
        #expect(fixture.dock.column.insertionIndex == nil)
        #expect(dockView.draggingUpdated(top) == .move)
        dockView.draggingEnded(top)
        #expect(fixture.dock.column.insertionIndex == nil)
        properties.draggingEnded(top)
    }

    @Test func draggingOutFloatsAndTheOptionsMenuFloatsAndDocksAndItAllPersists() async throws {
        let fixture = DockFixture()
        let floating = FloatingPanelsController(panels: fixture.registry, layout: fixture.layout, interaction: fixture.dock.interaction)
        let parent = TestWindow.make(NSRect(x: 0, y: 0, width: 600, height: 400))
        defer {
            for window in floating.windows.values { window.close() }
            parent.close()
        }
        floating.parentWindow = { parent }
        let interaction = fixture.dock.interaction
        interaction.startDragSession = { _, _, _, _ in }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        // A tab dragged out of its strip onto the pasteboard floats there.
        let layers = fixture.group("layers")
        interaction.beginDrag(.panel("layers"), from: layers.tabButtons[0], event: event)
        interaction.dragEnded(at: NSPoint(x: 300, y: 500), operation: [])
        let floated = try #require(fixture.layout.layout.floating.first)
        #expect(floated.group.panels == ["layers"] && floated.frame.x == 300 && floated.frame.maxY == 500)
        let window = try #require(floating.windows[floated.group.id])
        let groupView = try #require(window.contentView as? PanelGroupView)
        #expect(groupView.isFloating && groupView.background != nil && !window.isOpaque && window.backgroundColor == .clear)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
        // Choosing its tab updates the floating group in place.
        fixture.layout.update { $0.activate("layers") }
        #expect(window.contentView === groupView)
        // Collapsed, the window is its title bar, and the stored frame keeps its height.
        fixture.layout.update { $0.setCollapsed(true, group: floated.group.id) }
        #expect(window.frame.height == PanelGroupView.titleHeight)
        window.setFrameOrigin(NSPoint(x: 320, y: window.frame.minY))
        window.frameDidChange()
        #expect(fixture.layout.layout.floating.first?.frame.height == floated.frame.height && fixture.layout.layout.floating.first?.frame.x == 320)
        fixture.layout.update { $0.setCollapsed(false, group: floated.group.id) }

        // Dock Group and Float Group from the Options menu.
        interaction.perform(.dock, panel: "layers", groupView: groupView)
        #expect(fixture.layout.layout.edge(of: floated.group.id) == .right && floating.windows.isEmpty)
        interaction.perform(.float, panel: "object", groupView: nil)
        #expect(fixture.layout.layout.edge(of: "properties") == nil && floating.windows["properties"] != nil)
        let saved = try await fixture.reloaded()
        #expect(saved == fixture.layout.layout, "every arrangement is in the saved layout")
    }

    @Test func dragImagesPictureTheTabOrTheGroupHeader() {
        let fixture = DockFixture()
        let group = fixture.group("properties")
        let rect = PanelInteraction.dragRect(of: group)
        #expect(rect.height == PanelGroupView.titleHeight + PanelGroupView.tabRowHeight && rect.minY == 0)
        let tab = group.tabButtons[0]
        #expect(PanelInteraction.dragRect(of: tab) == tab.bounds)
        let image = PanelInteraction.dragImage(of: group, rect: rect)
        #expect(image.size == rect.size)
        #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
        #expect(PanelInteraction.dragImage(of: NSView(), rect: .zero).size == NSSize(width: 1, height: 1))
        let collapsed = fixture.group("assets")
        #expect(PanelInteraction.dragRect(of: collapsed).height == PanelGroupView.titleHeight)
    }
}

@Suite @MainActor struct ObjectPanelSizingTests {
    /// panels.adoc: at the default window size the Object panel's editor half shows under its
    /// properties list -- selecting a stroke row shows the stroke editor without resizing.
    @Test func theObjectPanelShowsItsEditorAtTheDefaultWindowSize() async throws {
        let fixture = await AttributeFixture.make()
        let selectionModel = SelectionModel()
        selectionModel.set(Selection(fixture.ids))
        let active = ActiveSelection(model: selectionModel, document: fixture.document)
        let list = fixture.list()
        let stroke = try #require(list.rows.first { $0.list == .strokes })
        InspectorRowRequest.shared.request(stroke.id, targets: list.targets)
        let dock = DockFixture(selection: active)
        let properties = dock.group("properties")
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(50))
            dock.dock.view.layoutSubtreeIfNeeded()
            properties.layoutSubtreeIfNeeded()
        }
        let body = try #require(properties.contentView.subviews.first)
        #expect(body.accessibilityIdentifier() == "panel.object")
        let minimum = body.constraints.first { $0.identifier == "NSHostingView.minHeight" }?.constant ?? 0
        #expect(minimum >= ObjectPanelBody.editorMinimumHeight, "the editor half has a floor")
        let visible = properties.bodyScroll.contentView.bounds.height
        #expect(properties.contentView.frame.height <= visible + 1, "the whole Object panel, editor included, fits: \(properties.contentView.frame.height) in \(visible)")
        #expect(InspectorRowRequest.shared.pending == nil, "the stroke row is selected")
    }
}

@Suite @MainActor struct PanelChromeTests {
    @Test func theTitleBarTogglesOnAClickAndKeepsItsButtons() throws {
        let group = PanelGroup(id: "g", name: "Group", panels: ["a", "b"])
        let view = PanelGroupView(group: group, title: { $0.rawValue }, body: { _ in NSView() }, isFloating: true)
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 300)
        view.layoutSubtreeIfNeeded()
        let bar = view.titleBar
        #expect(bar.hitTest(NSPoint(x: view.titleLabel.frame.midX, y: view.titleLabel.frame.midY)) === bar, "the title is part of the bar")
        #expect(bar.hitTest(NSPoint(x: view.optionsButton.frame.midX, y: view.optionsButton.frame.midY)) === view.optionsButton)
        #expect(bar.hitTest(NSPoint(x: view.gripper.frame.midX, y: view.gripper.frame.midY)) === view.gripper)
        var toggles = 0
        view.onToggleCollapse = { toggles += 1 }
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 260, height: 300))
        defer { window.close() }
        window.contentView?.addSubview(view)
        func mouse(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 290), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        while NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast, inMode: .eventTracking, dequeue: true) != nil {}
        window.postEvent(mouse(.leftMouseUp, x: 100), atStart: false)
        bar.mouseDown(with: mouse(.leftMouseDown, x: 100))
        #expect(toggles == 1)
        // A drag in a document window's dock does not move anything and does not toggle.
        window.postEvent(mouse(.leftMouseDragged, x: 140), atStart: false)
        bar.mouseDown(with: mouse(.leftMouseDown, x: 100))
        #expect(toggles == 1)
        #expect(view.background != nil && view.closeButton != nil)
        #expect(view.disclosure.accessibilityLabel() == "Collapse")
        view.gripper.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        view.gripper.resetCursorRects()
    }

    @Test func theDockHandleDrawsAGrabber() throws {
        let environment = TestEnvironment()
        let handle = DockHandleView(edge: .right, layout: environment.layout)
        handle.frame = NSRect(x: 0, y: 0, width: DockHandleView.thickness, height: 100)
        let rep = try #require(handle.bitmapImageRepForCachingDisplay(in: handle.bounds))
        handle.cacheDisplay(in: handle.bounds, to: rep)
        #expect(PanelGlass.isAvailable)
        let surface = PanelGlass.surface(cornerRadius: 4)
        PanelGlass.setTint(.red, of: surface)
        PanelGlass.setContent(NSView(), of: surface)
        #expect(PanelGlass.contentMaterial(cornerRadius: 4).material == .windowBackground)
    }
}
