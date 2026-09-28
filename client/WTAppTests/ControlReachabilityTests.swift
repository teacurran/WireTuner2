import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The control reachability audit (rch; rch-inventory.md): every control a user can see -- menu bar
/// and context menu items, toolbar items, the Tools panel's tools, the panels and the Object panel's
/// sections -- is built, or is on the reviewed allow-list below of what is not built by design.  A
/// control that is "built" at model level but reaches the user as a placeholder, a stub, or an
/// editor squeezed to nothing fails here.
@Suite(.serialized) @MainActor struct ControlReachabilityTests {
    // MARK: The allow-list

    /// Menu, context-menu and toolbar commands that are not built, each with the page that
    /// specifies it and the task that would build it (rch-inventory.md, "Not built").  An entry that
    /// stops being a placeholder fails `theAllowListHasNoStaleEntries`: take it off.
    static let notBuilt: [CommandID: String] = [:]

    /// Object kinds the Object panel has no section of their own for, although object-panel.adoc's
    /// "Properties by kind" lists one.
    static let kindsWithoutOwnSection: [String: String] = [
        // Chart: object-panel.adoc lists no chart row by design; a chart is edited in its Chart
        // sheet (menu:Object[Chart > Edit Data…]), and the chart element section shows when an
        // element is picked with the Subselect tool (charts.adoc).
        "chart": "object-panel.adoc (no row); charts.adoc",
    ]

    /// Sections every kind gets (the common attributes, data merge, links, SVG animation).
    static let commonSections: Set<String> = ["common", "data", "links", "svgAnimation"]

    // MARK: Placeholders

    /// Whether `validation` is a placeholder's: the catalog's "Not available yet", an extension
    /// stub's "… is coming soon", or a reason saying the feature "arrives with" a later task.
    static func isPlaceholder(_ validation: CommandValidation?) -> Bool {
        guard let validation, !validation.isEnabled, let reason = validation.reason else { return false }
        return reason == Command.placeholderReason || reason.hasSuffix(ExtensionRegistry.comingSoon) || reason.contains("arrives with")
    }

    /// Every context menu a user can open, on every kind of target.
    static let contextTargets: [ContextMenuTarget] = ContextObjectKind.allCases.map { .objects([$0]) }
        + [.objects([.path, .text]), .pasteboard(overPage: true), .pasteboard(overPage: false), .guide(locked: false), .guide(locked: true),
           .presence(participantID: "p", name: "Ana"), .tab, .textEditing]
        + ContextMenuCatalog.documentedPanelItems.map { .panel($0.context) }

    /// A launched app with its front document window.
    @MainActor struct App {
        let suite = TestDefaults()
        let delegate: AppDelegate
        let window: DocumentWindowController

        init() throws {
            delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            window = try #require(delegate.activeDocumentWindow)
        }

        func close() {
            window.close()
            suite.remove()
        }

        /// The ids of every control a user can reach: the menu bar, every context menu, every
        /// toolbar's factory buttons and the Main toolbar's default set.
        func reachableCommands() -> [(id: CommandID, where: String)] {
            var result: [(CommandID, String)] = []
            let tree = MenuTreeBuilder.build(registry: delegate.commands, shortcuts: delegate.shortcuts)
            for case let .submenu(title, items) in tree.menus {
                result += items.flatMap(\.commandIDs).map { ($0, "menu \(title)") }
            }
            for target in ControlReachabilityTests.contextTargets {
                let nodes = ContextMenuBuilder.nodes(for: target, registry: delegate.commands, shortcuts: delegate.shortcuts)
                result += nodes.flatMap(\.commandIDs).map { ($0, "context menu \(target)") }
            }
            for toolbar in ToolbarID.allCases {
                result += delegate.toolbars.controller.defaultItems(toolbar).map { ($0, "toolbar \(toolbar.rawValue)") }
            }
            result += MainToolbarController.defaultCommands.map { ($0, "Main toolbar") }
            return result
        }
    }

