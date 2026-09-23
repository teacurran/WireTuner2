import AppKit
import SwiftUI
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

/// Registries wired as the app wires them, for the toolbar tests.
@MainActor
final class ToolbarFixture {
    let commands = CommandRegistry()
    let panels = PanelRegistry()
    let tools = ToolRegistry()
    let layout: PanelLayoutController
    let extensions: ExtensionRegistry
    let controller: ToolbarController
    let url: URL
    private(set) var performed: [CommandID] = []

    init(url: URL = TestEnvironment.temporaryDirectory().appending(path: ToolbarStore.fileName), defaults: UserDefaults? = nil) {
        self.url = url
        tools.registerBuiltIn()
        let palette = ToolPaletteModel()
        PanelCatalog.register(into: panels)
        panels.registerIfAbsent(ToolsPanel.descriptor(model: palette))
        layout = PanelLayoutController(registry: panels)
        extensions = ExtensionRegistry(defaults: defaults)
        controller = ToolbarController(commands: commands, layout: layout, extensions: extensions, tools: tools, store: ToolbarStore(url: url))
        StandardCommands.register(into: commands)
        for command in tools.commands(activate: { _ in }, activeTool: { .pointer }) { commands.replace(command) }
        for placeholder in ToolbarCatalog.placeholders { commands.registerIfAbsent(placeholder) }
        ExtensionCommands.sync(into: commands, registry: extensions) {}
        ToolbarPanels.register(into: panels, controller: controller)
        layout.load()
        controller.perform = { [unowned self] id in
            self.performed.append(id)
            return self.commands.perform(id)
        }
    }
}

/// A drag in progress, for `ToolbarView`'s drop handling.
@MainActor
final class FakeDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(string: String?, location: NSPoint) {
        draggingPasteboard = NSPasteboard.withUniqueName()
        draggingPasteboard.clearContents()
        if let string { draggingPasteboard.setString(string, forType: .string) }
        draggingLocation = location
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}

@Suite(.serialized) @MainActor struct ToolbarTests {
    // MARK: Contents

