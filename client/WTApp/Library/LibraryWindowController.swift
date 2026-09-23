import AppKit
import SwiftUI

/// The Library window (creating-opening.adoc, "Opening a document").  One per app; opened by
/// menu:File[Open…] and menu:Window[Library], refreshed each time it is shown.
@MainActor
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("library-window")

    let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.title = "Library"
        window.identifier = Self.windowIdentifier
        window.setAccessibilityIdentifier(Self.windowIdentifier.rawValue)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: LibraryView(model: model))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LibraryWindowController is built in code")
    }

    /// Brings the window forward and refreshes the library.
    @discardableResult
    func show() -> Task<Void, Never> {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        let model = model
        return Task { await model.refresh() }
    }
}

/// menu:File[Open…] and menu:Window[Library] (both show the Library window), and
/// menu:File[New] creating through the library so a new document is in it at once.
enum LibraryCommands {
    enum ID {
        static let open = StandardCommands.ID.open
        static let library: CommandID = "window.library"
    }

    @MainActor
    static func commands(show: @escaping @MainActor @Sendable () -> Void) -> [Command] {
        [
            Command(
                id: ID.open, title: "Open…", key: KeyEquivalent("o", .command), menu: MenuPath(StandardCommands.Menu.file),
                keywords: ["document", "library"], action: .perform(show)
            ),
            Command(
                id: ID.library, title: "Library", menu: MenuPath(StandardCommands.Menu.window), keywords: ["documents", "open", "folders"],
                action: .perform(show)
            ),
        ]
    }

    @MainActor
    static func install(into registry: CommandRegistry, show: @escaping @MainActor @Sendable () -> Void) {
        for command in commands(show: show) { registry.replace(command) }
    }
}
