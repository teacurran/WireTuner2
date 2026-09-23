// Lens fills (ATTR-019; docs/_includes/appearance/fill-attributes.adoc, "Client").  The objects
// below the lens object in its canvas (everything drawn before it, groups' clips and opacity
// kept) are rendered into an offscreen backdrop over white paper for the lens's device bounds,
// aligned with the device pixels; the lens then composites: Transparency = colour at `amount`
// over the backdrop; Magnify = the backdrop drawn scaled about the centerpoint (re-rendered
// through the magnification, so it stays sharp); Invert = the complement; Lighten and Darken =
// white or black at `amount`; Monochrome = the backdrop's luminance mapped to tints of `color`.
// Objects only masks the result to what the objects painted; a Snapshot renders the captured
// items instead of the live backdrop.  Nested lenses recurse up to a depth of 8; a lens deeper
// than that, or inside a tile, brush symbol or snapshot, renders as a Basic fill.

import WTGeometry
import CoreGraphics
import Foundation
import os

enum LensRendering {
    /// Backdrops within backdrops deeper than this render the lens as Basic.
    static let maxDepth = 8

    private static let logger = Logger(subsystem: "com.villagecompute.wiretuner", category: "render")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var capHits = 0

    /// How many times a lens rendered as Basic because it was nested too deeply (the log
    /// entry's counter, for tests and diagnostics).
    static var depthCapCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return capHits
    }

    static func fill(_ lens: LensFill, bounds: Rect, in context: CGContext, environment: PaintEnvironment) {
        guard let canvas = environment.canvas else {
            fillBasic(lens, in: context)
            return
        }
        guard environment.lensDepth < maxDepth else {
            lock.lock()
            capHits += 1
            lock.unlock()
            logger.notice("lens nested deeper than \(maxDepth, privacy: .public) levels renders as Basic")
            fillBasic(lens, in: context)
            return
        }
        // The device pixels to produce: the clip's bounding box in base space, times the
        // raster scale, rounded out.
        let scale = max(environment.rasterScale, 1)
        let clipInBase = context.boundingBoxOfClipPath.applying(context.ctm)
        guard !clipInBase.isNull, !clipInBase.isInfinite, abs(clipInBase.minX) < 1e7, abs(clipInBase.minY) < 1e7 else {
            return
        }
        let region = CGRect(
            x: (clipInBase.minX * scale).rounded(.down),
            y: (clipInBase.minY * scale).rounded(.down),
            width: 0, height: 0
        )
        let width = Int((clipInBase.maxX * scale).rounded(.up) - region.minX)
        let height = Int((clipInBase.maxY * scale).rounded(.up) - region.minY)
        guard width > 0, height > 0, width <= 8192, height <= 8192 else {
            return
        }
        let pixelRect = CGRect(x: region.minX, y: region.minY, width: Double(width), height: Double(height))
        let localToCanvas = PaintDrawing.localToCanvas(context, environment: environment)
        let prefix = lens.snapshot == nil ? canvas.items(before: environment.indexPath) : []

        /// The backdrop over `paper` (nil: transparent, for the objects' coverage).
        func backdrop(paper: Color?) -> BitmapSurface? {
            guard let surface = BitmapSurface(width: width, height: height) else {
                return nil
            }
            let target = surface.context
            if let paper {
                target.setFillColor(paper.cg)
                target.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            target.translateBy(x: -pixelRect.minX, y: -pixelRect.minY)
            target.scaleBy(x: scale, y: scale)
            target.concatenate(environment.canvasToBase)
            if let snapshot = lens.snapshot {
                target.concatenate(localToCanvas)
                environment.renderer.drawNested(snapshot, in: target)
                return surface
            }
            if lens.type == .magnify {
                let center = lens.centerpoint ?? Point(x: bounds.midX, y: bounds.midY)
                let m = lens.effectiveMagnification
                let magnify = CGAffineTransform(translationX: -center.x, y: -center.y)
                    .concatenating(CGAffineTransform(scaleX: m, y: m))
                    .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
                target.concatenate(localToCanvas.inverted().concatenating(magnify).concatenating(localToCanvas))
            }
            environment.renderer.drawCanvasItems(prefix, canvas: canvas, in: target, lensDepth: environment.lensDepth + 1)
            return surface
        }

        guard let seen = backdrop(paper: .white) else {
            return
        }
        let coverage = lens.objectsOnly ? backdrop(paper: nil) : nil
        composite(lens, backdrop: seen, coverage: coverage)
        guard let image = seen.makeImage() else {
            return
        }
        context.saveGState()
        context.concatenate(context.ctm.inverted())
        context.scaleBy(x: 1 / scale, y: 1 / scale)
        context.interpolationQuality = .none
        context.draw(image, in: pixelRect)
        context.restoreGState()
    }

    /// A lens that cannot look beneath itself: Basic `color` at `amount` percent tint.
    static func fillBasic(_ lens: LensFill, in context: CGContext) {
        context.setFillColor(lens.basicColor.cg)
        context.fill(context.boundingBoxOfClipPath)
    }

    /// Applies the lens to `backdrop` (opaque, premultiplied) in place, masked by `coverage`'s
    /// alpha when given.
    static func composite(_ lens: LensFill, backdrop: BitmapSurface, coverage: BitmapSurface?) {
        let bytes = backdrop.context.data!.assumingMemoryBound(to: UInt8.self)
        let mask = coverage.map { $0.context.data!.assumingMemoryBound(to: UInt8.self) }
        let rowBytes = backdrop.context.bytesPerRow
        let maskRowBytes = coverage?.context.bytesPerRow ?? 0
        let f = lens.fraction
        let color = SIMD3(lens.color.red, lens.color.green, lens.color.blue)
        for row in 0..<backdrop.height {
            for column in 0..<backdrop.width {
                let offset = row * rowBytes + column * 4
                let seen = SIMD3(Double(bytes[offset]), Double(bytes[offset + 1]), Double(bytes[offset + 2])) / 255
                var out: SIMD3<Double>
                switch lens.type {
                case .transparency: out = color * f + seen * (1 - f)
                case .magnify: out = seen
                case .invert: out = SIMD3(1, 1, 1) - seen
                case .lighten: out = seen + (SIMD3(1, 1, 1) - seen) * f
                case .darken: out = seen * (1 - f)
                case .monochrome:
                    let luminance = 0.2126 * seen.x + 0.7152 * seen.y + 0.0722 * seen.z
                    out = color + (SIMD3(1, 1, 1) - color) * luminance
                }
                var alpha = 1.0
                if let mask {
                    alpha = Double(mask[row * maskRowBytes + column * 4 + 3]) / 255
                }
                bytes[offset] = UInt8((min(max(out.x, 0), 1) * alpha * 255).rounded())
                bytes[offset + 1] = UInt8((min(max(out.y, 0), 1) * alpha * 255).rounded())
                bytes[offset + 2] = UInt8((min(max(out.z, 0), 1) * alpha * 255).rounded())
                bytes[offset + 3] = UInt8((alpha * 255).rounded())
            }
        }
    }
}
