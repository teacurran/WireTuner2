import AppKit

/// The document window: a placeholder canvas (APP-002 replaces it with the scroll view and
/// `WTCanvasView`) with the panel dock at its right edge.
enum MainWindow {
    static let identifier = NSUserInterfaceItemIdentifier("main-window")
    static let canvasIdentifier = "canvas-placeholder"

    @MainActor
    static func make(dock: PanelDockController) -> NSWindow {
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

        let content = NSView()
        let canvas = CanvasPlaceholderView()
        let dockView = dock.view
        content.addSubview(canvas)
        content.addSubview(dockView)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: dockView.leadingAnchor),
            canvas.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            dockView.topAnchor.constraint(equalTo: content.topAnchor),
            dockView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            dockView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window.contentView = content
        return window
    }
}

/// Stands in for the canvas until APP-002.
@MainActor
final class CanvasPlaceholderView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(MainWindow.canvasIdentifier)
        setAccessibilityLabel("Canvas")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CanvasPlaceholderView is built in code")
    }
}

/// Owns the document window and its dock controller.
@MainActor
final class MainWindowController: NSWindowController {
    let dock: PanelDockController

    init(panels: PanelRegistry, layout: PanelLayoutController) {
        dock = PanelDockController(panels: panels, layout: layout)
        super.init(window: MainWindow.make(dock: dock))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is built in code")
    }
}
