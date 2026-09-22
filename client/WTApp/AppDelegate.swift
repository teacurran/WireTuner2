import AppKit
import Sparkle

/// The application delegate.  `@main` on an `NSApplicationDelegate` runs `NSApplicationMain`
/// and installs an instance of this class as the delegate; there is no storyboard, so the menu
/// bar and the window are built in code.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Sparkle.  Not started until the distribution task ships an `SUPublicEDKey`; starting
    /// the updater without one is a fatal Sparkle error.  The menu item stays disabled until
    /// then because Sparkle validates it against the updater's state.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private(set) var mainWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(updater: updaterController)
        let controller = NSWindowController(window: MainWindow.make())
        controller.showWindow(nil)
        mainWindowController = controller
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
