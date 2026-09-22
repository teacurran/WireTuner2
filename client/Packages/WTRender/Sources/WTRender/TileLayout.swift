// Which tiles a viewport shows and where each one sits on screen.  Pure maths, separated from
// the CALayer surface so the compositor's decisions are testable.

import WTGeometry

/// One visible tile and its frame in view points (y-down, view origin at the top-left).
public struct TilePlacement: Hashable, Sendable {
    public let key: TileKey
    public let frame: Rect

    public init(key: TileKey, frame: Rect) {
        self.key = key
        self.frame = frame
    }
}

/// The tiles covering a viewport on one display, with their on-screen frames.
public struct TileLayout: Hashable, Sendable {
    public let geometry: TileGeometry
    /// Row-major from the top-left visible tile.
    public let placements: [TilePlacement]

    public init(viewport: Viewport, backingScale: Double, canvas: CanvasID, tileSize: Int = TileGeometry.standardTileSize) {
        let geometry = TileGeometry(viewport: viewport, backingScale: backingScale, tileSize: tileSize)
        let toView = geometry.tileSpaceToView(viewport: viewport)
        self.geometry = geometry
        placements = geometry
            .tiles(coveringViewRect: viewport.viewBounds, viewport: viewport, canvas: canvas)
            .map { key in
                TilePlacement(key: key, frame: geometry.tileSpaceRect(of: key).applying(toView))
            }
    }

    public var keys: Set<TileKey> {
        Set(placements.map(\.key))
    }

    public var isEmpty: Bool { placements.isEmpty }

    /// `frame` (y-down view points) expressed in a y-up layer coordinate system `height`
    /// points tall, for a host layer whose geometry is not flipped.
    public static func layerFrame(_ frame: Rect, inHeight height: Double) -> Rect {
        Rect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
    }
}