    @Test func contentsInsertMoveAndRemoveKeepOneButtonPerCommand() throws {
        var contents = ToolbarContents()
        let defaults: [CommandID] = ["a", "b", "c"]
        #expect(contents.items(.text, defaults: defaults) == defaults)
        contents.insert("d", into: .text, at: 1, defaults: defaults)
        #expect(contents.items(.text, defaults: defaults) == ["a", "d", "b", "c"])
        contents.insert("a", into: .text, at: 3, defaults: defaults)
        #expect(contents.items(.text, defaults: defaults) == ["d", "b", "a", "c"])
        contents.insert("c", into: .text, at: 0, defaults: defaults)
        #expect(contents.items(.text, defaults: defaults) == ["c", "d", "b", "a"])
        contents.insert("e", into: .text, at: nil, defaults: defaults)
        contents.insert("f", into: .text, at: 99, defaults: defaults)
        #expect(contents.items(.text, defaults: defaults) == ["c", "d", "b", "a", "e", "f"])
        contents.remove("zz", from: .text, defaults: defaults)
        contents.remove("d", from: .text, defaults: defaults)
        #expect(contents.items(.text, defaults: defaults) == ["c", "b", "a", "e", "f"])
        contents.hiddenByViewMenu = [.info]

        let data = try JSONEncoder().encode(contents)
        #expect(try JSONDecoder().decode(ToolbarContents.self, from: data) == contents)
        let lenient = try JSONDecoder().decode(ToolbarContents.self, from: Data(#"{"items": {"text": ["x"], "bogus": ["y"]}}"#.utf8))
        #expect(lenient.items == [.text: ["x"]] && lenient.version == 1 && lenient.hiddenByViewMenu.isEmpty)
        #expect(try JSONDecoder().decode(ToolbarContents.self, from: Data("{}".utf8)) == ToolbarContents())
    }

    @Test func theStoreRoundTripsAndToleratesAMissingOrBadFile() throws {
        let url = TestEnvironment.temporaryDirectory().appending(path: "Toolbars.json")
        let store = ToolbarStore(url: url)
        #expect(store.load() == nil)
        var contents = ToolbarContents()
        contents.items[.envelope] = ["envelope.create"]
        try store.save(contents)
        #expect(store.load() == contents)
        try Data("nope".utf8).write(to: url)
        #expect(store.load() == nil)
        #expect(ToolbarStore.defaultURL.lastPathComponent == "Toolbars.json")
        let blocked = ToolbarStore(url: URL(fileURLWithPath: "/dev/null/Toolbars.json"))
        #expect(throws: (any Error).self) { try blocked.save(contents) }
    }

    @Test func thePayloadRoundTrips() {
        let fromToolbar = ToolbarDragPayload(command: "extension.union", source: .extensionOperations)
        #expect(ToolbarDragPayload(string: fromToolbar.string) == fromToolbar)
        let fromList = ToolbarDragPayload(command: "edit.copy", source: nil)
        #expect(fromList.string == "wt.toolbar:-:edit.copy")
        #expect(ToolbarDragPayload(string: fromList.string) == fromList)
        #expect(ToolbarDragPayload(string: "wt.toolbar:nope:x") == nil)
        #expect(ToolbarDragPayload(string: "other:-:x") == nil)
        #expect(ToolbarDragPayload(string: "wt.toolbar:-:") == nil)
        #expect(ToolbarDragPayload(string: "wt.toolbar") == nil)
        #expect(fromList.itemProvider().canLoadObject(ofClass: NSString.self))
    }

    // MARK: Controller

    @Test func defaultButtonsComeFromTheRegistries() {
        let fixture = ToolbarFixture()
        let controller = fixture.controller
        #expect(controller.items(.text) == ToolbarCatalog.textItems.map(\.id))
        #expect(controller.items(.envelope) == ToolbarCatalog.envelopeItems.map(\.id))
        #expect(controller.items(.extensionTools).count == 19)
        #expect(controller.items(.extensionOperations).count == 18)
        #expect(controller.items(.info).isEmpty && controller.items(.tools).isEmpty)
        #expect(controller.symbol(for: "text.align.left") == "text.alignleft")
        #expect(controller.symbol(for: "extension.union") == "square.on.square")
        #expect(controller.symbol(for: "tool.pen") == "pencil.tip")
        #expect(controller.symbol(for: "edit.copy") == nil)
        #expect(controller.title(of: "nope") == "nope")
        #expect(controller.tooltip(for: "tool.pen") == "Pen (P)")
        #expect(controller.tooltip(for: "extension.simplify") == "Simplify")
        controller.showsTooltips = false
        #expect(controller.tooltip(for: "tool.pen") == nil)
        #expect(controller.validation(of: "nope").reason == "Unknown command")
        #expect(!controller.validation(of: "text.fontFamily").isEnabled)
        #expect(controller.toolbars(showing: "extension.blend") == [.extensionOperations])
        #expect(ToolbarID.text.accessibilityIdentifier(for: "text.editor") == "toolbar.text.text.editor")
        #expect(ToolbarID.tools.panelID == ToolsPanel.id && ToolbarID.info.panelID == "toolbar.info")
        #expect(ToolbarID.allCases.allSatisfy { !$0.title.isEmpty && $0.id == $0.rawValue })
    }

    @Test func toolbarsShowHideAndViewMenuRestoresTheSameSet() {
        let fixture = ToolbarFixture()
        let controller = fixture.controller
        #expect(ToolbarID.dockable.allSatisfy { !controller.isVisible($0) }, "closed in the factory layout")
        #expect(controller.isVisible(.tools))
        controller.toggle(.text)
        controller.toggle(.info)
        #expect(controller.isVisible(.text) && controller.isVisible(.info))
        #expect(fixture.layout.layout.edge(of: fixture.layout.layout.group(containing: ToolbarID.text.panelID)!.id) == .top)
        controller.toggle(.info)
        #expect(!controller.isVisible(.info))
        controller.show(.envelope)

        controller.toggleAll()
        #expect(controller.areHiddenByViewMenu)
        #expect(ToolbarID.allCases.allSatisfy { !controller.isVisible($0) })
        let reloaded = ToolbarController(commands: fixture.commands, layout: fixture.layout, extensions: fixture.extensions, tools: fixture.tools, store: ToolbarStore(url: fixture.url))
        #expect(reloaded.contents.hiddenByViewMenu == [.text, .envelope, .tools], "persisted")
        controller.toggleAll()
        #expect(!controller.areHiddenByViewMenu)
        #expect(controller.isVisible(.text) && controller.isVisible(.envelope) && controller.isVisible(.tools) && !controller.isVisible(.info))

        // Nothing visible: View > Toolbars has nothing to hide.
        for toolbar in ToolbarID.allCases { controller.hide(toolbar) }
        controller.toggleAll()
        #expect(!controller.areHiddenByViewMenu)
    }

    @Test func customizingEditsPersistAndReset() {
        let fixture = ToolbarFixture()
        let controller = fixture.controller
        var notifications = 0
        let token = controller.observe { notifications += 1 }

        // Add a command to the Text toolbar from the Customize window.
        #expect(controller.drop(ToolbarDragPayload(command: "edit.copy", source: nil), on: .text, at: 0, modifiers: []))
        #expect(controller.items(.text).first == "edit.copy")
        #expect(notifications == 1)
        // Move it to Extension Operations (Cmd-drag).
        controller.drop(ToolbarDragPayload(command: "edit.copy", source: .text), on: .extensionOperations, at: 2, modifiers: [.command])
        #expect(!controller.items(.text).contains("edit.copy"))
        #expect(controller.items(.extensionOperations)[2] == "edit.copy")
        // Duplicate it to the Tools panel (Cmd+Option-drag).
        controller.drop(ToolbarDragPayload(command: "edit.copy", source: .extensionOperations), on: .tools, at: nil, modifiers: [.command, .option])
        #expect(controller.items(.tools) == ["edit.copy"] && controller.items(.extensionOperations).contains("edit.copy"))
        // Reorder within one toolbar.
        controller.move("extension.union", from: .extensionOperations, to: .extensionOperations, at: 5)
        #expect(controller.items(.extensionOperations).firstIndex(of: "extension.union") == 4)
        // An unknown command is refused.
        #expect(!controller.drop(ToolbarDragPayload(command: "nope", source: nil), on: .text, at: 0, modifiers: []))
        // Dragged off the toolbar: removed.
        controller.dragEnded(ToolbarDragPayload(command: "edit.copy", source: .tools), accepted: false)
        #expect(controller.items(.tools).isEmpty)
        controller.dragEnded(ToolbarDragPayload(command: "edit.copy", source: .extensionOperations), accepted: true)
        controller.dragEnded(ToolbarDragPayload(command: "edit.copy", source: nil), accepted: false)
        #expect(controller.items(.extensionOperations).contains("edit.copy"))

        // Each state survives relaunch.
        let relaunched = ToolbarController(commands: fixture.commands, layout: fixture.layout, extensions: fixture.extensions, tools: fixture.tools, store: ToolbarStore(url: fixture.url))
        #expect(relaunched.items(.extensionOperations) == controller.items(.extensionOperations))

        controller.reset()
        #expect(controller.contents.items.isEmpty)
        #expect(controller.items(.extensionOperations) == controller.defaultItems(.extensionOperations))
        let afterReset = ToolbarController(commands: fixture.commands, layout: fixture.layout, extensions: fixture.extensions, tools: fixture.tools, store: ToolbarStore(url: fixture.url))
        #expect(afterReset.contents.items.isEmpty)
        let count = notifications
        controller.reset()
        #expect(notifications == count, "no change, no notification")
        controller.stopObserving(token)
        controller.add("edit.paste", to: .info)
        #expect(notifications == count)
        controller.remove("edit.paste", from: .info)
        #expect(controller.lastSaveError == nil)

        // Without a store (tests), edits stay in memory.
        let memory = ToolbarController(commands: fixture.commands, layout: fixture.layout, extensions: fixture.extensions, tools: fixture.tools)
        memory.add("edit.copy", to: .info)
        #expect(memory.items(.info) == ["edit.copy"])
    }

    @Test func dragRulesAndClicksWhileCustomizing() {
        let fixture = ToolbarFixture()
        let controller = fixture.controller
        #expect(!controller.canDrag("edit.copy", modifiers: []), "not customizing, no Command")
        #expect(controller.canDrag("edit.copy", modifiers: [.command]))
        #expect(!controller.canDrag("text.fontFamily", modifiers: [.command]), "disabled buttons cannot be dragged")
        var selected: CommandID?
        controller.onSelectCommand = { selected = $0 }
        controller.setCustomizing(true)
        controller.setCustomizing(true)
        #expect(controller.canDrag("edit.copy", modifiers: []))
        #expect(!controller.press("edit.copy"))
        #expect(selected == "edit.copy" && controller.highlighted == "edit.copy")
        #expect(fixture.performed.isEmpty)
        controller.setCustomizing(false)
        #expect(controller.highlighted == nil)

        // Outside customizing a click runs the command; a tool extension ends Repeat.
        var sample = fixture.extensions.descriptor(for: "fractalize")!
        sample.run = { _ in [:] }
        fixture.extensions.replace(sample)
        fixture.extensions.perform("fractalize")
        #expect(fixture.extensions.repeatState != nil)
        controller.press("tool.mirror")
        #expect(fixture.performed == ["tool.mirror"])
        #expect(fixture.extensions.repeatState == nil)
        controller.press("edit.copy")
        #expect(fixture.performed.last == "edit.copy")
    }

    @Test func turnedOffExtensionsLeaveTheirToolbars() {
        let fixture = ToolbarFixture()
        fixture.extensions.setEnabled(false, category: "Path Operations")
        #expect(!fixture.controller.items(.extensionOperations).contains("extension.union"))
        #expect(fixture.controller.items(.extensionOperations).contains("extension.simplify"))
        fixture.extensions.setEnabled(false, "tool.chart")
        #expect(!fixture.controller.items(.extensionTools).contains("tool.chart"))
    }

    // MARK: Info toolbar

    @Test func infoReadoutsFromTheStubTools() {
        let environment = TestEnvironment()
        let host = RecordingHost()
        let manager = ToolManager(registry: environment.tools, context: ToolContext(document: .memory(title: "Info"), host: host), initialTool: .pointer)
        let fixture = ToolbarFixture()
        fixture.controller.attach(infoSource: manager)

        // Pointer: position.
        manager.pointerMoved(TestEvents.point(10, 20))
        #expect(fixture.controller.info.info == ToolInfo(position: Point(x: 10, y: 20)))
        // Rotate: angle and centre.
        manager.select("rotate")
        manager.mouseDown(TestEvents.point(0, 0))
        manager.mouseDragged(TestEvents.point(10, -10))
        let rotate = fixture.controller.info.info
        #expect(rotate.center == Point(x: 0, y: 0))
        #expect(abs((rotate.angle ?? 0) - 45) < 1e-9)
        manager.mouseUp(TestEvents.point(10, -10))
        #expect(fixture.controller.info.info.angle == nil)
        // Polygon: sides.
        manager.select("polygon")
        manager.mouseDown(TestEvents.point(0, 0))
        manager.mouseDragged(TestEvents.point(3, 4))
        #expect(fixture.controller.info.info.sides == 5)
        #expect(fixture.controller.info.info.delta == Vector(dx: 3, dy: 4))
        // Any other stub: the delta.
        manager.select("bezigon")
        manager.mouseDown(TestEvents.point(1, 1))
        manager.mouseDragged(TestEvents.point(2, 3))
        #expect(fixture.controller.info.info.delta == Vector(dx: 1, dy: 2) && fixture.controller.info.info.sides == nil)

        let tool = UnimplementedTool(id: "rotate", title: "Rotate")
        tool.mouseDragged(TestEvents.point(5, 5))
        #expect(tool.info == ToolInfo(), "no press, no readout")

        fixture.controller.attach(infoSource: nil)
        #expect(fixture.controller.info.info == ToolInfo())
    }

    @Test func infoFieldsFormatOnlyWhatIsSet() {
        #expect(InfoReadout.fields(ToolInfo()).isEmpty)
        let info = ToolInfo(position: Point(x: 1.5, y: 2), delta: Vector(dx: 3, dy: 4), angle: 45, center: Point(x: 0, y: 0), radius: 7.25, sides: 6, objectKind: "Path")
        let fields = InfoReadout.fields(info)
        #expect(fields.map(\.id) == ["position", "delta", "angle", "center", "radius", "sides", "object"])
        #expect(fields[0].value == "1.5, 2 pt")
        #expect(fields[2].value == "45°")
        #expect(fields[5].value == "6")
        #expect(ToolInfo(position: Point(x: 1, y: 1)).merged(with: ToolInfo(sides: 3)) == ToolInfo(position: Point(x: 1, y: 1), sides: 3))
        #expect(ToolReadout.kind(for: "scale") == .transform)
        #expect(ToolReadout.kind(for: "polygon") == .sides(5))
        #expect(ToolReadout.kind(for: "pen") == .delta)
        let model = InfoToolbarModel()
        model.info = info
        let hosting = NSHostingView(rootView: InfoReadoutView(model: model))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0)
    }

    // MARK: Views

    @Test func theViewFollowsTheControllerAndTakesDrops() {
        let fixture = ToolbarFixture()
        let controller = fixture.controller
        let view = ToolbarView(controller: controller, toolbar: .text)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 30)
        view.layoutSubtreeIfNeeded()
        view.layout()
        #expect(view.isHorizontal && view.stack.orientation == .horizontal)
        #expect(view.buttons.map(\.command) == controller.items(.text))
        #expect(view.intrinsicContentSize.width > 0)
        let first = view.buttons[0]
        #expect(first.accessibilityIdentifier() == "toolbar.text.text.fontFamily")
        #expect(!first.isEnabled)
        #expect(first.toolTip == Command.placeholderReason)

        // Tooltips follow *Show tooltips*; highlight follows the Customize window.
        controller.add("edit.copy", to: .text, at: 0)
        #expect(view.buttons.first?.command == "edit.copy")
        #expect(view.buttons.first?.isEnabled == true)
        #expect(view.buttons.first?.toolTip == "Copy (⌘C)")
        controller.showsTooltips = false
        #expect(view.buttons.first?.toolTip == nil)
        controller.highlighted = "edit.copy"
        #expect(view.buttons.first?.isHighlightedForCustomizing == true)
        #expect(view.buttons.first?.layer?.borderWidth == 2)

        // A checked command shows on.
        controller.add("tool.pointer", to: .text, at: 0)
        #expect(view.buttons.first?.state == .on)
        controller.remove("tool.pointer", from: .text)

        // Drops.
        let insertion = view.insertionIndex(at: NSPoint(x: 0, y: 10))
        #expect(insertion == 0)
        #expect(view.insertionIndex(at: NSPoint(x: 10_000, y: 10)) == view.buttons.count)
        let drop = FakeDraggingInfo(string: ToolbarDragPayload(command: "edit.paste", source: nil).string, location: NSPoint(x: 10_000, y: 10))
        #expect(view.draggingEntered(drop) == .move)
        #expect(view.draggingUpdated(drop) == .move)
        #expect(view.performDragOperation(drop))
        #expect(controller.items(.text).last == "edit.paste")
        let junk = FakeDraggingInfo(string: "hello", location: .zero)
        #expect(view.draggingEntered(junk) == [])
        #expect(!view.performDragOperation(junk))
        #expect(!view.performDragOperation(FakeDraggingInfo(string: nil, location: .zero)))

        // A column when taller than wide.
        view.frame = NSRect(x: 0, y: 0, width: 30, height: 600)
        view.layout()
        #expect(view.stack.orientation == .vertical)
        view.layoutSubtreeIfNeeded()
        #expect(view.insertionIndex(at: NSPoint(x: 10, y: 10_000)) == 0)

        // Window updates revalidate.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        window.contentView = NSView()
        #expect(view.window == nil)
    }

