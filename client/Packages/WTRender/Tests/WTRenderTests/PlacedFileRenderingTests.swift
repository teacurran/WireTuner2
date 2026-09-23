import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// IMG-011: a placed file draws its preview scaled into its bounding box, or the gray box with
/// its name when there is no preview or its pixels are not in the store -- in both renderers and
/// in PDF output.  The corpus case `placedFiles` holds the gray boxes' goldens and parity.
@Suite struct PlacedFileRenderingTests {
    static let viewport = Viewport(size: Size(width: 80, height: 48))
    static let bounds = Rect(x: 0, y: 0, width: 64, height: 32)

    static func list(_ items: [DisplayItem]) -> DisplayList {
        DisplayList(canvas: "placed", items: items)
    }

    static func placed(preview: String?, name: String = "art.eps") -> DisplayItem {
        PlacedFileDrawing.item(PlacedFile(bounds: bounds, previewAssetID: preview, previewWidth: 16, previewHeight: 16, name: name, transform: .translation(x: 8, y: 8)))
    }

    /// Renders twice, as a canvas does: the first frame schedules the preview's decode.
    static func render(_ list: DisplayList, store: ImageStore?) throws -> BitmapSurface {
        var renderer = CoreGraphicsRenderer(background: .white)
        renderer.imageStore = store
        _ = renderer.renderBitmap(list, viewport: viewport)
        store?.waitUntilIdle()
        return try #require(renderer.renderBitmap(list, viewport: viewport).flatMap(BitmapSurface.init(drawing:)))
    }

    static let fill = RGBA8(red: 217, green: 217, blue: 217, alpha: 255)

    @Test func theItemIsThePreviewWithTheGrayBoxAsItsFallback() throws {
        guard case .image(let image) = Self.placed(preview: "cafe") else {
            Issue.record("a preview draws as an image")
            return
        }
        #expect(image.assetID == "cafe" && image.rect == Self.bounds && image.hasAlpha && image.name == "art.eps")
        #expect(image.transform == .translation(x: 8, y: 8))
        guard case .group(let box)? = image.fallback else {
            Issue.record("the fallback is the gray box")
            return
        }
        #expect(box.atomic && box.children.count == 3, "fill, border and the clipped label")
        #expect(image.fallback?.bounds == Self.bounds, "the fallback is in the image's local space and stays inside its frame")
        for preview in [nil, ""] as [String?] {
            guard case .group(let group) = Self.placed(preview: preview) else {
                Issue.record("without a preview the gray box draws alone")
                continue
            }
            #expect(group.atomic)
            #expect(DisplayItem.group(group).bounds == Self.bounds.applying(.translation(x: 8, y: 8)))
        }
        guard case .group(let unnamed) = Self.placed(preview: nil, name: "") else {
            Issue.record("a gray box")
            return
        }
        #expect(unnamed.children.count == 2, "no label for an empty name")
    }

    @Test func aBoxOfZeroAreaReadsAsOneInch() {
        #expect(PlacedFile(bounds: Rect(x: 3, y: 4, width: 0, height: 9)).effectiveBounds == Rect(x: 3, y: 4, width: 72, height: 72))
        #expect(PlacedFile(bounds: Rect(x: .nan, y: 4, width: 9, height: 9)).effectiveBounds == Rect(x: 0, y: 0, width: 72, height: 72))
        #expect(PlacedFile(bounds: Self.bounds).effectiveBounds == Self.bounds)
        // A sliver's border stays inside it.
        let sliver = PlacedFileDrawing.grayBox(Rect(x: 0, y: 0, width: 0.4, height: 10), name: "")
        #expect(sliver.bounds == Rect(x: 0, y: 0, width: 0.4, height: 10))
    }

