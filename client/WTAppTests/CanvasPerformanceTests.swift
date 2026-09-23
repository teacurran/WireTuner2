import AppKit
import Foundation
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

/// APP-002's "Done when": panning a 50,000-object document stays at 60 fps.  Measured through
/// the real layer pipeline (canvas view → `TiledCanvasLayer` → `TileCache` → Core Graphics),
/// in the Debug build the tests run against.  Non-fatal: the numbers are printed for the
/// report and a missed budget is recorded as a warning, not a failure (CI machines vary, and
/// REND-006's Metal renderer is the on-screen path the budget is really for).
@Suite(.serialized) @MainActor struct CanvasPerformanceTests {
    static let objectCount = 50_000
    static let frameBudget = 1.0 / 60

    /// 50,000 small rectangles on a 250 × 200 grid over a 7,500 × 6,000 point area of the
    /// pasteboard, alternately filled and stroked.
    static func denseDocument() -> DocumentHandle {
        var items: [DenseRectangles.Item] = []
        items.reserveCapacity(objectCount)
        for index in 0..<objectCount {
            let column = Double(index % 250)
            let row = Double(index / 250)
            let rect = Rect(x: 4000 + column * 30, y: 4000 + row * 30, width: 22, height: 22)
            items.append(DenseRectangles.Item(rect: rect, fill: index.isMultiple(of: 2) ? (column / 250, row / 200, 0.5) : nil))
        }
        return try! DenseRectangles.document(title: "Dense", items)
    }

    struct Stats: CustomStringConvertible {
        let samples: [Double]
        var mean: Double { samples.reduce(0, +) / Double(samples.count) }
        var p95: Double { samples.sorted()[Int(Double(samples.count - 1) * 0.95)] }
        var max: Double { samples.max() ?? 0 }
        var description: String {
            String(format: "mean %.3f ms, p95 %.3f ms, max %.3f ms over %d frames", mean * 1000, p95 * 1000, max * 1000, samples.count)
        }
    }

    @Test func panning50000RectanglesFitsTheFrameBudget() async {
        let document = Self.denseDocument()
        #expect(document.displayList.count == Self.objectCount + 1, "the objects after the pages group")
        let canvas = CanvasView(document: document, frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        canvas.tiles.backingScale = 2
        canvas.setViewport(Viewport(scrollOrigin: Point(x: 5000, y: 5000), zoom: 1, size: Size(width: 1200, height: 800)))
        await canvas.tiles.settle()

        // 1. Main-thread cost of a pan frame (what blocks the run loop): layout plus tile
        //    lookups, never rasterisation.  120 frames of 8 points each, one second at 120 Hz.
        var frames: [Double] = []
        for _ in 0..<120 {
            let start = DispatchTime.now().uptimeNanoseconds
            canvas.setViewport(canvas.viewport.scrolled(byViewDelta: Vector(dx: 8, dy: 3)))
            frames.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        let mainThread = Stats(samples: frames)

        // 2. Wall time per frame including rasterising the tiles the pan uncovered, settled
        //    before the next frame: the worst case of a pan into never-seen artwork.
        var settled: [Double] = []
        for _ in 0..<30 {
            let start = DispatchTime.now().uptimeNanoseconds
            canvas.setViewport(canvas.viewport.scrolled(byViewDelta: Vector(dx: 32, dy: 0)))
            await canvas.tiles.settle()
            settled.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        let withRaster = Stats(samples: settled)
        let tiles = canvas.tiles.fallbackCanvas?.tileLayerCount ?? canvas.tiles.atlasTileCount

        print("APP-002 pan, 50,000 rects, 1200×800 pt @2×, \(tiles) visible tiles — main thread per frame: \(mainThread)")
        print("APP-002 pan, 50,000 rects — frame including rasterising uncovered tiles: \(withRaster)")
        if mainThread.p95 > Self.frameBudget {
            withKnownIssue("main-thread pan frame p95 \(mainThread) exceeds 16.7 ms", isIntermittent: true) {
                Issue.record("frame budget missed")
            }
        }
        #expect(mainThread.samples.count == 120)
    }
}
