import AppKit
import WTModel

/// The Crop tool's commands and the Object panel's image section (IMG-025, IMG-016), the
/// accessibility check (IO-033) and the Eyedropper's drag out of the canvas (COLOR-012): installed
/// after the other features (replacing the catalog stubs), and the per-window hook attached to each
/// document window as it opens.  The Crop and Link tools are in the tool catalog itself.
extension AppDelegate {
    func installImageLinkAndAccessibility() {
        let documents = documents!
        let window: @MainActor () -> DocumentWindowController? = { documents.activeWindowController }
        for command in CropFeatures.commands(window: window) + ImageSection.commands(window: window) + [AccessibilityCheckerFeatures.command(window: window)] {
            commands.replace(command)
        }
        ImageSection.register(into: .standard)
        let preferences = preferences
        ImageSection.threshold = { Double(preferences[PreferenceCatalog.Document.lowResolutionWarning]) }
        ImageSection.perform = { [weak self] id in _ = self?.menuTarget?.perform(id) }
        ImageSection.author = { node, document in
            documents.allWindowControllers.first { $0.documentHandle === document }?.session?.author(of: node.replica)?.name
        }
    }

    func attachImageLinkAndAccessibility(_ window: DocumentWindowController) {
        ImageLinkWindowParts.attach(window)
    }
}

/// One window's hook: the Eyedropper's colour becomes a colour drag when it leaves the canvas.
@MainActor
enum ImageLinkWindowParts {
    static func attach(_ window: DocumentWindowController, dragOut: EyedropperDragOut = .shared) {
        window.canvas.onLeaveCanvas = { [weak window] event in
            guard let window else { return false }
            return dragOut.begin(window, event: event)
        }
    }
}
