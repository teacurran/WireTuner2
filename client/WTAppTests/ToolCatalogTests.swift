import AppKit
import SwiftUI
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

@Suite @MainActor struct ToolCatalogTests {
    /// The registry snapshot (BASIC-008): every tool of toolbars.adoc with its keys, flyout,
    /// section, options and help page.  Adding a tool without deciding its shortcut (an empty
    /// list is a decision) or its help page fails here.
    static let snapshot: [String] = [
        "pointer v,0 - tools options selecting", "subselect a,1 - tools options selecting", "lasso l - tools options selecting",
        "page d - tools - pages", "text t - tools - creating-text",
        "pen p,6 pen tools - pen-bezigon", "bezigon b,5 pen tools - pen-bezigon",
        "pencil y,9 pencil tools options freeform", "variableStrokePen - pencil tools options freeform", "calligraphicPen - pencil tools options freeform",
        "line n,4 - tools - rectangles-ellipses-lines",
        "rectangle r,2 rectangle tools - rectangles-ellipses-lines", "polygon g rectangle tools options polygons-stars",
        "ellipse o,3 ellipse tools - rectangles-ellipses-lines", "spiral - ellipse tools options spirals-arcs", "arc - ellipse tools options spirals-arcs",
        "freeform f freeform tools options editing-paths", "roughen - freeform tools options path-effects", "bend - freeform tools options path-effects",
        "fisheyeLens - freeform tools options path-effects", "smudge - freeform tools options path-effects", "shadow - freeform tools options path-effects",
        "mirror - freeform tools options path-effects", "rotation3D - freeform tools options path-effects",
        "knife k,7 knife tools options editing-paths", "eraser e knife tools options editing-paths",
        "trace 8 - tools options tracing", "eyedropper i - tools - applying-color",
        "extrude x effects tools - extrude", "blend w effects tools - blends", "perspective - effects tools - perspective",
        "graphicHose shift+h - tools options graphic-hose", "chart - - tools options charts", "connector - - tools - connectors",
        "action - - tools - interactivity", "outputArea - - tools - output-area",
        "rotate - transform tools options transforming", "scale - transform tools options transforming",
        "skew - transform tools options transforming", "reflect - transform tools options transforming",
        "zoom z - view - document-view", "hand h - view - document-view",
    ]

    static func line(_ descriptor: ToolDescriptor) -> String {
        let keys = descriptor.shortcuts.isEmpty ? "-" : descriptor.shortcuts.map(\.canonical).joined(separator: ",")
        return [descriptor.id.rawValue, keys, descriptor.group?.rawValue ?? "-", descriptor.section.rawValue, descriptor.options == nil ? "-" : "options", descriptor.helpSlug].joined(separator: " ")
    }

    @Test func everyToolIsRegisteredWithItsDecisions() {
        #expect(ToolCatalog.all.map(Self.line) == Self.snapshot)
        #expect(ToolCatalog.all.allSatisfy { !$0.helpSlug.isEmpty && !$0.title.isEmpty })
        #expect(Set(ToolCatalog.all.map(\.id)).count == ToolCatalog.all.count)
        for descriptor in ToolCatalog.all {
            #expect(NSImage(systemSymbolName: descriptor.symbolName, accessibilityDescription: nil) != nil, "\(descriptor.symbolName) is an SF Symbol")
        }
        // Tools and their digits never collide with each other or any other default binding.
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        let tools = ToolRegistry()
        tools.registerBuiltIn()
        SelectionCommands.install(commands: registry, tools: tools)
        for command in tools.commands(activate: { _ in }, activeTool: { nil }) { registry.replace(command) }
        ViewCommands.install(into: registry, target: { nil }, newDocument: {})
        ToolPanelCommands.install(into: registry, palette: ToolPaletteModel()) { nil }
        WindowTabCommands.install(into: registry)
        let conflicts = ShortcutSet.builtInDefault(commands: registry.commands).conflicts()
        #expect(conflicts.isEmpty, "\(conflicts)")
        #expect(tools.descriptor(for: .pointer)?.make() is PointerTool)
        #expect(tools.members(of: .pen).map(\.id) == ["pen", "bezigon"])
        #expect(ToolRegistry.builtIn().count == 42)
    }