    @Test func buttonsRunCommandsAndDragOff() {
        let fixture = ToolbarFixture()
        let controller = fixture.controller
        controller.add("edit.copy", to: .info)
        let view = ToolbarView(controller: controller, toolbar: .info)
        #expect(view.readout != nil)
        let button = view.buttons[0]
        #expect(button.payload == ToolbarDragPayload(command: "edit.copy", source: .info))
        button.pressed(nil)
        #expect(fixture.performed == ["edit.copy"])
        #expect(ToolbarButton.sourceOperations == [.move, .copy, .delete])

        // Pressing with a drag allowed but no drag following is a click.
        controller.setCustomizing(true)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        button.mouseDown(with: event)
        #expect(controller.highlighted == "edit.copy")
        controller.setCustomizing(false)

        // A disabled button neither drags nor clicks.
        controller.add("text.fontFamily", to: .info)
        view.buttons.last?.mouseDown(with: event)
        controller.remove("text.fontFamily", from: .info)

        button.dragEnded(operation: .move)
        #expect(controller.items(.info) == ["edit.copy"])
        button.dragEnded(operation: [])
        #expect(controller.items(.info).isEmpty)
        #expect(view.buttons.isEmpty)
    }

    @Test func buttonsWithoutASymbolShowTheirTitle() {
        let fixture = ToolbarFixture()
        fixture.controller.add("edit.copy", to: .envelope, at: 0)
        let view = ToolbarView(controller: fixture.controller, toolbar: .envelope)
        #expect(view.buttons[0].title == "Copy")
        #expect(view.buttons[1].image != nil)
        let representable = NSHostingView(rootView: ToolbarViewRepresentable(controller: fixture.controller, toolbar: .envelope))
        representable.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
        representable.layoutSubtreeIfNeeded()
        #expect(representable.fittingSize.height >= 0)
    }

