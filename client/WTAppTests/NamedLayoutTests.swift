import AppKit
import SwiftUI
import Testing
@testable import WireTuner

/// BASIC-030: named panel layouts.
@Suite(.serialized) @MainActor struct NamedLayoutTests {
    @MainActor private struct Fixture {
        let commands = CommandRegistry()
        let panels = PanelRegistry()
        let layout: PanelLayoutController
        let store: NamedLayoutStore
        let controller: NamedLayoutController

        @MainActor
        init(directory: URL = TestEnvironment.temporaryDirectory()) {
            PanelCatalog.register(into: panels)
            layout = PanelLayoutController(registry: panels)
            layout.load()
            store = NamedLayoutStore(directory: directory)
            controller = NamedLayoutController(layout: layout, store: store, commands: commands)
            controller.displays = { DisplayGeometry(main: LayoutRect(x: 0, y: 0, width: 1440, height: 900), screens: [LayoutRect(x: 0, y: 0, width: 1440, height: 900)], displayIDs: ["1"]) }
            StandardCommands.register(into: commands)
            PanelCommands.sync(into: commands, panels: panels, layout: layout)
        }
    }

    @Test func theStoreKeepsOneFilePerLayout() throws {
        let fixture = Fixture()
        let store = fixture.store
        #expect(store.names().isEmpty)
        #expect(try store.load("Missing") == nil)
        try store.save(fixture.layout.layout, as: "Painting")
        try store.save(fixture.layout.layout, as: "a/b:c")
        try store.saveCurrent(fixture.layout.layout)
        #expect(store.names() == ["a-b-c", "Painting"])
        #expect(try store.load("Painting") == fixture.layout.layout)
        #expect(store.loadCurrent() == fixture.layout.layout)
        try store.delete("Painting")
        #expect(store.names() == ["a-b-c"])
        #expect(NamedLayoutStore.fileName(for: ".hidden") == "_hidden.json")
        #expect(NamedLayoutStore.defaultDirectory.lastPathComponent == "Layouts")
    }

    @Test func savingSwitchingUpdatingAndDeletingRoundTrip() throws {
        let fixture = Fixture()
        let layout = fixture.layout
        let controller = fixture.controller
        var menuChanges = 0
        controller.onMenuChange = { menuChanges += 1 }
        let factory = layout.layout

        // Save "Wide" with Layers floating.
        layout.update { $0.float(group: "layers", frame: LayoutRect(x: 100, y: 100, width: 260, height: 300)) }
        let wide = layout.layout
        controller.askName = { existing in
            #expect(existing.isEmpty)
            return "Wide"
        }
        #expect(controller.saveWithPrompt() == "Wide")
        #expect(controller.names == ["Wide"] && controller.activeName == "Wide")
        #expect(menuChanges == 1)
        controller.askName = { _ in nil }
        #expect(controller.saveWithPrompt() == nil)
        controller.askName = { _ in "  " }
        #expect(controller.saveWithPrompt() == nil)
        controller.save(as: "  ")
        controller.save(as: NamedLayoutController.currentTitle)
        #expect(controller.names == ["Wide"])

        // Back to the factory arrangement as "Current" work, then switch to Wide and back.
        controller.delete("Wide")
        #expect(controller.activeName == nil)
        layout.update { $0 = factory }
        controller.save(as: "Wide")
        try fixture.store.save(wide, as: "Wide")
        layout.update { $0.setCollapsed(true, group: "layers") }
        let working = layout.layout
        controller.applyCurrent()  // already current: nothing happens
        controller.delete("Wide")
        try fixture.store.save(wide, as: "Wide")
        controller.refresh()
        controller.apply("Wide")
        #expect(layout.layout.floating.count == 1)
        #expect(controller.activeName == "Wide")
        controller.apply("Wide")
        controller.apply("Missing")
        #expect(controller.activeName == "Wide")
        controller.applyCurrent()
        #expect(layout.layout == working, "switching away and back loses nothing")
        #expect(controller.activeName == nil)

        // Updating: save over the existing name.
        controller.apply("Wide")
        layout.update { $0.dock(group: "layers", at: .left) }
        controller.save(as: "Wide")
        #expect(try fixture.store.load("Wide")?.edge(of: "layers") == .left)
        controller.delete("Wide")
        #expect(controller.names.isEmpty && controller.activeName == nil)
        controller.delete("Wide")
        #expect(controller.lastError != nil)

        // An unreadable layout is not applied.
        try FileManager.default.createDirectory(at: fixture.store.directory, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: fixture.store.directory.appending(path: "Broken.json"))
        controller.apply("Broken")
        #expect(controller.activeName == nil && controller.lastError != nil)
    }

