// Filling a region with a paint other than a solid colour, in Core Graphics (ATTR-014,
// ATTR-018, ATTR-019, ATTR-021, ATTR-027).  `PaintDrawing.fill` paints the *current clip* of a
// context whose user space is the item's local space; the Core Graphics renderer clips to the
// path and calls it, and the Metal renderer calls it on an unclipped offscreen bitmap aligned to
// its device pixels and composites the result through its own coverage of the path, so the two
// renderers agree on every interior pixel by construction (docs/spec/client.adoc, NOTE on the
// ATTR paints).
//
// Paints are defined in resolution-independent spaces: page-anchored ones (Pattern, Custom,
// Textured) in canvas (pasteboard) space, object-anchored ones (gradients, Tiled) in local
// space, lenses in device space from the display list beneath.  Sampled paints evaluate a grid
// anchored at their space's origin, so tiles, offscreens and repeated renders sample the same
// points.

import WTGeometry
import CoreGraphics
import Foundation

/// What a paint needs to know about where it is drawn.
struct PaintEnvironment {
    /// Draws nested display items (tiles, snapshots, backdrops) with the caller's settings.
    var renderer: CoreGraphicsRenderer
    /// Canvas (pasteboard) space → the context's base space, as it was when the canvas began:
    /// page-anchored paints hang off it and Core Graphics patterns are specified in it.
    var canvasToBase: CGAffineTransform
    /// The region being painted, in local space, and its rule (Contour, Auto size, placement).
    var path: DisplayPath
    var rule: FillRule
    /// Sampled paints are evaluated this many times finer than the base space (PDF output).
    var rasterScale: Double
    /// Where the item sits in its canvas, for a lens's backdrop; nil inside tiles, brush symbols
    /// and snapshots, where a lens renders as Basic.
    var canvas: DisplayList?
    var indexPath: [Int]
    /// How deep in lens backdrops this draw is.
    var lensDepth: Int
}

enum PaintDrawing {
    /// Paints the clip of `context` (user space = local) with `paint`.  Solid and None paints
    /// are the renderers' own business and do nothing here.
    static func fill(_ paint: Paint, in context: CGContext, environment: PaintEnvironment) {
        guard let bounds = environment.path.controlBounds else {
            return
        }
        switch paint {
        case .none, .solid:
            return
        case .gradient(let gradient):
            GradientRendering.fill(gradient, bounds: bounds, path: environment.path, rule: environment.rule, in: context, rasterScale: environment.rasterScale)
        case .pattern(let pattern):
            ProceduralFills.fill(pattern, in: context, environment: environment)
        case .custom(let custom):
            ProceduralFills.fill(custom, bounds: bounds, in: context, environment: environment)
        case .textured(let textured):
            ProceduralFills.fill(textured, in: context, environment: environment)
        case .tiled(let tiled):
            fill(tiled, in: context, environment: environment)
        case .lens(let lens):
            LensRendering.fill(lens, bounds: bounds, in: context, environment: environment)
        }
    }

    /// Canvas space → the context's current user space.
    static func canvasToUser(_ context: CGContext, environment: PaintEnvironment) -> CGAffineTransform {
        environment.canvasToBase.concatenating(context.ctm.inverted())
    }

    /// Local (the current user space) → canvas space.
    static func localToCanvas(_ context: CGContext, environment: PaintEnvironment) -> CGAffineTransform {
        context.ctm.concatenating(environment.canvasToBase.inverted())
    }

    // MARK: Tiled fills

    /// A Core Graphics pattern whose cell is the tile's bounds scaled, rotated by `angle` and
    /// phased by `offset` in local space; the cell draws the tile's display items.
    static func fill(_ tiled: TiledFill, in context: CGContext, environment: PaintEnvironment) {
        guard let cell = tiled.tileBounds else {
            return
        }
        let scale = tiled.effectiveScale
        let placement = CGAffineTransform(scaleX: scale.x, y: scale.y)
            .concatenating(CGAffineTransform(rotationAngle: (tiled.angle.isFinite ? tiled.angle : 0) * Double.pi / 180))
            .concatenating(CGAffineTransform(translationX: tiled.offset.x.isFinite ? tiled.offset.x : 0, y: tiled.offset.y.isFinite ? tiled.offset.y : 0))
        let matrix = placement.concatenating(context.ctm)
        let renderer = environment.renderer
        let items = tiled.tile
        fillPattern(in: context, bounds: cell.cg, matrix: matrix, step: CGSize(width: cell.width, height: cell.height)) { cellContext in
            renderer.drawNested(items, in: cellContext)
        }
    }