    // MARK: Commands and install

    @Test func windowAndViewMenuCommands() {
        let fixture = ToolbarFixture()
        var customized = 0
        for command in ToolbarCommands.commands(controller: fixture.controller, customize: { customized += 1 }) { fixture.commands.replace(command) }
        let commands = fixture.commands
        ToolbarPanels.register(into: fixture.panels, controller: fixture.controller)
        let panelView = ToolbarPanels.descriptors(controller: fixture.controller)[0].makeView()
        #expect((panelView as? ToolbarView)?.toolbar == .text)
        #expect(commands.validate(ToolbarCommands.ID.show(.text))?.isChecked == false)
        #expect(commands.perform(ToolbarCommands.ID.show(.text)))
        #expect(commands.validate(ToolbarCommands.ID.show(.text))?.isChecked == true)
        #expect(commands.validate(ToolbarCommands.ID.toggleAll)?.isChecked == true)
        #expect(commands.perform(ToolbarCommands.ID.toggleAll))
        #expect(commands.validate(ToolbarCommands.ID.toggleAll)?.isChecked == false)
        #expect(commands.perform(ToolbarCommands.ID.customize))
        #expect(customized == 1)
        fixture.controller.add("edit.copy", to: .text)
        #expect(commands.perform(ToolbarCommands.ID.reset))
        #expect(fixture.controller.contents.items.isEmpty)

        let tree = MenuTreeBuilder.build(registry: commands, shortcuts: ShortcutSet.builtInDefault(commands: commands.commands))
        let window = tree.items(inMenu: "Window") ?? []
        let toolbars = window.first { $0.title == "Toolbars" }
        guard case let .submenu(_, items)? = toolbars else { Issue.record("Window > Toolbars"); return }
        #expect(items.compactMap(\.title) == ["Text", "Info", "Envelope", "Extension Tools", "Extension Operations", "Customize…", "Reset Toolbars"])
        // The toolbars are not listed with the panels.
        let panelItems = PanelCommands.commands(panels: fixture.panels, layout: fixture.layout).map(\.title)
        #expect(!panelItems.contains("Info") && panelItems.contains("Tools"))
    }

