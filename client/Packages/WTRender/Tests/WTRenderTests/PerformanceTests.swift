import WTGeometry
import Foundation
import Testing
@testable import WTRender

/// The Core Graphics fallback's frame budget is 16 ms (docs/spec/testing.adoc, "Performance
/// baseline").  These measure and report; they do not fail the suite, because the number
/// depends on the Mac the tests run on.
@Suite struct PerformanceTests {
    @Test func fiftyThousandRectsPerTile() {
        let list = Corpus.manyRects()
        #expect(list.count == 50_000)
        let renderer = CoreGraphicsRenderer(background: .white)
        let viewport = Viewport(size: Size(width: 2048, height: 2048))
        let geometry = TileGeometry(viewport: viewport, backingScale: 1)
        let keys = geometry.tiles(coveringViewRect: viewport.viewBounds, viewport: viewport, canvas: list.canvas)
        #expect(keys.count == 64)

        // Warm up once, then time every tile of a 2048 × 2048 view at 100%.
        _ = renderer.renderTile(list, key: keys[0], geometry: geometry)
        var perTile: [Double] = []
        for key in keys {
            let start = DispatchTime.now().uptimeNanoseconds
            let image = renderer.renderTile(list, key: key, geometry: geometry)
            let end = DispatchTime.now().uptimeNanoseconds
            #expect(image != nil)
            perTile.append(Double(end - start) / 1e6)
        }
        let mean = perTile.reduce(0, +) / Double(perTile.count)
        let worst = perTile.max()!
        let cullStart = DispatchTime.now().uptimeNanoseconds
        let visible = list.indices(intersecting: geometry.pasteboardBounds(of: keys[0])).count
        let cullMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - cullStart) / 1e6
        print("PERF 50,000 rects: \(keys.count) tiles, mean \(String(format: "%.2f", mean)) ms, worst \(String(format: "%.2f", worst)) ms per 256-px tile; cull of \(list.count) bounds \(String(format: "%.3f", cullMilliseconds)) ms (\(visible) visible); budget 16 ms")
        #expect(mean > 0)
        withKnownIssue("performance budget is measured, not enforced, on this Mac", isIntermittent: true) {
            #expect(worst < 16, "worst tile \(worst) ms")
        }
    }

    @Test func wholeViewOfFiftyThousandRects() {
        let list = Corpus.manyRects()
        let renderer = CoreGraphicsRenderer(background: .white)
        let viewport = Viewport(zoom: 0.5, size: Size(width: 1440, height: 900))
        let start = DispatchTime.now().uptimeNanoseconds
        let image = renderer.renderBitmap(list, viewport: viewport, scale: 2)
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        #expect(image != nil)
        print("PERF 50,000 rects: whole 1440 × 900 @2× view at 50% in \(String(format: "%.1f", milliseconds)) ms")
    }
}
