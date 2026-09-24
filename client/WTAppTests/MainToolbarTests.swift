import AppKit
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

/// BASIC-010: the Main toolbar is made of registry commands.
@Suite(.serialized) @MainActor struct MainToolbarTests {
    private func fixture() -> (TestEnvironment, DocumentWindowController, MainToolbarController) {
        let environment = TestEnvironment()
        StandardCommands.register(into: environment.commands)
        PanelCatalog.register(into: environment.panels)
        PanelCommands.sync(into: environment.commands, panels: environment.panels, layout: environment.layout)
        let controller = DocumentWindowController(document: .memory(title: "Toolbar"), environment: environment.document)
        ViewCommands.install(into: environment.commands, target: { controller }, newDocument: {})
        environment.shortcuts = ShortcutSet.builtInDefault(commands: environment.commands.commands)
        return (environment, controller, controller.mainToolbar!)
    }

    @Test func theDefaultSetIsThePagesAndEveryCommandIsOffered() {
        let (environment, controller, toolbar) = fixture()
        defer { controller.close() }
        #expect(controller.window?.toolbar === toolbar.toolbar)
        #expect(toolbar.toolbar.allowsUserCustomization && toolbar.toolbar.autosavesConfiguration)
        let defaults = toolbar.toolbarDefaultItemIdentifiers(toolbar.toolbar)
        #expect(defaults.compactMap(MainToolbarController.commandID(of:)) == MainToolbarController.defaultCommands)
        let labels = MainToolbarController.defaultCommands.map { toolbar.item(for: $0).label }
        #expect(labels == [
            "New", "Open", "Save Version", "Import", "Print", "Lock", "Unlock", "Find & Replace", "Align", "Transform",
            "Library", "Object", "Color Mixer", "Swatches", "Layers", "Share",
        ])
        let allowed = Set(toolbar.toolbarAllowedItemIdentifiers(toolbar.toolbar))
        for command in environment.commands.commands {
            #expect(allowed.contains(MainToolbarController.itemIdentifier(for: command.id)))
        }
        #expect(allowed.contains(.flexibleSpace) && allowed.contains(.space))
        #expect(MainToolbarController.commandID(of: .flexibleSpace) == nil)
        #expect(toolbar.toolbar(toolbar.toolbar, itemForItemIdentifier: .space, willBeInsertedIntoToolbar: true) == nil)
        let new = toolbar.toolbar(toolbar.toolbar, itemForItemIdentifier: MainToolbarController.itemIdentifier(for: StandardCommands.ID.new), willBeInsertedIntoToolbar: true)
        #expect(new?.toolTip == "New (⌘N)")
        #expect(toolbar.item(for: "not.registered").label == "not.registered")
        #expect(StandardCommands.commands().contains { $0.id == StandardCommands.ID.customizeToolbar && $0.action.responderSelectorName == "runToolbarCustomizationPalette:" })
    }

    @Test func eachButtonRunsItsCommandAndLockDisablesWithoutASelection() {
        let (environment, controller, toolbar) = fixture()
        defer { controller.close() }
        let object = toolbar.item(for: PanelCommands.ID.show("object"))
        #expect(toolbar.validateToolbarItem(object))
        toolbar.runItem(object)
        #expect(environment.performed.last == PanelCommands.ID.show("object"))
        for id in MainToolbarController.defaultCommands {
            toolbar.runItem(toolbar.item(for: id))
            #expect(environment.performed.last == id)
        }
        let lock = toolbar.item(for: ContextMenuCatalog.ID.lock)
        let unlock = toolbar.item(for: ContextMenuCatalog.ID.unlock)
        #expect(!toolbar.validateToolbarItem(lock) && !toolbar.validateToolbarItem(unlock))
        #expect(lock.toolTip?.contains(ViewCommands.nothingSelected) == true)
        #expect(!toolbar.validateToolbarItem(NSToolbarItem(itemIdentifier: .space)))
        toolbar.runItem(NSToolbarItem(itemIdentifier: .space))
    }

    @Test func customizationIsSharedAndSurvivesAnotherWindow() {
        let (environment, controller, _) = fixture()
        defer { controller.close() }
        let identifier = NSToolbar.Identifier("wiretuner.tests.\(UUID().uuidString)")
        defer { UserDefaults.standard.removeObject(forKey: "NSToolbar Configuration \(identifier)") }
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 800, height: 300))
        let first = MainToolbarController(environment: environment.document, window: window, identifier: identifier)
        first.toolbar.insertItem(withItemIdentifier: MainToolbarController.itemIdentifier(for: StandardCommands.ID.zoomIn), at: 0)
        let second = TestWindow.make(NSRect(x: 0, y: 0, width: 800, height: 300))
        let again = MainToolbarController(environment: environment.document, window: second, identifier: identifier)
        #expect(again.toolbar.items.first?.itemIdentifier == MainToolbarController.itemIdentifier(for: StandardCommands.ID.zoomIn))
        window.close()
        second.close()
    }
}
