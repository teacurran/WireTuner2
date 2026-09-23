// Drawing modes (REND-005; docs/_includes/basics/document-view.adoc, "Drawing modes").  A mode
// is renderer state applied while drawing, never a property of the display list: switching
// modes redraws the same list value.  Also the Preview-in-Browser host hook.

import WTGeometry
import Foundation

/// How the canvas draws a display list.  Mirrors `ViewState.mode` (`DrawingMode`).
public enum ViewMode: String, CaseIterable, Hashable, Sendable {
    /// The artwork as it prints.
    case preview
    /// Preview without transparency groups or raster effects, images as boxes, small text
    /// greeked.
    case fastPreview
    /// Paths only, as one-device-pixel hairlines in the layer highlight colour; images as
    /// crossed boxes.
    case keyline
    /// Keyline with Fast Preview's shortcuts.
    case fastKeyline

    /// Text whose on-page height is at most this many points is greeked in the fast modes.
    public static let greekingThreshold = 50.0

    /// The mode from the two View-menu toggles.
    public init(keyline: Bool, fast: Bool) {
        switch (keyline, fast) {
        case (false, false): self = .preview
        case (false, true): self = .fastPreview
        case (true, false): self = .keyline
        case (true, true): self = .fastKeyline
        }
    }

    /// menu:View[Keyline] is checked.
    public var isKeyline: Bool { self == .keyline || self == .fastKeyline }

    /// menu:View[Fast Mode] is checked.
    public var isFast: Bool { self == .fastPreview || self == .fastKeyline }

    /// The mode after menu:View[Keyline] (kbd:[Cmd+K]): keyline flips, fast stays.
    public var togglingKeyline: ViewMode { ViewMode(keyline: !isKeyline, fast: isFast) }

    /// The mode after menu:View[Fast Mode] (kbd:[Cmd+Shift+K]): fast flips, keyline stays.
    public var togglingFast: ViewMode { ViewMode(keyline: isKeyline, fast: !isFast) }

    /// Whether a group below full opacity is composited through a transparency layer.  The
    /// fast modes draw its members straight onto the canvas at the group's alpha instead, and
    /// Keyline draws opaque hairlines.
    public var drawsTransparencyGroups: Bool { self == .preview }

    /// Whether raster effects are drawn.  No raster-effect item exists until the FX epic; this
    /// is the switch its renderer path reads.
    public var drawsRasterEffects: Bool { self == .preview }

    /// Whether image placeholders are drawn as crossed boxes (outline only).
    public var drawsImagesAsBoxes: Bool { self != .preview }

    /// Whether text at or below `greekingThreshold` points is drawn as a grey bar.
    public var greeksText: Bool { isFast }
}

/// What the app asks the host to export for Preview in Browser: the current page, or the whole
/// document when it has interactions (docs/_includes/basics/document-view.adoc, "Preview in
/// Browser").
public struct BrowserPreviewRequest: Hashable, Sendable {
    /// The canvas the current page is on.
    public var canvas: CanvasID
    /// The page's rectangle in pasteboard space.
    public var pageBounds: Rect
    /// Export every page with its interactions and animation frames instead of one page.
    public var wholeDocument: Bool

    public init(canvas: CanvasID, pageBounds: Rect, wholeDocument: Bool = false) {
        self.canvas = canvas
        self.pageBounds = pageBounds
        self.wholeDocument = wholeDocument
    }
}

/// The hook the app calls for menu:View[Preview in Browser].  Implemented by `WTInterchange`'s
/// SVG/HTML exporter (IO epic, BASIC-017); until one is registered the command is disabled.
/// WTRender defines the seam only.
public protocol BrowserPreviewHook: Sendable {
    /// Writes a temporary export for `request` and returns the file URL to open in the
    /// default browser.
    func exportForBrowserPreview(_ request: BrowserPreviewRequest) async throws -> URL
}
