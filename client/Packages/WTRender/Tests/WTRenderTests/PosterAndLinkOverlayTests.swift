import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// A placed SVG animation's poster glyph (WEB-026), measured bounds through `LayerScene` and
/// `DisplayList`, and the Show Links overlay (WEB-004).
@Suite struct PosterAndLinkOverlayTests {
    static let poster = ImageItem(assetID: "p", rect: Rect(x: 0, y: 0, width: 20, height: 20), showsPlayGlyph: true)
    static let viewport = Viewport(size: Size(width: 32, height: 32))

    @Test func thePlayGlyphDrawsOverThePosterOnTheCanvas() throws {
        var large = Self.poster
        large.rect = Rect(x: 0, y: 0, width: 30, height: 30)
        var plain = large
        plain.showsPlayGlyph = false
        func render(_ item: ImageItem) throws -> BitmapSurface {
            try #require(CoreGraphicsRenderer(background: .white).renderBitmap(DisplayList(canvas: "c", items: [.image(item)]), viewport: Self.viewport, scale: 4)
                .flatMap(BitmapSurface.init(drawing:)))
        }
        let marked = try render(large), bare = try render(plain)
        // The disc (radius 3 about (15, 15)) darkens the placeholder; the triangle inside it is white.
        #expect(marked.pixel(x: 52, y: 60).red < bare.pixel(x: 52, y: 60).red)
        #expect(marked.pixel(x: 61, y: 60).red > 240)
        #expect(marked.pixel(x: 20, y: 8) == bare.pixel(x: 20, y: 8))
        #expect(ImageDrawing.playGlyph(large).disc.controlBounds == Rect(x: 12, y: 12, width: 6, height: 6))
        // In box modes the glyph is left out with the pixels.
        let keyline = CoreGraphicsRenderer(background: .white).with(viewMode: .keyline)
        #expect(keyline.renderBitmap(DisplayList(canvas: "c", items: [.image(large)]), viewport: Self.viewport) != nil)
    }

    @Test func metalLowersTheGlyphWithThePlaceholder() {
        var plain = Self.poster
        plain.showsPlayGlyph = false
        let builder = PaintListBuilder(viewMode: .preview, overprintPreview: false, tolerance: .standard, surface: Rect(x: 0, y: 0, width: 32, height: 32),
                                       swapsFillRules: false)
        func count(_ item: ImageItem) -> Int {
            builder.operations(for: DisplayList(canvas: "c", items: [.image(item)]), pasteboardTransform: .identity,
                               cull: Rect(x: -100, y: -100, width: 300, height: 300)).count
        }
        #expect(count(Self.poster) == count(plain) + 2)
    }

    @Test func outputListsDropTheGlyphAndReuseMeasuredBounds() {
        let group = DisplayItem.group(GroupItem(children: [.image(Self.poster), .fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), paint: .solid(.black)))]))
        let plainGroup = DisplayItem.group(GroupItem(children: [.fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), paint: .solid(.black)))]))
        let measured: [Rect?] = [Rect(x: 0, y: 0, width: 20, height: 20), Rect(x: 0, y: 0, width: 20, height: 20), Rect(x: 0, y: 0, width: 1, height: 1)]
        let layer = LayerContent(layer: LayerRendering(id: NodeID(counter: 1, replica: 1)), items: [(.image(Self.poster), nil), (group, nil), (plainGroup, nil)],
                                 bounds: measured)
        let output = LayerScene.build(canvas: "c", layers: [layer], purpose: .output(includeHidden: false))
        guard case .image(let image) = output.items[0], case .group(let inner) = output.items[1], case .image(let nested) = inner.children[0] else {
            Issue.record("items")
            return
        }
        #expect(!image.showsPlayGlyph && !nested.showsPlayGlyph && output.items[2] == plainGroup)
        #expect(output.itemBounds == measured)
        let screen = LayerScene.build(canvas: "c", layers: [layer], purpose: .screen(guideColor: .black))
        #expect(screen.items[0] == .image(Self.poster))
        // Bounds of the wrong length are measured again.
        var short = layer
        short.bounds = [nil]
        #expect(LayerScene.build(canvas: "c", layers: [short], purpose: .screen(guideColor: .black)).itemBounds == layer.items.map(\.item.bounds))
        #expect(DisplayItem.text(TextRunItem(text: "t", origin: .zero, bounds: .zero)).withoutCanvasMarks == nil)
    }

    @Test func aListOverMeasuredBoundsKeepsThemUnlessTheyDoNotFit() {
        let items: [DisplayItem] = [.image(Self.poster)]
        let given = DisplayList(canvas: "c", items: items, itemBounds: [Rect(x: 1, y: 1, width: 1, height: 1)], nodeIDs: [NodeID(counter: 2, replica: 1)])
        #expect(given.itemBounds == [Rect(x: 1, y: 1, width: 1, height: 1)] && given.bounds == Rect(x: 1, y: 1, width: 1, height: 1))
        let measured = DisplayList(canvas: "c", items: items, itemBounds: [])
        #expect(measured.itemBounds == [Rect(x: 0, y: 0, width: 20, height: 20)])
    }

    // MARK: Show Links

    static let a = NodeID(counter: 1, replica: 1)
    static let b = NodeID(counter: 2, replica: 1)
    static let overlay = LinkOverlay(marks: [
        LinkMark(url: "https://a", node: a, shape: .object(Rect(x: 0, y: 0, width: 20, height: 20))),
        LinkMark(url: "https://b", node: b, shape: .object(Rect(x: 10, y: 10, width: 20, height: 20))),
        LinkMark(url: "https://line", node: a, shape: .textLine(Rect(x: 0, y: 0, width: 5, height: 4))),
    ])

    @Test func hoveringNamesTheTopmostLinkWithTextLinesFirst() {
        #expect(Self.overlay.url(at: Point(x: 2, y: 2)) == "https://line")
        #expect(Self.overlay.url(at: Point(x: 15, y: 15)) == "https://b")
        #expect(Self.overlay.url(at: Point(x: 5, y: 15)) == "https://a")
        #expect(Self.overlay.url(at: Point(x: 31, y: 31)) == nil)
        #expect(Self.overlay.url(at: Point(x: 31, y: 31), tolerance: 2) == "https://b")
        #expect(LinkOverlay().isEmpty && !Self.overlay.isEmpty)
        #expect(Self.overlay.marks[2].rect == Rect(x: 0, y: 0, width: 5, height: 4))
    }

    @Test func aChangedLinkRepaintsOnlyItsObject() {
        #expect(Self.overlay.bounds[Self.a] == Rect(x: 0, y: 0, width: 20, height: 20))
        var changed = Self.overlay
        changed.marks[1].url = "https://c"
        #expect(LinkOverlay.dirtyRects(from: Self.overlay, to: changed) == [Rect(x: 10, y: 10, width: 20, height: 20), Rect(x: 10, y: 10, width: 20, height: 20)])
        #expect(LinkOverlay.dirtyRects(from: Self.overlay, to: Self.overlay).isEmpty)
        let removed = LinkOverlay(marks: Array(Self.overlay.marks.prefix(1)))
        #expect(LinkOverlay.dirtyRects(from: Self.overlay, to: removed) == [Rect(x: 0, y: 0, width: 20, height: 20), Rect(x: 0, y: 0, width: 20, height: 20),
                                                                         Rect(x: 10, y: 10, width: 20, height: 20)])
    }

    @Test func theOverlayTintsObjectsAndUnderlinesLines() throws {
        let surface = try #require(BitmapSurface(width: 32, height: 32, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        surface.context.setFillColor(.white)
        surface.context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        // View space y down, as the canvas overlays draw.
        surface.context.translateBy(x: 0, y: 32)
        surface.context.scaleBy(x: 1, y: -1)
        let overlay = LinkOverlay(marks: [
            LinkMark(url: "o", node: Self.a, shape: .object(Rect(x: 0, y: 0, width: 10, height: 10))),
            LinkMark(url: "t", node: Self.b, shape: .textLine(Rect(x: 20, y: 0, width: 10, height: 10))),
        ])
        overlay.draw(in: surface.context, viewport: Self.viewport)
        #expect(surface.pixel(x: 5, y: 5).red < 255 && surface.pixel(x: 5, y: 5).blue == 255)
        #expect(surface.pixel(x: 25, y: 9).blue > 200 && surface.pixel(x: 25, y: 9).red < 100, "the underline along the line's bottom")
        #expect(surface.pixel(x: 25, y: 3) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255))
        #expect(overlay.viewRect(Rect(x: 0, y: 0, width: 10, height: 10), viewport: Self.viewport) == CGRect(x: 0, y: 0, width: 10, height: 10))
    }
}