    /// Fills the clip of `context` with a coloured Core Graphics pattern: `bounds` in pattern
    /// space is one cell, repeated every `step`; `matrix` maps pattern space to the context's
    /// base space.
    static func fillPattern(in context: CGContext, bounds: CGRect, matrix: CGAffineTransform, step: CGSize, draw: @escaping (CGContext) -> Void) {
        let box = PatternBox(draw: draw)
        var callbacks = CGPatternCallbacks(
            version: 0,
            drawPattern: { info, cellContext in
                Unmanaged<PatternBox>.fromOpaque(info!).takeUnretainedValue().draw(cellContext)
            },
            releaseInfo: { info in
                Unmanaged<PatternBox>.fromOpaque(info!).release()
            }
        )
        guard let pattern = CGPattern(
            info: Unmanaged.passRetained(box).toOpaque(),
            bounds: bounds,
            matrix: matrix,
            xStep: step.width,
            yStep: step.height,
            tiling: .constantSpacing,
            isColored: true,
            callbacks: &callbacks
        ) else {
            return
        }
        context.saveGState()
        context.setFillColorSpace(CGColorSpace(patternBaseSpace: nil)!)
        var alpha: CGFloat = 1
        context.setFillPattern(pattern, colorComponents: &alpha)
        context.fill(context.boundingBoxOfClipPath)
        context.restoreGState()
    }

    private final class PatternBox {
        let draw: (CGContext) -> Void

        init(draw: @escaping (CGContext) -> Void) {
            self.draw = draw
        }
    }
}

/// Sampled paints: a function of a point in some paint space, evaluated on a grid anchored at
/// that space's origin over the part of the clip that needs it and drawn as an image.
enum RasterPaint {
    /// Grids larger than this on a side are coarsened.
    static let maxEdge = 4096

    /// Samples per paint-space unit for drawing through `space` (paint → user): the device
    /// scale (times `rasterScale`) rounded to a power of two in 1/4 ... 16, so nearby zooms
    /// share a grid.
    static func resolution(for context: CGContext, space: CGAffineTransform, rasterScale: Double) -> Double {
        let toDevice = space.concatenating(context.ctm)
        let scale = abs(toDevice.a * toDevice.d - toDevice.b * toDevice.c).squareRoot() * max(rasterScale, 1)
        guard scale.isFinite, scale > 0 else {
            return 1
        }
        return pow(2, min(max(log2(scale).rounded(), -2), 4))
    }

    /// Fills the clip of `context` with `sample` (straight-alpha sRGB) evaluated in the space
    /// `space` maps into the context's user space.  Grids wider or taller than `maxEdge` are
    /// coarsened by halving the resolution.
    static func fill(
        _ context: CGContext,
        space: CGAffineTransform,
        rasterScale: Double,
        interpolation: CGInterpolationQuality,
        resolution fixed: Double? = nil,
        maxEdge: Int = RasterPaint.maxEdge,
        sample: (Point) -> SIMD4<Double>
    ) {
        let clip = context.boundingBoxOfClipPath
        guard !clip.isNull, !clip.isInfinite, clip.width > 0, clip.height > 0 else {
            return
        }
        let region = clip.applying(space.inverted())
        guard region.minX.isFinite, region.minY.isFinite, region.maxX.isFinite, region.maxY.isFinite,
              max(abs(region.minX), abs(region.minY), abs(region.maxX), abs(region.maxY)) < 1e8
        else {
            return
        }
        let toDevice = space.concatenating(context.ctm)
        let deviceScale = max(abs(toDevice.a * toDevice.d - toDevice.b * toDevice.c).squareRoot(), 1e-9)
        var resolution = fixed ?? RasterPaint.resolution(for: context, space: space, rasterScale: rasterScale)
        // Enough padding that the image filter never reaches the clamped border within the
        // clip: three device pixels' worth of samples, at least two.
        func padding() -> Int { max(2, Int((3 * resolution / deviceScale).rounded(.up))) }
        var grid = RasterPaint.grid(region, resolution: resolution, padding: padding())
        while (grid.width > maxEdge || grid.height > maxEdge) && resolution > 1e-3 {
            resolution /= 2
            grid = RasterPaint.grid(region, resolution: resolution, padding: padding())
        }
        guard grid.width > 0, grid.height > 0, let surface = BitmapSurface(width: grid.width, height: grid.height) else {
            return
        }
        let bytes = surface.context.data!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = surface.context.bytesPerRow
        for row in 0..<grid.height {
            // Image row 0 is drawn at the top of the rectangle, which in y-down paint space is
            // the largest y.
            let j = grid.y0 + (grid.height - 1 - row)
            let y = (Double(j) + 0.5) / resolution
            for column in 0..<grid.width {
                let x = (Double(grid.x0 + column) + 0.5) / resolution
                let color = sample(Point(x: x, y: y))
                let alpha = min(max(color.w, 0), 1)
                let offset = row * rowBytes + column * 4
                bytes[offset] = UInt8((min(max(color.x, 0), 1) * alpha * 255).rounded())
                bytes[offset + 1] = UInt8((min(max(color.y, 0), 1) * alpha * 255).rounded())
                bytes[offset + 2] = UInt8((min(max(color.z, 0), 1) * alpha * 255).rounded())
                bytes[offset + 3] = UInt8((alpha * 255).rounded())
            }
        }
        guard let image = surface.makeImage() else {
            return
        }
        context.saveGState()
        context.concatenate(space)
        context.interpolationQuality = interpolation
        context.draw(image, in: CGRect(x: Double(grid.x0) / resolution, y: Double(grid.y0) / resolution, width: Double(grid.width) / resolution, height: Double(grid.height) / resolution))
        context.restoreGState()
    }

