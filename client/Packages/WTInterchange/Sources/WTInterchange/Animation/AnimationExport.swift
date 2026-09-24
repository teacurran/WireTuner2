// Animation export (animation.adoc, "Exporting an animation" and "Client"; WEB-019, WEB-020):
// the frames of the document's animation -- WTRender's `FrameComposer` frame list, each frame the
// canvas list restricted to its layers -- rasterized at the export size by the bitmap
// rasterizer (WTRender's Core Graphics renderer, supersampled) and written as an animated GIF,
// an APNG or an MP4 movie, one file holding every frame.  Frame timing is the document's frame
// rate (or the options'), each frame shown for its hold times the period.

import CoreGraphics
import Foundation
import WTGeometry
import WTRender

/// The document's animation as an export reads it (`AnimationSettings` and the frame list),
/// taken with the snapshot.
public struct ExportAnimation: Sendable {
    /// *Background*: what lies behind every frame.
    public enum Background: Hashable, Sendable {
        case pageColor
        case white
        case transparent
    }

    /// `FrameComposer.frames(source:layers:pages:)` of the document.
    public var frames: [AnimationFrame]
    /// Frames per second as stored; 0 reads as 12.
    public var fps: Double
    public var loop: Bool
    public var background: Background
    /// The canvas display list with its layer spans: a frame draws it restricted to its layers.
    public var displayList: DisplayList
    /// What a frame on no page shows (the Layers source): the page or output area exported.
    public var area: Rect
    /// The page colour (Document panel), for *Page color*.
    public var pageColor: Color?
    /// *Autoplay*: exported SVG and HTML start playing on load; off shows frame 1 until the
    /// viewer hovers or clicks (WEB-018).
    public var autoplay: Bool

    public init(frames: [AnimationFrame], fps: Double = FrameComposer.defaultFPS, loop: Bool = true, background: Background = .pageColor, displayList: DisplayList, area: Rect, pageColor: Color? = nil,
                autoplay: Bool = true) {
        self.frames = frames
        self.fps = fps
        self.loop = loop
        self.background = background
        self.displayList = displayList
        self.area = area
        self.pageColor = pageColor
        self.autoplay = autoplay
    }
}

/// The options every animation format shares (the Export sheet's *Options…*).
public struct AnimationCommonOptions: Hashable, Sendable {
    public enum Size: Hashable, Sendable {
        /// Points times this factor: 1 is one pixel per point.
        case scale(Double)
        /// An explicit pixel size; the frame is scaled to fit and centred on the background.
        case pixels(width: Int, height: Int)
    }

    public enum Loop: Hashable, Sendable {
        /// The document's *Loop*: forever when on, once when off.
        case document
        case forever
        /// Played this many times in all (1 plays once).
        case count(Int)
    }

    public var size: Size
    /// Frames per second; nil uses the document's.
    public var fps: Double?
    public var loop: Loop
    /// *Pages* to export (page indices); nil exports every frame.  Frames on no page (the
    /// Layers source) are always exported.
    public var pages: Set<Int>?
    /// Nil uses the document's *Background*.
    public var background: ExportAnimation.Background?
    /// The supersampling factor, 1 ... 4.
    public var antiAliasing: Int

    public init(size: Size = .scale(1), fps: Double? = nil, loop: Loop = .document, pages: Set<Int>? = nil, background: ExportAnimation.Background? = nil, antiAliasing: Int = 4) {
        self.size = size
        self.fps = fps
        self.loop = loop
        self.pages = pages
        self.background = background
        self.antiAliasing = antiAliasing
    }

    func validate() throws {
        switch size {
        case .scale(let factor):
            guard factor.isFinite, factor > 0, factor <= 16 else {
                throw ExportError.invalidOption("The scale must be between 0 and 16.")
            }
        case .pixels(let width, let height):
            guard (1...16384).contains(width), (1...16384).contains(height) else {
                throw ExportError.invalidOption("The pixel size must be 1 to 16,384 on each side.")
            }
        }
        if let fps {
            guard fps.isFinite, fps >= 0.01, fps <= 120 else {
                throw ExportError.invalidOption("The frame rate must be 0.01 to 120 frames per second.")
            }
        }
        if case .count(let count) = loop, count < 1 {
            throw ExportError.invalidOption("The loop count must be at least 1.")
        }
        guard (1...4).contains(antiAliasing) else {
            throw ExportError.invalidOption("Anti-aliasing must be None, 2, 3 or 4.")
        }
    }

