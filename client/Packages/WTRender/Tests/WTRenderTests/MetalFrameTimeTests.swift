import WTGeometry
import Foundation
import Metal
import QuartzCore
import Testing
@testable import WTRender

/// REND-006's frame-time gate (docs/spec/testing.adoc, "Performance gates"): a scripted 10 s
/// pan, zoom and rotate of the 50,000-item design point through the Metal tile canvas at
/// 120 Hz, each frame's CPU encode time plus GPU execution time measured.  The 8.3 ms budget is a
/// `PerfBudget`, held in the perf run (`make client-perf`: release, `WT_PERF=1`); other runs
/// report the numbers only.  Frames are paced to the 120 Hz wall clock, so tile rasterization
/// runs on the tile queue alongside them as it does on screen; it is reported separately,
/// because a frame never waits for it.
@MainActor
@Suite(.enabled(if: MetalAvailability.isAvailable, "no Metal device: frame-time gate incomplete"))
struct MetalFrameTimeTests {
    static let budgetMilliseconds = 8.3
    static let refreshRate = 120.0
    static let seconds = 10.0

    /// The viewport at frame `index` of the script: pan for the first third, pinch-zoom (in to
    /// 3× and back) for the second, rotate through 45° for the last.
    static func viewport(at index: Int, frames: Int, start: Viewport) -> (viewport: Viewport, gesture: Bool) {
        let third = frames / 3
        if index < third {
            return (start.scrolled(byViewDelta: Vector(dx: 3 * Double(index), dy: 1.5 * Double(index))), false)
        }
        let panned = start.scrolled(byViewDelta: Vector(dx: 3 * Double(third), dy: 1.5 * Double(third)))
        if index < 2 * third {
            let phase = Double(index - third) / Double(third)
            return (panned.zoomed(to: 1 + 2 * sin(phase * .pi)), true)
        }
        let phase = Double(index - 2 * third) / Double(frames - 2 * third)
        return (panned.rotated(toDegrees: 45 * phase), true)
    }

    @Test func scriptedPanZoomRotateOfFiftyThousandItems() async throws {
        // Its own queues, so the parity suites' command buffers do not stand in front of its tiles.
        let context = try #require(MetalContext(device: MTLCreateSystemDefaultDevice()))
        let list = Corpus.manyRects()
        #expect(list.count == 50_000)
        let clock = ManualClock()
        let canvas = MetalTileCanvas(context: context, backingScale: 2, atlasCapacity: 768, clock: { clock.now })
        let start = Viewport(scrollOrigin: Point(x: 200, y: 200), size: Size(width: 1440, height: 900))
        let texture = try makeFrameTexture(context, width: 2880, height: 1800)

        // Warm up: the first screenful rasterized before the clock starts.
        canvas.update(displayList: list, viewport: start)
        let rasterStart = CACurrentMediaTime()
        await canvas.settle()
        let initialTiles = canvas.rasterizedTileCount
        let rasterSeconds = CACurrentMediaTime() - rasterStart
        _ = canvas.renderFrame(into: texture)

        let frames = Int(Self.seconds * Self.refreshRate)
        var timings: [FrameTiming] = []
        timings.reserveCapacity(frames)
        var updateSeconds: [Double] = []
        var gesturing = false
        let wallClock = ContinuousClock()
        let scriptStart = wallClock.now
        let interval = Duration.nanoseconds(Int64(1e9 / Self.refreshRate))
        for index in 0..<frames {
            try await Task.sleep(until: scriptStart + interval * index, clock: wallClock)
            clock.now += 1 / Self.refreshRate
            let step = Self.viewport(at: index, frames: frames, start: start)
            let updateStart = CACurrentMediaTime()
            if step.gesture != gesturing {
                gesturing = step.gesture
                if gesturing { canvas.beginGesture() } else { canvas.endGesture() }
            }
            canvas.update(displayList: list, viewport: step.viewport)
            updateSeconds.append(CACurrentMediaTime() - updateStart)
            timings.append(try #require(canvas.renderFrame(into: texture)))
        }
        canvas.endGesture()
        await canvas.settle()
        #expect(canvas.backend == .metal)

        let totals = zip(timings, updateSeconds).map { ($0.totalSeconds + $1) * 1000 }
        let sorted = totals.sorted()
        let worst = sorted.last!
        let mean = totals.reduce(0, +) / Double(totals.count)
        let p99 = sorted[Int(Double(sorted.count - 1) * 0.99)]
        let over = totals.filter { $0 > Self.budgetMilliseconds }.count
        let gpuWorst = timings.map(\.gpuSeconds).max()! * 1000
        let cpuWorst = zip(timings, updateSeconds).map { ($0.cpuSeconds + $1) * 1000 }.max()!
        print("PERF Metal frame (\(PerfBudget.buildName)): \(frames) frames of a 10 s pan/zoom/rotate, 50,000 items, 2880 × 1800 px; mean \(String(format: "%.3f", mean)) ms, p99 \(String(format: "%.3f", p99)) ms, worst \(String(format: "%.3f", worst)) ms (CPU worst \(String(format: "%.3f", cpuWorst)), GPU worst \(String(format: "%.3f", gpuWorst))); \(over) over \(Self.budgetMilliseconds) ms; up to \(timings.map(\.tiles).max()!) tiles per frame; rasterized \(canvas.rasterizedTileCount) tiles (first \(initialTiles) in \(String(format: "%.0f", rasterSeconds * 1000)) ms)")
        #expect(timings.allSatisfy { $0.tiles > 0 }, "every frame shows tiles")
        PerfBudget.expect(.milliseconds(worst), within: .milliseconds(Self.budgetMilliseconds), "worst frame")
    }
}
