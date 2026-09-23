import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// IMG-004 / IMG-018: placed images drawn from an `ImageStore` by both renderers.
@Suite struct ImageRenderingTests {
    /// A 16 × 16 blob: left half red, right half blue, top rows (y < 4) white.
    static func quadrants() -> CGImage {
        ImageFixtures.rgba(width: 16, height: 16) { x, y in
            y < 4 ? [255, 255, 255, 255] : (x < 8 ? [255, 0, 0, 255] : [0, 0, 255, 255])
        }
    }

    static func store(_ images: [String: CGImage], tiledThreshold: Int = ImagePyramid.defaultTiledThreshold, pyramidThreshold: Int = ImagePyramid.defaultPyramidThreshold) -> ImageStore {
        let directory = ImageFixtures.directory()
        var urls: [String: URL] = [:]
        for (id, image) in images {
            urls[id] = ImageFixtures.write(image, to: directory.appendingPathComponent("\(id).png"))
        }
        let resolved = urls
        return ImageStore(blobURL: { resolved[$0] }, pyramidThreshold: pyramidThreshold, tiledThreshold: tiledThreshold)
    }

    static let viewport = Viewport(size: Size(width: 32, height: 32))

    static func list(_ item: ImageItem) -> DisplayList {
        DisplayList(canvas: "images", items: [.image(item)])
    }

    /// Renders twice: the first frame schedules the decode, the second draws the pixels.
    static func render(_ item: ImageItem, store: ImageStore, management: ColorManagement = .standard, scale: Double = 1) throws -> BitmapSurface {
        var renderer = CoreGraphicsRenderer(background: .white).with(colorManagement: management)
        renderer.imageStore = store
        _ = renderer.renderBitmap(list(item), viewport: viewport, scale: scale)
        store.waitUntilIdle()
        let image = try #require(renderer.renderBitmap(list(item), viewport: viewport, scale: scale))
        let surface = try #require(BitmapSurface(width: image.width, height: image.height, colorSpace: image.colorSpace!))
        surface.context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return surface
    }

