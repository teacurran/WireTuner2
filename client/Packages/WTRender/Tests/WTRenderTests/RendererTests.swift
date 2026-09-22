import WTGeometry
import CoreGraphics
import Foundation
import Testing
@testable import WTRender

@Suite struct CoreGraphicsRendererTests {
    /// Anti-aliased edge pixels may differ between the bitmap and the rasterized PDF by at
    /// most this much per channel (observed maximum 10/255 at 15° rotation).
    static let edgeTolerance = 16

    /// Interior pixels are identical, except inside groups composited with opacity below 1:
    /// Core Graphics blends a PDF transparency group in a different working space than a
    /// live transparency layer, which shifts single channels by up to 4/255 (observed: green
    /// 140 vs 144 for 50% red over white).  Recorded in docs/spec/client.adoc.
    static let translucentGroupInteriorTolerance = 4

    static func hasTranslucentGroup(_ items: [DisplayItem]) -> Bool {
        items.contains { item in
            guard case .group(let group) = item else { return false }
            return group.opacity < 1 || hasTranslucentGroup(group.children)
        }
    }

    private let renderer = CoreGraphicsRenderer(background: .white)

    @Test func rendersSolidFillExactly() throws {
        let image = try #require(renderer.renderBitmap(Corpus.solidRect, viewport: Viewport(size: Corpus.viewSize)))
        let surface = try #require(BitmapSurface(drawing: image))
        #expect(surface.width == 128 && surface.height == 96)
        let inside = surface.pixel(x: 40, y: 30)
        #expect(inside == RGBA8(red: 230, green: 26, blue: 26, alpha: 255), "\(inside)")
        #expect(surface.pixel(x: 100, y: 80) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255))
        #expect(surface.pixel(x: 40, y: 5) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255), "y is down: the rect starts at row 10")
        #expect(surface.isFlat(x: 40, y: 30))
        #expect(!surface.isFlat(x: 10, y: 10))
        #expect(surface.pixel(x: -5, y: 500) == surface.pixel(x: 0, y: 95), "pixel lookups clamp")
    }

    @Test func transparentBackgroundByDefault() throws {
        let image = try #require(CoreGraphicsRenderer().renderBitmap(Corpus.solidRect, viewport: Viewport(size: Corpus.viewSize)))
        let surface = try #require(BitmapSurface(drawing: image))
        #expect(surface.pixel(x: 100, y: 80) == RGBA8(red: 0, green: 0, blue: 0, alpha: 0))
        #expect(surface.pixel(x: 40, y: 30).alpha == 255)
        #expect(CoreGraphicsRenderer().flatteningTolerance == .standard)
        #expect(CoreGraphicsRenderer().background == nil)
    }

    @Test func fillRulesDiffer() throws {
        let image = try #require(renderer.renderBitmap(Corpus.evenOddStar, viewport: Viewport(size: Corpus.viewSize)))
        let surface = try #require(BitmapSurface(drawing: image))
        // The pentagon at the centre of an even-odd star is a hole; non-zero fills it.
        #expect(surface.pixel(x: 40, y: 48) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255))
        #expect(surface.pixel(x: 92, y: 48) == RGBA8(red: 26, green: 179, blue: 51, alpha: 255))
    }

    @Test func viewTransformAppliesToDrawing() throws {
        // Zoom 2 with the scroll origin at (10, 10): the rect's (10, 10) corner lands on the view origin.
        let viewport = Viewport(scrollOrigin: Point(x: 10, y: 10), zoom: 2, size: Corpus.viewSize)
        let image = try #require(renderer.renderBitmap(Corpus.solidRect, viewport: viewport))
        let surface = try #require(BitmapSurface(drawing: image))
        #expect(surface.pixel(x: 2, y: 2).red == 230)
        #expect(surface.pixel(x: 118, y: 78).red == 230, "60 × 40 units fill 120 × 80 points")
        #expect(surface.pixel(x: 122, y: 82).red == 255)

        // At 2× device scale the bitmap doubles and the pixel grid follows.
        let retina = try #require(renderer.renderBitmap(Corpus.solidRect, viewport: viewport, scale: 2))
        #expect(retina.width == 256 && retina.height == 192)
        let retinaSurface = try #require(BitmapSurface(drawing: retina))
        #expect(retinaSurface.pixel(x: 238, y: 158).red == 230)
        #expect(retinaSurface.pixel(x: 242, y: 162).red == 255)
    }

