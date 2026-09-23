import AppKit
import QuartzCore
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The on-screen orientation check REND-001 left open: the tiled canvas hosted in the canvas
/// view's (unflipped) layer tree must show pasteboard (0, 0) at the view's top-left corner,
/// and the overlay must draw in the same y-down view space.
@Suite @MainActor struct CanvasOrientationTests {
    static let red = Color(red: 1, green: 0, blue: 0)

    /// A canvas scrolled to the pasteboard origin at 100%, with a 20-point red square at
    /// pasteboard (0, 0).
    private func makeCanvas(size: CGSize = CGSize(width: 200, height: 120)) async -> CanvasView {
        let document = DocumentHandle.memory(title: "Orientation")
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0)]
        _ = await document.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 20), appearance: appearance)).value
        let canvas = CanvasView(document: document, frame: NSRect(origin: .zero, size: size))
        canvas.setViewport(Viewport(scrollOrigin: .zero, zoom: 1, size: Size(size)))
        return canvas
    }

    /// The canvas's layer tree rendered at the tiles' backing scale.
    private func snapshot(_ canvas: CanvasView) -> BitmapSurface {
        let scale = canvas.tiles.backingScale
        let surface = BitmapSurface(width: Int(canvas.bounds.width * scale), height: Int(canvas.bounds.height * scale))!
        surface.context.scaleBy(x: scale, y: scale)
        canvas.layer!.render(in: surface.context)
        return surface
    }

    private func isRed(_ pixel: RGBA8) -> Bool { pixel.red > 200 && pixel.green < 60 && pixel.blue < 60 && pixel.alpha > 200 }

    @Test func pasteboardOriginAppearsAtTheTopLeft() async {
        let canvas = await makeCanvas()
        #expect(!canvas.isFlipped)
        #expect(canvas.layer?.isGeometryFlipped == false)
        #expect(canvas.tiles.layer.isGeometryFlipped == false)
        #expect(canvas.viewport.scrollOrigin == .zero)
        await canvas.tiles.settle()

        let image = snapshot(canvas)
        let scale = Int(canvas.tiles.backingScale)
        // Rows count from the top of the image: the square fills the top-left 20 × 20 points.
        #expect(isRed(image.pixel(x: 5 * scale, y: 5 * scale)), "top-left: \(image.pixel(x: 5 * scale, y: 5 * scale))")
        #expect(isRed(image.pixel(x: 18 * scale, y: 18 * scale)))
        #expect(!isRed(image.pixel(x: 5 * scale, y: 115 * scale)), "bottom-left must be empty")
        #expect(!isRed(image.pixel(x: 25 * scale, y: 5 * scale)))
        #expect(!isRed(image.pixel(x: 5 * scale, y: 25 * scale)))
        #expect(!isRed(image.pixel(x: 195 * scale, y: 5 * scale)))
    }

    @Test func scrollingMovesTheSquareUpAndLeft() async {
        let canvas = await makeCanvas()
        canvas.setViewport(canvas.viewport.scrolled(byViewDelta: Vector(dx: 10, dy: 10)))
        await canvas.tiles.settle()
        let image = snapshot(canvas)
        let scale = Int(canvas.tiles.backingScale)
        #expect(isRed(image.pixel(x: 5 * scale, y: 5 * scale)))
        #expect(!isRed(image.pixel(x: 12 * scale, y: 12 * scale)), "the square now ends at (10, 10)")
    }

    @Test func theOverlayDrawsInYDownViewPoints() async {
        let canvas = await makeCanvas()
        let environment = TestEnvironment()
        let tool = OverlayProbeTool()
        environment.tools.replace(ToolDescriptor(id: OverlayProbeTool.id, title: "Probe", symbolName: "circle", helpSlug: "probe") { tool })
        canvas.toolManager = ToolManager(registry: environment.tools, context: ToolContext(document: canvas.document, host: canvas), initialTool: OverlayProbeTool.id)
        await canvas.tiles.settle()
        canvas.overlay.display()
        let image = snapshot(canvas)
        let scale = Int(canvas.tiles.backingScale)
        let blue = image.pixel(x: 190 * scale, y: 5 * scale)
        #expect(blue.blue > 200 && blue.red < 60, "the probe's top-right square: \(blue)")
        let bottom = image.pixel(x: 190 * scale, y: 115 * scale)
        #expect(bottom.red > 150 && bottom.green > 150, "bottom-right shows the grey pasteboard: \(bottom)")
        #expect(tool.drawCount >= 1)
    }
}

