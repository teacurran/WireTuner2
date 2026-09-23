// Drawing a placed image (IMG-004, IMG-018; docs/_includes/imported/bitmaps.adoc, "Client";
// image-color.adoc, "Client").  The natural frame is drawn under the item's transform, clipped
// to the crop; the pyramid level is the smallest whose scale covers the on-screen scale, and a
// tiled (very large) image zoomed in past its finest reduced level draws the full-resolution
// pixels of the part in view only.  Interpolation is high below 100% of the level's scale and
// none above 400%, so pixels stay crisp far in.  The decoded image is drawn in its effective
// source profile (Core Graphics matches it into the tile context with the image's intent);
// under a soft proof its pixels go through the proof chain first, cached per level.

import CoreGraphics
import Foundation
import WTGeometry

enum ImageDrawing {
    /// The decoded, treated image for `item` at the context's scale; nil while it is not
    /// decoded (bitmaps) or when it cannot be (a missing or corrupt blob).
    static func image(for item: ImageItem, store: ImageStore, renderer: CoreGraphicsRenderer, in context: CGContext) -> CGImage? {
        let treatment = item.treatment(renderer.colorManagement)
        let scale = deviceScale(of: item, store: store, in: context)
        if renderer.vectorOutput {
            return store.imageBlocking(for: item.assetID, treatment: treatment, scale: scale)
        }
        return store.image(for: item.assetID, treatment: treatment, scale: scale)
    }

    /// Device pixels per image pixel: the context's scale times the frame's points per pixel
    /// (1 until the header has been read).
    static func deviceScale(of item: ImageItem, store: ImageStore, in context: CGContext) -> Double {
        let local = item.transform.concatenating(AffineTransform(context.ctm))
        let deviceScale = abs(local.determinant).squareRoot()
        guard let pixelWidth = store.pyramid(for: item.assetID)?.pixelWidth, pixelWidth > 0, item.rect.width > 0 else {
            return deviceScale
        }
        return deviceScale * item.rect.width / Double(pixelWidth)
    }

    /// Draws `image` over the item's natural frame, clipped to the visible frame.
    static func draw(_ image: CGImage, item: ImageItem, renderer: CoreGraphicsRenderer, into context: CGContext) {
        context.saveGState()
        context.concatenate(item.transform.cg)
        context.clip(to: item.visibleRect.cg)
        context.setRenderingIntent((item.intent ?? renderer.colorManagement.intent).cg)
        let frame = item.rect
        // The frame is y-down; Core Graphics draws images y-up.
        context.translateBy(x: 0, y: CGFloat(frame.minY + frame.maxY))
        context.scaleBy(x: 1, y: -1)
        let levelScale = abs(context.ctm.a * context.ctm.d - context.ctm.b * context.ctm.c).squareRoot() * frame.width / Double(max(image.width, 1))
        context.interpolationQuality = interpolation(forLevelScale: levelScale)
        if let store = renderer.imageStore, let tile = fullResolutionTile(item: item, store: store, treatment: item.treatment(renderer.colorManagement), levelScale: levelScale, image: image, in: context) {
            context.draw(prepared(tile.image, item: item, renderer: renderer), in: tile.rect)
        } else {
            context.draw(prepared(image, item: item, renderer: renderer), in: frame.cg)
        }
        context.restoreGState()
    }

    /// High below 100% of the level's pixels, none above 400%, default between.
    static func interpolation(forLevelScale scale: Double) -> CGInterpolationQuality {
        if scale < 1 {
            return .high
        }
        return scale > 4 ? .none : .default
    }

    /// The image in its effective source profile (when the pixels are untreated and the
    /// profile's model matches), then through the proof chain when proofing.
    static func prepared(_ image: CGImage, item: ImageItem, renderer: CoreGraphicsRenderer) -> CGImage {
        var tagged = image
        let treatment = item.treatment(renderer.colorManagement)
        if treatment.isIdentity, let profile = item.sourceProfile,
           let space = renderer.colorManagement.converter.registry.colorSpace(for: profile),
           space.numberOfComponents == image.colorSpace?.numberOfComponents,
           let copy = image.copy(colorSpace: space) {
            tagged = copy
        }
        // Proofing converts RGBA pixels: an image in another model is drawn into sRGB first.
        let drawSpace = tagged.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? WTColor.Spaces.sRGB
        guard !renderer.vectorOutput,
              renderer.colorManagement.proof != nil,
              let source = renderer.colorManagement.converter.registry.register(colorSpace: drawSpace),
              let transform = renderer.colorManagement.proofTransform(forImageIn: source, intent: item.intent)
        else {
            return tagged
        }
        return ImageProofCache.shared.proofed(tagged, drawnIn: drawSpace, transform: transform, into: renderer.colorManagement.colorSpace)
    }

