import AppKit
import SwiftUI
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

/// BASIC-018 and BASIC-019: every context menu has the documented items in the documented
/// order, with the menu bar's shortcuts.
@Suite(.serialized) @MainActor struct ContextMenuTests {
    private func registry() -> (CommandRegistry, ShortcutSet) {
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        SelectionCommands.install(commands: registry, tools: ToolRegistry())
        PanelCommands.sync(into: registry, panels: {
            let panels = PanelRegistry()
            PanelCatalog.register(into: panels)
            return panels
        }(), layout: PanelLayoutController(registry: PanelRegistry()))
        return (registry, ShortcutSet.builtInDefault(commands: registry.commands))
    }

    private func titles(_ target: ContextMenuTarget) -> [String?] {
        let (registry, shortcuts) = registry()
        return ContextMenuBuilder.nodes(for: target, registry: registry, shortcuts: shortcuts).map(\.title)
    }

    static let common: [String?] = [
        "Cut", "Copy", "Paste", "Clear", "Duplicate", "Clone", nil, "Group", "Ungroup", nil, "Lock", "Unlock", nil,
        "Arrange", "Align", "Transform", nil, "Hide Selection", "Add to Library…", "Name…", "Note…", "Link…", "Copy Link", "Locate Object", nil, "Select", "Object Panel",
    ]

    static let kindItems: [ContextObjectKind: [String?]] = [
        .path: ["Path", "Remove Overlap", "Simplify", "Expand Stroke…", "Inset Path…", "Attach to Path"],
        .text: ["Editor…", "Font", "Size", "Style", "Align", "Attach to Path", "Detach from Path", "Flow Inside Path", "Convert to Paths", "Spelling…"],
        .bitmap: ["Edit in External Editor", "Trace…", "Crop", "Links…"],
        .importedGraphic: ["Links…", "Convert to Editable"],
        .group: ["Ungroup", "Group Transforms as Unit", "Enter Group"],
        .blend: ["Blend Steps…", "Attach to Path", "Release"],
        .clip: ["Release Contents", "Edit Contents"],
        .connector: ["Reroute", "Detach Ends"],
        .symbolInstance: ["Release Instance", "Edit Symbol", "Show in Library"],
        .chart: ["Edit Data…", "Chart Type…"],
        .envelope: ["Show Map", "Copy as Path", "Release", "Remove"],
    ]

    @Test(arguments: ContextObjectKind.allCases)
    func eachObjectKindHasItsItemsThenTheCommonOnes(kind: ContextObjectKind) {
        #expect(titles(.objects([kind])) == Self.kindItems[kind]! + [nil] + Self.common)
    }

    @Test func thePathSubmenuAndTheCommonSubmenus() throws {
        let (registry, shortcuts) = registry()
        let nodes = ContextMenuBuilder.nodes(for: .objects([.path]), registry: registry, shortcuts: shortcuts)
        guard case let .submenu(_, path) = nodes[0] else { Issue.record("Path submenu"); return }
        #expect(path.map(\.title) == ["Close / Open", "Reverse Direction", "Join", "Split"])
        let arrange = try #require(nodes.first { $0.title == "Arrange" })
        guard case let .submenu(_, arrangeItems) = arrange else { return }
        #expect(arrangeItems.map(\.title) == ["Bring to Front", "Bring Forward", "Send Backward", "Send to Back"])
        guard case let .submenu(_, select)? = nodes.first(where: { $0.title == "Select" }) else { Issue.record("Select"); return }
        #expect(select.map(\.title) == ["All", "None", "Invert Selection", "Superselect", "Subselect All"])
    }

    @Test func aMultipleSelectionAddsCombineAndKindItemsOnlyWhenAlike() {
        var expected = Self.common
        expected.insert("Combine", at: expected.firstIndex(of: "Align")!)
        #expect(titles(.objects([.path, .text])) == expected)
        #expect(titles(.objects([.group, .group])) == Self.kindItems[.group]! + [nil] + expected)
        let (registry, shortcuts) = registry()
        let nodes = ContextMenuBuilder.nodes(for: .objects([.path, .bitmap]), registry: registry, shortcuts: shortcuts)
        guard case let .submenu(_, combine)? = nodes.first(where: { $0.title == "Combine" }) else { Issue.record("Combine"); return }
        #expect(combine.map(\.title) == ["Union", "Divide", "Intersect", "Punch", "Crop", "Transparency", "Blend", "Join"])
    }

