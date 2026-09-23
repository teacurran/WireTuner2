// Frame-by-frame animation (WEB-016; docs/_includes/web/animation.adoc, "Client").  The frame
// list is derived from the layers or pages -- never stored -- and a frame is shown by drawing
// the display list restricted to its layers (the same mechanism as layer visibility, without
// writing visibility to the document, and without rebuilding the list).  Playback advances by
// wall-clock time at the document's frame rate, holds multiplying a frame's period, dropping
// frames rather than slowing down.

import CoreGraphics
import Foundation
import WTGeometry

/// `FrameSource`.
public enum FrameSource: Hashable, Sendable {
    /// Not animated.
    case none
    /// Each foreground layer, bottom to top, is one frame.
    case layers
    /// Each page is one frame.
    case pages
    /// Every page contributes one frame per foreground layer.
    case pagesAndLayers
}

/// A layer as the frame list reads it (`LayerProps` with `LayerFrameProps`).
public struct AnimationLayer: Hashable, Sendable {
    public var id: NodeID
    /// Above the separator: a frame; below it: background, in every frame.
    public var printing: Bool
    public var visible: Bool
    /// *Exclude from animation*: in no frame.
    public var excluded: Bool
    /// Frame periods the layer stays on screen; 0 reads as 1.
    public var hold: Int
    public var isGuides: Bool

    public init(id: NodeID, printing: Bool = true, visible: Bool = true, excluded: Bool = false, hold: Int = 1, isGuides: Bool = false) {
        self.id = id
        self.printing = printing
        self.visible = visible
        self.excluded = excluded
        self.hold = hold
        self.isGuides = isGuides
    }

    var effectiveHold: Int { max(hold, 1) }
    var animates: Bool { visible && !excluded && !isGuides }
}

/// One frame: which layers show, on which page, for how many periods.
public struct AnimationFrame: Hashable, Sendable {
    /// The layers drawn: the background layers and the frame's own, bottom first.
    public var layers: [NodeID]
    /// The frame's page (index into the pages given), nil for a layers-only frame.
    public var page: Int?
    /// The page's rectangle on the pasteboard.
    public var pageRect: Rect?
    /// Frame periods it stays on screen.
    public var hold: Int
}

/// Builds frame lists and draws frames.
public enum FrameComposer {
    /// The frame rate a stored 0 reads as.
    public static let defaultFPS = 12.0

    /// The frames of a document whose layers are `layers` (bottom first, in `LayerOrder`) and
    /// whose pages are `pages` (pasteboard rectangles in page order).
    public static func frames(source: FrameSource, layers: [AnimationLayer], pages: [Rect]) -> [AnimationFrame] {
        let background = layers.filter { $0.animates && !$0.printing }.map(\.id)
        let foreground = layers.filter { $0.animates && $0.printing }
        switch source {
        case .none:
            return []
        case .layers:
            return foreground.map { AnimationFrame(layers: background + [$0.id], page: nil, pageRect: nil, hold: $0.effectiveHold) }
        case .pages:
            let all = layers.filter(\.animates).map(\.id)
            return pages.enumerated().map { AnimationFrame(layers: all, page: $0.offset, pageRect: $0.element, hold: 1) }
        case .pagesAndLayers:
            return pages.enumerated().flatMap { page in
                foreground.map { AnimationFrame(layers: background + [$0.id], page: page.offset, pageRect: page.element, hold: $0.effectiveHold) }
            }
        }
    }

    /// The list as frame `frame` shows it: only its layers' items (and items on no layer).
    public static func displayList(_ displayList: DisplayList, for frame: AnimationFrame) -> DisplayList {
        displayList.restricted(toLayers: Set(frame.layers))
    }

    /// Frame `frame` rasterized at `pixelWidth` × `pixelHeight`: its page (or `area` when
    /// given, or the list's bounds) scaled to fit, over `background` (nil: transparent).
    public static func rasterize(_ displayList: DisplayList, frame: AnimationFrame, area: Rect? = nil, pixelWidth: Int, pixelHeight: Int, background: Color? = nil, renderer: CoreGraphicsRenderer = CoreGraphicsRenderer()) -> CGImage? {
        guard let rect = area ?? frame.pageRect ?? displayList.bounds, rect.width > 0, rect.height > 0, pixelWidth > 0, pixelHeight > 0 else {
            return nil
        }
        let scale = min(Double(pixelWidth) / rect.width, Double(pixelHeight) / rect.height)
        let viewport = Viewport(scrollOrigin: Point(x: rect.minX, y: rect.minY), zoom: 1, size: Size(width: Double(pixelWidth) / scale, height: Double(pixelHeight) / scale))
        var drawing = CoreGraphicsRenderer(flatteningTolerance: renderer.flatteningTolerance, background: background, viewMode: .preview, overprintPreview: renderer.overprintPreview)
        drawing.colorManagement = renderer.colorManagement
        drawing.imageStore = renderer.imageStore
        guard let surface = BitmapSurface(width: pixelWidth, height: pixelHeight, colorSpace: drawing.colorManagement.colorSpace) else {
            return nil
        }
        surface.context.scaleBy(x: scale, y: scale)
        drawing.render(FrameComposer.displayList(displayList, for: frame), viewport: viewport, into: surface.context)
        return surface.makeImage()
    }
}

