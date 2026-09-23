import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WireTuner

@Suite @MainActor struct PanelRegistryTests {
    @Test func registersAndOrdersByMenuOrder() throws {
        let registry = PanelRegistry()
        let counter = Counter()
        registry.onChange = { counter.bump() }
        try registry.register(PanelDescriptor(id: "b", title: "B", defaultGroup: "G", menuOrder: 20) { NSView() })
        try registry.register(PanelDescriptor(id: "a", title: "A", defaultGroup: "G", menuOrder: 10) { NSView() })
        try registry.register(PanelDescriptor(id: "c", title: "C", defaultGroup: "H", menuOrder: 10) { NSView() })
        #expect(registry.ids == ["a", "c", "b"])
        #expect(registry.descriptor(for: "a")?.title == "A")
        #expect(registry.descriptor(for: "zzz") == nil)
        #expect(registry.contains("b"))
        #expect(registry.title(for: "c") == "C")
        #expect(registry.title(for: "zzz") == "zzz")
        #expect(counter.count == 3)

        #expect(throws: PanelRegistry.Failure.duplicateID("a")) {
            try registry.register(PanelDescriptor(id: "a", title: "Again", defaultGroup: "G") { NSView() })
        }
        #expect(!registry.registerIfAbsent(PanelDescriptor(id: "a", title: "Again", defaultGroup: "G") { NSView() }))
        #expect(registry.registerIfAbsent(PanelDescriptor(id: "d", title: "D", defaultGroup: "G") { NSView() }))
        #expect(registry.ids.count == 4)
        #expect(counter.count == 4)
    }

    @Test func swiftUIDescriptorsHostTheirBody() {
        let descriptor = PanelDescriptor(id: "hello", title: "Hello", defaultGroup: "G", helpSlug: "hello") {
            Text("Hello")
        }
        #expect(descriptor.helpSlug == "hello")
        let view = descriptor.makeView()
        #expect(view is NSHostingView<Text>)
        #expect(view.accessibilityIdentifier() == "panel.hello")
    }

    @Test func placeholderPanelsRegisterOnce() {
        let registry = PanelRegistry()
        PlaceholderPanels.register(into: registry)
        PlaceholderPanels.register(into: registry)
        #expect(registry.ids == ["object", "layers"])
        #expect(registry.descriptor(for: "object")?.defaultGroup == "Properties")
        #expect(registry.descriptor(for: "layers")?.helpSlug == "layers")
        let body = PlaceholderPanels.layers.makeView()
        #expect(body.accessibilityIdentifier() == "panel.layers")
        #expect(body.fittingSize.width > 0)
    }

    @Test func windowMenuIsGeneratedFromTheRegistry() throws {
        let panels = PanelRegistry()
        PlaceholderPanels.register(into: panels)
        let layout = PanelLayoutController(registry: panels)
        layout.load()
        let commands = CommandRegistry()
        StandardCommands.register(into: commands)
        let added = PanelCommands.sync(into: commands, panels: panels, layout: layout)
        // menu:View[Panels] replaces the standard set's placeholder; Reset to Default is new.
        #expect(added == ["panel.show.object", "panel.show.layers", PanelCommands.ID.resetLayout])
        #expect(commands.validate(PanelCommands.ID.togglePanels)?.isEnabled == true)
        #expect(PanelCommands.sync(into: commands, panels: panels, layout: layout).isEmpty)

        let tree = MenuTreeBuilder.build(registry: commands, shortcuts: ShortcutSet.builtInDefault(commands: commands.commands))
        let window = tree.items(inMenu: "Window")!
        #expect(window.map(\.title) == ["Minimize", "Zoom", "New Window", nil, "Object", "Layers", nil, "Panel Layout", nil, "Bring All to Front"])
        #expect(window[7] == .submenu(title: "Panel Layout", items: [.item(MenuItemNode(commandID: PanelCommands.ID.resetLayout, title: "Reset to Default", key: nil))]))
        #expect(tree.items(inMenu: "View")!.contains(.item(MenuItemNode(commandID: PanelCommands.ID.togglePanels, title: "Panels", key: nil))))

        try panels.register(PanelDescriptor(id: "swatches", title: "Swatches", defaultGroup: "Assets", menuOrder: 15) { NSView() })
        #expect(PanelCommands.sync(into: commands, panels: panels, layout: layout) == ["panel.show.swatches"])
        let rebuilt = MenuTreeBuilder.build(registry: commands, shortcuts: ShortcutSet.builtInDefault(commands: commands.commands))
        #expect(rebuilt.items(inMenu: "Window")!.compactMap(\.commandID).filter { $0.rawValue.hasPrefix("panel.show.") }
            == ["panel.show.object", "panel.show.layers", "panel.show.swatches"])
    }

    @Test func panelCommandsDriveTheLayout() {
        let panels = PanelRegistry()
        PlaceholderPanels.register(into: panels)
        let layout = PanelLayoutController(registry: panels)
        layout.load()
        let commands = CommandRegistry()
        PanelCommands.sync(into: commands, panels: panels, layout: layout)

        let show = PanelCommands.ID.show("layers")
        #expect(commands.validate(show) == .checked(true))
        #expect(commands.perform(show))
        #expect(commands.validate(show) == .checked(false))
        #expect(layout.layout.group("layers")?.collapsed == true)
        #expect(commands.perform(show))
        #expect(layout.isVisible("layers"))

        #expect(commands.validate(PanelCommands.ID.togglePanels) == .checked(true))
        #expect(commands.perform(PanelCommands.ID.togglePanels))
        #expect(commands.validate(PanelCommands.ID.togglePanels) == .checked(false))
        #expect(layout.panelsHidden)

        #expect(commands.perform(PanelCommands.ID.resetLayout))
        #expect(layout.layout == layout.defaultLayout)
        #expect(commands.command(show)?.keywords.contains("Layers") == true)
    }
}
