import AppKit
import Testing
@testable import WireTuner

@Suite struct MainMenuTests {
    @Test @MainActor func menuBarHasTheStandardMenus() {
        let delegate = AppDelegate()
        let menu = MainMenu.build(updater: delegate.updaterController)
        #expect(menu.items.map(\.title) == ["WireTuner", "File", "Edit", "Window", "Help"])
        #expect(NSApp.windowsMenu?.title == "Window")
        #expect(NSApp.helpMenu?.title == "Help")
    }

    @Test @MainActor func mainWindowIsIdentified() {
        let window = MainWindow.make()
        #expect(window.title == "WireTuner")
        #expect(window.identifier == MainWindow.identifier)
    }
}