    @Test func featuresInstallEverything() {
        let suite = TestDefaults()
        let environment = TestEnvironment()
        StandardCommands.register(into: environment.commands)
        let features = ToolbarFeatures(commands: environment.commands, layout: environment.layout, tools: environment.tools, defaults: suite.defaults, store: nil)
        let palette = ToolPaletteModel()
        var performed: [CommandID] = []
        var menuChanges = 0
        features.onMenuChange = { menuChanges += 1 }
        features.install(commands: environment.commands, panels: environment.panels, palette: palette, preferences: environment.preferences) { id in
            performed.append(id)
            return true
        }
        #expect(environment.commands.contains(ExtensionCommands.ID.manage))
        #expect(environment.commands.contains("text.fontFamily"))
        #expect(environment.panels.contains("toolbar.text"))
        #expect(features.controller.press("edit.copy"))
        #expect(performed == ["edit.copy"])

        // Show tooltips follows the preference.
        environment.preferences.set(false, for: PreferenceCatalog.Panels.showTooltips)
        #expect(!features.controller.showsTooltips)
        environment.preferences.set(true, for: PreferenceCatalog.General.smallerHandles)
        #expect(!features.controller.showsTooltips)

        // Turning an extension off rebuilds the menu.
        features.extensions.setEnabled(false, "union")
        #expect(menuChanges == 1)
        #expect(environment.commands.command(ExtensionRegistry.commandID(for: "union"))?.menuPath == nil)

        // The Tools panel draws its added buttons.
        #expect(palette.extraItems != nil)
        let body = NSHostingView(rootView: ToolsPanelBody(model: palette))
        body.frame = NSRect(x: 0, y: 0, width: 84, height: 600)
        body.layoutSubtreeIfNeeded()

        let manage = features.showManageExtensions()
        #expect(manage.identifier?.rawValue == "extensions.manage")
        features.manageExtensions.close()
        #expect(environment.commands.perform(ExtensionCommands.ID.manage))
        features.manageExtensions.close()

        #expect(environment.commands.perform(ToolbarCommands.ID.customize))
        let customize = features.showCustomize()
        #expect(features.controller.isCustomizing)
        #expect(features.showCustomize() === customize)
        customize.close()
        #expect(!features.controller.isCustomizing)
    }