/// Which frame shows when, from wall-clock time: playback at `fps`, each frame for its hold
/// times the period, looping or stopping at the last frame.
public struct AnimationTimeline: Hashable, Sendable {
    public let holds: [Int]
    public let fps: Double
    public let loop: Bool
    /// Where each frame starts, in periods; the last entry is the total.
    private let starts: [Int]

    /// `fps` of 0 (never written) reads as 12; values are clamped to 0.01...120.
    public init(frames: [AnimationFrame], fps: Double, loop: Bool) {
        holds = frames.map { max($0.hold, 1) }
        let rate = fps.isFinite && fps > 0 ? fps : FrameComposer.defaultFPS
        self.fps = min(max(rate, 0.01), 120)
        self.loop = loop
        var starts = [0]
        for hold in holds {
            starts.append(starts[starts.count - 1] + hold)
        }
        self.starts = starts
    }

    /// Periods in one pass.
    public var totalPeriods: Int { starts[starts.count - 1] }

    /// Seconds in one pass.
    public var duration: Double { Double(totalPeriods) / fps }

    /// The frame showing `seconds` after playback started from `startFrame`; nil once a
    /// non-looping animation has played its last frame through (it then stays on the last).
    public func frame(at seconds: Double, startingAt startFrame: Int = 0) -> Int? {
        guard totalPeriods > 0 else {
            return nil
        }
        let offset = starts[min(max(startFrame, 0), holds.count - 1)]
        var period = offset + Int((max(seconds, 0) * fps).rounded(.down))
        if period >= totalPeriods {
            guard loop else {
                return nil
            }
            period %= totalPeriods
        }
        var low = 0, high = holds.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= period {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }
}

/// Something that calls back on every display refresh (the canvas's display link) or on a
/// timer, with the current time in seconds.
@MainActor
public protocol PlaybackTicker: AnyObject {
    func start(_ tick: @escaping @MainActor (Double) -> Void)
    func stop()
}

/// A main-queue timer ticking at `interval`: the ticker when no display link is at hand.
@MainActor
public final class TimerTicker: PlaybackTicker {
    public let interval: Double
    private var timer: DispatchSourceTimer?

    public init(interval: Double = 1.0 / 120) {
        self.interval = max(interval, 0.001)
    }

    public func start(_ tick: @escaping @MainActor (Double) -> Void) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler {
            MainActor.assumeIsolated {
                tick(ProcessInfo.processInfo.systemUptime)
            }
        }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }
}

/// Canvas playback: the current frame as time passes, reported when it changes.  Preview mode
/// writes nothing to the document; the canvas draws `FrameComposer.displayList(_:for:)` of
/// the current list, so a remote change shows in the next frame.
@MainActor
public final class AnimationPlayer {
    public let timeline: AnimationTimeline
    private let ticker: PlaybackTicker
    /// Called with the new frame index whenever it changes.
    public var onFrame: (@MainActor (Int) -> Void)?
    public private(set) var currentFrame: Int
    public private(set) var isPlaying = false
    private var startTime: Double?
    private var startFrame = 0

    public init(timeline: AnimationTimeline, ticker: PlaybackTicker, frame: Int = 0) {
        self.timeline = timeline
        self.ticker = ticker
        currentFrame = min(max(frame, 0), max(timeline.holds.count - 1, 0))
    }

    /// Plays from the current frame (from the first when a non-looping run had ended on the
    /// last).
    public func play() {
        guard !isPlaying, !timeline.holds.isEmpty else { return }
        isPlaying = true
        startTime = nil
        startFrame = !timeline.loop && currentFrame == timeline.holds.count - 1 ? 0 : currentFrame
        ticker.start { [weak self] now in
            self?.tick(at: now)
        }
    }

    public func stop() {
        guard isPlaying else { return }
        isPlaying = false
        ticker.stop()
    }

    /// Advances to the frame due at `now` (seconds on the ticker's clock).
    public func tick(at now: Double) {
        guard isPlaying else { return }
        let start = startTime ?? now
        startTime = start
        guard let frame = timeline.frame(at: now - start, startingAt: startFrame) else {
            show(timeline.holds.count - 1)
            stop()
            return
        }
        show(frame)
    }

    /// Steps by `delta` frames (wrapping when looping), stopping playback.
    public func step(by delta: Int) {
        stop()
        let count = timeline.holds.count
        guard count > 0 else { return }
        let target = currentFrame + delta
        show(timeline.loop ? ((target % count) + count) % count : min(max(target, 0), count - 1))
    }

    /// Jumps to `frame`, stopping playback.
    public func seek(to frame: Int) {
        stop()
        show(min(max(frame, 0), max(timeline.holds.count - 1, 0)))
    }

    private func show(_ frame: Int) {
        guard frame != currentFrame else { return }
        currentFrame = frame
        onFrame?(frame)
    }
}
