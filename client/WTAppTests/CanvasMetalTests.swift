import AppKit
import Foundation
import Metal
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

/// The canvas hosts the REND-006 Metal tile canvas (Core Graphics when there is no Apple-family
/// GPU), runs its display link only while in a window, and reports what a frame costs.
@Suite(.serialized) @MainActor struct CanvasMetalTests {
    nonisolated static var hasMetal: Bool { MetalContext.shared != nil }
    static let frameBudget = 1.0 / 120

    @Test func theFallbackCanvasDrawsWithCoreGraphics() {
        let canvas = CanvasView(document: .memory(title: "CG"), tiles: CanvasView.makeFallbackTiles())
        guard case .coreGraphics = canvas.backend else { Issue.record("expected the fallback"); return }
        #expect(canvas.measureFrame() == nil)
        #expect(canvas.tiles.fallbackCanvas != nil)
        canvas.setViewMode(.keyline)
        canvas.gesture(.magnify, phase: .began)
        #expect(canvas.tiles.isGesturing)
        canvas.gesture(.magnify, phase: .ended)
        #expect(!canvas.tiles.isGesturing)
    }

    @Test(.enabled(if: CanvasMetalTests.hasMetal, "needs an Apple-family GPU"))
    func theMetalCanvasRunsItsDisplayLinkOnlyInAWindow() throws {
        let canvas = CanvasView(document: .memory(title: "Metal"), tiles: CanvasView.makeTiles(), frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        #expect(canvas.backend == .metal)
        #expect(!canvas.tiles.isDisplayLinkRunning)
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = canvas
        #expect(canvas.tiles.isDisplayLinkRunning)
        window.contentView = NSView()
        #expect(!canvas.tiles.isDisplayLinkRunning)
        window.close()
    }

    @Test(.enabled(if: CanvasMetalTests.hasMetal, "needs an Apple-family GPU"))
    func closingTheDocumentWindowStopsTheDisplayLink() {
        let environment = TestEnvironment()
        var document = environment.document
        document.makeTiles = { CanvasView.makeTiles() }
        let controller = DocumentWindowController(document: .memory(title: "Close"), environment: document)
        #expect(controller.canvas.backend == .metal)
        #expect(controller.canvas.tiles.isDisplayLinkRunning)
        controller.close()
        #expect(!controller.canvas.tiles.isDisplayLinkRunning, "a closed window's canvas leaves the main run loop")
    }

    @Test(.enabled(if: CanvasMetalTests.hasMetal, "needs an Apple-family GPU"))
    func panZoomAndRotateFramesFitTheBudget() async throws {
        let document = CanvasPerformanceTests.denseDocument()
        let canvas = CanvasView(document: document, tiles: CanvasView.makeTiles(), frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        canvas.tiles.backingScale = 2
        canvas.setViewport(Viewport(scrollOrigin: Point(x: 5000, y: 5000), zoom: 1, size: Size(width: 1200, height: 800)))
        await canvas.tiles.settle()
        #expect(canvas.measureFrame() != nil)
        var pan: [Double] = []
        var zoom: [Double] = []
        var rotate: [Double] = []
        for _ in 0..<60 {
            canvas.setViewport(canvas.viewport.scrolled(byViewDelta: Vector(dx: 6, dy: 2)))
            pan.append(try #require(canvas.measureFrame()).totalSeconds)
        }
        canvas.gesture(.magnify, phase: .began)
        for _ in 0..<60 {
            canvas.magnify(by: 0.01, at: CGPoint(x: 600, y: 400))
            zoom.append(try #require(canvas.measureFrame()).totalSeconds)
        }
        canvas.gesture(.magnify, phase: .ended)
        canvas.gesture(.rotate, phase: .began)
        for _ in 0..<60 {
            canvas.rotate(byGestureDegrees: 0.5, snapping: false, at: CGPoint(x: 600, y: 400))
            rotate.append(try #require(canvas.measureFrame()).totalSeconds)
        }
        canvas.gesture(.rotate, phase: .ended)
        await canvas.tiles.settle()
        let stats = [("pan", pan), ("pinch", zoom), ("rotate", rotate)].map { name, samples in
            (name, CanvasPerformanceTests.Stats(samples: samples))
        }
        for (name, stat) in stats {
            print("BASIC-034 \(name), 50,000 rects, 1200×800 pt @2×, Metal frame (CPU encode + GPU): \(stat)")
            #expect(stat.samples.count == 60)
            // The timing is a budget (testing.adoc, "Client budgets"): held in the perf run only,
            // where a loaded machine skips it instead of failing a correctness run.
            PerfBudget.expect(.seconds(stat.p95), within: .seconds(Self.frameBudget), "\(name) frame p95",
                              enforcedInDebug: "the app's tests build Debug only; a Debug figure within the budget is a Release one too")
        }
    }
}

/// Pointer moves, host and tool defaults, menu paths.
@Suite(.serialized) @MainActor struct CanvasGestureEventTests {
    @Test func pointerMovesReachTheCanvas() throws {
        let environment = TestEnvironment()
        let controller = DocumentWindowController(document: .memory(title: "Gestures"), environment: environment.document)
        defer { controller.close() }
        let canvas = controller.canvas
        let before = canvas.viewport
        let moved = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0
        ))
        canvas.mouseMoved(with: moved)
        #expect(canvas.viewport.zoom > 0 && before.zoom > 0)
    }

    @Test func toolAndHostDefaultsDoNothing() {
        final class BareHost: CanvasHost {
            var viewport = Viewport(size: Size(width: 10, height: 10))
            func setViewport(_ viewport: Viewport) {}
            func setNeedsOverlayDisplay() {}
            func toolCursorDidChange() {}
            func showStatusMessage(_ message: String) {}
        }
        let host = BareHost()
        host.requestNamedView(host.viewport)
        host.showHUD("hud")
        let tool = UnimplementedTool(id: ToolID("x"), title: "X")
        tool.forceClick(CanvasEvent(pasteboardPoint: .zero, viewPoint: .zero))
        #expect(ToolID("x").rawValue == "x")
    }

    @Test func menuPathsDecodeWithAndWithoutASubsection() throws {
        let path = MenuPath("View", "Custom", section: 1, subsection: 1)
        let data = try JSONEncoder().encode(path)
        #expect(try JSONDecoder().decode(MenuPath.self, from: data) == path)
        let older = try JSONDecoder().decode(MenuPath.self, from: Data(#"{"components": ["View"], "section": 2}"#.utf8))
        #expect(older == MenuPath("View", section: 2))
        #expect(path.section(atDepth: 1) == 1 && path.section(atDepth: 2) == 1 && MenuPath("A", section: 3).section(atDepth: 2) == 0)
    }
}
