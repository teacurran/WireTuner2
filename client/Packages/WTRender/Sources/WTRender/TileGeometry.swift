// Tile geometry shared by both renderers (docs/spec/client.adoc, "The display list";
// docs/_includes/basics/document-view.adoc, "Tile caching under rotation").
//
// *Tile space* is the pasteboard mapped through `R(rotation) · S(step scale)` with no
// translation: device pixels, axes parallel to the screen's, origin at the pasteboard origin.
// A tile is a 256 × 256 device-pixel cell of that space, so panning changes which tiles are
// looked up but never their keys or contents, and a rotated canvas is rasterized once at the
// settled angle and never resampled for display.

import WTGeometry
import Foundation

/// Identifies one rasterized tile: `(canvas, zoom step, rotation, column, row)`.  Rotation is
/// stored canonically (normalized to (-180, 180], rounded to 1/1000°) so keys built from
/// slightly different floating-point angles compare equal.
public struct TileKey: Hashable, Sendable, CustomStringConvertible {
    public let canvas: CanvasID
    public let zoomStep: ZoomStep
    public let rotationDegrees: Double
    public let column: Int
    public let row: Int

    public init(canvas: CanvasID, zoomStep: ZoomStep, rotationDegrees: Double, column: Int, row: Int) {
        self.canvas = canvas
        self.zoomStep = zoomStep
        self.rotationDegrees = TileKey.canonicalRotation(rotationDegrees)
        self.column = column
        self.row = row
    }

    /// `degrees` normalized to (-180, 180] and rounded to 1/1000°.
    public static func canonicalRotation(_ degrees: Double) -> Double {
        let rounded = (degrees * 1000).rounded() / 1000
        return Viewport.normalizedDegrees(rounded)
    }

    public var description: String {
        "\(canvas)@\(zoomStep.index)/\(rotationDegrees)°[\(column),\(row)]"
    }
}

/// The tiling of one canvas at one zoom step and rotation: the maths from pasteboard rects to
/// tile keys and back.
public struct TileGeometry: Hashable, Sendable {
    /// Tiles are 256 × 256 device pixels.
    public static let standardTileSize = 256

    public let zoomStep: ZoomStep
    /// Canonical, as `TileKey` stores it.
    public let rotationDegrees: Double
    /// Tile edge in device pixels.
    public let tileSize: Int

    public init(zoomStep: ZoomStep, rotationDegrees: Double, tileSize: Int = TileGeometry.standardTileSize) {
        self.zoomStep = zoomStep
        self.rotationDegrees = TileKey.canonicalRotation(rotationDegrees)
        self.tileSize = max(tileSize, 1)
    }

    /// The tiling that serves `viewport` on a display with `backingScale` device pixels per
    /// view point: the zoom step nearest the rasterization scale, at the viewport's angle.
    public init(viewport: Viewport, backingScale: Double, tileSize: Int = TileGeometry.standardTileSize) {
        self.init(
            zoomStep: ZoomStep(nearest: viewport.zoom * backingScale),
            rotationDegrees: viewport.rotationDegrees,
            tileSize: tileSize
        )
    }

    /// The tiling `key` belongs to.
    public init(key: TileKey, tileSize: Int = TileGeometry.standardTileSize) {
        self.init(zoomStep: key.zoomStep, rotationDegrees: key.rotationDegrees, tileSize: tileSize)
    }

    /// Pasteboard → tile space: `R(rotation) · S(step scale)`.
    public var pasteboardToTileSpace: AffineTransform {
        Viewport.rotationAndScale(rotationDegrees: rotationDegrees, scale: zoomStep.scale)
    }

    /// Tile space → pasteboard.
    public var tileSpaceToPasteboard: AffineTransform {
        pasteboardToTileSpace.invertedOrIdentity
    }

