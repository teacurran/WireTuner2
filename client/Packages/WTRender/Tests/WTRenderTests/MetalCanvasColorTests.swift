import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// CMS-006 / IMG-004 on the tile canvas: a new colour pipeline or image store re-renders every
/// tile, the layer is tagged with the working space, and the display query follows the display.
@MainActor
struct MetalCanvasColorTests {
    static let viewport = Viewport(size: Size(width: 64, height: 64))

    @Test func theFallbackCanvasTakesThePipelineAndTheStore() {
        let canvas = MetalTileCanvas(device: nil)
        let management = ColorManagement(workingSpace: .displayP3)
        canvas.setColorManagement(management)
        canvas.setColorManagement(management)
        #expect(canvas.colorManagement == management)
        #expect(canvas.metalLayer.colorspace?.name == CGColorSpace.displayP3)
        canvas.setImageStore(ImageStore(blobURL: { _ in nil }))
        canvas.displayColorSpaceChanged(WTColor.Spaces.displayP3)
        #expect(canvas.displayGamut.canShow(Color(displayP3Red: 1, green: 0, blue: 0)))
        #expect(canvas.needsDisplay)
    }

    @Test(.enabled(if: MetalAvailability.isAvailable, "no Metal device"))
    func theMetalCanvasRerendersInTheWorkingSpace() async {
        let canvas = MetalTileCanvas()
        canvas.update(displayList: Corpus.solidRect, viewport: Self.viewport)
        await canvas.settle()
        let before = canvas.rasterizedTileCount
        canvas.setColorManagement(ColorManagement(workingSpace: .displayP3))
        await canvas.settle()
        #expect(canvas.rasterizedTileCount > before, "every tile re-rendered")
        #expect(canvas.metalLayer.colorspace?.name == CGColorSpace.displayP3)
        let afterPipeline = canvas.rasterizedTileCount
        canvas.setImageStore(ImageStore(blobURL: { _ in nil }))
        await canvas.settle()
        #expect(canvas.rasterizedTileCount > afterPipeline)
        canvas.displayColorSpaceChanged(WTColor.Spaces.sRGB)
        #expect(canvas.displayGamut.clips(Color(displayP3Red: 1, green: 0, blue: 0)))
    }
}
