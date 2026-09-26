import AppKit
import Foundation
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

/// COLLAB-035's "Done when": hovering in Inspect mode redraws the overlay in under 2 ms per frame
/// with the design-point document (50,000 objects here, as the canvas budgets use) and invalidates
/// no document tile.  A frame is what one pointer move costs on the main thread: the hit test,
/// the measurements from the geometry kernel's bounds, and the overlay layer drawing itself
/// (`display()`, synchronously).  The tile counters are held in every run; the time is a
/// `PerfBudget`, held only in the perf run.
@Suite(.serialized) @MainActor struct InspectOverlayPerformanceTests {
    static let frameBudget = 0.002
    static let frames = 200

    /// Tiles rasterized so far by whichever renderer the canvas runs.
    static func rasterized(_ canvas: CanvasView) async -> Int {
        let fallback = await canvas.tiles.fallbackCanvas?.cache.renders ?? 0
        return canvas.tiles.rasterizedTileCount + fallback
    }

    @Test func hoveringRedrawsTheOverlayWithinTheFrameBudgetAndNoTile() async throws {
        let environment = TestEnvironment()
        let document = CanvasPerformanceTests.denseDocument()
        let window = DocumentWindowController(document: document, environment: environment.document)
        defer { window.close() }
        let canvas = window.canvas
        canvas.setViewport(Viewport(scrollOrigin: Point(x: 4000, y: 4000), zoom: 1, size: canvas.viewport.size))
        await canvas.tiles.settle()
        let inspect = InspectModeController(window: window)
        inspect.enter()
        defer { inspect.leave() }
        let tool = try #require(inspect.tool)
        // One object selected, so every hover also measures the gaps to it.
        let first = Point(x: 4011, y: 4011)
        tool.mouseDown(CanvasEvent(pasteboardPoint: first, viewPoint: canvas.viewport.toView(first)))
        #expect(!window.selection.selection.ids.isEmpty)
        inspect.overlay.display()
        await canvas.tiles.settle()
        let tilesBefore = await Self.rasterized(canvas)

        var samples: [Double] = []
        var outlined = 0
        for index in 0..<Self.frames {
            // Across the grid: over objects (every 30 pt a rectangle 22 pt wide) and the gaps between.
            let point = Point(x: 4011 + Double(index % 40) * 7.5, y: 4011 + Double(index / 40) * 30)
            let event = CanvasEvent(pasteboardPoint: point, viewPoint: canvas.viewport.toView(point), modifiers: index.isMultiple(of: 5) ? .option : [])
            let start = DispatchTime.now().uptimeNanoseconds
            tool.pointerMoved(event)
            inspect.overlay.display()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            if inspect.overlay.state.shown.outline != nil { outlined += 1 }
        }
        await canvas.tiles.settle()
        let stats = CanvasPerformanceTests.Stats(samples: samples)
        print("COLLAB-035 inspect hover, 50,000 rects, overlay frame (hit test, measure, draw): \(stats)")
        #expect(samples.count == Self.frames)
        #expect(outlined > Self.frames / 2, "most points are over a rectangle")
        let tilesAfter = await Self.rasterized(canvas)
        #expect(tilesAfter == tilesBefore, "hovering repaints no document tile")
        #expect(canvas.tiles.fallbackCanvas?.pendingTileCount ?? 0 == 0)
        PerfBudget.expect(.seconds(stats.p95), within: .seconds(Self.frameBudget), "hover frame p95",
                          enforcedInDebug: "the app's tests build Debug only; a Debug figure within the budget is a Release one too")
    }
}