/// Fills a 10-point square at the view's top-right corner.
@MainActor
final class OverlayProbeTool: Tool {
    static let id: ToolID = "probe"
    private(set) var drawCount = 0
    var cursor: NSCursor { .arrow }
    func activate(in context: ToolContext) {}
    func deactivate() {}
    func mouseDown(_ e: CanvasEvent) {}
    func mouseDragged(_ e: CanvasEvent) {}
    func mouseUp(_ e: CanvasEvent) {}
    func flagsChanged(_ e: CanvasEvent) {}
    func keyDown(_ e: NSEvent) -> Bool { false }
    func cancel() {}
    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        drawCount += 1
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: viewport.size.width - 15, y: 0, width: 10, height: 10))
    }
}

/// WEB-016's canvas half: preview mode and display-link playback of the document's frames.
@Suite @MainActor struct CanvasPlaybackTests {
    /// Two layers, a red square on the bottom one at (0, 0) and on the top one at (40, 0), with
    /// *Layers* as the frame source.
    private func makeCanvas() async -> (CanvasView, [OpID]) {
        let document = DocumentHandle.memory(title: "Frames")
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0)]
        let square = Size(width: 20, height: 20)
        _ = await document.perform(CreateShape(.rectangle(CornerRadii()), size: square, appearance: appearance)).value
        let bottom = document.state.liveChildren(WellKnown.layers)[0]
        let top = await document.perform(CreateLayer(name: "Frame 2", above: bottom)).value!.createdNodes[0]
        _ = await document.perform(CreateShape(.rectangle(CornerRadii()), size: square, transform: .translation(x: 40, y: 0), appearance: appearance, layer: top)).value
        _ = await document.perform(SetAnimationSettings(source: .layers, fps: 10)).value
        let canvas = CanvasView(document: document, frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        canvas.setViewport(Viewport(scrollOrigin: .zero, zoom: 1, size: Size(width: 100, height: 40)))
        return (canvas, [bottom, top])
    }

    private func redAt(_ canvas: CanvasView, x: Int) async -> Bool {
        await canvas.tiles.settle()
        let scale = canvas.tiles.backingScale
        let surface = BitmapSurface(width: Int(canvas.bounds.width * scale), height: Int(canvas.bounds.height * scale))!
        surface.context.scaleBy(x: scale, y: scale)
        canvas.layer!.render(in: surface.context)
        let pixel = surface.pixel(x: x * Int(scale), y: 5 * Int(scale))
        return pixel.red > 200 && pixel.green < 60 && pixel.alpha > 200
    }

    @Test func playbackShowsOneLayerPerFrameAndWritesNothing() async throws {
        let (canvas, layers) = await makeCanvas()
        #expect(await redAt(canvas, x: 5))
        #expect(await redAt(canvas, x: 45))
        let changes = canvas.document.changeCount
        let ticker = DisplayLinkTicker(view: canvas)
        let playback = try #require(canvas.startPlayback(ticker: ticker))
        #expect(ticker.isRunning && playback.frames.map(\.layers) == [[NodeID(layers[0])], [NodeID(layers[1])]])
        #expect(canvas.previewFrame == playback.frames[0])
        #expect(await redAt(canvas, x: 5))
        #expect(await !redAt(canvas, x: 45))
        ticker.fire(at: 100)
        ticker.fire(at: 100.15)
        #expect(canvas.previewFrame == playback.frames[1] && playback.player.currentFrame == 1)
        #expect(await !redAt(canvas, x: 5))
        #expect(await redAt(canvas, x: 45))
        // A change during playback shows in the frame; preview itself wrote nothing.
        _ = await canvas.document.perform(SetLayerFlag([layers[1]], .keyline, true)).value
        #expect(canvas.shownDisplayList.layers.map(\.layer.keyline) == [true])
        #expect(canvas.document.changeCount == changes + 1)
        // Clicking the canvas ends preview mode.
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: click)
        #expect(canvas.previewFrame == nil && canvas.playback == nil && !ticker.isRunning)
        #expect(canvas.shownDisplayList == canvas.document.displayList)
        #expect(await redAt(canvas, x: 5))
    }

    @Test func aDocumentWithoutFramesDoesNotPlay() async {
        let canvas = CanvasView(document: .memory(title: "Still"), frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        #expect(canvas.startPlayback() == nil && canvas.previewFrame == nil)
        let ticker = DisplayLinkTicker(view: canvas)
        ticker.start { _ in }
        #expect(ticker.isRunning)
        ticker.stop()
        #expect(!ticker.isRunning)
        var detached: NSView? = NSView()
        let orphan = DisplayLinkTicker(view: detached!)
        detached = nil
        orphan.start { _ in Issue.record("no view, no ticks") }
        orphan.fire(at: 1)
        #expect(!orphan.isRunning)
    }
}