    /// Plays in all (0: forever).
    func plays(documentLoop: Bool) -> Int {
        switch loop {
        case .document: return documentLoop ? 0 : 1
        case .forever: return 0
        case .count(let count): return count
        }
    }
}

/// Animated GIF options: the common ones, *Colors* and *Dither*.
public struct AnimatedGIFOptions: ExportOptions, Hashable {
    public var common: AnimationCommonOptions
    /// Colours per frame, 2 ... 256 (each frame has its own palette).
    public var colors: Int
    /// Error-diffusion dither, 0 ... 100%.
    public var ditherPercent: Int

    public init(common: AnimationCommonOptions = AnimationCommonOptions(), colors: Int = 256, ditherPercent: Int = 0) {
        self.common = common
        self.colors = colors
        self.ditherPercent = ditherPercent
    }

    public static var defaults: AnimatedGIFOptions { AnimatedGIFOptions() }
}

/// APNG options: full colour with real transparency.
public struct APNGOptions: ExportOptions, Hashable {
    public var common: AnimationCommonOptions

    public init(common: AnimationCommonOptions = AnimationCommonOptions()) {
        self.common = common
    }

    public static var defaults: APNGOptions { APNGOptions() }
}

/// MP4 options: the codec comes from the format (H.264 or HEVC).
public struct MP4Options: ExportOptions, Hashable {
    public var common: AnimationCommonOptions
    /// *Quality*, 1 ... 100: the bit rate per pixel and frame.
    public var quality: Int

    public init(common: AnimationCommonOptions = AnimationCommonOptions(), quality: Int = 75) {
        self.common = common
        self.quality = quality
    }

    public static var defaults: MP4Options { MP4Options() }
}

/// The frames an export writes, when each is shown, and how to draw it.
struct AnimationPlan {
    let animation: ExportAnimation
    let frames: [AnimationFrame]
    let timeline: AnimationTimeline
    let background: ExportAnimation.Background
    let width: Int
    let height: Int
    let antiAliasing: Int
    /// Plays in all (0: forever).
    let plays: Int
    /// The size was rounded down to even pixels (MP4).
    let evened: Bool
    /// Each frame's drawn rectangle is scaled by this into pixels.
    private let pixelsPerPoint: Double

    /// The plan for `scene`'s animation with `options`; an MP4 rounds the size down to even
    /// pixels.  Throws `nothingToExport` for a document without frames.
    init(scene: ExportScene, options: AnimationCommonOptions, evenSize: Bool = false) throws {
        try options.validate()
        guard let animation = scene.animation else {
            throw ExportError.nothingToExport
        }
        let frames = animation.frames.filter { frame in frame.page.map { options.pages?.contains($0) ?? true } ?? true }
        guard let first = frames.first else {
            throw ExportError.nothingToExport
        }
        self.animation = animation
        self.frames = frames
        timeline = AnimationTimeline(frames: frames, fps: options.fps ?? animation.fps, loop: animation.loop)
        background = options.background ?? animation.background
        antiAliasing = options.antiAliasing
        plays = options.plays(documentLoop: animation.loop)
        let rect = first.pageRect ?? animation.area
        var width: Int
        var height: Int
        switch options.size {
        case .scale(let factor):
            width = max(Int((rect.width * factor).rounded()), 1)
            height = max(Int((rect.height * factor).rounded()), 1)
        case .pixels(let w, let h):
            (width, height) = (w, h)
        }
        evened = evenSize && (width % 2 != 0 || height % 2 != 0)
        if evenSize {
            width = max(width - width % 2, 2)
            height = max(height - height % 2, 2)
        }
        self.width = width
        self.height = height
        pixelsPerPoint = min(Double(width) / max(rect.width, 0.001), Double(height) / max(rect.height, 0.001))
    }

