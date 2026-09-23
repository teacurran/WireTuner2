// The Core Graphics tile canvas: the first on-screen path and the permanent fallback
// (docs/spec/client.adoc, "Metal tile renderer", *Fallback*).  A host `CALayer` composes one
// sublayer per visible tile; tiles are rasterized by the `TileCache` actor off the main actor
// and their images land in `contents` when ready.  Pan is a lookup: frames move, keys stay.
//
// Until REND-004 wires change-driven invalidation, a changed display list invalidates the
// whole canvas (`update` compares the list by value; passing the same value is O(1)).

import WTGeometry
import QuartzCore

/// Composes cached tiles into a `CALayer`.  Owned and driven on the main actor by the canvas
/// view controller; `layer` is what goes into the view hierarchy.
@MainActor
public final class TiledCanvasLayer {
    private struct Request {
        let id: Int
        let task: Task<Void, Never>
    }

    /// The host layer.  Its bounds follow the viewport size on `update`.
    public let layer: CALayer
    public let cache: TileCache

    /// Device pixels per view point of the display the layer is on.  Changing it changes the
    /// zoom step, so the next `update` lays out and requests a new set of tiles.
    public var backingScale: Double

    public private(set) var displayList: DisplayList?
    public private(set) var viewport: Viewport?
    public private(set) var layout: TileLayout?

    private var tileLayers: [TileKey: CALayer] = [:]
    private var pending: [TileKey: Request] = [:]
    private var invalidations: [Int: Task<Void, Never>] = [:]
    private var nextID = 0

    public init(cache: TileCache, backingScale: Double = 2) {
        self.cache = cache
        self.backingScale = backingScale
        layer = CALayer()
        layer.masksToBounds = true
    }

    /// Visible tiles.
    public var tileLayerCount: Int { tileLayers.count }

    /// Tiles requested from the cache and not yet applied.
    public var pendingTileCount: Int { pending.count }

    /// Whether the tile layer for `key` currently shows an image.
    public func hasContents(for key: TileKey) -> Bool {
        tileLayers[key]?.contents != nil
    }

    /// Shows `displayList` through `viewport`: lays out the visible tiles, drops the others
    /// and requests any that have no image yet.  Returns the layout it applied.
    @discardableResult
    public func update(displayList: DisplayList, viewport: Viewport) -> TileLayout {
        let listChanged = self.displayList != displayList
        self.displayList = displayList
        self.viewport = viewport
        layer.bounds = CGRect(x: 0, y: 0, width: viewport.size.width, height: viewport.size.height)

        let layout = TileLayout(viewport: viewport, backingScale: backingScale, canvas: displayList.canvas)
        self.layout = layout
        let visible = layout.keys

        for (key, tileLayer) in tileLayers where !visible.contains(key) {
            tileLayer.removeFromSuperlayer()
            tileLayers[key] = nil
            cancelRequest(for: key)
        }
        for placement in layout.placements {
            let tileLayer = tileLayers[placement.key] ?? makeTileLayer(for: placement.key)
            tileLayer.frame = TileLayout.layerFrame(placement.frame, inHeight: viewport.size.height).cg
        }
        if listChanged {
            invalidateAll()
        } else {
            requestMissingTiles()
        }
        return layout
    }

    /// Drops the cached tiles under a changed pasteboard rectangle and re-requests the
    /// visible ones (REND-004 feeds this from `ChangeSummary`).
    public func invalidate(pasteboardRect rect: Rect) {
        guard let displayList, let layout else {
            return
        }
        let affected = tileLayers.keys.filter { layout.geometry.pasteboardBounds(of: $0).intersects(rect) }
        for key in affected {
            cancelRequest(for: key)
            tileLayers[key]?.contents = nil
        }
        let canvas = displayList.canvas
        runInvalidation { cache in
            await cache.invalidate(pasteboardRect: rect, canvas: canvas)
        }
    }

    /// Drops every cached tile of the canvas and re-requests the visible ones.
    public func invalidateAll() {
        guard let displayList else {
            return
        }
        for key in tileLayers.keys {
            cancelRequest(for: key)
            tileLayers[key]?.contents = nil
        }
        let canvas = displayList.canvas
        runInvalidation { cache in
            await cache.invalidateAll(canvas: canvas)
        }
    }

    /// Switches the renderer -- a view mode change (REND-005) or overprint preview -- without
    /// touching the display list: the cached tiles are dropped and the visible ones re-requested.
    public func setRenderer(_ renderer: any WTRender) {
        for key in tileLayers.keys {
            cancelRequest(for: key)
            tileLayers[key]?.contents = nil
        }
        runInvalidation { cache in
            await cache.replaceRenderer(renderer)
        }
    }

    /// Waits until every invalidation has reached the cache and every requested tile has
    /// been applied (or dropped).
    public func settle() async {
        while let task = invalidations.values.first ?? pending.values.first?.task {
            await task.value
        }
    }

    // MARK: Tile requests

    /// Runs `operation` on the cache; while any invalidation is in flight no tile is
    /// requested, so a request can never read a tile the invalidation is about to drop.
    /// When the last one completes, every visible tile without an image is requested.
    private func runInvalidation(_ operation: @Sendable @escaping (TileCache) async -> Void) {
        nextID += 1
        let id = nextID
        invalidations[id] = Task { [cache] in
            await operation(cache)
            invalidations[id] = nil
            if invalidations.isEmpty {
                requestMissingTiles()
            }
        }
    }

    private func requestMissingTiles() {
        guard invalidations.isEmpty, let displayList, let layout else {
            return
        }
        for (key, tileLayer) in tileLayers where tileLayer.contents == nil && pending[key] == nil {
            request(key, displayList: displayList, geometry: layout.geometry)
        }
    }

    private func request(_ key: TileKey, displayList: DisplayList, geometry: TileGeometry) {
        nextID += 1
        let id = nextID
        let task = Task { [cache] in
            let image = await cache.tile(for: key, in: displayList, geometry: geometry)
            apply(image, for: key, requestID: id)
        }
        pending[key] = Request(id: id, task: task)
    }

    private func apply(_ image: CGImage?, for key: TileKey, requestID: Int) {
        guard pending[key]?.id == requestID else {
            return  // superseded or cancelled
        }
        pending[key] = nil
        guard let image, let tileLayer = tileLayers[key] else {
            return
        }
        tileLayer.contents = image
    }

    private func cancelRequest(for key: TileKey) {
        pending[key]?.task.cancel()
        pending[key] = nil
    }

    private func makeTileLayer(for key: TileKey) -> CALayer {
        let tileLayer = CALayer()
        tileLayer.contentsGravity = .resize
        tileLayer.magnificationFilter = .linear
        tileLayer.minificationFilter = .linear
        tileLayer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        tileLayers[key] = tileLayer
        layer.addSublayer(tileLayer)
        return tileLayer
    }
}