    @Test func rotatedViewDrawsRotated() throws {
        let viewport = Viewport(size: Corpus.viewSize).rotated(toDegrees: 90)
        let image = try #require(renderer.renderBitmap(Corpus.solidRect, viewport: viewport))
        let surface = try #require(BitmapSurface(drawing: image))
        // The rect's centre (40, 30) stays where the unrotated view showed it only if it were the
        // pivot; instead check a point via the transform itself.
        let centre = viewport.toView(Point(x: 40, y: 30))
        #expect(surface.pixel(x: Int(centre.x), y: Int(centre.y)).red == 230)
        let outside = viewport.toView(Point(x: 100, y: 80))
        #expect(surface.pixel(x: Int(outside.x), y: Int(outside.y)).red == 255)
    }

    @Test func placeholdersAndGroupsPaint() throws {
        let image = try #require(renderer.renderBitmap(Corpus.placeholders, viewport: Viewport(size: Corpus.viewSize)))
        let surface = try #require(BitmapSurface(drawing: image))
        #expect(surface.pixel(x: 20, y: 30) == RGBA8(red: 191, green: 191, blue: 191, alpha: 255), "image placeholder grey")
        // 15% of (0.1, 0.2, 0.9) over white is (221, 225, 251) after Core Graphics' rounding.
        let text = surface.pixel(x: 90, y: 60)
        #expect(text == RGBA8(red: 221, green: 225, blue: 251, alpha: 255), "text placeholder tint \(text)")
        // The one-unit baseline at y = 70 covers rows 69 and 70 by half each: much bluer than the tint.
        let baseline = surface.pixel(x: 90, y: 70)
        #expect(baseline.red < text.red - 50 && baseline.blue > 220, "baseline in the text colour \(baseline)")

        let group = try #require(renderer.renderBitmap(Corpus.groupClipOpacity, viewport: Viewport(size: Corpus.viewSize)))
        let groupSurface = try #require(BitmapSurface(drawing: group))
        let halfRed = groupSurface.pixel(x: 64, y: 30)
        #expect(halfRed == RGBA8(red: 242, green: 140, blue: 140, alpha: 255), "50% red over white \(halfRed)")
        #expect(groupSurface.pixel(x: 2, y: 2) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255), "clipped away")
    }

    @Test func offscreenAndEmptyListsLeaveTheBackground() throws {
        for list in [Corpus.empty, Corpus.offscreen] {
            let image = try #require(renderer.renderBitmap(list, viewport: Viewport(size: Corpus.viewSize)))
            let surface = try #require(BitmapSurface(drawing: image))
            #expect(surface.pixel(x: 64, y: 48) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255))
        }
    }

    @Test func degenerateSurfacesAreRefused() {
        #expect(BitmapSurface(width: 0, height: 10) == nil)
        #expect(BitmapSurface(width: 10, height: 0) == nil)
        #expect(BitmapSurface(width: 100_000, height: 1) == nil)
        #expect(renderer.renderBitmap(Corpus.solidRect, viewport: Viewport(size: .zero)) == nil)
        let huge = TileGeometry(zoomStep: ZoomStep(index: 0), rotationDegrees: 0, tileSize: 20_000)
        let key = TileKey(canvas: Corpus.canvas, zoomStep: ZoomStep(index: 0), rotationDegrees: 0, column: 0, row: 0)
        #expect(renderer.renderTile(Corpus.solidRect, key: key, geometry: huge) == nil)
    }

