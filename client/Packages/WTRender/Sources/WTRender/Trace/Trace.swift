// The trace kernel (IMG-021, IMG-022; docs/_includes/imported/tracing.adoc, "Client"): a
// sampled bitmap in, paths out.  Quantization (median cut, noise filtering) is
// `TraceQuantizer`, outline tracing (boundary following with hole polarity, polygon
// approximation, Schneider fitting) `TraceOutline`, centerline tracing (thinning, skeleton
// graph, width estimation) `TraceCenterline`.
//
// The spec places the kernel in `WTGeometry.Trace`; it lives here because it samples through
// the Core Graphics renderer and WTGeometry stays free of rendering (deviation recorded on the
// tracing page).  Coordinates: bitmap pixel space is y-down with pixel (x, y) covering
// [x, x + 1] × [y, y + 1]; every contour is mapped through the caller's bitmap → pasteboard
// transform before it is returned.

import WTGeometry
import CoreGraphics
import Foundation

/// Tracing a bitmap into vector paths.
public enum Trace {
    /// Thrown when the caller cancels a trace in flight.
    public struct Cancelled: Error, Hashable, Sendable {
        public init() {}
    }

    /// A straight-alpha RGBA8 bitmap, row 0 at the top.
    public struct Bitmap: Hashable, Sendable {
        public let width: Int
        public let height: Int
        /// `width * height * 4` bytes: red, green, blue, alpha per pixel, not premultiplied.
        public let pixels: [UInt8]

        /// Nil when the byte count does not match the dimensions or a dimension is not positive.
        public init?(width: Int, height: Int, pixels: [UInt8]) {
            guard width > 0, height > 0, pixels.count == width * height * 4 else {
                return nil
            }
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        /// The image drawn into an sRGB RGBA8 context and un-premultiplied; nil when no context
        /// can be made.
        public init?(cgImage image: CGImage) {
            let width = image.width
            let height = image.height
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return nil
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let source = context.data!.assumingMemoryBound(to: UInt8.self)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for index in 0..<(width * height) {
                let alpha = Int(source[index * 4 + 3])
                pixels[index * 4 + 3] = UInt8(alpha)
                for channel in 0..<3 {
                    let value = Int(source[index * 4 + channel])
                    pixels[index * 4 + channel] = alpha == 0 ? 0 : UInt8(min(255, (value * 255 + alpha / 2) / alpha))
                }
            }
            self.init(width: width, height: height, pixels: pixels)
        }
    }

    /// Rendering part of a canvas into a bitmap to trace (the spec's "Input" step).
    public enum Sampling {
        /// `rect` (pasteboard) of `displayList` rendered by the Core Graphics reference renderer
        /// over white at `pixelsPerPoint`, and the map from bitmap pixel space back to pasteboard
        /// space.  Nil for an empty rect or one too large to allocate.
        public static func render(_ displayList: DisplayList, rect: Rect, pixelsPerPoint: Double) -> (bitmap: Bitmap, transform: AffineTransform)? {
            guard !rect.isNull, rect.width > 0, rect.height > 0, pixelsPerPoint > 0 else {
                return nil
            }
            let viewport = Viewport(scrollOrigin: rect.origin, zoom: 1, size: Size(width: rect.width, height: rect.height))
            let renderer = CoreGraphicsRenderer(background: .white)
            guard let image = renderer.renderBitmap(displayList, viewport: viewport, scale: pixelsPerPoint),
                  let bitmap = Bitmap(cgImage: image)
            else {
                return nil
            }
            let transform = AffineTransform.scale(1 / pixelsPerPoint).concatenating(.translation(x: rect.minX, y: rect.minY))
            return (bitmap, transform)
        }
    }

    /// How the output colours are expressed.
    public enum ColorModel: Hashable, Sendable {
        case rgb
        /// Each path also carries a naive CMYK mix (K = 1 − max(R, G, B)).
        case cmyk
    }

    /// *Path overlap*: how far lighter regions extend under darker neighbours.
    public enum Overlap: Hashable, Sendable {
        case none
        /// 2 px.
        case loose
        /// 0.5 px.
        case tight

        var distance: Double {
            switch self {
            case .none: return 0
            case .loose: return 2
            case .tight: return 0.5
            }
        }
    }

    /// *Trace type*.
    public enum Mode: Hashable, Sendable {
        case outline
        case centerline
        /// Each connected feature narrower than `openPathsBelow` pixels becomes open strokes,
        /// every other feature outlines.
        case centerlineAndOutline(openPathsBelow: Double)
    }

    /// The Trace tool's options (the `trace_tool` preference).
    public struct Options: Hashable, Sendable {
        /// Palette entries, 2 ... 256.
        public var colors: Int
        /// Quantize to gray levels instead of colours.
        public var grays: Bool
        public var colorModel: ColorModel
        /// 0 off; 1 ... 5 a 3 × 3 majority filter of rising strength; larger values merge
        /// connected regions smaller than `noiseTolerance²` pixels into their neighbours.
        public var noiseTolerance: Int
        /// *Trace conformity* 0 ... 10: fitting tolerance `2.5 − 0.2 · conformity` pixels.
        public var conformity: Int
        public var overlap: Overlap
        /// Trace only the outline of everything that is not paper, holes removed.
        public var outerEdge: Bool
        public var mode: Mode
        /// Centerline strokes are 1 pt wide rather than measured.
        public var uniform: Bool
        /// Outlines are filled with their colour; off, they are stroked 1 pt instead (*Convert
        /// selection edge*).
        public var fillsPaths: Bool

