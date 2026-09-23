import Foundation

/// The four drawing modes (document-view.adoc, "Drawing modes"; `DrawingMode` in
/// `doc/v1/view.proto`).
///
/// TODO(REND-005): WTRender's `ViewMode` had not landed when APP-002 started (it was in
/// flight in the working tree, uncommitted).  This local enum has the same shape
/// (`isKeyline`, `isFast`, `togglingKeyline`, `togglingFast`, `init(keyline:fast:)`) and
/// shadows WTRender's inside the app; once REND-005 is committed, delete this file, keep the
/// `title`s and raw values, and hand the mode to the renderer
/// (`CoreGraphicsRenderer.with(viewMode:)`) so changing it redraws.  Until then changing the
/// mode changes no pixels.
enum ViewMode: String, CaseIterable, Codable, Sendable {
    case preview
    case fastPreview = "fast_preview"
    case keyline
    case fastKeyline = "fast_keyline"

    var title: String {
        switch self {
        case .preview: "Preview"
        case .fastPreview: "Fast Preview"
        case .keyline: "Keyline"
        case .fastKeyline: "Fast Keyline"
        }
    }

    var isKeyline: Bool { self == .keyline || self == .fastKeyline }
    var isFast: Bool { self == .fastPreview || self == .fastKeyline }

    init(keyline: Bool, fast: Bool) {
        switch (keyline, fast) {
        case (false, false): self = .preview
        case (false, true): self = .fastPreview
        case (true, false): self = .keyline
        case (true, true): self = .fastKeyline
        }
    }

    /// menu:View[Keyline]: toggles between the Keyline pair and the Preview pair, keeping
    /// fast (Fast Keyline becomes Fast Preview).
    var togglingKeyline: ViewMode { ViewMode(keyline: !isKeyline, fast: isFast) }

    /// menu:View[Fast Mode]: toggles between the fast pair and the full pair.
    var togglingFast: ViewMode { ViewMode(keyline: isKeyline, fast: !isFast) }
}
