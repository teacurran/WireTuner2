// A bitmap the Core Graphics renderer draws into: tiles, golden images and the parity tests
// all read pixels back through it.

import CoreGraphics

/// One pixel of a `BitmapSurface`: premultiplied, 8 bits per channel, in the surface's space.
public struct RGBA8: Hashable, Sendable, CustomStringConvertible {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// The largest absolute per-channel difference to `other`, alpha included.
    public func maxChannelDifference(to other: RGBA8) -> Int {
        max(
            abs(Int(red) - Int(other.red)),
            abs(Int(green) - Int(other.green)),
            abs(Int(blue) - Int(other.blue)),
            abs(Int(alpha) - Int(other.alpha))
        )
    }

    public var description: String {
        "(\(red), \(green), \(blue), \(alpha))"
    }
}

/// A premultiplied RGBA8 bitmap context (sRGB unless another RGB space is given) with pixel
/// access.  Not thread-safe; owned by
/// whoever draws into it.
public final class BitmapSurface {
    public let width: Int
    public let height: Int
    public let context: CGContext

    /// A transparent surface of `width` × `height` device pixels; nil when Core Graphics
    /// refuses the allocation (a zero or absurd size).
    public init?(width: Int, height: Int, colorSpace: CGColorSpace = CoreGraphicsRenderer.colorSpace) {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              )
        else {
            return nil
        }
        self.width = width
        self.height = height
        self.context = context
    }

    /// A surface of the image's size with the image drawn into it, for reading its pixels.
    public convenience init?(drawing image: CGImage) {
        self.init(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    /// A snapshot of the pixels as an image.
    public func makeImage() -> CGImage? {
        context.makeImage()
    }

    /// The pixel at column `x`, row `y` counted from the top-left; clamped to the surface.
    public func pixel(x: Int, y: Int) -> RGBA8 {
        let column = min(max(x, 0), width - 1)
        let row = min(max(y, 0), height - 1)
        let base = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = row * context.bytesPerRow + column * 4
        return RGBA8(red: base[offset], green: base[offset + 1], blue: base[offset + 2], alpha: base[offset + 3])
    }

    /// Whether the 3 × 3 neighbourhood of (`x`, `y`) is one flat colour: an interior pixel
    /// of a solid fill or of the background, as opposed to an anti-aliased edge pixel.
    public func isFlat(x: Int, y: Int) -> Bool {
        let center = pixel(x: x, y: y)
        for dy in -1...1 {
            for dx in -1...1 where pixel(x: x + dx, y: y + dy) != center {
                return false
            }
        }
        return true
    }
}
