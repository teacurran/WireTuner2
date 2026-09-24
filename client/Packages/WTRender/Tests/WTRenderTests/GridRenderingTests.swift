import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// DOC-016: the grid's dots -- lattice, zoom-dependent thinning, bounds and the frame budget.
@Suite struct GridRenderingTests {
    @Test func strideThinsBelowFourPixels() {
        #expect(GridRendering.stride(size: 12, zoom: 1) == 1)
        #expect(GridRendering.stride(size: 4, zoom: 1) == 1)
        #expect(GridRendering.stride(size: 3.9, zoom: 1) == 3)
        #expect(GridRendering.stride(size: 12, zoom: 0.25) == 3)
        #expect(GridRendering.stride(size: 12, zoom: 0.06) == 12)
        #expect(GridRendering.stride(size: 1, zoom: 0.06) == 134)
        #expect(GridRendering.stride(size: 0, zoom: 1) == nil && GridRendering.stride(size: 12, zoom: 0) == nil)
        #expect(GridRendering.stride(size: .infinity, zoom: 1) == nil && GridRendering.stride(size: 1e-300, zoom: 1e-10) == nil)
        // Every zoom keeps the visible lattice at least 4 px (thinned: 8 px) apart.
        for zoom in stride(from: 0.06, through: 256, by: 0.37) {
            for size in [0.5, 1, 7.2, 12, 72, 7200] {
                let k = GridRendering.stride(size: size, zoom: zoom)!
                let spacing = size * Double(k) * zoom
                #expect(spacing >= (k == 1 ? 4 : 8) - 1e-9)
                #expect(k == 1 || size * Double(k - 1) * zoom < 8)
            }
        }
    }

    @Test func dotsSitOnTheLatticeInsideTheArea() throws {
        let grid = GridSpec(size: 10, origin: Point(x: 3, y: 4))
        let item = try #require(GridRendering.item(grid, in: Rect(x: 0, y: 0, width: 25, height: 15), zoom: 2))
        guard case .fill(let fill) = item else {
            Issue.record("expected a fill")
            return
        }
        // Columns at x = 3, 13, 23; rows at y = 4, 14: six dots of five elements each.
        #expect(fill.path.elements.count == 30)
        #expect(fill.path.elements.first == .move(to: Point(x: 2.75, y: 3.75)))
        #expect(fill.path.controlBounds == Rect(x: 2.75, y: 3.75, width: 20.5, height: 10.5))
        #expect(GridRendering.dotCount(grid, in: Rect(x: 0, y: 0, width: 25, height: 15), zoom: 2) == 6)
        #expect(fill.paint == .solid(Color(white: 0.75)))
        // Thinned at a small zoom: every k-th line from the origin.
        let thinned = GridRendering.dotCount(GridSpec(size: 1), in: Rect(x: 0, y: 0, width: 100, height: 100), zoom: 1)
        #expect(thinned == 13 * 13)
        #expect(GridRendering.dotCount(GridSpec(size: 1), in: Rect(x: 0, y: 0, width: 100, height: 100), zoom: 4) == 101 * 101)
    }

    @Test func nothingToDraw() {
        let grid = GridSpec(size: 10)
        #expect(GridRendering.item(GridSpec(size: 0), in: Rect(x: 0, y: 0, width: 10, height: 10), zoom: 1) == nil)
        #expect(GridRendering.item(GridSpec(size: 10, origin: Point(x: .nan, y: 0)), in: Rect(x: 0, y: 0, width: 10, height: 10), zoom: 1) == nil)
        #expect(GridRendering.item(grid, in: .null, zoom: 1) == nil)
        #expect(GridRendering.item(grid, in: Rect(x: 1, y: 1, width: 5, height: 5), zoom: 1) == nil)
        #expect(GridRendering.item(grid, in: Rect(x: 0, y: 0, width: 0, height: 5), zoom: 1) == nil)
        #expect(GridRendering.item(grid, in: Rect(x: 0, y: 0, width: 10, height: 10), zoom: .nan) == nil)
        #expect(GridRendering.dotCount(grid, in: .null, zoom: 1) == 0 && GridRendering.dotCount(grid, in: Rect(x: 1, y: 1, width: 5, height: 5), zoom: 1) == 0)
        // An area holding more dots than the cap draws nothing rather than stalling.
        let huge = Rect(x: 0, y: 0, width: 1_000_000, height: 1_000_000)
        #expect(GridRendering.item(grid, in: huge, zoom: 1) == nil && GridRendering.dotCount(grid, in: huge, zoom: 1) == 0)
        #expect(GridSpec(size: 10).snapGrid == SnapGrid(origin: .zero, size: 10) && !GridSpec(size: -1).isValid)
    }

    /// The grid for a full 2560 × 1600 view at every zoom step is built well inside a 60 fps frame
    /// (the dots are at least 4 px apart, so a view holds at most 256,000 of them before the cap).
    @Test func gridForAViewFitsAFrame() {
        let view = Size(width: 2560, height: 1600)
        var worst = Duration.zero
        let clock = ContinuousClock()
        for zoom in [0.06, 0.1, 0.25, 0.5, 1, 2, 4, 8, 16, 64, 256] {
            let area = Rect(x: 100, y: 100, width: view.width / zoom, height: view.height / zoom)
            let started = clock.now
            let item = GridRendering.item(GridSpec(size: 12), in: area, zoom: zoom)
            worst = max(worst, clock.now - started)
            let count = GridRendering.dotCount(GridSpec(size: 12), in: area, zoom: zoom)
            #expect(count <= Int(view.width * view.height / 16) + 2_000)
            #expect((item == nil) == (count == 0))
        }
        PerfBudget.expect(worst, within: .milliseconds(8), "grid dots, 2560 × 1600 view")
    }
}
