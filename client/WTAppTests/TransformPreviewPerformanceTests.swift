import AppKit
import Foundation
import Testing
import WTGeometry
import WTModel
import WTRender
@testable import WireTuner

/// The transformation previews' frame budget (transforming.adoc, OBJ-032's "A drag of 100 objects
/// previews at 60 fps and commits one change", measured for OBJ-033 and OBJ-035): 100 selected
/// rectangles dragged by the Rotate, Scale, Skew and Reflect tools, the Pointer's transform
/// handles, Mirror and 3D Rotation, 120 drag events each; the time of one event plus the overlay
/// it draws is a frame.  The p95 is printed for the report and held to 1/60 s in the perf run
/// (`make client-perf`); every drag commits exactly one change.
@Suite(.serialized) @MainActor struct TransformPreviewPerformanceTests {
    static let frameBudget = 1.0 / 60
    static let events = 120

    /// A document with 100 rectangles in a 10 × 10 grid, all selected.
    static func world() async -> (document: DocumentHandle, selection: SelectionController, host: RecordingHost) {
        let document = DocumentHandle.memory(title: "Preview")
        let rects = (0..<100).map { Rect(x: Double($0 % 10) * 30, y: Double($0 / 10) * 30, width: 20, height: 20) }
        let ids = await document.addRectangles(rects)
        let selection = SelectionController(document: document)
        selection.model.set(Selection(ids))
        return (document, selection, RecordingHost(viewport: Viewport(size: Size(width: 1200, height: 800))))
    }

    static func bitmap() -> CGContext {
        CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// Drags `tool` from `from` along a circle of `radius` around `from`, timing each event and
    /// its overlay; returns the p95 in seconds and the changes committed.
    static func measure(_ tool: any Tool, press: Point, from: Point, radius: Double, name: String) async -> (p95: Double, changes: Int) {
        let (document, selection, host) = await world()
        var context = ToolContext(document: document, host: host, selection: selection)
        context.drawing = { DrawingSettings() }
        tool.activate(in: context)
        if let pointer = tool as? PointerTool { pointer.showHandles() }
        let before = document.changeCount
        let ctx = bitmap()
        tool.mouseDown(TestEvents.point(press.x, press.y))
        var frames: [Double] = []
        var last = press
        for step in 0..<events {
            let angle = Double(step) / Double(events) * .pi / 2
            last = Point(x: from.x + radius * cos(angle) + 20, y: from.y + radius * sin(angle) + 20)
            let start = DispatchTime.now().uptimeNanoseconds
            tool.mouseDragged(TestEvents.point(last.x, last.y))
            tool.drawOverlay(in: ctx, viewport: host.viewport)
            frames.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        tool.mouseUp(TestEvents.point(last.x, last.y))
        await document.settle()
        let stats = CanvasPerformanceTests.Stats(samples: frames)
        print("OBJ-033/035 preview, 100 objects, \(name): \(stats)")
        return (stats.p95, document.changeCount - before)
    }

    @Test(arguments: ["rotate", "scale", "skew", "reflect", "handles", "mirror", "rotation3D"])
    func aDragOf100ObjectsPreviewsWithinAFrameAndCommitsOnce(_ name: String) async {
        let tool: any Tool
        var press = Point(x: 135, y: 135)
        var from = Point(x: 200, y: 135)
        switch name {
        case "rotate": tool = TransformTool(.rotate)
        case "scale": tool = TransformTool(.scale)
        case "skew": tool = TransformTool(.skew)
        case "reflect": tool = TransformTool(.reflect)
        case "handles":
            tool = PointerTool()
            press = Point(x: 290, y: 290)
            from = press
        case "mirror": tool = MirrorTool()
        default: tool = Rotation3DTool()
        }
        let result = await Self.measure(tool, press: press, from: from, radius: 60, name: name)
        #expect(result.changes == 1, "one change per drag")
        PerfBudget.expect(.seconds(result.p95), within: .seconds(Self.frameBudget), name,
                          enforcedInDebug: "the app's tests build Debug only; a Debug figure within the budget is a Release one too")
    }
}