    /// For a tiled image drawn finer than its finest reduced level: the full-resolution pixels
    /// of the part of the frame in the clip, and where they go (y-up frame space).
    static func fullResolutionTile(item: ImageItem, store: ImageStore, treatment: ImageTreatment, levelScale: Double, image: CGImage, in context: CGContext) -> (image: CGImage, rect: CGRect)? {
        guard levelScale > 1, let pyramid = store.pyramid(for: item.assetID), pyramid.isTiled, image.width < pyramid.pixelWidth else {
            return nil
        }
        let frame = item.rect.cg
        let visible = context.boundingBoxOfClipPath.intersection(frame)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else {
            return nil
        }
        let perPoint = CGFloat(pyramid.pixelWidth) / frame.width
        let perPointY = CGFloat(pyramid.pixelHeight) / frame.height
        // Frame space here is y-up from the frame's bottom; pixel rows count from the top.
        let pixels = CGRect(
            x: ((visible.minX - frame.minX) * perPoint).rounded(.down),
            y: ((frame.maxY - visible.maxY) * perPointY).rounded(.down),
            width: (visible.width * perPoint).rounded(.up) + 1,
            height: (visible.height * perPointY).rounded(.up) + 1
        ).intersection(CGRect(x: 0, y: 0, width: pyramid.pixelWidth, height: pyramid.pixelHeight))
        guard let tile = store.fullResolutionTile(for: item.assetID, rect: pixels, treatment: treatment) else {
            return nil
        }
        let rect = CGRect(
            x: frame.minX + pixels.minX / perPoint,
            y: frame.maxY - pixels.maxY / perPointY,
            width: pixels.width / perPoint,
            height: pixels.height / perPointY
        )
        return (tile, rect)
    }

    /// The download progress bar along the placeholder's bottom edge, or nil when the blob is
    /// not downloading.
    static func progressBar(for item: ImageItem, store: ImageStore?) -> Rect? {
        guard case .downloading(let progress) = store?.state(of: item.assetID) else {
            return nil
        }
        let frame = item.visibleRect
        let height = frame.height * 0.04
        return Rect(x: frame.minX, y: frame.maxY - height, width: frame.width * progress, height: height)
    }

    /// The frame's diagonals, and its outline when `framed`.
    static func box(_ rect: Rect, framed: Bool) -> DisplayPath {
        var box = framed ? DisplayPath(rect: rect) : DisplayPath()
        box.move(to: Point(x: rect.minX, y: rect.minY))
        box.addLine(to: Point(x: rect.maxX, y: rect.maxY))
        box.move(to: Point(x: rect.maxX, y: rect.minY))
        box.addLine(to: Point(x: rect.minX, y: rect.maxY))
        return box
    }
}

/// Proofed image levels, keyed by the image object and the chain (CMS-007: rasters are
/// converted through the proof chain per level, not per frame).
final class ImageProofCache: @unchecked Sendable {
    static let shared = ImageProofCache()
    static let capacity = 64

    private let lock = NSLock()
    /// Entries hold their source image, so an identifier is never reused while cached.
    private var entries: [Key: (source: CGImage, result: CGImage)] = [:]
    private var order: [Key] = []

    private struct Key: Hashable {
        var image: ObjectIdentifier
        var transform: ObjectIdentifier
    }

    /// `image`, drawn into RGBA8 in `source`, converted through `transform` into `space`.
    func proofed(_ image: CGImage, drawnIn source: CGColorSpace, transform: WTColor.Transform, into space: CGColorSpace) -> CGImage {
        let key = Key(image: ObjectIdentifier(image), transform: ObjectIdentifier(transform))
        if let cached = lock.withLock({ entries[key] }) {
            return cached.result
        }
        let width = image.width, height = image.height
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: source, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        var pixels = Array(UnsafeBufferPointer(start: data, count: width * height * 4))
        transform.convertRGBA8(&pixels, width: width, height: height, bytesPerRow: width * 4)
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        lock.withLock {
            if entries[key] == nil {
                order.append(key)
            }
            entries[key] = (image, result)
            while order.count > ImageProofCache.capacity {
                entries[order.removeFirst()] = nil
            }
        }
        return result
    }
}
