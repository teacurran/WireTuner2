// FONT-009 (glyph-grid.adoc, "Glyph thumbnails"): a glyph cell's image -- the flattened outline
// (components resolved, strokes expanded, overlaps unioned: `GlyphFlattener`, the same outline
// the generator writes) filled at one of the three cell sizes, the em from descender to ascender
// fitted to the cell height and the advance centred -- and a per-glyph cache keyed by the glyph
// and a version the caller advances when the glyph or a component source changes
// (`WTModel.GlyphInvalidation` names them), so a change re-renders only those glyphs.

import CoreGraphics
import Foundation
import WTGeometry

/// Renders glyph cell images.
public enum GlyphThumbnail {
    /// The grid's cell sizes (glyph-grid.adoc, *Glyph cell size*), in points.
    public enum CellSize: Int, Hashable, Sendable, CaseIterable {
        case small = 40
        case medium = 64
        case large = 96
    }

    /// The image of `outline` (glyph-canvas space, y down) in a square cell `pixels` wide: the
    /// em from `descender` to `ascender` (font units, y up) fills the height, the advance width
    /// is centred; nil when the context cannot be made.
    public static func image(_ outline: FilledPath, advanceWidth: Double, ascender: Double, descender: Double, pixels: Int,
                             color: CGColor = CGColor(gray: 0, alpha: 1)) -> CGImage? {
        guard pixels > 0, ascender > descender,
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let size = Double(pixels)
        let scale = size / (ascender - descender)
        // Bitmap y is up; glyph-canvas y is down with the baseline at 0: font y = -canvas y.
        let offsetX = (size - max(advanceWidth, 0) * scale) / 2
        context.translateBy(x: offsetX, y: -descender * scale)
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(color)
        context.addPath(DisplayPath(contours: outline.contours).cgPath)
        context.fillPath(using: outline.fillRule == .evenOdd ? .evenOdd : .winding)
        return context.makeImage()
    }
}

/// Glyph cell images by glyph, version and size.
public final class GlyphThumbnailCache: @unchecked Sendable {
    private struct Key: Hashable {
        var glyph: NodeID
        var pixels: Int
    }

    private let lock = NSLock()
    private var entries: [Key: (version: UInt64, image: CGImage)] = [:]
    /// How many images were rendered (not served from the cache).
    public private(set) var renders = 0

    public init() {}

    /// The cached image of `glyph` at `pixels` when its version is `version`, else `render()`'s
    /// (stored).
    public func image(for glyph: NodeID, version: UInt64, pixels: Int, render: () -> CGImage?) -> CGImage? {
        let key = Key(glyph: glyph, pixels: pixels)
        lock.lock()
        if let entry = entries[key], entry.version == version {
            lock.unlock()
            return entry.image
        }
        lock.unlock()
        guard let image = render() else { return nil }
        lock.lock()
        entries[key] = (version, image)
        renders += 1
        lock.unlock()
        return image
    }

    /// Drops the images of `glyphs`.
    public func invalidate(_ glyphs: Set<NodeID>) {
        lock.lock()
        entries = entries.filter { !glyphs.contains($0.key.glyph) }
        lock.unlock()
    }

    /// Drops everything.
    public func removeAll() {
        lock.lock()
        entries = [:]
        lock.unlock()
    }

    /// How many images are cached.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