    @Test func theCustomizeWindowListsSearchesAndSelects() {
        let fixture = ToolbarFixture()
        let window = CustomizeToolbarsWindowController(controller: fixture.controller)
        let model = window.model
        window.show()
        #expect(fixture.controller.isCustomizing)
        let groups = model.groups
        #expect(groups.first?.title == "WireTuner")
        #expect(groups.contains { $0.title == "Tools" && $0.commands.contains("tool.pen") })
        #expect(groups.contains { $0.title == "Tools/Commands" && $0.commands.contains("text.fontFamily") })
        model.query = "union"
        // Union is both menu:Modify[Combine > Union] and menu:Extensions[Path Operations > Union].
        #expect(model.groups.map(\.title) == ["Modify", "Extensions"])
        model.query = "zzzz"
        #expect(model.groups.isEmpty)
        model.query = ""

        #expect(model.selectionPlacement == "")
        model.selection = "extension.union"
        #expect(fixture.controller.highlighted == "extension.union")
        #expect(model.selectionPlacement == "On Extension Operations")
        model.selection = "edit.copy"
        #expect(model.selectionPlacement == "On no toolbar")
        // A button clicked while customizing selects its command.
        fixture.controller.press("tool.mirror")
        #expect(model.selection == "tool.mirror")

        let hosting = NSHostingView(rootView: CustomizeToolbarsView(model: model) {})
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 520)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0)

        window.makeView().done()
        #expect(!fixture.controller.isCustomizing && model.selection == nil)
        #expect(CustomizeToolbarsModel.category(of: Command.placeholder(id: "tool.x", title: "X")) == "Tools")
    }
}
