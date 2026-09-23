// The renderer seam (docs/spec/client.adoc, "Rendering"): both the Core Graphics reference
// renderer and the Metal tile renderer (REND-006) implement this over the same display list,
// view transform, tile geometry and flattening tolerance.  What differs is only how a tile
// becomes pixels, and REND-007 holds the two answers to agreement tile by tile.

import CoreGraphics

/// A renderer of display lists.
///
/// Core Graphics contexts handed to a renderer follow Core Graphics' convention: user space
/// has its origin at the bottom-left and y grows upward.  Renderers flip so that the display
/// list's y-down pasteboard appears the right way up.
public protocol WTRender: Sendable {
    /// The shared curve-flattening tolerance this renderer honours.
    var flatteningTolerance: FlatteningTolerance { get }

    /// The drawing mode this renderer applies (REND-005).  Modes are renderer state: the same
    /// display list value is drawn in every mode.
    var viewMode: ViewMode { get }

    /// Draws what `viewport` shows into `context`, whose user space is view points (a PDF
    /// page or a bitmap context pre-scaled by the caller).
    func render(_ displayList: DisplayList, viewport: Viewport, into context: CGContext)

    /// Draws tile `key` of `geometry` into `context`, whose user space is the tile's device
    /// pixels (`geometry.tileSize` square).
    func render(_ displayList: DisplayList, tile key: TileKey, geometry: TileGeometry, into context: CGContext)

    /// Rasterizes tile `key` to a `geometry.tileSize`-square image with a transparent
    /// background; nil only when no bitmap can be allocated.
    func renderTile(_ displayList: DisplayList, key: TileKey, geometry: TileGeometry) -> CGImage?
}