    @Test func descriptorsDescribeThemselves() {
        let pen = ToolCatalog.all.first { $0.id == "pen" }!
        #expect(pen.tooltip == "Pen (P)")
        #expect(pen.shortcut == KeyEquivalent("p"))
        let chart = ToolCatalog.all.first { $0.id == "chart" }!
        #expect(chart.tooltip == "Chart" && chart.shortcut == nil)
        let legacy = ToolDescriptor(id: "x", title: "X", symbolName: "circle", shortcut: nil, helpSlug: "x") { PanTool() }
        #expect(legacy.shortcuts.isEmpty)
        #expect(pen.delivering { PanTool() }.make() is PanTool)
        #expect(FlyoutGroup(rawValue: "pen") == .pen)
    }

    @Test func unimplementedToolsShowTheHUDAndWriteNothing() async throws {
        let environment = TestEnvironment()
        let controller = DocumentWindowController(document: .placeholder(title: "HUD"), environment: environment.document)
        defer { controller.close() }
        for descriptor in ToolCatalog.all {
            controller.toolManager.select(descriptor.id)
            #expect(controller.toolManager.activeToolID == descriptor.id)
            guard descriptor.make() is UnimplementedTool else { continue }
            controller.toolManager.mouseDown(TestEvents.point(10, 10))
            controller.toolManager.mouseUp(TestEvents.point(10, 10))
            #expect(controller.canvas.hudMessage == "The \(descriptor.title) tool is coming soon")
            #expect(controller.statusBar.message.stringValue == "The \(descriptor.title) tool is coming soon")
        }
        #expect(controller.documentHandle.changeCount == 0, "the outbox stays empty")
        #expect(!controller.canvas.hud.isHidden)
        controller.canvas.hideHUD()
        #expect(controller.canvas.hud.isHidden && controller.canvas.hudMessage == nil)
    }

    @Test func theHUDHidesItselfAfterAWhile() async throws {
        let canvas = CanvasView(document: .placeholder(title: "H"))
        canvas.showHUD("Hello")
        canvas.showHUD("Again")
        #expect(canvas.hudMessage == "Again")
        try await Task.sleep(for: CanvasView.hudDuration + .milliseconds(300))
        #expect(canvas.hudMessage == nil)
    }
}

@Suite @MainActor struct ToolPaletteTests {
    private func palette() -> (ToolPaletteModel, ToolRegistry, [ToolID]) {
        let registry = ToolRegistry()
        registry.registerBuiltIn()
        let model = ToolPaletteModel()
        model.reload(from: registry)
        final class Box { var selected: [ToolID] = [] }
        let box = Box()
        model.select = { id in
            box.selected.append(id)
            model.activeToolID = id
        }
        return (model, registry, box.selected)
    }

    @Test func slotsShowOneMemberPerFlyout() {
        let (model, _, _) = palette()
        let slots = model.slots(in: .tools)
        #expect(slots.first == .tool(.pointer))
        #expect(slots.contains(.flyout(.pen, visible: "pen", members: ["pen", "bezigon"])))
        #expect(slots.count == 21, "40 tools, 27 of them in 8 flyouts")
        #expect(model.slots(in: .view) == [.tool(.zoom), .tool(.hand)])
        #expect(ToolSlot.flyout(.pen, visible: "bezigon", members: []).id == "flyout.pen")
        #expect(ToolSlot.tool(.hand).id == "hand" && ToolSlot.tool(.hand).visibleTool == .hand)
        model.choose("bezigon")
        #expect(model.visibleMember(of: .pen) == "bezigon")
        #expect(model.slots(in: .tools).contains(.flyout(.pen, visible: "bezigon", members: ["pen", "bezigon"])))
        #expect(model.visibleMember(of: FlyoutGroup(rawValue: "none")) == nil)
    }

