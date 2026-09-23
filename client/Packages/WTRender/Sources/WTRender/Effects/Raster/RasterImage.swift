// A raster effect's pixels: premultiplied sRGB RGBA8 on a grid in pasteboard space anchored at
// the pasteboard origin, `pixelSize` points per pixel (FX-009).  Both renderers resample the same
// image per device pixel, bilinearly, so a Core Graphics tile and a Metal texture of the same
// pixels agree exactly; PDF output embeds the image itself.

import CoreGraphics
import Foundation
import WTGeometry

final class RasterImage: @unchecked Sendable {
    /// The top-left corner of pixel (0, 0), in pasteboard points.
    let origin: Point
    /// Points per pixel.
    let pixelSize: Double
    let width: Int
    let height: Int
    /// Premultiplied RGBA, row 0 at the top (smallest pasteboard y).
    let bytes: [UInt8]

    init(origin: Point, pixelSize: Double, width: Int, height: Int, bytes: [UInt8]) {
        self.origin = origin
        self.pixelSize = pixelSize
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// The image's rectangle in pasteboard space.
    var rect: Rect {
        Rect(x: origin.x, y: origin.y, width: Double(width) * pixelSize, height: Double(height) * pixelSize)
    }

    var byteCount: Int { bytes.count }

    /// Whether every pixel is transparent.
    var isClear: Bool {
        var index = 3
        while index < bytes.count {
            if bytes[index] != 0 { return false }
            index += 4
        }
        return true
    }

    /// The image as a Core Graphics image (PDF output); nil for an empty image.
    var cgImage: CGImage? {
        guard width > 0, height > 0, let surface = BitmapSurface(width: width, height: height) else {
            return nil
        }
        let data = surface.context.data!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = surface.context.bytesPerRow
        for row in 0..<height {
            for column in 0..<(width * 4) {
                data[row * rowBytes + column] = bytes[row * width * 4 + column]
            }
        }
        return surface.makeImage()
    }

    /// The premultiplied colour at `point` (pasteboard), bilinear between pixel centres and
    /// transparent outside the image, channels 0 ... 255.
    func sample(_ point: Point) -> SIMD4<Double> {
        let x = (point.x - origin.x) / pixelSize - 0.5
        let y = (point.y - origin.y) / pixelSize - 0.5
        guard x.isFinite, y.isFinite, x > -1, y > -1, x < Double(width), y < Double(height) else {
            return .zero
        }
        let x0 = Int(x.rounded(.down))
        let y0 = Int(y.rounded(.down))
        let fx = x - Double(x0)
        let fy = y - Double(y0)
        func pixel(_ column: Int, _ row: Int) -> SIMD4<Double> {
            guard column >= 0, row >= 0, column < width, row < height else {
                return .zero
            }
            let offset = (row * width + column) * 4
            return SIMD4(Double(bytes[offset]), Double(bytes[offset + 1]), Double(bytes[offset + 2]), Double(bytes[offset + 3]))
        }
        let top = pixel(x0, y0) * (1 - fx) + pixel(x0 + 1, y0) * fx
        let bottom = pixel(x0, y0 + 1) * (1 - fx) + pixel(x0 + 1, y0 + 1) * fx
        return top * (1 - fy) + bottom * fy
    }
}

/// A raster stage's output: images under the content, the content itself (drawn as vector
/// unless `replaced`), and images over it.
final class RasterResult: @unchecked Sendable {
    let below: [RasterImage]
    let replaced: RasterImage?
    let above: [RasterImage]

    init(below: [RasterImage], replaced: RasterImage?, above: [RasterImage]) {
        self.below = below
        self.replaced = replaced
        self.above = above
    }

    var byteCount: Int {
        (below + above).reduce(replaced?.byteCount ?? 0) { $0 + $1.byteCount }
    }
}
