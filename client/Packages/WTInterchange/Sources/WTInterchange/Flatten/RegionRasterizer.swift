// Rendering display items to an image with alpha at an export resolution (IO-017): what the
// flattener places where a format cannot express a paint, an effect or a lens.  The pixels are
// Core Graphics reference-renderer output, so a rasterized region looks exactly as it does on
// screen and in WTRender's goldens.

import CoreGraphics
import Foundation
import WTGeometry
import WTRender

enum RegionRasterizer {
    /// The largest edge, in pixels, a rasterized region may have; larger regions render at a
    /// reduced resolution rather than exhausting memory.
    static let maximumEdge = 8192

    /// `items` rendered over `region` (pasteboard) at `ppi`, as an image placed at the
    /// pixel-aligned rectangle it covers; nil for an empty region.
    static func render(_ items: [DisplayItem], region: Rect, ppi: Double, canvas: CanvasID = "export") -> FlatImage? {
        guard !region.isEmpty else {
            return nil
        }
        var scale = max(ppi, 1) / 72
        let longest = max(region.width, region.height) * scale
        if longest > Double(maximumEdge) {
            scale *= Double(maximumEdge) / longest
        }
        let left = (region.minX * scale).rounded(.down)
        let top = (region.minY * scale).rounded(.down)
        let width = max((region.maxX * scale).rounded(.up) - left, 1)
        let height = max((region.maxY * scale).rounded(.up) - top, 1)
        let pixelRect = Rect(x: left / scale, y: top / scale, width: width / scale, height: height / scale)
        var renderer = CoreGraphicsRenderer()
        renderer.rasterPreview = .document
        let viewport = Viewport(scrollOrigin: pixelRect.origin, zoom: 1, size: Size(width: pixelRect.width, height: pixelRect.height))
        // At least one and at most `maximumEdge` pixels a side: the surface always exists.
        let image = renderer.renderBitmap(DisplayList(canvas: canvas, items: items), viewport: viewport, scale: scale)!
        return FlatImage(image: image, rect: pixelRect, rasterized: true)
    }
}