    /// The frame's page area widened to the output's proportions around its centre, so the
    /// rasterizer's pixel size is exactly `width` × `height` with the frame fitted in it.
    func bounds(of frame: AnimationFrame) -> Rect {
        let rect = frame.pageRect ?? animation.area
        let width = Double(self.width) / pixelsPerPoint
        let height = Double(self.height) / pixelsPerPoint
        return Rect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    /// Frame `index` rendered: straight-edged pixels, with alpha when `alpha` and the
    /// background is transparent, otherwise over the background.
    func render(_ index: Int, alpha: Bool) -> RasterBitmap {
        let frame = frames[index]
        let page = ExportPage(bounds: bounds(of: frame), displayList: FrameComposer.displayList(animation.displayList, for: frame), background: animation.pageColor)
        let transparent = alpha && background == .transparent
        let common = BitmapCommonOptions(
            ppi: 72 * pixelsPerPoint, antiAliasing: antiAliasing,
            background: transparent ? .transparent : (background == .pageColor ? .pageColor : .white),
            rgbSpace: .sRGB
        )
        return BitmapRasterizer(common: common).render(page, scale: 1, bitsPerComponent: 8, alpha: transparent).bitmap
    }

    /// Frame `index` as an image whose pixels are held in memory.
    func image(_ index: Int, alpha: Bool) -> CGImage {
        let bitmap = render(index, alpha: alpha)
        var bytes = Data(capacity: bitmap.bytesPerRow * bitmap.height)
        for band in 0..<bitmap.bandCount {
            bytes.append(bitmap.band(band))
        }
        let provider = CGDataProvider(data: bytes as CFData)!
        return CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bitmap.bytesPerRow, space: bitmap.colorSpace, bitmapInfo: bitmap.bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Where each frame starts and ends in seconds.
    func times(_ index: Int) -> (start: Double, end: Double) {
        let start = timeline.holds[..<index].reduce(0, +)
        return (Double(start) / timeline.fps, Double(start + timeline.holds[index]) / timeline.fps)
    }

    /// GIF's delays: centiseconds between rounded frame boundaries, so rounding never drifts;
    /// a frame that would last under 2 cs -- which browsers stretch to 10 cs -- is dropped and
    /// its time given to the frame before, as playback drops frames rather than slowing down.
    func centisecondDelays() -> (frames: [(index: Int, delay: Int)], dropped: Int) {
        func centiseconds(_ seconds: Double) -> Int { Int((seconds * 100).rounded()) }
        var kept: [(index: Int, start: Int)] = []
        for index in frames.indices {
            let start = centiseconds(times(index).start)
            if let last = kept.last, start - last.start < 2 {
                continue
            }
            kept.append((index, start))
        }
        let end = centiseconds(times(frames.count - 1).end)
        if kept.count > 1, end - kept[kept.count - 1].start < 2 {
            kept.removeLast()
        }
        var result: [(index: Int, delay: Int)] = []
        for (position, entry) in kept.enumerated() {
            let next = position + 1 < kept.count ? kept[position + 1].start : end
            result.append((entry.index, max(next - entry.start, 2)))
        }
        return (result, frames.count - result.count)
    }
}

/// Writes the animation formats: GIF (animated), APNG and MP4 (H.264, HEVC).
public struct AnimationExporter: Exporter {
    public let format: ExportFormat
    /// Reports the fraction done and is checked for cancellation between frames.
    public var progress: ExportProgress?

    public init(format: ExportFormat, progress: ExportProgress? = nil) {
        precondition(format.family == .animation, "\(format) is not an animation format")
        self.format = format
        self.progress = progress
    }

    public var optionsType: any ExportOptions.Type {
        switch format {
        case .animatedGIF: return AnimatedGIFOptions.self
        case .apng: return APNGOptions.self
        default: return MP4Options.self
        }
    }

    public var capabilities: ExportCapabilities { format.capabilities }

    public func export(scene: ExportScene, options: any ExportOptions, to destination: ExportDestination) throws -> ExportSummary {
        let url = destination.url.deletingPathExtension().appendingPathExtension(format.fileExtension)
        let progress = self.progress ?? ExportProgress()
        let notes: [String]
        do {
            switch format {
            case .animatedGIF:
                notes = try AnimatedImageWriter.writeGIF(scene: scene, options: typed(options, as: AnimatedGIFOptions.self), to: url, progress: progress)
            case .apng:
                notes = try AnimatedImageWriter.writeAPNG(scene: scene, options: typed(options, as: APNGOptions.self), to: url, progress: progress)
            default:
                notes = try MovieWriter(codec: format == .mp4HEVC ? .hevc : .h264).write(scene: scene, options: typed(options, as: MP4Options.self), to: url, progress: progress)
            }
        } catch ExportError.cancelled {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.cancelled
        }
        progress.report(1)
        return ExportSummary(files: [url], notes: notes)
    }

    /// The export run off the calling actor: cancelling the calling task cancels it (the partial
    /// file is removed and `ExportError.cancelled` thrown).
    public func export(scene: ExportScene, options: any ExportOptions, to destination: ExportDestination, progress: ExportProgress) async throws -> ExportSummary {
        var exporter = self
        exporter.progress = progress
        let running = exporter
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try running.export(scene: scene, options: options, to: destination)
            }.value
        } onCancel: {
            progress.cancel()
        }
    }
}