    @Test func aLayoutOnAMissingDisplayRestoresOntoTheMainDisplay() throws {
        let fixture = Fixture()
        var layout = fixture.layout.layout
        layout.float(group: "layers", frame: LayoutRect(x: 3000, y: 100, width: 260, height: 300))
        layout.floating[0].display = "2"
        try fixture.store.save(layout, as: "Two Screens")
        fixture.controller.refresh()
        fixture.controller.apply("Two Screens")
        let floating = fixture.layout.layout.floating[0]
        #expect(floating.display == nil)
        #expect(floating.frame.x == 40 && floating.frame.y == 900 - 300 - 40)

        // On a connected display and on screen: left alone.
        var kept = PanelLayout()
        kept.floating = [FloatingGroup(group: PanelGroup(panels: ["layers"]), frame: LayoutRect(x: 10, y: 10, width: 100, height: 100), display: "1")]
        kept.moveFloatingGroups(onto: LayoutRect(x: 0, y: 0, width: 800, height: 600), displays: ["1"], screens: [LayoutRect(x: 0, y: 0, width: 800, height: 600)])
        #expect(kept.floating[0].frame.x == 10 && kept.floating[0].display == "1")
        // No display recorded and off every screen: moved.
        kept.floating[0].display = nil
        kept.floating[0].frame.x = -5000
        kept.moveFloatingGroups(onto: LayoutRect(x: 0, y: 0, width: 800, height: 600), displays: ["1"], screens: [LayoutRect(x: 0, y: 0, width: 800, height: 600)])
        #expect(kept.floating[0].frame.x == 40)

        let current = DisplayGeometry.current()
        #expect(current.main.width > 0 || current.screens.isEmpty)
    }

    @Test func theMenuListsCurrentThenTheLayoutsThenReset() throws {
        let fixture = Fixture()
        try fixture.store.save(fixture.layout.layout, as: "B")
        try fixture.store.save(fixture.layout.layout, as: "A")
        fixture.controller.refresh()
        let tree = MenuTreeBuilder.build(registry: fixture.commands, shortcuts: ShortcutSet.builtInDefault(commands: fixture.commands.commands))
        let window = tree.items(inMenu: "Window") ?? []
        guard case let .submenu(_, items)? = window.first(where: { $0.title == "Panel Layout" }) else { Issue.record("Panel Layout"); return }
        #expect(items.compactMap(\.title) == ["Save Layout…", "Manage Layouts…", "Current", "A", "B", "Reset to Default"])
        #expect(fixture.commands.validate(NamedLayoutController.ID.current)?.isChecked == true)
        #expect(fixture.commands.perform(NamedLayoutController.ID.named("A")))
        #expect(fixture.commands.validate(NamedLayoutController.ID.named("A"))?.isChecked == true)
        #expect(fixture.commands.validate(NamedLayoutController.ID.current)?.isChecked == false)
        #expect(fixture.commands.perform(NamedLayoutController.ID.current))
        #expect(fixture.controller.activeName == nil)
        fixture.controller.askName = { _ in "C" }
        #expect(fixture.commands.perform(NamedLayoutController.ID.save))
        #expect(fixture.controller.names == ["A", "B", "C"])
        #expect(fixture.commands.perform(NamedLayoutController.ID.manage))
        fixture.controller.delete("B")
        #expect(!fixture.commands.contains(NamedLayoutController.ID.named("B")))
        #expect(fixture.commands.contains(PanelCommands.ID.resetLayout))
    }

    @Test func theNameAlertAndManageWindow() {
        let fixture = Fixture()
        let alert = NamedLayoutController.nameAlert(["One", "Two"])
        #expect((alert.accessoryView as? NSComboBox)?.numberOfItems == 2)
        #expect(alert.buttons.map(\.title) == ["Save", "Cancel"])
        fixture.controller.save(as: "One")
        let window = fixture.controller.showManage()
        #expect(window.identifier?.rawValue == "panels.layout.manage")
        #expect(fixture.controller.showManage() === window)
        window.close()
        let view = ManageLayoutsView(controller: fixture.controller)
        view.deleteSelection()
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 280)
        hosting.layoutSubtreeIfNeeded()
        #expect(fixture.controller.names == ["One"])
        ManageLayoutsView(controller: fixture.controller, selection: "One").deleteSelection()
        #expect(fixture.controller.names.isEmpty)
    }
}
