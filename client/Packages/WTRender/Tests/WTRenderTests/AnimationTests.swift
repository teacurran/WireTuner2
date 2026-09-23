import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// WEB-016: frame lists, frame drawing and playback.
@Suite struct AnimationTests {
    static func id(_ counter: UInt64) -> NodeID { NodeID(counter: counter, replica: 4) }

    /// A background layer, three frame layers (the second held 3), a hidden one, an excluded
    /// one and the Guides layer, bottom first.
    static let layers = [
        AnimationLayer(id: id(1), printing: false),
        AnimationLayer(id: id(2)),
        AnimationLayer(id: id(3), hold: 3),
        AnimationLayer(id: id(4), visible: false),
        AnimationLayer(id: id(5), excluded: true),
        AnimationLayer(id: id(6), hold: 0),
        AnimationLayer(id: id(7), isGuides: true),
    ]
    static let pages = [Rect(x: 0, y: 0, width: 40, height: 30), Rect(x: 50, y: 0, width: 40, height: 30)]

    @Test func layerFramesAreForegroundLayersOverTheBackground() {
        let frames = FrameComposer.frames(source: .layers, layers: Self.layers, pages: Self.pages)
        #expect(frames.map(\.layers) == [[Self.id(1), Self.id(2)], [Self.id(1), Self.id(3)], [Self.id(1), Self.id(6)]])
        #expect(frames.map(\.hold) == [1, 3, 1])
        #expect(frames.allSatisfy { $0.page == nil && $0.pageRect == nil })
        #expect(FrameComposer.frames(source: .none, layers: Self.layers, pages: Self.pages).isEmpty)
        #expect(FrameComposer.frames(source: .layers, layers: [AnimationLayer(id: Self.id(1), printing: false)], pages: []).isEmpty, "no foreground layers: no frames")
    }

    @Test func pageFramesAndPagesAndLayers() {
        let pages = FrameComposer.frames(source: .pages, layers: Self.layers, pages: Self.pages)
        #expect(pages.count == 2)
        #expect(pages[1].pageRect == Self.pages[1] && pages[1].page == 1)
        #expect(pages[0].layers == [Self.id(1), Self.id(2), Self.id(3), Self.id(6)])
        let both = FrameComposer.frames(source: .pagesAndLayers, layers: Self.layers, pages: Self.pages)
        #expect(both.count == 6)
        #expect(both.map(\.page) == [0, 0, 0, 1, 1, 1])
        #expect(both[4].layers == [Self.id(1), Self.id(3)] && both[4].hold == 3)
    }

    static func list() -> DisplayList {
        func square(_ x: Double, _ color: Color) -> DisplayItem {
            .path(PathItem(path: DisplayPath(rect: Rect(x: x, y: 0, width: 10, height: 10)), appearance: Appearance([.fill(FillPaint(paint: .solid(color)))])))
        }
        return LayerScene.build(canvas: "a", layers: [
            LayerContent(layer: LayerRendering(id: id(1), printing: false), items: [(square(0, .black), id(11))]),
            LayerContent(layer: LayerRendering(id: id(2)), items: [(square(10, Color(red: 1, green: 0, blue: 0)), id(21))]),
            LayerContent(layer: LayerRendering(id: id(3)), items: [(square(20, Color(red: 0, green: 0, blue: 1)), id(31))]),
        ], purpose: .screen(guideColor: .black))
    }

    /// A frame draws only its layers, from the same list: no rebuild, no document write.
    @Test func framesDrawTheirLayersFromTheSameList() throws {
        let list = Self.list()
        let frames = FrameComposer.frames(source: .layers, layers: [AnimationLayer(id: Self.id(1), printing: false), AnimationLayer(id: Self.id(2)), AnimationLayer(id: Self.id(3))], pages: [])
        let first = FrameComposer.displayList(list, for: frames[0])
        #expect(first.nodeIDs == [Self.id(11), Self.id(21)])
        let image = try #require(FrameComposer.rasterize(list, frame: frames[1], area: Rect(x: 0, y: 0, width: 30, height: 10), pixelWidth: 60, pixelHeight: 20, background: .white))
        let surface = try #require(BitmapSurface(drawing: image))
        #expect(surface.pixel(x: 30, y: 10) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255), "frame 2 hides layer 2")
        #expect(surface.pixel(x: 50, y: 10).blue == 255)
        #expect(surface.pixel(x: 10, y: 10).red < 140, "the background layer, dimmed, in every frame")
        let paged = AnimationFrame(layers: [Self.id(2)], page: 0, pageRect: Rect(x: 10, y: 0, width: 10, height: 10), hold: 1)
        let pageImage = try #require(FrameComposer.rasterize(list, frame: paged, pixelWidth: 10, pixelHeight: 10))
        #expect(try #require(BitmapSurface(drawing: pageImage)).pixel(x: 5, y: 5).red == 255)
        let whole = AnimationFrame(layers: [Self.id(3)], page: nil, pageRect: nil, hold: 1)
        #expect(FrameComposer.rasterize(list, frame: whole, pixelWidth: 30, pixelHeight: 10) != nil)
        #expect(FrameComposer.rasterize(list, frame: whole, pixelWidth: 0, pixelHeight: 10) == nil)
        #expect(FrameComposer.rasterize(DisplayList(canvas: "e", items: []), frame: whole, pixelWidth: 5, pixelHeight: 5) == nil)
    }

