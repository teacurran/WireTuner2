import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// FX-008's *Raster effect preview* preference reaching both renderers of the tile canvas.
@MainActor
@Suite struct RasterPreviewSettingTests {
    @Test(.enabled(if: MetalAvailability.isAvailable, "no Metal device"))
    func theMetalCanvasReRendersItsTilesAtTheNewPreview() async throws {
        let canvas = MetalTileCanvas(context: MetalAvailability.context, backingScale: 1, atlasCapacity: 64, clock: { 100 })
        canvas.update(displayList: Corpus.solidRect, viewport: Viewport(size: Size(width: 300, height: 200)))
        await canvas.settle()
        let before = canvas.rasterizedTileCount
        canvas.setRasterPreview(.off)
        #expect(canvas.renderer?.rasterPreview == .off)
        await canvas.settle()
        #expect(canvas.rasterizedTileCount > before, "every visible tile renders again")
    }

    @Test func theCoreGraphicsFallbackTakesItToo() async throws {
        let canvas = MetalTileCanvas(device: nil)
        let fallback = try #require(canvas.fallbackCanvas)
        canvas.update(displayList: Corpus.solidRect, viewport: Viewport(size: Size(width: 300, height: 200)))
        await canvas.settle()
        canvas.setRasterPreview(.draft)
        await canvas.settle()
        #expect(fallback.tileLayerCount > 0 && canvas.renderer == nil)
    }
}
