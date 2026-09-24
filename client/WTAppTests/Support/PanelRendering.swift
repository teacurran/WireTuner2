import AppKit
import SwiftUI

/// Renders a SwiftUI view in a window for real (its `ForEach` rows and pickers built), so tests
/// reach the view builders a bare `body` call leaves alone.
@MainActor
enum PanelRendering {
    @discardableResult
    static func host<V: View>(_ view: V, size: NSSize = NSSize(width: 360, height: 900)) -> NSHostingView<V> {
        let hosting = NSHostingView(rootView: view)
        let window = TestWindow.make(NSRect(origin: .zero, size: size))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        window.close()
        return hosting
    }
}
