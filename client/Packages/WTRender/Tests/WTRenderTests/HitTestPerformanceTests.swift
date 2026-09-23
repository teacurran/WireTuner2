import WTGeometry
import Foundation
import Testing
@testable import WTRender

/// REND-003 "Done when": hit testing 50,000 objects stays under 2 ms (docs/spec/testing.adoc,
/// "Performance gates").  Measured in release (`swift test -c release -Xswiftc -enable-testing
/// --filter HitTestPerformance`), where the median is enforced; a debug build measures and
/// reports only, since unoptimized Swift is several times slower.
@Suite struct HitTestPerformanceTests {
    /// 50,000 attribute-stack paths on a grid: rectangles and every tenth an ellipse, each with a
    /// fill and a stroke; every hundredth a group of two members.
    static func designPoint(count: Int = 50_000, spacing: Double = 12, edge: Double = 8) -> DisplayList {
        let columns = Int(Double(count).squareRoot().rounded(.up))
        var items: [DisplayItem] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            let rect = Rect(x: Double(index % columns) * spacing, y: Double(index / columns) * spacing, width: edge, height: edge)
            let path = index % 10 == 0 ? DisplayPath(ellipseIn: rect) : DisplayPath(rect: rect)
            let item = DisplayItem.path(PathItem(path: path, appearance: .fillAndStroke(fill: red, stroke: .black, width: 1)))
            if index % 100 == 0 {
                let half = Rect(x: rect.minX, y: rect.minY, width: edge / 2, height: edge)
                items.append(.group(GroupItem(children: [item, .path(PathItem(path: DisplayPath(rect: half), appearance: .fillAndStroke(fill: blue, stroke: .black)))])))
            } else {
                items.append(item)
            }
        }
        return DisplayList(canvas: "perf", items: items)
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    @Test func fiftyThousandObjects() {
        let list = Self.designPoint()
        #expect(list.count == 50_000)
        let viewport = Viewport(size: Size(width: 2700, height: 2700))

        let buildStart = DispatchTime.now().uptimeNanoseconds
        let tester = HitTester(displayList: list, viewport: viewport)
        let buildMilliseconds = Self.milliseconds(since: buildStart)
        #expect(tester.index.count == 50_000)

        var rng = SplitMix64(seed: 42)
        let points = (0..<1_000).map { _ in
            Point(x: Double.random(in: 0..<2690, using: &rng), y: Double.random(in: 0..<2690, using: &rng))
        }
        _ = tester.hitTest(viewPoint: points[0])  // warm up
        var timings: [Double] = []
        var hits = 0
        for point in points {
            let start = DispatchTime.now().uptimeNanoseconds
            let results = tester.hitTest(viewPoint: point)
            timings.append(Self.milliseconds(since: start))
            hits += results.isEmpty ? 0 : 1
        }
        timings.sort()
        let median = timings[timings.count / 2]
        let p95 = timings[timings.count * 95 / 100]
        let worst = timings[timings.count - 1]

        let marqueeStart = DispatchTime.now().uptimeNanoseconds
        let marquee = tester.hitTest(marquee: Rect(x: 100, y: 100, width: 240, height: 240), contactSensitive: true)
        let marqueeMilliseconds = Self.milliseconds(since: marqueeStart)
        #expect(marquee.count > 300)

        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        print("PERF hit test, 50,000 objects (\(build)): R-tree bulk load \(String(format: "%.1f", buildMilliseconds)) ms; 1,000 random hits (\(hits) on an object) median \(String(format: "%.4f", median)) ms, p95 \(String(format: "%.4f", p95)) ms, worst \(String(format: "%.4f", worst)) ms; 240-pt contact marquee (\(marquee.count) items) \(String(format: "%.2f", marqueeMilliseconds)) ms; budget 2 ms")
        #expect(hits > 300, "a good share of random points land on the grid's objects")
        #if DEBUG
        withKnownIssue("the 2 ms budget applies to release builds; debug measures only", isIntermittent: true) {
            #expect(median < 2, "median \(median) ms")
        }
        #else
        #expect(median < 2, "median \(median) ms")
        #endif
    }
}