    @Test func pressingTheVisibleToolsKeyCyclesItsFlyout() {
        let (model, _, _) = palette()
        model.pressShortcut("pencil")
        #expect(model.activeToolID == "pencil")
        model.pressShortcut("pencil")
        #expect(model.activeToolID == "variableStrokePen" && model.visibleMember(of: .pencil) == "variableStrokePen")
        model.pressShortcut("pencil")
        #expect(model.activeToolID == "calligraphicPen")
        model.pressShortcut("pencil")
        #expect(model.activeToolID == "pencil")
        model.pressShortcut("bezigon")
        #expect(model.activeToolID == "bezigon")
        model.pressShortcut("bezigon")
        #expect(model.activeToolID == "pen", "the visible tool's own key advances")
        model.pressShortcut("pointer")
        #expect(model.activeToolID == .pointer)
        model.pressShortcut("pointer")
        #expect(model.activeToolID == .pointer, "a tool outside a flyout stays")
        // Another member's key while one is current selects it directly.
        model.pressShortcut("pen")
        model.pressShortcut("bezigon")
        #expect(model.activeToolID == "bezigon")
        // The slot is remembered when the current tool changes elsewhere (a command).
        model.activeToolID = "polygon"
        #expect(model.visibleMember(of: .rectangle) == "polygon")
        model.activeToolID = nil
        model.pressShortcut("rectangle")
        #expect(model.activeToolID == .rectangle)
    }

    @Test func slotsPersistInThePanelLayout() {
        let (model, _, _) = palette()
        let panels = PanelRegistry()
        let layout = PanelLayoutController(registry: panels)
        model.slotStore = (get: { layout.flyoutSlot($0) }, set: { layout.setFlyoutSlot($0, to: $1) })
        model.choose("arc")
        #expect(layout.layout.flyoutSlots == ["ellipse": "arc"])
        #expect(layout.flyoutSlot("ellipse") == "arc")
        layout.update { $0.flyoutSlots["ellipse"] = "unknown" }
        #expect(model.visibleMember(of: .ellipse) == "ellipse")
    }

    @Test func optionsOpenOnlyForToolsThatHaveThem() {
        let (model, _, _) = palette()
        var presented: [ToolID] = []
        model.presentOptions = { presented.append($0.id) }
        model.showOptions(.pointer)
        model.showOptions("pen")
        model.showOptions("missing")
        #expect(presented == [.pointer])

        let environment = TestEnvironment()
        let controller = DocumentWindowController(document: .placeholder(title: "Options"), environment: environment.document)
        defer { controller.close() }
        let sheet = controller.presentToolOptions(ToolCatalog.all[0])
        #expect(sheet?.identifier?.rawValue == "tool-options.pointer")
        #expect(controller.presentToolOptions(ToolCatalog.all.first { $0.id == "pen" }!) == nil)
        let options = ToolOptionsPlaceholder.controller(title: "Lasso")
        #expect(options.title == "Lasso Options")
        let window = NSWindow(contentViewController: options)
        ToolOptionsPlaceholder.close(window)
        ToolOptionsPlaceholder.close(nil)
        if let sheet { ToolOptionsPlaceholder.close(sheet) }
        let view = NSHostingView(rootView: ToolOptionsPlaceholderView(title: "Pencil") {})
        #expect(view.fittingSize.width > 0)
    }