    /// Tile space → view points for `viewport`.  Rotation cancels, so this is a scale
    /// (`zoom / step scale`, within 0.55% of the display's point-to-pixel ratio) and a
    /// translation: the transform the compositor places tile layers with.
    public func tileSpaceToView(viewport: Viewport) -> AffineTransform {
        // R·S(zoom)·p + t  ==  (zoom / stepScale) · (R·S(stepScale)·p) + t: compose the exact
        // scale-and-translate rather than R⁻¹·S⁻¹ then R·S·T, which leaves floating-point
        // noise in the rotation terms.
        AffineTransform.scale(viewport.zoom / zoomStep.scale).concatenating(.translation(viewport.translation))
    }

    /// View points → tile space.
    public func viewToTileSpace(viewport: Viewport) -> AffineTransform {
        tileSpaceToView(viewport: viewport).invertedOrIdentity
    }

    /// The tile's cell in tile space (device pixels).
    public func tileSpaceRect(of key: TileKey) -> Rect {
        let edge = Double(tileSize)
        return Rect(x: Double(key.column) * edge, y: Double(key.row) * edge, width: edge, height: edge)
    }

    /// The pasteboard-space bounding box of the tile (larger than the tile when rotated).
    public func pasteboardBounds(of key: TileKey) -> Rect {
        tileSpaceRect(of: key).applying(tileSpaceToPasteboard)
    }

    /// Pasteboard → the tile's own pixel space (origin at the tile's top-left corner).
    public func pasteboardToTile(_ key: TileKey) -> AffineTransform {
        let cell = tileSpaceRect(of: key)
        return pasteboardToTileSpace.concatenating(.translation(x: -cell.minX, y: -cell.minY))
    }

    /// The tile at tile-space point `point`.
    public func key(containing point: Point, canvas: CanvasID) -> TileKey {
        let edge = Double(tileSize)
        return TileKey(
            canvas: canvas,
            zoomStep: zoomStep,
            rotationDegrees: rotationDegrees,
            column: Int((point.x / edge).rounded(.down)),
            row: Int((point.y / edge).rounded(.down))
        )
    }

    /// Every tile overlapping `rect` in tile space, row-major from the top-left.  Empty for
    /// an empty rect.  Edges that fall exactly on a tile boundary do not pull in the neighbour.
    public func tiles(coveringTileSpaceRect rect: Rect, canvas: CanvasID) -> [TileKey] {
        guard !rect.isEmpty else {
            return []
        }
        let edge = Double(tileSize)
        let firstColumn = Int((rect.minX / edge).rounded(.down))
        let firstRow = Int((rect.minY / edge).rounded(.down))
        let lastColumn = Int(((rect.maxX - 1e-9) / edge).rounded(.down))
        let lastRow = Int(((rect.maxY - 1e-9) / edge).rounded(.down))
        var keys: [TileKey] = []
        keys.reserveCapacity((lastColumn - firstColumn + 1) * (lastRow - firstRow + 1))
        for row in firstRow...lastRow {
            for column in firstColumn...lastColumn {
                keys.append(TileKey(canvas: canvas, zoomStep: zoomStep, rotationDegrees: rotationDegrees, column: column, row: row))
            }
        }
        return keys
    }

    /// Every tile that a pasteboard rectangle touches (through the rotated bounding box):
    /// the invalidation path, REND-004's dirty rect → dirty tile keys.
    public func tiles(coveringPasteboardRect rect: Rect, canvas: CanvasID) -> [TileKey] {
        tiles(coveringTileSpaceRect: rect.applying(pasteboardToTileSpace), canvas: canvas)
    }

    /// Every tile visible through `viewRect` (view points) of `viewport`: the lookup the
    /// compositor makes each frame.  Tile space and view space share their rotation, so the
    /// mapped rectangle is axis-aligned and no bounding-box slack appears.
    public func tiles(coveringViewRect viewRect: Rect, viewport: Viewport, canvas: CanvasID) -> [TileKey] {
        let transform = viewToTileSpace(viewport: viewport)
        return tiles(coveringTileSpaceRect: viewRect.applying(transform), canvas: canvas)
    }
}