        public init(
            colors: Int = 16,
            grays: Bool = false,
            colorModel: ColorModel = .rgb,
            noiseTolerance: Int = 0,
            conformity: Int = 5,
            overlap: Overlap = .none,
            outerEdge: Bool = false,
            mode: Mode = .outline,
            uniform: Bool = false,
            fillsPaths: Bool = true
        ) {
            self.colors = colors
            self.grays = grays
            self.colorModel = colorModel
            self.noiseTolerance = noiseTolerance
            self.conformity = conformity
            self.overlap = overlap
            self.outerEdge = outerEdge
            self.mode = mode
            self.uniform = uniform
            self.fillsPaths = fillsPaths
        }

        /// The fitting tolerance in pixels.
        public var tolerance: Double {
            2.5 - 0.2 * Double(min(max(conformity, 0), 10))
        }

        var effectiveColors: Int { min(max(colors, 2), 256) }
    }

    /// One traced path: closed filled outlines (outer contours positive in bitmap space, holes
    /// reversed) or open centerline strokes.
    public struct TracedPath: Hashable, Sendable {
        public var contours: [Contour]
        public var fill: Color?
        public var stroke: Color?
        /// Pasteboard units; nil when unstroked.
        public var strokeWidth: Double?
        /// The naive CMYK mix of the path's colour when the colour model is CMYK.
        public var cmyk: SIMD4<Double>?

        public init(contours: [Contour], fill: Color? = nil, stroke: Color? = nil, strokeWidth: Double? = nil, cmyk: SIMD4<Double>? = nil) {
            self.contours = contours
            self.fill = fill
            self.stroke = stroke
            self.strokeWidth = strokeWidth
            self.cmyk = cmyk
        }

        /// The path's colour as the document stores it: the CMYK mix as a CMYK colour in the
        /// CMYK colour model, otherwise the sRGB fill or stroke.
        public var color: Color? {
            guard let cmyk else {
                return fill ?? stroke
            }
            return Color(space: .cmyk, components: cmyk, alpha: (fill ?? stroke)?.alpha ?? 1)
        }
    }

    /// A trace's paths in painter's order (lighter regions first).
    public struct Result: Hashable, Sendable {
        public var paths: [TracedPath]

        public init(paths: [TracedPath]) {
            self.paths = paths
        }

        /// Every contour's segment count, summed.
        public var segmentCount: Int {
            paths.reduce(0) { $0 + $1.contours.reduce(0) { $0 + $1.segments.count } }
        }
    }

    /// Traces `bitmap` synchronously.  `transform` maps bitmap pixels to pasteboard space;
    /// `progress` receives 0 ... 1; `isCancelled` is polled at least once per row and per
    /// contour, and a true answer throws `Cancelled`.
    public static func run(
        _ bitmap: Bitmap,
        options: Options = Options(),
        transform: AffineTransform = .identity,
        progress: ((Double) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> Result {
        func check() throws {
            if isCancelled() {
                throw Cancelled()
            }
        }
        try check()
        var labels = try TraceQuantizer.quantize(bitmap, colors: options.effectiveColors, grays: options.grays, check: check)
        progress?(0.2)
        try TraceQuantizer.filterNoise(&labels, tolerance: options.noiseTolerance, check: check)
        progress?(0.3)
        let paths = try TraceStages.trace(labels, options: options, transform: transform, check: check) { fraction in
            progress?(0.3 + 0.7 * fraction)
        }
        progress?(1)
        return Result(paths: paths)
    }

    /// Traces `bitmap` off the caller's actor; cancelling the calling task cancels the trace,
    /// which then throws `Cancelled`.
    public static func trace(
        _ bitmap: Bitmap,
        options: Options = Options(),
        transform: AffineTransform = .identity,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Result {
        let task = Task.detached(priority: .userInitiated) {
            try run(bitmap, options: options, transform: transform, progress: progress, isCancelled: { Task.isCancelled })
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The contours of a binary mask (`mask[y * width + x] != 0` inside), in bitmap pixel
    /// space: outer contours positive, holes reversed (dropped when `keepHoles` is false),
    /// fitted at `conformity`.  The subject mask (IMG-027) and *Convert selection edge* use it.
    public static func outline(mask: [UInt8], width: Int, height: Int, conformity: Int = 6, keepHoles: Bool = true) -> [Contour] {
        guard width > 0, height > 0, mask.count == width * height else {
            return []
        }
        var tracer = TraceOutline(width: width, height: height)
        tracer.load { mask[$0] != 0 }
        let tolerance = Options(conformity: conformity).tolerance
        // A check that never throws never cancels.
        let loops = try! tracer.loops(check: {})
        return loops.compactMap { loop in
            guard keepHoles || loop.isOuter else {
                return nil
            }
            return TraceFitting.closedContour(loop.samples, tolerance: tolerance)
        }
    }

    /// The naive CMYK of an sRGB colour: K = 1 − max(R, G, B), the rest scaled by 1 − K.
    static func cmyk(of color: Color) -> SIMD4<Double> {
        let k = 1 - max(color.red, color.green, color.blue)
        guard k < 1 else {
            return SIMD4(0, 0, 0, 1)
        }
        return SIMD4((1 - color.red - k) / (1 - k), (1 - color.green - k) / (1 - k), (1 - color.blue - k) / (1 - k), k)
    }
}