    @Test func wellsFollowTheSelectionAndEditTheDefaults() {
        let (model, _, _) = palette()
        #expect(model.wells == .standard && model.canEditWells)
        model.swapWells()
        #expect(model.wells.fill == .solid(Color(white: 0)) && model.wells.stroke == .solid(Color(white: 1)))
        model.activeWell = .stroke
        model.setActiveWellToNone()
        #expect(model.wells.stroke == Paint.none)
        model.activeWell = .fill
        model.setActiveWellToNone()
        #expect(model.wells.fill == Paint.none)
        model.restoreDefaultWells()
        #expect(model.wells == .standard)

        let red = Paint.solid(Color(red: 1, green: 0, blue: 0))
        model.selectionWells = WellColors(stroke: red, fill: .none)
        #expect(model.wells.stroke == red && !model.canEditWells)
        model.swapWells()
        model.setActiveWellToNone()
        model.restoreDefaultWells()
        #expect(model.wells.stroke == red, "the selection's colours wait for the appearance commands")

        let path = DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1))
        #expect(WellColors.of(.fill(FillItem(path: path, paint: red))) == WellColors(stroke: .none, fill: red))
        #expect(WellColors.of(.stroke(StrokeItem(path: path, paint: red))) == WellColors(stroke: red, fill: .none))
        let styled = PathItem(path: path, appearance: .fillAndStroke(fill: Color(white: 1), stroke: Color(white: 0)))
        #expect(WellColors.of(.path(styled)) == .standard)
        #expect(WellColors.of(.path(PathItem(path: path, appearance: Appearance()))) == WellColors(stroke: .none, fill: .none))
        #expect(WellColors.of(.group(GroupItem(children: [.fill(FillItem(path: path, paint: red))])))?.fill == red)
        #expect(WellColors.of(.group(GroupItem(children: []))) == nil)
        #expect(model.tooltip("Pen") == "Pen")
        model.showsTooltips = false
        #expect(model.tooltip("Pen") == nil)
    }

    @Test func snapTogglesChangeViewStateOnly() {
        let environment = TestEnvironment()
        let controller = DocumentWindowController(document: .placeholder(title: "Snap"), environment: environment.document)
        defer { controller.close() }
        var changes = 0
        controller.onViewStateChange = { _ in changes += 1 }
        let registry = CommandRegistry()
        let palette = ToolPaletteModel()
        ToolPanelCommands.install(into: registry, palette: palette) { controller }
        for kind in SnapSettings.Kind.allCases {
            let before = controller.snap[kind]
            #expect(registry.validate(ToolPanelCommands.snapCommandID(kind)) == .checked(before))
            #expect(registry.perform(ToolPanelCommands.snapCommandID(kind)))
            #expect(controller.snap[kind] == !before)
            #expect(!kind.title.isEmpty && NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil) != nil)
        }
        #expect(changes == 4)
        #expect(controller.documentHandle.changeCount == 0, "no change is produced")
        #expect(controller.currentState.snap == controller.snap)
        let empty = CommandRegistry()
        ToolPanelCommands.install(into: empty, palette: palette) { nil }
        #expect(empty.validate(ToolPanelCommands.snapCommandID(.grid))?.isEnabled == false)
        #expect(empty.perform(ToolPanelCommands.ID.swap))
        #expect(empty.perform(ToolPanelCommands.ID.none))
        #expect(empty.perform(ToolPanelCommands.ID.restoreDefault))
        palette.selectionWells = WellColors(stroke: .none, fill: .none)
        #expect(empty.validate(ToolPanelCommands.ID.swap)?.isEnabled == false)
    }

    @Test func thePanelRendersVerticallyAndHorizontally() {
        let (model, _, _) = palette()
        model.viewMode = .keyline
        model.snap = SnapSettings()
        model.selectionWells = WellColors(stroke: .solid(Color(white: 0.5)), fill: .none)
        model.activeToolID = "pen"
        for size in [NSSize(width: 84, height: 600), NSSize(width: 700, height: 44)] {
            let view = NSHostingView(rootView: ToolsPanelBody(model: model))
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            #expect(view.frame.size == size)
        }
        let descriptor = ToolsPanel.descriptor(model: model)
        #expect(descriptor.id == "tools" && descriptor.defaultGroup == "Tools" && descriptor.icon == "hammer")
        #expect(descriptor.makeView() is NSHostingView<ToolsPanelBody>)
    }
}