    @Test func thePasteboardAndPageMenus() {
        let empty = titles(.pasteboard(overPage: false))
        #expect(empty == ["View", nil, "Paste", "Paste Behind", "All", "Show All", nil, "Page", nil, "Rulers", "Grid", "Guides", nil, "Document Panel"])
        let (registry, shortcuts) = registry()
        let page = ContextMenuBuilder.nodes(for: .pasteboard(overPage: true), registry: registry, shortcuts: shortcuts)
        guard case let .submenu(_, pageItems)? = page.first(where: { $0.title == "Page" }) else { Issue.record("Page"); return }
        #expect(pageItems.map(\.title) == ["Add Page", "Duplicate Page", "Remove Page", "Page Setup…"])
        let off = ContextMenuBuilder.nodes(for: .pasteboard(overPage: false), registry: registry, shortcuts: shortcuts)
        guard case let .submenu(_, offItems)? = off.first(where: { $0.title == "Page" }) else { return }
        #expect(offItems.map(\.title) == ["Add Page"], "the other page items only over a page")
        guard case let .submenu(_, view) = page[0] else { Issue.record("View"); return }
        #expect(view.map(\.title) == ContextMenuCatalog.contextMagnifications.map { "\($0)%" } + [nil, "Fit to Page", "Fit All"])
    }

