import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// DOC-009: page furniture -- structure, hairlines and device-pixel dots at every zoom, and the
/// screen and print renders agreeing on the page background.
@Suite struct PageRenderingTests {
    static let page = PageFrame(rect: Rect(x: 20, y: 20, width: 60, height: 40), bleed: 6, isActive: false, presence: [.black, .white])
    static let renderer = CoreGraphicsRenderer(background: Color(red: 1, green: 0, blue: 1))

    static func render(_ items: [DisplayItem], zoom: Double, scroll: Point = .zero, size: Size = Size(width: 200, height: 160)) throws -> BitmapSurface {
        let viewport = Viewport(scrollOrigin: scroll, zoom: zoom, size: size)
        let image = try #require(CoreGraphicsRenderer(background: .white).renderBitmap(DisplayList(canvas: "pages", items: items), viewport: viewport))
        return try #require(BitmapSurface(drawing: image))
    }

    static func isDark(_ pixel: RGBA8) -> Bool {
        Int(pixel.red) + Int(pixel.green) + Int(pixel.blue) < 3 * 200
    }

    @Test func itemsForScreenAndPrint() {
        let style = PageStyle()
        let active = PageFrame(rect: Rect(x: 100, y: 0, width: 10, height: 10), isActive: true)
        let empty = PageFrame(rect: Rect(x: 0, y: 0, width: 0, height: 10), bleed: 3)
        let background = PageRendering.backgroundItems([Self.page, active, empty], style: style)
        // Pasteboard, then one white fill per page with an area.
        #expect(background.count == 3)
        guard case .fill(let pasteboard) = background[0], case .fill(let sheet) = background[1] else {
            Issue.record("expected fills")
            return
        }
        #expect(pasteboard.paint == .solid(style.pasteboardColor) && pasteboard.path.controlBounds == PageStyle.standardPasteboard)
        #expect(sheet.paint == .solid(.white) && sheet.path.controlBounds == Self.page.rect)
        let frame = PageRendering.frameItems([active, Self.page, empty], style: style)
        // Bleed line, then the inactive outline and its two dots, then the active outline last.
        #expect(frame.count == 5)
        guard case .stroke(let bleed) = frame[0], case .stroke(let outline) = frame[1], case .stroke(let emphasized) = frame[4] else {
            Issue.record("expected strokes")
            return
        }
        #expect(bleed.path.controlBounds == Self.page.bleedRect && bleed.style.isHairline && bleed.style.dashInDevicePixels)
        #expect(bleed.style.dash == style.bleedDash)
        #expect(outline.paint == .solid(style.outlineColor) && outline.style.isHairline)
        #expect(emphasized.paint == .solid(style.activeOutlineColor) && emphasized.path.controlBounds == active.rect)
        // Print: the page backgrounds alone.
        let print = PageRendering.item([Self.page, active], style: style, output: .print, grid: [.fill(FillItem(path: DisplayPath(rect: .zero), paint: .none))])
        guard case .group(let group) = print else {
            Issue.record("expected a group")
            return
        }
        #expect(group.children.count == 2)
        #expect(PageRendering.frameItems([Self.page], output: .print).isEmpty)
        #expect(PageRendering.backgroundItems([Self.page], style: PageStyle(pasteboard: nil)).count == 1)
        // A bad pixel size reads as one; the dots scale with it.
        #expect(PageStyle(pixelSize: 0).pixelSize == 1 && PageStyle(pixelSize: .nan).pixelSize == 1)
        let dots = PageRendering.presenceDots(Self.page, style: PageStyle(presenceDotDiameter: 4, pixelSize: 0.5))
        #expect(dots.count == 2 && dots[0].bounds?.width == 2)
        #expect(PageRendering.presenceDots(Self.page, style: PageStyle(presenceDotDiameter: 0)).isEmpty)
        #expect(Self.page.bleedRect == Rect(x: 14, y: 14, width: 72, height: 52))
        #expect(PageFrame(rect: Self.page.rect, bleed: -3).bleedRect == Self.page.rect)
    }