    @Test func timelinesHoldLoopAndStop() {
        let frames = FrameComposer.frames(source: .layers, layers: Self.layers, pages: [])
        let timeline = AnimationTimeline(frames: frames, fps: 10, loop: true)
        #expect(timeline.totalPeriods == 5 && timeline.duration == 0.5)
        #expect([0, 0.1, 0.25, 0.35, 0.41, 0.55].map { timeline.frame(at: $0) } == [0, 1, 1, 1, 2, 0])
        #expect(timeline.frame(at: 0, startingAt: 2) == 2)
        #expect(timeline.frame(at: 0.1, startingAt: 2) == 0)
        let once = AnimationTimeline(frames: frames, fps: 0, loop: false)
        #expect(once.fps == 12)
        #expect(once.frame(at: 10) == nil)
        #expect(AnimationTimeline(frames: [], fps: 500, loop: true).frame(at: 0) == nil)
        #expect(AnimationTimeline(frames: [], fps: 500, loop: true).fps == 120)
    }

    @MainActor
    final class ManualTicker: PlaybackTicker {
        var tick: (@MainActor (Double) -> Void)?
        var starts = 0
        func start(_ tick: @escaping @MainActor (Double) -> Void) {
            starts += 1
            self.tick = tick
        }
        func stop() { tick = nil }
    }

    @MainActor
    @Test func playbackAdvancesByWallClockAndDropsFrames() {
        let frames = FrameComposer.frames(source: .layers, layers: Self.layers, pages: [])
        let ticker = ManualTicker()
        let player = AnimationPlayer(timeline: AnimationTimeline(frames: frames, fps: 10, loop: false), ticker: ticker)
        var shown: [Int] = []
        player.onFrame = { shown.append($0) }
        player.play()
        player.play()
        #expect(ticker.starts == 1 && player.isPlaying)
        ticker.tick?(100.0)
        ticker.tick?(100.45)
        #expect(shown == [2], "a late tick skips straight to the frame due")
        ticker.tick?(101)
        #expect(!player.isPlaying && player.currentFrame == 2)
        player.tick(at: 200)
        // Play again from the start after running out.
        player.play()
        ticker.tick?(0)
        #expect(player.currentFrame == 0)
        player.step(by: 1)
        #expect(!player.isPlaying && player.currentFrame == 1)
        player.step(by: 5)
        #expect(player.currentFrame == 2)
        player.seek(to: -3)
        #expect(player.currentFrame == 0)
        player.stop()
        let looping = AnimationPlayer(timeline: AnimationTimeline(frames: frames, fps: 10, loop: true), ticker: ticker, frame: 9)
        #expect(looping.currentFrame == 2)
        looping.step(by: 1)
        #expect(looping.currentFrame == 0)
        looping.step(by: -1)
        #expect(looping.currentFrame == 2)
        let empty = AnimationPlayer(timeline: AnimationTimeline(frames: [], fps: 10, loop: true), ticker: ticker)
        empty.play()
        empty.step(by: 1)
        #expect(!empty.isPlaying && empty.currentFrame == 0)
    }

    @MainActor
    @Test func timerTickerTicksUntilStopped() async throws {
        let ticker = TimerTicker(interval: 0.005)
        var ticks: [Double] = []
        ticker.start { ticks.append($0) }
        try await Task.sleep(nanoseconds: 60_000_000)
        ticker.stop()
        let count = ticks.count
        #expect(count >= 2)
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(ticks.count == count)
        #expect(TimerTicker(interval: 0).interval == 0.001)
    }

    /// A 100-frame, 2,000-object document plays at 30 fps without rebuilding the list: each
    /// frame is the list restricted and drawn (33 ms, a `PerfBudget`: the perf run holds it).
    @Test func aHundredFramesOfTwoThousandObjectsHoldThirtyFPS() throws {
        var content: [LayerContent] = [LayerContent(layer: LayerRendering(id: Self.id(10_000), printing: false), items: [])]
        var layers = [AnimationLayer(id: Self.id(10_000), printing: false)]
        for frame in 0..<100 {
            let layer = Self.id(UInt64(20_000 + frame))
            let items: [(item: DisplayItem, node: NodeID?)] = (0..<20).map { index in
                let x = Double(index * 20 + frame), y = Double(index * 10)
                return (.path(PathItem(path: DisplayPath(ellipseIn: Rect(x: x, y: y, width: 14, height: 14)), appearance: Appearance([.fill(FillPaint(paint: .solid(Color(red: 0.2, green: 0.4, blue: 0.8))))]))), Self.id(UInt64(100_000 + frame * 20 + index)))
            }
            content.append(LayerContent(layer: LayerRendering(id: layer), items: items))
            layers.append(AnimationLayer(id: layer))
        }
        let list = LayerScene.build(canvas: "a", layers: content, purpose: .screen(guideColor: .black))
        #expect(list.count == 2000)
        let frames = FrameComposer.frames(source: .layers, layers: layers, pages: [])
        _ = FrameComposer.rasterize(list, frame: frames[0], area: Rect(x: 0, y: 0, width: 520, height: 200), pixelWidth: 520, pixelHeight: 200, background: .white)
        let start = Date()
        var worst = 0.0
        for frame in frames {
            let frameStart = Date()
            _ = FrameComposer.rasterize(list, frame: frame, area: Rect(x: 0, y: 0, width: 520, height: 200), pixelWidth: 520, pixelHeight: 200, background: .white)
            worst = max(worst, Date().timeIntervalSince(frameStart))
        }
        let total = Date().timeIntervalSince(start)
        print("PERF animation: 100 frames of 2,000 objects in \(String(format: "%.1f", total * 1000)) ms, worst frame \(String(format: "%.2f", worst * 1000)) ms")
        PerfBudget.expect(.seconds(worst), within: .seconds(1.0 / 30), "worst frame")
    }
}