    @Test func withoutAPreviewOrItsPixelsTheGrayBoxDraws() throws {
        let store = ImageRenderingTests.store([:])
        for (items, store) in [([Self.placed(preview: nil)], nil), ([Self.placed(preview: "cafe")], nil), ([Self.placed(preview: "cafe")], store)] as [([DisplayItem], ImageStore?)] {
            let surface = try Self.render(Self.list(items), store: store)
            #expect(surface.pixel(x: 60, y: 30) == Self.fill, "the box's fill")
            #expect(surface.pixel(x: 8, y: 30).red < 150, "the border inside the left edge")
            #expect(surface.pixel(x: 7, y: 30) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255), "nothing outside the box")
            var ink = 0
            for x in 12..<40 {
                for y in 12..<22 where surface.pixel(x: x, y: y).red < 150 {
                    ink += 1
                }
            }
            #expect(ink > 10, "the name from the top-left corner")
        }
    }

    @Test func thePreviewDrawsScaledIntoTheBoundingBox() throws {
        let store = ImageRenderingTests.store(["cafe": ImageRenderingTests.quadrants()])
        let list = Self.list([Self.placed(preview: "cafe")])
        #expect(list.bounds(ofImageAsset: "cafe") == [Self.bounds.applying(.translation(x: 8, y: 8))])
        let surface = try Self.render(list, store: store)
        // 16 px over 64 × 32 pt: the white top quarter is 8 pt tall, red left, blue right.
        #expect(surface.pixel(x: 20, y: 11) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255))
        #expect(surface.pixel(x: 20, y: 30) == RGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        #expect(surface.pixel(x: 60, y: 30) == RGBA8(red: 0, green: 0, blue: 255, alpha: 255))

        // PDF output draws the preview too (the PostScript is not written into a PDF).
        var renderer = CoreGraphicsRenderer(background: .white)
        renderer.imageStore = store
        let page = try #require(renderer.renderPDF(list, viewport: Self.viewport).flatMap { PDFRasterizer.rasterize($0, scale: 1) })
        for (x, y) in [(20, 30), (60, 30)] {
            #expect(page.pixel(x: x, y: y).maxChannelDifference(to: surface.pixel(x: x, y: y)) <= 2)
        }
    }

    @Test func hitTestingFindsTheBox() {
        for item in [Self.placed(preview: nil), Self.placed(preview: "cafe")] {
            let tester = HitTester(displayList: Self.list([item]), viewport: Self.viewport)
            #expect(!tester.hitTest(viewPoint: Point(x: 60, y: 30)).isEmpty)
            #expect(tester.hitTest(viewPoint: Point(x: 76, y: 44)).isEmpty)
        }
    }

    @Test(.enabled(if: MetalAvailability.isAvailable, "no Metal device"))
    func metalMatchesCoreGraphicsWithAndWithoutThePreview() throws {
        let store = ImageRenderingTests.store(["cafe": ImageRenderingTests.quadrants()])
        let list = DisplayList(canvas: "placed", items: [
            PlacedFileDrawing.item(PlacedFile(bounds: Rect(x: 0, y: 0, width: 32, height: 20), previewAssetID: "cafe", name: "shown.eps",
                                              transform: AffineTransform.rotation(radians: .pi / 18).concatenating(.translation(x: 4, y: 4)))),
            PlacedFileDrawing.item(PlacedFile(bounds: Rect(x: 0, y: 0, width: 40, height: 24), previewAssetID: "absent", name: "absent.eps", transform: .translation(x: 40, y: 30))),
            PlacedFileDrawing.item(PlacedFile(bounds: Rect(x: 0, y: 0, width: 30, height: 20), name: "none.eps", transform: .translation(x: 4, y: 40))),
        ])
        var warm = CoreGraphicsRenderer()
        warm.imageStore = store
        _ = warm.renderBitmap(list, viewport: Viewport(size: Size(width: 80, height: 80)))
        store.waitUntilIdle()
        for scale in [1.0, 2.0] {
            let failing = try ColorParityTests.compare(list, management: .standard, store: store, scale: scale)
            #expect(failing.isEmpty, "\(scale)x: \(failing)")
        }
    }
}
