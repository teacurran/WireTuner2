import AppKit

/// The document window, empty until APP-002 gives it a canvas.
enum MainWindow {
    static let identifier = NSUserInterfaceItemIdentifier("main-window")

    @MainActor
    static func make() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WireTuner"
        window.identifier = identifier
        window.setFrameAutosaveName("MainWindow")
        window.center()
        window.setAccessibilityIdentifier(identifier.rawValue)
        return window
    }
}
