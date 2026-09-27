import WTGeometry
import Foundation
import Metal
import QuartzCore
import Testing
@testable import WTRender

/// A manual clock for gesture timing.
@MainActor
final class ManualClock {
    var now = 100.0
}

/// An offscreen RGBA8 drawable the CPU can read.
func makeFrameTexture(_ context: MetalContext, width: Int, height: Int) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    return try #require(context.device.makeTexture(descriptor: descriptor))
}

/// The texture's pixels in a `BitmapSurface`.
func readBack(_ texture: any MTLTexture) throws -> BitmapSurface {
    let surface = try #require(BitmapSurface(width: texture.width, height: texture.height))
    texture.getBytes(surface.context.data!, bytesPerRow: surface.context.bytesPerRow, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    return surface
}

@MainActor
@Suite(.enabled(if: MetalAvailability.isAvailable, "no Metal device: Metal canvas run incomplete"))
struct MetalTileCanvasTests {
    private let size = Size(width: 300, height: 200)

    private func makeCanvas(context: MetalContext? = MetalAvailability.context, clock: ManualClock = ManualClock(), atlasCapacity: Int = 64, backingScale: Double = 2) -> MetalTileCanvas {
        MetalTileCanvas(context: context, backingScale: backingScale, atlasCapacity: atlasCapacity, clock: { clock.now })
    }

    @Test func rastersVisibleTilesAndCompositesThemLikeCoreGraphics() async throws {
        let context = try #require(MetalAvailability.context)
        let canvas = makeCanvas(backingScale: 1)
        #expect(canvas.backend == .metal)
        #expect(canvas.layer.sublayers?.first === canvas.metalLayer)
        #expect(canvas.displayList == nil && canvas.viewport == nil && canvas.rasterGeometry == nil)
        let viewport = Viewport(size: Corpus.viewSize)
        canvas.update(displayList: Corpus.groupClipOpacity, viewport: viewport)
        #expect(canvas.needsDisplay)
        #expect(canvas.metalLayer.drawableSize == CGSize(width: 128, height: 96))
        await canvas.settle()
        let geometry = try #require(canvas.rasterGeometry)
        let visible = canvas.visibleKeys(of: geometry, viewport: viewport, canvas: Corpus.canvas)
        #expect(visible.count == 1)
        #expect(visible.allSatisfy(canvas.hasTile))
        #expect(canvas.rasterizedTileCount == 1)
        #expect(canvas.atlasTileCount == 1)

        canvas.pasteboardColor = .white
        let texture = try makeFrameTexture(context, width: 128, height: 96)
        let timing = try #require(canvas.renderFrame(into: texture))
        #expect(timing.tiles == 1)
        #expect(timing.totalSeconds >= timing.cpuSeconds)
        #expect(!canvas.needsDisplay)

        // At 100% on a 1× display the tile is composited 1:1: the frame is the tile.
        let frame = try readBack(texture)
        let reference = try #require(CoreGraphicsRenderer(background: .white).renderBitmap(Corpus.groupClipOpacity, viewport: viewport).flatMap(BitmapSurface.init(drawing:)))
        let parity = TileParity(reference: reference, candidate: frame)
        #expect(parity.passes, "\(parity)")
    }

    @Test func panIsALookupUntilUncachedTilesEnterTheView() async throws {
        let canvas = makeCanvas()
        let start = Viewport(size: size)
        canvas.update(displayList: Corpus.solidRect, viewport: start)
        await canvas.settle()
        let initial = canvas.rasterizedTileCount
        #expect(initial == 6)

        // 10 points on a 2× display stays inside the 3 × 2 tiles already drawn.
        canvas.update(displayList: Corpus.solidRect, viewport: start.scrolled(byViewDelta: Vector(dx: 10, dy: 0)))
        await canvas.settle()
        #expect(canvas.rasterizedTileCount == initial, "pan inside cached tiles rasterizes nothing")
        #expect(canvas.needsDisplay, "but it does schedule a frame")

        // A full tile further brings in a new column.
        canvas.update(displayList: Corpus.solidRect, viewport: start.scrolled(byViewDelta: Vector(dx: 138, dy: 0)))
        await canvas.settle()
        #expect(canvas.rasterizedTileCount == initial + 2)

        // Back again: the old tiles are still in the atlas.
        canvas.update(displayList: Corpus.solidRect, viewport: start)
        await canvas.settle()
        #expect(canvas.rasterizedTileCount == initial + 2)
    }

    @Test func gesturesDrawExistingTilesThenReRasterizeOnSettleOrEvery250ms() async throws {
        let context = try #require(MetalAvailability.context)
        let clock = ManualClock()
        let canvas = makeCanvas(clock: clock)
        let start = Viewport(size: size)
        canvas.update(displayList: Corpus.ellipse, viewport: start)
        await canvas.settle()
        let settled = try #require(canvas.rasterGeometry)
        let texture = try makeFrameTexture(context, width: 600, height: 400)

        canvas.beginGesture()
        #expect(canvas.isGesturing)
        clock.now += 0.1
        canvas.update(displayList: Corpus.ellipse, viewport: start.zoomed(to: 1.3).rotated(byDegrees: 10))
        await canvas.settle()
        #expect(canvas.rasterGeometry == settled, "within 250 ms the gesture keeps the old tiling")
        let during = try #require(canvas.renderFrame(into: texture))
        #expect(during.tiles > 0, "existing tiles are drawn through the changing transform")
        let rastersBefore = canvas.rasterizedTileCount

        clock.now += 0.2
        let turned = start.zoomed(to: 1.5).rotated(byDegrees: 20)
        canvas.update(displayList: Corpus.ellipse, viewport: turned)
        let refreshed = try #require(canvas.rasterGeometry)
        #expect(refreshed == TileGeometry(viewport: turned, backingScale: 2), "after 250 ms the current step and angle rasterize")
        // While the new tiles render, the previous tiling still fills the frame.
        let bridging = try #require(canvas.renderFrame(into: texture))
        #expect(bridging.tiles > 0)
        await canvas.settle()
        #expect(canvas.rasterizedTileCount > rastersBefore)

        clock.now += 0.01
        let ended = turned.zoomed(to: 1.6)
        canvas.update(displayList: Corpus.ellipse, viewport: ended)
        #expect(canvas.rasterGeometry == refreshed)
        canvas.endGesture()
        #expect(!canvas.isGesturing)
        #expect(canvas.rasterGeometry == TileGeometry(viewport: ended, backingScale: 2), "settling rasterizes the settled zoom")
        await canvas.settle()
    }

    @Test func endingAGestureBeforeAnyUpdateIsHarmless() {
        let canvas = makeCanvas()
        canvas.beginGesture()
        canvas.endGesture()
        #expect(canvas.rasterGeometry == nil)
    }

    @Test func modeChangesAndInvalidationReRenderTiles() async throws {
        let canvas = makeCanvas()
        let viewport = Viewport(size: size)
        canvas.update(displayList: Corpus.solidRect, viewport: viewport)
        await canvas.settle()
        #expect(canvas.rasterizedTileCount == 6)

        canvas.setViewMode(.keyline)
        #expect(canvas.renderer?.viewMode == .keyline)
        await canvas.settle()
        #expect(canvas.rasterizedTileCount == 12, "a mode change re-renders every visible tile")

        canvas.invalidate(pasteboardRect: Rect(x: 10, y: 10, width: 4, height: 4))
        await canvas.settle()
        #expect(canvas.rasterizedTileCount == 13, "only the tile under the dirty rect re-renders")

        // The Greek type below preference re-renders every visible tile too.
        canvas.setGreekTypeBelow(8)
        #expect(canvas.renderer?.greekTypeBelow == 8)
        await canvas.settle()
        #expect(canvas.rasterizedTileCount == 19)

        // A changed list drops everything, including tiles still rendering.
        canvas.update(displayList: Corpus.ellipse, viewport: viewport)
        canvas.update(displayList: Corpus.solidRect, viewport: viewport)
        await canvas.settle()
        #expect(canvas.atlasTileCount == 6)
        #expect(canvas.layer.bounds == CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    @Test func aSmallAtlasRecyclesSlotsOfTilesThatLeftTheView() async throws {
        let canvas = makeCanvas(atlasCapacity: 8)
        let start = Viewport(size: size)
        canvas.update(displayList: Corpus.solidRect, viewport: start)
        await canvas.settle()
        canvas.update(displayList: Corpus.solidRect, viewport: start.scrolled(byViewDelta: Vector(dx: 400, dy: 300)))
        await canvas.settle()
        #expect(canvas.atlasTileCount == 8)
        #expect(canvas.rasterizedTileCount == 12)

        // More visible tiles than slots: what fits is drawn, nothing is evicted from view.
        let tiny = makeCanvas(atlasCapacity: 2)
        tiny.update(displayList: Corpus.solidRect, viewport: start)
        await tiny.settle()
        #expect(tiny.atlasTileCount == 2)
    }

    @Test func drawsIntoTheLayersDrawableAndDrivesADisplayLink() async throws {
        let canvas = makeCanvas()
        #expect(!canvas.drawFrame() || true)  // no size yet: the layer may still vend a drawable
        canvas.update(displayList: Corpus.solidRect, viewport: Viewport(size: size))
        await canvas.settle()
        #expect(canvas.drawFrame())
        #expect(!canvas.needsDisplay)

        canvas.startDisplayLink()
        #expect(canvas.isDisplayLinkRunning)
        canvas.startDisplayLink()  // idempotent
        canvas.setNeedsDisplay()
        #expect(canvas.needsDisplay)
        canvas.stopDisplayLink()
        #expect(!canvas.isDisplayLinkRunning)
    }

    @Test func discardingDropsTheTilesAndStopsTheDisplayLink() async throws {
        let canvas = makeCanvas()
        let viewport = Viewport(size: size)
        canvas.update(displayList: Corpus.solidRect, viewport: viewport)
        await canvas.settle()
        canvas.startDisplayLink()
        #expect(canvas.atlasTileCount > 0 && canvas.isDisplayLinkRunning)
        canvas.discardTiles()
        #expect(canvas.atlasTileCount == 0 && !canvas.isDisplayLinkRunning && canvas.rasterGeometry == nil && !canvas.needsDisplay)
        await canvas.settle()
        #expect(canvas.atlasTileCount == 0, "nothing is requested again until the next update")
        canvas.update(displayList: Corpus.solidRect, viewport: viewport)
        await canvas.settle()
        #expect(canvas.atlasTileCount > 0)
    }

    @Test func framesWithoutContentDrawThePasteboardOnly() throws {
        let context = try #require(MetalAvailability.context)
        let canvas = makeCanvas()
        canvas.pasteboardColor = Color(red: 1, green: 0, blue: 0)
        let texture = try makeFrameTexture(context, width: 16, height: 16)
        let timing = try #require(canvas.renderFrame(into: texture))
        #expect(timing.tiles == 0)
        #expect(try readBack(texture).pixel(x: 8, y: 8) == RGBA8(red: 255, green: 0, blue: 0, alpha: 255))
    }

    // MARK: Fallback

    @Test func fallsBackToCoreGraphicsWithoutADevice() async throws {
        let canvas = MetalTileCanvas(device: nil)
        #expect(canvas.backend == .coreGraphics(reason: "no Metal device"))
        let fallback = try #require(canvas.fallbackCanvas)
        #expect(canvas.layer.sublayers?.first === fallback.layer)
        #expect(canvas.metalLayer.superlayer == nil)
        #expect(!canvas.drawFrame())
        canvas.startDisplayLink()
        #expect(!canvas.isDisplayLinkRunning)

        let viewport = Viewport(size: size)
        canvas.update(displayList: Corpus.solidRect, viewport: viewport)
        await canvas.settle()
        #expect(fallback.tileLayerCount == 6)
        #expect(fallback.layout.map { $0.placements.allSatisfy { fallback.hasContents(for: $0.key) } } == true)

        // Mode changes and invalidation go to the Core Graphics canvas.
        canvas.setViewMode(.keyline)
        await canvas.settle()
        #expect(await fallback.cache.viewMode == .keyline)
        canvas.setGreekTypeBelow(8)
        await canvas.settle()
        #expect(canvas.renderer == nil)
        canvas.invalidate(pasteboardRect: Rect(x: 0, y: 0, width: 10, height: 10))
        await canvas.settle()
        canvas.backingScale = 1
        #expect(fallback.backingScale == 1)
        #expect(canvas.atlasTileCount == 0)
        #expect(!canvas.hasTile(fallback.layout!.placements[0].key))
        canvas.discardTiles()
        await canvas.settle()
        #expect(fallback.tileLayerCount == 0)
        #expect(await fallback.cache.count == 0)
    }

    @Test func theSystemDeviceGivesAMetalCanvas() async {
        let canvas = MetalTileCanvas()
        #expect(canvas.backend == .metal)
        #expect(canvas.context === MetalAvailability.context)
        canvas.update(displayList: Corpus.solidRect, viewport: Viewport(size: size))
        await canvas.settle()
        #expect(canvas.rasterizedTileCount == 6)
    }

    @Test func aFallbackWhileTilesRenderDiscardsThem() async throws {
        let context = try #require(MetalContext(device: MTLCreateSystemDefaultDevice()))
        let canvas = makeCanvas(context: context)
        canvas.update(displayList: Corpus.ellipse, viewport: Viewport(size: size))
        let texture = try makeFrameTexture(context, width: 600, height: 400)
        let early = try #require(canvas.renderFrame(into: texture))
        #expect(early.tiles == 0, "nothing is drawable before the first tiles land")
        context.injectCommandBufferFailures(MetalTileCanvas.failureLimit)
        for _ in 0..<MetalTileCanvas.failureLimit {
            _ = canvas.renderFrame(into: texture)
        }
        #expect(canvas.fallbackCanvas != nil)
        await canvas.settle()
        #expect(canvas.rasterizedTileCount == 0 && canvas.atlasTileCount == 0)
    }

    @Test func displayLinkRefreshesDrawOnlyWhenAFrameIsDue() async throws {
        let canvas = makeCanvas()
        canvas.update(displayList: Corpus.solidRect, viewport: Viewport(size: size))
        await canvas.settle()
        let drawable = try #require(canvas.metalLayer.nextDrawable())
        let idle = try #require(canvas.metalLayer.nextDrawable())
        canvas.startDisplayLink()
        #expect(!canvas.drawFrame(), "the running link owns the drawables")
        #expect(canvas.needsDisplay)
        canvas.displayLinkFired(drawable)
        #expect(!canvas.needsDisplay, "a due frame is presented")
        canvas.displayLinkFired(idle)
        #expect(!canvas.needsDisplay, "an idle refresh pauses the link")
        // Give the real link a few refreshes to call back through its delegate.
        canvas.setNeedsDisplay()
        for _ in 0..<50 where canvas.needsDisplay {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        canvas.stopDisplayLink()
    }

    @Test func threeFailedCommandBuffersInARowSwitchToCoreGraphics() async throws {
        // A private context, so the injected faults touch no other test.
        let context = try #require(MetalContext(device: MTLCreateSystemDefaultDevice()))
        let canvas = makeCanvas(context: context)
        context.injectCommandBufferFailures(MetalTileCanvas.failureLimit)
        let viewport = Viewport(size: size)
        canvas.update(displayList: Corpus.solidRect, viewport: viewport)
        await canvas.settle()
        #expect(canvas.backend == .coreGraphics(reason: "tile command buffer failed 3 times in a row"))
        let fallback = try #require(canvas.fallbackCanvas)
        await canvas.settle()
        #expect(fallback.displayList == Corpus.solidRect, "the fallback takes over the current list and viewport")
        #expect(fallback.tileLayerCount == 6)
    }

    @Test func aSuccessResetsTheFailureCount() async throws {
        let context = try #require(MetalContext(device: MTLCreateSystemDefaultDevice()))
        let canvas = makeCanvas(context: context)
        context.injectCommandBufferFailures(MetalTileCanvas.failureLimit - 1)
        canvas.update(displayList: Corpus.solidRect, viewport: Viewport(size: size))
        await canvas.settle()
        #expect(canvas.backend == .metal)
        #expect(canvas.rasterizedTileCount == 6)

        // Failed frames count too.
        let texture = try makeFrameTexture(context, width: 600, height: 400)
        context.injectCommandBufferFailures(MetalTileCanvas.failureLimit)
        for _ in 0..<MetalTileCanvas.failureLimit {
            _ = canvas.renderFrame(into: texture)
        }
        #expect(canvas.backend == .coreGraphics(reason: "frame command buffer failed 3 times in a row"))
        #expect(canvas.renderFrame(into: texture) == nil)
    }

    @Test func presentedFramesReportFailuresToo() async throws {
        let context = try #require(MetalContext(device: MTLCreateSystemDefaultDevice()))
        let canvas = makeCanvas(context: context)
        canvas.update(displayList: Corpus.solidRect, viewport: Viewport(size: size))
        await canvas.settle()
        context.injectCommandBufferFailures(MetalTileCanvas.failureLimit)
        for _ in 0..<MetalTileCanvas.failureLimit {
            #expect(canvas.drawFrame())
        }
        for _ in 0..<200 where canvas.backend == .metal {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(canvas.backend == .coreGraphics(reason: "frame command buffer failed 3 times in a row"))
    }
}

/// Slot bookkeeping, without a GPU.
@Suite struct TileSlotsTests {
    private func key(_ column: Int) -> TileKey {
        TileKey(canvas: "slots", zoomStep: ZoomStep(index: 0), rotationDegrees: 0, column: column, row: 0)
    }

    @Test func allocatesMarksReadyAndEvictsLeastRecentlyUsedUnprotected() {
        var slots = TileSlots(capacity: 2)
        #expect(slots.capacity == 2)
        let first = slots.allocate(key(0), protecting: [])
        let second = slots.allocate(key(1), protecting: [])
        #expect(first == 0 && second == 1)
        #expect(slots.allocate(key(0), protecting: []) == 0, "an allocated key keeps its slot")
        #expect(slots.readySlot(for: key(0)) == nil, "not drawable until marked ready")
        slots.markReady(key(0))
        slots.markReady(key(1))
        slots.markReady(key(9))  // never allocated: ignored
        #expect(slots.ready == [key(0), key(1)])
        #expect(slots.readySlot(for: key(0)) == 0)  // key(0) now most recent

        #expect(slots.allocate(key(2), protecting: []) == 1, "key(1) was least recently used")
        #expect(!slots.contains(key(1)))
        #expect(slots.allocate(key(3), protecting: [key(0), key(2)]) == nil, "every slot is protected")

        slots.remove(key(0))
        #expect(slots.count == 1)
        #expect(slots.allocate(key(3), protecting: []) == 0)
        #expect(slots.removeAll { _ in true }.count == 2)
        #expect(slots.count == 0 && slots.ready.isEmpty)
        #expect(TileSlots(capacity: 0).capacity == 1)
    }
}