    /// The outline is one device pixel wide at every zoom, and the bleed line's dots repeat every
    /// four device pixels at every zoom.
    @Test(arguments: [1.0, 2.0, 8.0])
    func hairlinesAndDotsAreDevicePixels(zoom: Double) throws {
        let style = PageStyle(pasteboard: nil, outlineColor: .black, bleedColor: .black, bleedDash: [2, 2])
        let page = PageFrame(rect: Rect(x: 10, y: 10, width: 300, height: 300), bleed: 2)
        let surface = try Self.render(PageRendering.item([page], style: style).asArray, zoom: zoom, scroll: Point(x: 0, y: 0))
        let viewport = Viewport(zoom: zoom, size: Size(width: 200, height: 160))
        // Across the page's left edge, one dark column.
        let edge = viewport.toView(Point(x: 10, y: 10))
        let row = Int(edge.y) + 30
        let x0 = Int(edge.x.rounded())
        let dark = ((x0 - 1)...(x0 + 1)).filter { Self.isDark(surface.pixel(x: $0, y: row)) }.count
        #expect((1...2).contains(dark), "zoom \(zoom): \(dark) dark columns")
        #expect(!Self.isDark(surface.pixel(x: x0 + 3, y: row)))
        // Along the bleed line's top edge (y = 8 pt), the dash period is four device pixels.
        let bleedRow = Int(viewport.toView(Point(x: 0, y: 8)).y)
        let start = Int(viewport.toView(Point(x: 12, y: 0)).x)
        let samples = (start..<start + 40).map { Self.isDark(surface.pixel(x: $0, y: bleedRow)) || Self.isDark(surface.pixel(x: $0, y: bleedRow - 1)) }
        let onRuns = zip(samples, samples.dropFirst()).filter { !$0.0 && $0.1 }.count
        #expect((9...11).contains(onRuns), "zoom \(zoom): \(onRuns) dashes in 40 px")
    }

    /// The page background prints white and the outline does not print: the screen render's
    /// page interior equals the print render's, and the print render has no outline.
    @Test func screenAndPrintRendersOfThePageAgree() throws {
        let style = PageStyle(pasteboard: Rect(x: 0, y: 0, width: 200, height: 160), outlineColor: .black)
        let viewport = Viewport(size: Size(width: 100, height: 80))
        let screen = DisplayList(canvas: "s", items: [PageRendering.item([Self.page], style: style)])
        let print = DisplayList(canvas: "p", items: [PageRendering.item([Self.page], style: style, output: .print)])
        let image = try #require(Self.renderer.renderBitmap(screen, viewport: viewport))
        let bitmap = try #require(BitmapSurface(drawing: image))
        let pdf = try #require(Self.renderer.renderPDF(print, viewport: viewport))
        let printed = try #require(PDFRasterizer.rasterize(pdf, scale: 1))
        for (x, y) in [(30, 30), (50, 40), (75, 55)] {
            #expect(bitmap.pixel(x: x, y: y) == printed.pixel(x: x, y: y))
            #expect(bitmap.pixel(x: x, y: y).red == 255 && bitmap.pixel(x: x, y: y).green == 255)
        }
        // The outline shows on screen only.
        #expect(Self.isDark(bitmap.pixel(x: 20, y: 40)) && !Self.isDark(printed.pixel(x: 20, y: 40)))
        // The pasteboard shows on screen only.
        #expect(bitmap.pixel(x: 5, y: 5) != printed.pixel(x: 5, y: 5))
    }

    @Test func dashInDevicePixelsIsIgnoredOnWideStrokes() {
        let path = DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 100, y: 0)], closed: false)
        let wide = StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 2, dash: [4, 4], dashInDevicePixels: true))
        let plain = StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 2, dash: [4, 4]))
        #expect(StrokeExpansion.basicRegions(for: wide, path: path, hairlineWidth: 0.25, tolerance: 0.01)
            == StrokeExpansion.basicRegions(for: plain, path: path, hairlineWidth: 0.25, tolerance: 0.01))
        let hairline = StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 0, dash: [4, 4], dashPhase: 1, dashInDevicePixels: true))
        let scaled = StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 0, dash: [1, 1], dashPhase: 0.25))
        #expect(StrokeExpansion.basicRegions(for: hairline, path: path, hairlineWidth: 0.25, tolerance: 0.01)
            == StrokeExpansion.basicRegions(for: scaled, path: path, hairlineWidth: 0.25, tolerance: 0.01))
    }
}

extension DisplayItem {
    var asArray: [DisplayItem] { [self] }
}