    /// Fills the clip of `context` with the coverage of `sample` (straight-alpha sRGB, in the
    /// space `space` maps into user space) computed per base-space pixel from `supersample` ×
    /// `supersample` samples, drawn back pixel for pixel.  Every pixel is a function of its own
    /// position alone, so a tile and an offscreen of the same pixels agree exactly -- which Core
    /// Graphics' own resampling of a rotated image or pattern does not guarantee.
    static func fillDevice(_ context: CGContext, space: CGAffineTransform, supersample: Int, sample: (Point) -> SIMD4<Double>) {
        let clip = context.boundingBoxOfClipPath
        guard !clip.isNull, !clip.isInfinite, clip.width > 0, clip.height > 0 else {
            return
        }
        let device = clip.applying(context.ctm)
        guard max(abs(device.minX), abs(device.minY), abs(device.maxX), abs(device.maxY)) < 1e7,
              let paintFromDevice = space.concatenating(context.ctm).invertedIfPossible
        else {
            return
        }
        let minX = Int(device.minX.rounded(.down))
        let minY = Int(device.minY.rounded(.down))
        let width = Int(device.maxX.rounded(.up)) - minX
        let height = Int(device.maxY.rounded(.up)) - minY
        guard width > 0, height > 0, width <= 8192, height <= 8192, let surface = BitmapSurface(width: width, height: height) else {
            return
        }
        let bytes = surface.context.data!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = surface.context.bytesPerRow
        let n = max(supersample, 1)
        let weight = 1 / Double(n * n)
        for row in 0..<height {
            // Base space is y-up: image row 0 is the top pixel row.
            let y = Double(minY + height - 1 - row)
            for column in 0..<width {
                let x = Double(minX + column)
                var sum = SIMD4<Double>(0, 0, 0, 0)
                for a in 0..<n {
                    for b in 0..<n {
                        let base = CGPoint(x: x + (Double(a) + 0.5) / Double(n), y: y + (Double(b) + 0.5) / Double(n)).applying(paintFromDevice)
                        let color = sample(Point(x: Double(base.x), y: Double(base.y)))
                        let alpha = min(max(color.w, 0), 1)
                        sum += SIMD4(color.x * alpha, color.y * alpha, color.z * alpha, alpha)
                    }
                }
                let offset = row * rowBytes + column * 4
                for channel in 0..<4 {
                    bytes[offset + channel] = UInt8((min(max(sum[channel] * weight, 0), 1) * 255).rounded())
                }
            }
        }
        guard let image = surface.makeImage() else {
            return
        }
        context.saveGState()
        context.concatenate(context.ctm.inverted())
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: minX, y: minY, width: width, height: height))
        context.restoreGState()
    }

    /// The sample grid covering `region` at `resolution`, padded by `padding` samples.
    static func grid(_ region: CGRect, resolution: Double, padding: Int = 2) -> (x0: Int, y0: Int, width: Int, height: Int) {
        let x0 = Int((region.minX * resolution).rounded(.down)) - padding
        let y0 = Int((region.minY * resolution).rounded(.down)) - padding
        let x1 = Int((region.maxX * resolution).rounded(.up)) + padding
        let y1 = Int((region.maxY * resolution).rounded(.up)) + padding
        return (x0, y0, max(x1 - x0, 0), max(y1 - y0, 0))
    }
}