    @Test func everyMenuAndToolbarItemIsBuiltOrAllowListed() async throws {
        let app = try App()
        defer { app.close() }
        let registry = app.delegate.commands
        // Placeholders are disabled whatever is selected; look with nothing selected and with a
        // path selected, so a command that only validates against a selection is seen too.
        var placeholders: Set<CommandID> = Set(registry.commands.filter { Self.isPlaceholder($0.validation()) }.map(\.id))
        let path = try #require(await app.window.documentHandle.addPath([Point(x: 0, y: 0), Point(x: 60, y: 0), Point(x: 30, y: 40)], closed: true))
        app.window.selection.model.apply([path], mode: .replace)
        placeholders.formUnion(registry.commands.filter { Self.isPlaceholder($0.validation()) }.map(\.id))
        var failures: [String] = []
        var seen: Set<CommandID> = []
        for (id, place) in app.reachableCommands() where seen.insert(id).inserted {
            guard registry.contains(id) else {
                failures.append("\(id) (\(place)) is not a registered command")
                continue
            }
            if placeholders.contains(id), Self.notBuilt[id] == nil {
                failures.append("\(id) \"\(registry.command(id)?.title ?? "")\" (\(place)) is a placeholder not on the allow-list")
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func theAllowListHasNoStaleEntries() throws {
        let app = try App()
        defer { app.close() }
        for (id, reference) in Self.notBuilt {
            let command = app.delegate.commands.command(id)
            #expect(command != nil, "\(id) (\(reference)) is not registered: take it off the allow-list")
            #expect(Self.isPlaceholder(command?.validation()), "\(id) (\(reference)) is built now: take it off the allow-list")
        }
    }

    // MARK: Tools

    /// Tools whose double-click is handled elsewhere than their descriptor's options sheet: the
    /// transformation tools open the Transform panel on their tab, the Chart tool its sheet.
    static func routesOptions(_ id: ToolID) -> Bool {
        EditingPanels.tab(for: id) != nil || id == ChartTool.id
    }

    @Test func everyToolInTheToolsPanelWorks() throws {
        let app = try App()
        defer { app.close() }
        let tools = app.delegate.tools.descriptors
        #expect(tools.count >= ToolCatalog.all.count)
        for descriptor in tools {
            #expect(!(descriptor.make() is UnimplementedTool), "\(descriptor.id) is a stub")
            if let sheet = descriptor.options?(), !Self.routesOptions(descriptor.id) {
                #expect(!(sheet is NSHostingController<ToolOptionsPlaceholderView>), "\(descriptor.id)'s options sheet is a placeholder")
            }
        }
        // Every catalog tool is in the panel.
        let ids = Set(tools.map(\.id))
        for descriptor in ToolCatalog.all { #expect(ids.contains(descriptor.id), "\(descriptor.id) is missing from the Tools panel") }
    }

    // MARK: Panels

    @Test func everyPanelIsBuiltAndInTheWindowMenu() throws {
        let app = try App()
        defer { app.close() }
        let tree = Set(MenuTreeBuilder.build(registry: app.delegate.commands, shortcuts: app.delegate.shortcuts).commandIDs)
        for descriptor in app.delegate.panels.descriptors {
            let kind = String(describing: type(of: descriptor.makeView()))
            #expect(!kind.contains("PlaceholderPanelBody"), "\(descriptor.id) is a placeholder panel")
            #expect(tree.contains(PanelCommands.ID.show(descriptor.id)), "\(descriptor.id) has no Window menu item")
        }
        // The default layout shows the Tools, Object and Layers panels.
        for id: PanelID in ["tools", "object", "layers"] { #expect(app.delegate.layout.isVisible(id), "\(id) is not in the default layout") }
    }

    // MARK: The Object panel

    /// One object of each kind object-panel.adoc lists, in `document`.
    static func objects(in document: DocumentHandle) async throws -> [(kind: String, id: OpID)] {
        var result: [(String, OpID)] = []
        func created(_ command: any WTModel.Command) async throws -> OpID {
            let node = try #require(await document.perform(command).value?.createdObjects.first)
            await document.settle()
            return node
        }
        let path = try #require(await document.addPath([Point(x: 0, y: 0), Point(x: 60, y: 0), Point(x: 30, y: 40)], closed: true))
        result.append(("path", path.opID))
        let rects = await document.addRectangles([Rect(x: 100, y: 0, width: 40, height: 40), Rect(x: 300, y: 0, width: 40, height: 40)])
        result.append(("rectangle", rects[0].opID))
        result.append(("ellipse", try await created(CreateShape(.ellipse, size: Size(width: 40, height: 30), transform: .translation(x: 160, y: 0)))))
        result.append(("polygon", try await created(CreatePolygon(PolygonShape(sides: 5, radius: 20), center: Point(x: 240, y: 20)))))
        result.append(("text block", try await created(CreateTextBlock(.area(Rect(x: 0, y: 100, width: 200, height: 40)), text: "The quokka"))))
        let loose = await document.addRectangles([Rect(x: 0, y: 200, width: 30, height: 30), Rect(x: 50, y: 200, width: 30, height: 30)])
        result.append(("group", try await created(GroupObjects(loose.map(\.opID)))))
        var pixels = Wiretuner_Doc_V1_PixelSource()
        pixels.blobSha256 = Data(repeating: 0xCD, count: 32)
        pixels.format = "public.png"
        pixels.pixelWidth = 30
        pixels.pixelHeight = 20
        pixels.mode = .rgb
        pixels.bitsPerChannel = 8
        result.append(("image", try await created(PlaceImage(pixels, name: "scan.png", dpiX: 72, dpiY: 72))))
        let label = try #require(await document.addText("Label", at: Point(x: 300, y: 300)))
        let symbol = try #require(await document.perform(ConvertToSymbol([label])).value)
        await document.settle()
        result.append(("symbol instance", try #require(symbol.createdObjects.first { document.state.nodeKind($0) == .instance })))
        result.append(("chart", try await created(CreateChart(size: Size(width: 100, height: 60), transform: .translation(x: 400, y: 100)))))
        let boxes = [rects[0].opID, rects[1].opID]
        let start = ConnectorEnd(node: NodeID(boxes[0]), side: .right, point: Point(x: 140, y: 20))
        let end = ConnectorEnd(node: NodeID(boxes[1]), side: .left, point: Point(x: 300, y: 20))
        result.append(("connector", try await created(CreateConnector(start: start, end: end))))
        let keys = await document.addRectangles([Rect(x: 0, y: 400, width: 30, height: 30), Rect(x: 200, y: 400, width: 30, height: 30)])
        result.append(("blend", try await created(Blend(keys.map(\.opID)))))
        return result
    }

    @Test func everyKindShowsItsSectionsWithHeightAtTheDefaultWindowSize() async throws {
        let app = try App()
        defer { app.close() }
        let document = app.window.documentHandle
        let registry = InspectorRegistry.standard
        let width = PanelDockController.defaultWidth - 24
        for (kind, node) in try await Self.objects(in: document) {
            let selection = Selection([SelectionID(node)])
            let model = ObjectPanelModel(document: document, selection: selection)
            let views = registry.views(for: model)
            let own = views.map(\.id).filter { !Self.commonSections.contains($0) }
            if Self.kindsWithoutOwnSection[kind] == nil {
                #expect(!own.isEmpty, "\(kind) shows no section of its own (it shows \(views.map(\.id)))")
            } else {
                #expect(own.isEmpty, "\(kind) has a section now: take it off kindsWithoutOwnSection")
            }
            #expect(views.contains { $0.id == "common" }, "\(kind) lacks the common attributes")
            for (id, view) in views {
                let hosting = NSHostingView(rootView: view.frame(width: width))
                let height = hosting.fittingSize.height
                #expect(height >= 1, "\(kind): the \(id) section renders with no height")
            }
        }
    }

    @Test func theObjectPanelKeepsItsEditorAtTheDefaultWindowSize() async throws {
        let app = try App()
        defer { app.close() }
        let document = app.window.documentHandle
        let registry = PanelRegistry()
        for (kind, node) in try await Self.objects(in: document) {
            let model = SelectionModel()
            model.set(Selection([SelectionID(node)]))
            let active = ActiveSelection(model: model, document: document)
            registry.removeAll()
            PanelCatalog.register(into: registry, selection: active)
            let layout = PanelLayoutController(registry: registry, store: nil)
            layout.load()
            let dock = PanelDockController(panels: registry, layout: layout)
            dock.view.frame = NSRect(x: 0, y: 0, width: PanelDockController.defaultWidth, height: DocumentWindowController.defaultContentSize.height)
            for _ in 0..<3 {
                try await Task.sleep(for: .milliseconds(30))
                dock.view.layoutSubtreeIfNeeded()
            }
            let properties = try #require(dock.groupViews.first { $0.group.id == "properties" })
            let body = try #require(properties.contentView.subviews.first)
            #expect(body.accessibilityIdentifier() == "panel.object")
            let minimum = body.constraints.first { $0.identifier == "NSHostingView.minHeight" }?.constant ?? 0
            #expect(minimum >= ObjectPanelBody.editorMinimumHeight, "\(kind): the Object panel's editor half has no floor (\(minimum))")
            #expect(properties.bodyScroll.contentView.bounds.height >= ObjectPanelBody.editorMinimumHeight, "\(kind): the Properties group is squeezed")
        }
    }
}