    @Test func tilesMatchTheWholeRender() throws {
        // Rendering the view as one bitmap and as tiles must give the same pixels.
        let viewport = Viewport(scrollOrigin: Point(x: 0, y: 0), rotationDegrees: 0, zoom: 1, size: Size(width: 512, height: 256))
        let list = DisplayList(canvas: Corpus.canvas, items: Corpus.strokes.items + Corpus.evenOddStar.items.map { item in
            guard case .fill(var fill) = item else { return item }
            fill.transform = .translation(x: 300, y: 100)
            return .fill(fill)
        })
        let wholeImage = try #require(renderer.renderBitmap(list, viewport: viewport))
        let whole = try #require(BitmapSurface(drawing: wholeImage))
        let geometry = TileGeometry(viewport: viewport, backingScale: 1)
        let keys = geometry.tiles(coveringViewRect: viewport.viewBounds, viewport: viewport, canvas: list.canvas)
        #expect(keys.count == 2)
        for key in keys {
            let tileImage = try #require(renderer.renderTile(list, key: key, geometry: geometry))
            let tile = try #require(BitmapSurface(drawing: tileImage))
            #expect(tile.width == 256 && tile.height == 256)
            // Core Graphics' scan conversion is not exactly translation-invariant at anti-aliased
            // edges; hold tiles to the spec's per-tile criterion (docs/spec/testing.adoc): at most
            // 0.1% of pixels differ, none by more than the edge tolerance.
            var mismatches = 0
            var maxDifference = 0
            for y in 0..<256 {
                for x in 0..<256 {
                    let difference = tile.pixel(x: x, y: y).maxChannelDifference(to: whole.pixel(x: key.column * 256 + x, y: key.row * 256 + y))
                    if difference != 0 {
                        mismatches += 1
                        maxDifference = max(maxDifference, difference)
                    }
                }
            }
            #expect(mismatches <= 65 && maxDifference <= Self.edgeTolerance, "tile \(key): \(mismatches) pixels differ from the whole render, max Δ\(maxDifference)")
        }
    }

    @Test(arguments: Corpus.all.map(\.name), Corpus.viewports.map(\.name))
    func bitmapAndPDFRendersArePixelIdentical(listName: String, viewportName: String) throws {
        let list = Corpus.all.first { $0.name == listName }!.list
        let viewport = Corpus.viewports.first { $0.name == viewportName }!.viewport
        for scale in [1.0, 2.0] {
            let bitmapImage = try #require(renderer.renderBitmap(list, viewport: viewport, scale: scale))
            let bitmap = try #require(BitmapSurface(drawing: bitmapImage))
            let pdf = try #require(renderer.renderPDF(list, viewport: viewport))
            #expect(pdf.count > 100)
            let rasterized = try #require(PDFRasterizer.rasterize(pdf, scale: scale))
            #expect(rasterized.width == bitmap.width && rasterized.height == bitmap.height)
            let interiorTolerance = Self.hasTranslucentGroup(list.items) ? Self.translucentGroupInteriorTolerance : 0
            let comparison = PixelComparison(reference: bitmap, candidate: rasterized, interiorTolerance: interiorTolerance, edgeTolerance: Self.edgeTolerance)
            #expect(
                comparison.passes,
                "\(listName)/\(viewportName)@\(scale)×: \(comparison.interiorMismatches) interior (max Δ\(comparison.maxInteriorDifference)), \(comparison.edgeMismatches) edge (max Δ\(comparison.maxEdgeDifference)) of \(comparison.pixels)"
            )
        }
    }

    @Test func pdfFailsGracefullyWithoutAMediaBox() {
        // A zero-size viewport still yields a PDF (Core Graphics accepts an empty media box).
        let viewport = Viewport(size: Size(width: 0, height: 0))
        #expect(renderer.renderPDF(Corpus.solidRect, viewport: viewport) != nil)
    }

    @Test func pixelDifferenceHelpers() {
        let a = RGBA8(red: 10, green: 20, blue: 30, alpha: 255)
        let b = RGBA8(red: 12, green: 15, blue: 30, alpha: 250)
        #expect(a.maxChannelDifference(to: b) == 5)
        #expect(a.description == "(10, 20, 30, 255)")
    }
}
