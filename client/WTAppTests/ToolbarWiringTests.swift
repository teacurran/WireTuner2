import AppKit
import Testing
@testable import WireTuner

@Suite(.serialized) @MainActor struct ToolbarWiringTests {
    @Test func theAppInstallsToolbarsExtensionsAndLayouts() {
        let suite = TestDefaults()
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = delegate.activeDocumentWindow!
        let titles = NSApp.mainMenu?.items.map(\.title) ?? []
        #expect(titles.contains("Extensions"))
        #expect(delegate.commands.contains(ToolbarCommands.ID.show(.info)))
        #expect(delegate.commands.contains(NamedLayoutController.ID.save))
        #expect(delegate.panels.contains(ToolbarID.info.panelID))

        // The Info toolbar follows the key window's tool manager.
        window.toolManager.pointerMoved(TestEvents.point(3, 4))
        #expect(delegate.toolbars.controller.info.info.position?.x == 3)
        // Choosing a tool ends Repeat.
        var sample = delegate.toolbars.extensions.descriptor(for: "fractalize")!
        sample.run = { _ in [:] }
        delegate.toolbars.extensions.replace(sample)
        #expect(delegate.menuTarget?.perform(ExtensionRegistry.commandID(for: "fractalize")) == true)
        delegate.toolPalette.choose("pen")
        #expect(delegate.toolbars.extensions.repeatState == nil)
        #expect(delegate.toolbars.parentWindow() === window.window)
        // A toolbar button runs its command through the menu target.
        #expect(delegate.toolbars.controller.press(ExtensionRegistry.commandID(for: "fractalize")))
        #expect(delegate.toolbars.extensions.repeatState?.extensionID == "fractalize")
        delegate.toolbars.controller.show(.text)
        #expect(delegate.toolbars.controller.isVisible(.text))
        // Turning an extension off rebuilds the menu bar.
        delegate.toolbars.extensions.setEnabled(false, category: "Path Operations")
        let extensions = NSApp.mainMenu?.items.first { $0.title == "Extensions" }?.submenu
        #expect(extensions?.items.contains { $0.title == "Path Operations" } == false)
        delegate.toolbars.extensions.setEnabled(true, category: "Path Operations")
        delegate.namedLayouts.save(as: "Mine")
        #expect(NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu?.items.contains { $0.title == "Panel Layout" } == true)

        for id in delegate.documents.documents.map(\.id) { delegate.documents.close(id) }
        suite.remove()
    }
}
