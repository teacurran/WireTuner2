import Foundation

/// The Redraw preferences as the canvas and the tools read them (document-view.adoc, "Redraw
/// preferences"; BASIC-013).  A value read from the store at each use, so a change applies to
/// the next drag or frame without a restart.
struct RedrawSettings: Equatable, Sendable {
    /// How imported bitmaps draw on screen.
    enum ImageDisplay: String, Sendable {
        case high, proxy, gray
    }

    /// How a drag previews the objects it moves.
    enum DragPreview: Equatable, Sendable {
        /// Every dragged object draws fully while it moves.
        case full
        /// Only outlines move, as in Keyline mode.
        case outlines
    }

    var previewDrag = 200
    var displaysTextEffects = true
    /// Text smaller than this many screen pixels draws as grey bars.
    var greekBelowPixels = 8
    var imageDisplay = ImageDisplay.high
    var rasterEffectPreview = "screen"

    init() {}

    @MainActor
    init(preferences: PreferenceStore) {
        let keys = PreferenceCatalog.Redraw.self
        previewDrag = preferences[keys.previewDrag]
        displaysTextEffects = preferences[keys.textEffects]
        greekBelowPixels = preferences[keys.greekBelow]
        imageDisplay = ImageDisplay(rawValue: preferences[keys.imageDisplay]) ?? .high
        rasterEffectPreview = preferences[keys.rasterEffectPreview]
    }

    /// Whether `id` is a Redraw preference (the canvas redraws when one changes).
    static func isRedrawPreference(_ id: String) -> Bool {
        PreferenceCatalog.Redraw.all.contains { $0.id == id }
    }

    /// A drag of `count` objects: up to *Preview drag* they draw fully, beyond it only their
    /// outlines move -- unless Option is held while *Option-drag copies paths* is off, which
    /// forces the full preview (with the preference on, Option-drag makes a copy instead).
    func dragPreview(count: Int, optionHeld: Bool, optionDragCopies: Bool) -> DragPreview {
        if optionHeld, !optionDragCopies { return .full }
        return count <= previewDrag ? .full : .outlines
    }

    /// Whether text `pixelHeight` tall on screen is greeked; selected text always draws as
    /// characters.
    func greeks(pixelHeight: Double, selected: Bool) -> Bool {
        !selected && pixelHeight < Double(greekBelowPixels)
    }
}
