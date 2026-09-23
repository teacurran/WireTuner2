import AppKit
import QuartzCore
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

/// The on-screen orientation check REND-001 left open: the tiled canvas hosted in the canvas
/// view's (unflipped) layer tree must show pasteboard (0, 0) at the view's top-left corner,
/// and the overlay must draw in the same y-down view space.
@Suite @MainActor struct CanvasOrientationTests {
    static let red = Color(red: 1, green: 0, blue: 0)

    /// A canvas scrolled to the pasteboard origin at 100%, with a 20-point red square at
    /// pasteboard (0, 0).
    private func makeCanvas(size: CGSize = CGSize(width: 200, height: 120)) -> CanvasView {
        let content = PlaceholderDocumentContent(canvas: "orientation", items: [
            .fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 20, height: 20)), paint: .solid(Self.red))),
        ])
        let document = DocumentHandle.placeholder(title: "Orientation", content: content)
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
        let canvas = makeCanvas()
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
        let canvas = makeCanvas()
        canvas.setViewport(canvas.viewport.scrolled(byViewDelta: Vector(dx: 10, dy: 10)))
        await canvas.tiles.settle()
        let image = snapshot(canvas)
        let scale = Int(canvas.tiles.backingScale)
        #expect(isRed(image.pixel(x: 5 * scale, y: 5 * scale)))
        #expect(!isRed(image.pixel(x: 12 * scale, y: 12 * scale)), "the square now ends at (10, 10)")
    }

    @Test func theOverlayDrawsInYDownViewPoints() async {
        let canvas = makeCanvas()
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
