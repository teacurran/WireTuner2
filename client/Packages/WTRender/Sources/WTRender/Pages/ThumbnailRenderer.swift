// The document thumbnail (DOC-032; docs/_includes/document/creating-opening.adoc, "Client"): the
// first page drawn through the Core Graphics reference renderer at a fixed size on its long edge,
// as an sRGB PNG with alpha.  The library window shows it; the package writer embeds the 1024 px
// render (IO-005).  Pure and thread-safe: WTSync's `ThumbnailCapture` calls it off the main actor.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WTGeometry

public enum ThumbnailRenderer {
    /// The library thumbnail's long edge in pixels.
    public static let libraryEdge = 512
    /// The package writer's long edge in pixels.
    public static let packageEdge = 1024

    /// The pixel size of a thumbnail of `page` with `longEdge` pixels on its long side (at least
    /// one pixel on the short side); nil for an empty or non-finite page.
    public static func pixelSize(of page: Rect, longEdge: Int = libraryEdge) -> (width: Int, height: Int)? {
        guard page.width > 0, page.height > 0, page.width.isFinite, page.height.isFinite, longEdge > 0 else { return nil }
        let scale = Double(longEdge) / max(page.width, page.height)
        return (max(1, Int((page.width * scale).rounded())), max(1, Int((page.height * scale).rounded())))
    }

    /// `displayList` inside `page` (pasteboard coordinates) as an image `longEdge` pixels on its
    /// long side, transparent where nothing is drawn, in sRGB.
    public static func image(_ displayList: DisplayList, page: Rect, longEdge: Int = libraryEdge,
                             renderer: CoreGraphicsRenderer = CoreGraphicsRenderer()) -> CGImage? {
        guard let size = pixelSize(of: page, longEdge: longEdge) else { return nil }
        let zoom = Double(size.width) / page.width
        let viewport = Viewport(scrollOrigin: Point(x: page.minX, y: page.minY), zoom: zoom,
                                size: Size(width: Double(size.width), height: Double(size.height)))
        return renderer.with(colorManagement: ColorManagement(workingSpace: .sRGB)).renderBitmap(displayList, viewport: viewport)
    }

    /// The thumbnail as PNG bytes (sRGB, with alpha); nil for an empty page.
    public static func png(_ displayList: DisplayList, page: Rect, longEdge: Int = libraryEdge,
                           renderer: CoreGraphicsRenderer = CoreGraphicsRenderer()) -> Data? {
        image(displayList, page: page, longEdge: longEdge, renderer: renderer).map(encodePNG)
    }

    /// `image` (an 8-bit RGBA bitmap, which PNG always takes) encoded as PNG.
    static func encodePNG(_ image: CGImage) -> Data {
        let data = NSMutableData()
        // ImageIO always has a PNG encoder.
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
