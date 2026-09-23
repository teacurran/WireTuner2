// The mip pyramid of one image blob (IMG-004, IMG-018; docs/_includes/imported/bitmaps.adoc,
// "Mip pyramid"): reduced copies at powers of two down to 512 px on the long edge, so the
// renderer draws the smallest level that is still at least as fine as the screen.  Levels are
// made from the encoded file by ImageIO without decoding it whole where the format allows,
// written to an on-disk cache beside the blob cache (keyed by the blob hash, so a new hash is
// a new directory and nothing is ever stale), and reused across launches.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The levels of one image and how to get each level's pixels.
public final class ImagePyramid: @unchecked Sendable {
    /// One level: `index` 0 is the full image, level `k` is reduced by `2^k`.
    public struct Level: Hashable, Sendable {
        public var index: Int
        public var width: Int
        public var height: Int
        /// Level pixels per full-image pixel (1 for level 0).
        public var scale: Double
    }

    /// Sources above this many pixels get reduced levels (bitmaps.adoc: 4 MP).
    public static let defaultPyramidThreshold = 4_000_000
    /// Sources above this many pixels are never decoded whole: reduced levels come from
    /// subsampled decodes and the full level is handed out in tiles (64 MP).
    public static let defaultTiledThreshold = 64_000_000
    /// The smallest level's long edge is at least this many pixels.
    public static let minimumEdge = 512

    public let hash: String
    public let url: URL
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Finest first.
    public let levels: [Level]
    /// Whether the full level is too large to decode whole.
    public let isTiled: Bool
    private let cacheDirectory: URL?
    private let source: CGImageSource

    /// The pyramid of the encoded image at `url`; nil when ImageIO cannot read it.  Only the
    /// header is read here.
    public init?(
        url: URL,
        hash: String,
        cacheDirectory: URL? = nil,
        pyramidThreshold: Int = ImagePyramid.defaultPyramidThreshold,
        tiledThreshold: Int = ImagePyramid.defaultTiledThreshold
    ) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        self.source = source
        self.url = url
        self.hash = hash
        self.cacheDirectory = cacheDirectory
        pixelWidth = width
        pixelHeight = height
        let pixels = width * height
        isTiled = pixels > tiledThreshold
        levels = ImagePyramid.levels(width: width, height: height, reduced: pixels > pyramidThreshold)
    }

    /// Level 0 and, when `reduced`, every halving whose long edge stays at or above
    /// `minimumEdge`.
    static func levels(width: Int, height: Int, reduced: Bool) -> [Level] {
        var result = [Level(index: 0, width: width, height: height, scale: 1)]
        guard reduced else {
            return result
        }
        let long = max(width, height)
        var index = 1
        while (long + (1 << index) - 1) >> index >= minimumEdge {
            let divisor = 1 << index
            result.append(Level(
                index: index,
                width: max(1, (width + divisor - 1) / divisor),
                height: max(1, (height + divisor - 1) / divisor),
                scale: 1 / Double(divisor)
            ))
            index += 1
        }
        return result
    }

    /// The smallest level whose scale is at least `scale` (device pixels per image pixel);
    /// level 0 when even it is coarser than the screen.
    public func level(forScale scale: Double) -> Level {
        levels.last { $0.scale >= scale } ?? levels[0]
    }

    /// The level's pixels: level 0 decoded whole (nil for a tiled pyramid, whose full level
    /// comes through `fullLevelTile`), reduced levels from the disk cache or generated and
    /// written to it.  Nil when the index is out of range or decoding fails.
    public func image(level index: Int) -> CGImage? {
        guard levels.indices.contains(index) else {
            return nil
        }
        if index == 0 {
            return isTiled ? nil : CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        let level = levels[index]
        if let cached = cachedLevel(level) {
            return cached
        }
        guard let image = generate(level) else {
            return nil
        }
        store(image, level: level)
        return image
    }

    /// The full-resolution pixels of `rect` (image pixels, origin top-left), decoded on demand
    /// and never kept whole.  Nil when the rectangle misses the image.
    public func fullLevelTile(rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        let clipped = rect.integral.intersection(bounds)
        guard !clipped.isEmpty,
              let whole = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              let crop = whole.cropping(to: clipped),
              let space = crop.colorSpace,
              let context = CGContext(
                data: nil,
                width: crop.width,
                height: crop.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: ImagePyramid.bitmapInfo(for: crop)
              )
        else {
            return nil
        }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return context.makeImage()
    }

    /// Premultiplied alpha for colour spaces with an alpha channel in the crop, none for gray.
    static func bitmapInfo(for image: CGImage) -> UInt32 {
        image.colorSpace?.model == .monochrome ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    }

    /// A reduced level from ImageIO: a subsampled decode for tiled sources when the format
    /// honours `kCGImageSourceSubsampleFactor` (JPEG, HEIF: factors 2, 4, 8) and yields the
    /// level's size, otherwise a thumbnail of the level's long edge.
    private func generate(_ level: Level) -> CGImage? {
        if isTiled, level.index <= 3,
           let subsampled = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceSubsampleFactor: 1 << level.index, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
           subsampled.width <= level.width + 1 {
            return subsampled
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(level.width, level.height),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Disk cache

    /// `<cache>/<hash>/<index>.png`.
    func cacheURL(for level: Level) -> URL? {
        cacheDirectory?.appendingPathComponent(hash, isDirectory: true).appendingPathComponent("\(level.index).png")
    }

    private func cachedLevel(_ level: Level) -> CGImage? {
        guard let url = cacheURL(for: level),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              abs(image.width - level.width) <= 1, abs(image.height - level.height) <= 1
        else {
            return nil
        }
        return image
    }

    private func store(_ image: CGImage, level: Level) {
        guard let url = cacheURL(for: level) else {
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written to a sibling and moved into place, so a reader never sees a half-written file.
        let partial = url.appendingPathExtension("partial-\(UUID().uuidString)")
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: partial)
        }
        try? FileManager.default.removeItem(at: partial)
    }

    /// Removes every cached level of `hash` under `cacheDirectory`.
    public static func purge(hash: String, in cacheDirectory: URL) {
        try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(hash, isDirectory: true))
    }
}