    @Test func guidePresenceTabAndTextMenus() {
        #expect(titles(.guide(locked: false)) == ["Lock Guide", "Release Guide", "Edit Guides…", "Delete Guide"])
        #expect(titles(.guide(locked: true)).first == "Unlock Guide")
        #expect(titles(.presence(participantID: "p", name: "Ana")) == ["Follow Ana", "Go to Ana's Page", "Hide Ana's Cursor"])
        #expect(titles(.textEditing) == [
            "Cut", "Copy", "Paste", nil, "Font", "Size", "Style", "Leading", "Alignment", "Special Characters", "Spelling", nil,
            "Editor…", "Convert Case", "Attach to Path", "Run Around Selection…", "Convert to Paths",
        ])
        #expect(ContextMenuTarget.guide(locked: false).name == nil)
        #expect(ContextMenuTarget.pasteboard(overPage: true).contexts == [.pasteboard, .page])
        #expect(ContextMenuTarget.objects([.path, .path]).contexts == [.path, .multiple])
        #expect(ContextMenuTarget.tab.contexts == [.tab] && ContextMenuTarget.textEditing.contexts == [.textEditing])
        #expect(ContextMenuTarget.presence(participantID: "p", name: "A").contexts == [.presence])
        #expect(ContextMenuTarget.guide(locked: true).contexts == [.guide])
    }

    @Test func theTabMenuHasTheDocumentedItems() {
        let (registry, shortcuts) = registry()
        ViewCommands.install(into: registry, target: { nil }, newDocument: {})
        WindowTabCommands.install(into: registry)
        let nodes = ContextMenuBuilder.nodes(for: .tab, registry: registry, shortcuts: shortcuts)
        #expect(nodes.map(\.title) == ["Close Tab", "Close Other Tabs", "Move Tab to New Window", "Rename Document…", "Share…", "Show in Library"])
    }

    @Test func everyItemHasTheMenuBarsKeyAndAMenuBarHome() {
        let (registry, shortcuts) = registry()
        let targets: [ContextMenuTarget] = ContextObjectKind.allCases.map { .objects([$0]) } + [
            .objects([.path, .text]), .pasteboard(overPage: true), .guide(locked: false), .presence(participantID: "p", name: "N"), .textEditing,
        ]
        let menuBar = MenuTreeBuilder.build(registry: registry, shortcuts: shortcuts)
        let inMenuBar = Set(menuBar.commandIDs)
        func items(_ nodes: [MenuNode]) -> [MenuItemNode] {
            nodes.flatMap { node -> [MenuItemNode] in
                switch node {
                case let .item(item): [item]
                case let .submenu(_, children): items(children)
                case .separator: []
                }
            }
        }
        for target in targets {
            for item in items(ContextMenuBuilder.nodes(for: target, registry: registry, shortcuts: shortcuts)) {
                #expect(item.key == shortcuts.keyEquivalent(for: item.commandID), "\(item.commandID)")
                let extraLevel = ContextMenuCatalog.contextMagnifications.contains { StandardCommands.ID.magnification($0) == item.commandID }
                #expect(inMenuBar.contains(item.commandID) || extraLevel, "\(item.commandID) is in the menu bar")
            }
        }
    }

    @Test(arguments: ContextMenuCatalog.documentedPanelItems.map(\.context))
    func panelMenusShowTheOwningPanelsCommands(context: MenuContext) throws {
        let (registry, shortcuts) = registry()
        let titles = try #require(ContextMenuCatalog.documentedPanelItems.first { $0.context == context }?.titles)
        #expect(ContextMenuBuilder.nodes(for: .panel(context), registry: registry, shortcuts: shortcuts).isEmpty)
        for (index, title) in titles.enumerated() {
            try registry.register(Command.placeholder(id: CommandID("stub.\(context.rawValue).\(index)"), title: title, contexts: [context]))
        }
        let nodes = ContextMenuBuilder.nodes(for: .panel(context), registry: registry, shortcuts: shortcuts)
        #expect(nodes.map(\.title) == titles.map { Optional($0) })
    }

    @Test func featuresAddItemsThroughContextsAndSeparatorsStayTidy() throws {
        let (registry, shortcuts) = registry()
        try registry.register(Command(id: "feature.extra", title: "Extra", menu: MenuPath("Modify"), contexts: [.connector], action: .perform(Command.noop)))
        let nodes = ContextMenuBuilder.nodes(for: .objects([.connector]), registry: registry, shortcuts: shortcuts)
        #expect(nodes.suffix(2).map(\.title) == [nil, "Extra"])
        #expect(ContextMenuBuilder.tidy([.separator, .separator, .item(MenuItemNode(commandID: "a", title: "A", key: nil)), .separator, .separator]).count == 1)
        let unknown = ContextMenuBuilder.render([.command("nope"), .submenu("Empty", [.command("nope")])], target: .tab, registry: registry, shortcuts: shortcuts)
        #expect(unknown.isEmpty)
    }

    @Test func objectKindsReadFromTheDisplayList() {
        let box = Rect(x: 0, y: 0, width: 10, height: 10)
        let path = DisplayPath(rect: box)
        #expect(ContextObjectKind(item: .fill(FillItem(path: path, paint: .solid(.black)))) == .path)
        #expect(ContextObjectKind(item: .stroke(StrokeItem(path: path, paint: .solid(.black)))) == .path)
        #expect(ContextObjectKind(item: .image(ImageItem(assetID: "i", rect: box))) == .bitmap)
        #expect(ContextObjectKind(item: .text(TextRunItem(text: "T", origin: .zero, bounds: box))) == .text)
        #expect(ContextObjectKind(item: .group(GroupItem(children: []))) == .group)
        #expect(ContextObjectKind(item: .group(GroupItem(children: [], clip: path))) == .clip)
        for kind in ContextObjectKind.allCases { #expect(kind.context.rawValue == kind.rawValue) }
    }

    @Test func controlClickingSelectsAnUnselectedObjectFirstAndLeavesThePasteboardAlone() async throws {
        let environment = TestEnvironment()
        StandardCommands.register(into: environment.commands)
        PanelCommands.sync(into: environment.commands, panels: environment.panels, layout: environment.layout)
        let controller = DocumentWindowController(document: .memory(title: "Context"), environment: environment.document)
        defer { controller.close() }
        let document = controller.documentHandle
        let a = Rect(x: 7500, y: 7500, width: 40, height: 40)
        let b = Rect(x: 7600, y: 7500, width: 40, height: 40)
        await document.addRectangles([a, b])
        controller.canvas.setViewport(controller.viewport.scrolled(byViewDelta: controller.viewport.toView(a.center) - controller.viewport.viewCenter))
        let viewport = controller.viewport
        // An unselected object: selected first, the menu is for it alone.
        let menu = controller.contextMenu(at: viewport.toView(a.center))
        #expect(controller.selection.model.count == 1)
        guard case let .objects(kinds)? = controller.contextTarget else { Issue.record("objects"); return }
        #expect(kinds == [.path])
        #expect(menu.items.first?.title == "Path")
        #expect(menu.items.contains { $0.identifier?.rawValue == "menu.edit.duplicate" })
        let objectPanel = try #require(menu.items.first { $0.title == "Object Panel" })
        #expect(objectPanel is FixedTitleMenuItem)
        // Inside a multiple selection: the selection stays and the menu is for all of it.
        controller.selection.model.set(Selection(document.selectableIDs()))
        let count = controller.selection.model.count
        #expect(count >= 2)
        _ = controller.contextMenu(at: viewport.toView(a.center))
        #expect(controller.selection.model.count == count)
        guard case let .objects(all)? = controller.contextTarget else { return }
        #expect(all.count == count)
        // Empty pasteboard: the selection is left alone.
        _ = controller.contextMenu(at: viewport.toView(Point(x: 10, y: 10)))
        #expect(controller.contextTarget == .pasteboard(overPage: false))
        #expect(controller.selection.model.count == count)
        // Over a page with nothing under the pointer.
        let page = try #require(document.currentPage)
        controller.canvas.setViewport(controller.viewport.scrolled(byViewDelta: controller.viewport.toView(page.center) - controller.viewport.viewCenter))
        _ = controller.contextMenu(at: controller.viewport.toView(page.center))
        #expect(controller.contextTarget == .pasteboard(overPage: true))
        // Guides and presence markers come from their hooks.
        controller.contextResolver.guide = { _ in .guide(locked: true) }
        _ = controller.contextMenu(at: controller.viewport.toView(page.center))
        #expect(controller.contextTarget == .guide(locked: true))
        controller.contextResolver.guide = { _ in nil }
        controller.contextResolver.presence = { _ in .presence(participantID: "p", name: "Ana") }
        let presence = controller.contextMenu(at: controller.viewport.toView(page.center))
        #expect(presence.items.first?.title == "Follow Ana")
        // The canvas asks the window for the menu.
        #expect(controller.canvas.onContextMenu != nil)
        // At a point where the window shows the canvas (a point under the status bar or a dock is
        // not the canvas's, found in use 2026-10-02).
        let safe = controller.canvas.appKitSafeRect
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: controller.canvas.convert(NSPoint(x: safe.midX, y: safe.midY), to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!
        #expect(controller.canvas.menu(for: event) != nil)
    }

    @Test func menuValidationKeepsAContextTitle() {
        let (registry, _) = registry()
        let target = CommandMenuTarget(registry: registry)
        let item = MainMenuBuilder.menuItem(
            for: MenuItemNode(commandID: PanelCommands.ID.show("object"), title: "Object Panel", key: nil, keepsTitle: true), registry: registry, target: target
        )
        _ = target.validateMenuItem(item)
        #expect(item.title == "Object Panel")
    }

    @Test func panelTabsHaveTheFrameworkMenu() throws {
        let environment = TestEnvironment()
        let interaction = PanelInteraction(panels: environment.panels, layout: environment.layout)
        let dock = PanelDockController(panels: environment.panels, layout: environment.layout, edge: .right, interaction: interaction)
        dock.view.layoutSubtreeIfNeeded()
        let groupView = try #require(dock.groupViews.first)
        let panel = try #require(groupView.group.panels.first)
        let menu = interaction.tabMenu(for: panel, in: groupView)
        let titles = menu.items.map(\.title)
        #expect(titles.first?.hasPrefix("Group ") == true)
        #expect(titles.contains("Rename Panel Group…"))
        #expect(titles.contains("Float Group"))
        #expect(titles.last?.hasPrefix("Help for") == true)
        #expect(!titles.contains("Close Group"))
        let button = try #require(groupView.tabButtons.first)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        #expect(button.menu(for: event)?.items.map(\.title) == titles)
    }

    @Test func panelBodiesRenderRegistryMenus() throws {
        let (registry, shortcuts) = registry()
        try registry.register(Command.placeholder(id: "stub.swatch", title: "New Swatch…", contexts: [.swatchesArea]))
        let performed = SnapSoundTests.Speaker()
        PanelContextMenus.nodes = { ContextMenuBuilder.nodes(for: .panel($0), registry: registry, shortcuts: shortcuts) }
        PanelContextMenus.perform = { performed.played.append($0.rawValue) }
        defer {
            PanelContextMenus.nodes = nil
            PanelContextMenus.perform = nil
        }
        #expect(PanelContextMenus.menu(for: .swatchesArea).map(\.title) == ["New Swatch…"])
        let nodes: [MenuNode] = [.item(MenuItemNode(commandID: "stub.swatch", title: "New Swatch…", key: nil)), .separator, .submenu(title: "More", items: [])]
        let view = NSHostingView(rootView: VStack { ContextMenuContent(nodes: nodes) }.panelContextMenu(.swatchesArea))
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.height > 0)
        #expect(PanelContextMenus.bodyContexts["swatches"] == .swatchesArea)
        PanelContextMenus.perform?("stub.swatch")
        #expect(performed.played == ["stub.swatch"])
    }
}
