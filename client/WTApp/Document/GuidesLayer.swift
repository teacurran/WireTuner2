import AppKit
import WTCRDT
import WTModel

/// The Layers panel's hooks for the Guides layer and the guide-drag auto-scroll (grid-guides.adoc;
/// layers.adoc, "The Guides layer and guide paths"; DOC-018's remainder).  The Guides layer's check
/// mark shows or hides the guides -- its guide paths (the layer flag, shared) and the ruler guides
/// of the front window (view state, never a change) -- and its padlock locks the guides for
/// everyone: the layer flag and `SettingsProps.guides_locked` in one change.  A guide dragged to
/// the canvas edge scrolls the window only with *Dragging a guide scrolls the window*.
@MainActor
enum GuidesLayer {
    /// The window whose ruler guides the check mark shows or hides.
    static var window: @MainActor () -> DocumentWindowController? = { nil }

    /// The command a click on the Guides layer's `flag` column performs; nil for the columns it
    /// does not change (printing, keyline) and for other layers.
    static func toggle(_ flag: SetLayerFlag.Flag, layer: LayerInfo) -> (any WTModel.Command)? {
        guard layer.role == .guides else { return nil }
        switch flag {
        case .visible:
            let shown = !layer.visible
            if let window = window() { window.showsGuides = shown }
            return SetLayerFlag([layer.id], .visible, shown)
        case .locked:
            let locked = !layer.locked
            return CompositeCommand(locked ? "Lock guides" : "Unlock guides", [SetLayerFlag([layer.id], .locked, locked), SetGuidesLocked(locked)])
        case .printing, .keyline:
            return nil
        }
    }

    /// Whether a canvas drag may auto-scroll now: as before, except that a guide being dragged
    /// scrolls only with the preference on.
    static func autoscrolls(_ manager: ToolManager?, previous: Bool, preferences: PreferenceStore) -> Bool {
        guard previous else { return false }
        guard manager?.handleDrag is GuideHandles else { return true }
        return preferences[PreferenceCatalog.General.guideDragScrolls]
    }

    /// The window's canvas asks the preference for guide drags.
    static func install(on window: DocumentWindowController, preferences: PreferenceStore) {
        let previous = window.canvas.autoscrolls
        window.canvas.autoscrolls = { [weak window] in
            autoscrolls(window?.toolManager, previous: previous(), preferences: preferences)
        }
    }
}