    @Test func naturalFrameCropAndReadTimeRules() {
        #expect(ImageItem.naturalRect(pixelWidth: 300, pixelHeight: 150, dpiX: 300, dpiY: 0) == Rect(x: 0, y: 0, width: 72, height: 150))
        #expect(ImageItem.naturalRect(pixelWidth: 10, pixelHeight: 10, dpiX: .nan, dpiY: 144) == Rect(x: 0, y: 0, width: 10, height: 5))
        var item = ImageItem(assetID: "a", rect: Rect(x: 0, y: 0, width: 100, height: 50), crop: Rect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        #expect(item.visibleRect == Rect(x: 50, y: 0, width: 50, height: 25))
        #expect(DisplayItem.image(item).bounds == Rect(x: 50, y: 0, width: 50, height: 25))
        #expect(DisplayItem.image(item).ownBounds == Rect(x: 50, y: 0, width: 50, height: 25))
        for invalid in [Rect(x: -0.1, y: 0, width: 0.5, height: 0.5), Rect(x: 0, y: 0, width: 0, height: 1), Rect(x: 0.6, y: 0, width: 0.5, height: 1), Rect(x: 0, y: 0.8, width: 1, height: 0.5)] {
            item.crop = invalid
            #expect(item.effectiveCrop == nil && item.visibleRect == item.rect)
        }
    }

    @Test func hitTestingRespectsTheCrop() {
        let item = ImageItem(assetID: "a", rect: Rect(x: 0, y: 0, width: 20, height: 20), crop: Rect(x: 0.5, y: 0, width: 0.5, height: 1))
        let tester = HitTester(displayList: Self.list(item), viewport: Self.viewport)
        #expect(tester.hitTest(viewPoint: Point(x: 5, y: 10)).isEmpty, "the cropped-away half does not hit")
        #expect(!tester.hitTest(viewPoint: Point(x: 15, y: 10)).isEmpty)
    }

    @Test func withoutAStoreOrBeforeDecodingThePlaceholderDraws() throws {
        let item = ImageItem(assetID: "q", rect: Rect(x: 0, y: 0, width: 16, height: 16))
        let placeholder = try #require(CoreGraphicsRenderer(background: .white).renderBitmap(Self.list(item), viewport: Self.viewport).flatMap(BitmapSurface.init(drawing:)))
        #expect(placeholder.pixel(x: 3, y: 8) == RGBA8(red: 191, green: 191, blue: 191, alpha: 255))
        let store = Self.store([:])
        store.setDownloading(assetID: "q", progress: 0.5)
        var renderer = CoreGraphicsRenderer(background: .white)
        renderer.imageStore = store
        let downloading = try #require(renderer.renderBitmap(Self.list(item), viewport: Self.viewport).flatMap(BitmapSurface.init(drawing:)))
        #expect(downloading.pixel(x: 2, y: 15).red < 150, "the progress bar fills the left half of the bottom edge")
        #expect(downloading.pixel(x: 13, y: 15).red > 150)
        #expect(ImageDrawing.progressBar(for: item, store: nil) == nil)
    }

    @Test func decodedPixelsDrawWithTheCrop() throws {
        let store = Self.store(["q": Self.quadrants()])
        final class Readied: @unchecked Sendable {
            let lock = NSLock()
            var ids: [String] = []
        }
        let readied = Readied()
        store.onReady = { id in readied.lock.withLock { readied.ids.append(id) } }
        let item = ImageItem(assetID: "q", rect: Rect(x: 0, y: 0, width: 16, height: 16), crop: Rect(x: 0, y: 0, width: 0.5, height: 1))
        let surface = try Self.render(item, store: store)
        #expect(surface.pixel(x: 3, y: 10) == RGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        #expect(surface.pixel(x: 3, y: 1) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255), "the image's top row is at the frame's top")
        #expect(surface.pixel(x: 12, y: 10) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255), "cropped away: the white background")
        #expect(readied.lock.withLock { readied.ids.contains("q") })
    }

    @Test func grayImagesTakeTheTintAndTransparency() throws {
        let gray = ImageFixtures.grayImage(width: 8, height: 8) { x, _ in x < 4 ? 0 : 255 }
        let store = Self.store(["g": gray])
        let item = ImageItem(assetID: "g", rect: Rect(x: 0, y: 0, width: 16, height: 16), mode: .grayscale, transparentBackground: true, tint: Color(cyan: 0, magenta: 1, yellow: 1, black: 0))
        let surface = try Self.render(item, store: store, management: ColorManagement(workingSpace: .displayP3))
        let dark = surface.pixel(x: 3, y: 8)
        #expect(dark.red > 150 && dark.green < 100, "dark pixels take the tint through Working CMYK (\(dark))")
        #expect(surface.pixel(x: 13, y: 8) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255), "white is transparent over the background")
    }

    @Test func theSourceProfileAndTheProofChangeThePixels() throws {
        let store = Self.store(["q": Self.quadrants()])
        let plain = ImageItem(assetID: "q", rect: Rect(x: 0, y: 0, width: 16, height: 16))
        var tagged = plain
        tagged.sourceProfile = WTColor.ProfileRegistry.shared.displayP3
        tagged.intent = .perceptual
        let p3Tiles = ColorManagement(workingSpace: .displayP3)
        let base = try Self.render(plain, store: store, management: p3Tiles).pixel(x: 3, y: 10)
        let assigned = try Self.render(tagged, store: store, management: p3Tiles).pixel(x: 3, y: 10)
        #expect(base != assigned, "a P3 source profile reinterprets the pixels (\(base) vs \(assigned))")
        #expect(assigned == RGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        let proofed = try Self.render(plain, store: store, management: p3Tiles.with(proof: WTColor.ProofSetup(profile: WTColor.ProfileRegistry.shared.defaultCMYK))).pixel(x: 12, y: 10)
        let unproofed = try Self.render(plain, store: store, management: p3Tiles).pixel(x: 12, y: 10)
        #expect(proofed.maxChannelDifference(to: unproofed) > 8, "screen blue proofed to the press")
        // A proofed gray image goes through sRGB first; the result is cached per level.
        let gray = Self.store(["g": ImageFixtures.grayImage(width: 4, height: 4) { _, _ in 128 }])
        let grayItem = ImageItem(assetID: "g", rect: Rect(x: 0, y: 0, width: 16, height: 16), mode: .grayscale)
        let management = ColorManagement.standard.with(proof: WTColor.ProofSetup(profile: WTColor.ProfileRegistry.shared.defaultCMYK, simulatePaperWhite: true))
        let once = try Self.render(grayItem, store: gray, management: management).pixel(x: 8, y: 8)
        let twice = try Self.render(grayItem, store: gray, management: management).pixel(x: 8, y: 8)
        #expect(once == twice)
    }

    @Test func proofCacheEvictsBeyondCapacity() throws {
        let cache = ImageProofCache()
        let transform = try #require(WTColor.Converter.shared.transform(from: WTColor.ProfileRegistry.shared.sRGB, to: WTColor.ProfileRegistry.shared.displayP3))
        let images = (0...ImageProofCache.capacity).map { _ in ImageFixtures.opaque(width: 2, height: 2) }
        let first = cache.proofed(images[0], drawnIn: WTColor.Spaces.sRGB, transform: transform, into: WTColor.Spaces.displayP3)
        #expect(cache.proofed(images[0], drawnIn: WTColor.Spaces.sRGB, transform: transform, into: WTColor.Spaces.displayP3) === first)
        for image in images.dropFirst() {
            _ = cache.proofed(image, drawnIn: WTColor.Spaces.sRGB, transform: transform, into: WTColor.Spaces.displayP3)
        }
        #expect(cache.proofed(images[0], drawnIn: WTColor.Spaces.sRGB, transform: transform, into: WTColor.Spaces.displayP3) !== first, "evicted and rebuilt")
    }

    @Test func pdfOutputDecodesInlineAndMatchesTheScreen() throws {
        let store = Self.store(["q": Self.quadrants()])
        let item = ImageItem(assetID: "q", rect: Rect(x: 0, y: 0, width: 16, height: 16))
        var renderer = CoreGraphicsRenderer(background: .white)
        renderer.imageStore = store
        let pdf = try #require(renderer.renderPDF(Self.list(item), viewport: Self.viewport))
        let page = try #require(PDFRasterizer.rasterize(pdf, scale: 1))
        let screen = try Self.render(item, store: store)
        for (x, y) in [(3, 10), (12, 10), (8, 1)] {
            #expect(page.pixel(x: x, y: y).maxChannelDifference(to: screen.pixel(x: x, y: y)) <= 2)
        }
    }

    @Test func interpolationFollowsTheLevelScale() {
        #expect(ImageDrawing.interpolation(forLevelScale: 0.5) == .high)
        #expect(ImageDrawing.interpolation(forLevelScale: 2) == .default)
        #expect(ImageDrawing.interpolation(forLevelScale: 8) == .none)
    }

    @Test func aTiledImageZoomedInDrawsFullResolutionPixels() throws {
        // A 1,024-pixel checkerboard treated as tiled above 1,000 pixels: level 1 is 512 px wide,
        // so at one device pixel per image pixel the full level draws, only the part in view.
        let checker = ImageFixtures.rgba(width: 1024, height: 1024) { x, y in (x + y) % 2 == 0 ? [0, 0, 0, 255] : [255, 255, 255, 255] }
        let store = Self.store(["t": checker], tiledThreshold: 1_000, pyramidThreshold: 1_000)
        let item = ImageItem(assetID: "t", rect: Rect(x: 0, y: 0, width: 128, height: 128))
        let surface = try Self.render(item, store: store, scale: 8)
        let a = surface.pixel(x: 4, y: 4), b = surface.pixel(x: 5, y: 4)
        #expect(a.red < 30 && b.red > 225, "single source pixels are resolved (\(a), \(b), \(surface.pixel(x: 4, y: 12)), \(surface.pixel(x: 1, y: 1)))")
        #expect(store.pyramid(for: "t")?.isTiled == true)
    }

    @Test func keylineAndFastModesDrawTheCroppedBox() throws {
        let item = ImageItem(assetID: "q", rect: Rect(x: 0, y: 0, width: 16, height: 16), crop: Rect(x: 0, y: 0, width: 0.5, height: 1))
        let keyline = try #require(CoreGraphicsRenderer(background: .white, viewMode: .keyline).renderBitmap(Self.list(item), viewport: Self.viewport).flatMap(BitmapSurface.init(drawing:)))
        #expect(keyline.pixel(x: 12, y: 8) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255))
        #expect(keyline.pixel(x: 0, y: 8).red < 128)
    }

    @Test func invalidationFindsEveryFrameOfAnAsset() {
        let item = ImageItem(assetID: "q", rect: Rect(x: 0, y: 0, width: 10, height: 10), transform: .translation(x: 5, y: 5))
        let list = DisplayList(canvas: "images", items: [.image(item), .group(GroupItem(children: [.image(item), .image(ImageItem(assetID: "other", rect: Rect(x: 0, y: 0, width: 1, height: 1)))])), .fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), paint: .solid(.black)))])
        #expect(list.bounds(ofImageAsset: "q") == [Rect(x: 5, y: 5, width: 10, height: 10), Rect(x: 5, y: 5, width: 10, height: 10)])
        #expect(InvalidationMapper().dirtyRegion(imageAsset: "q", in: [list]).rects(for: "images") == [Rect(x: 5, y: 5, width: 10, height: 10)])
    }
}

/// COLOR-006: recoloring a swatch repaints its dependents, batched.
@Suite struct ColorInvalidationTests {
    @Test func recoloringFiftyThousandDependentsIsOnePass() {
        let list = Corpus.manyRects(count: 50_000)
        let ids = (0..<50_000).map { NodeID(counter: UInt64($0), replica: 1) }
        let indexed = DisplayList(canvas: list.canvas, items: list.items, nodeIDs: ids)
        let start = Date()
        let region = InvalidationMapper().dirtyRegion(recoloring: ids, in: [indexed])
        let elapsed = Date().timeIntervalSince(start)
        #expect(region.rects(for: list.canvas) == [indexed.bounds!])
        print("PERF recolor of 50,000 dependents mapped in \(elapsed) s (COLOR-006 budget: 16 ms on M1, release)")
        #if !DEBUG
        #expect(elapsed < 0.016)
        #endif
        let few = InvalidationMapper().dirtyRegion(recoloring: ids.prefix(2), in: [indexed])
        #expect(few.rects(for: list.canvas).count >= 1)
        #expect(InvalidationMapper().wholeDocument([indexed, DisplayList(canvas: "empty", items: [])]).rects(for: list.canvas) == [indexed.bounds!])
    }
}
