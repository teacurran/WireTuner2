import WTGeometry
import CoreGraphics
import Foundation
import Testing
@testable import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// ATTR-014: Pattern strokes and fills at 0.25 pt pixels anchored to the page origin.
@Suite struct PatternPaintTests {
    func filled(_ rect: Rect, _ bitmap: PatternBitmap = .checker, color: Color = .black) -> DisplayItem {
        .path(PathItem(path: DisplayPath(rect: rect), appearance: Appearance([.fill(FillPaint(paint: .pattern(PatternPaint(bitmap: bitmap, color: color))))])))
    }

    @Test func bitmapsReadEightRowsMostSignificantBitLeft() {
        let bitmap = PatternBitmap(rows: [0x80, 0x01])
        #expect(bitmap.rows.count == 8)
        #expect(bitmap.isPainted(x: 0, y: 0) && !bitmap.isPainted(x: 1, y: 0))
        #expect(bitmap.isPainted(x: 7, y: 1))
        #expect(!bitmap.isPainted(x: 8, y: 0) && !bitmap.isPainted(x: 0, y: -1))
        #expect(PatternBitmap(rows: Array(repeating: 0xFF, count: 12)).rows.count == 8)
        #expect(PatternBitmap(rows: []).isEmpty && !PatternBitmap.solid.isEmpty)
    }

    @Test func adjacentPatternFilledRectanglesTileWithoutSeamsAtEveryZoom() {
        for scale in [1.0, 2, 3, 4, 8] {
            let split = renderSurface([filled(Rect(x: 8, y: 8, width: 32, height: 40)), filled(Rect(x: 40, y: 8, width: 32, height: 40))], scale: scale)
            let whole = renderSurface([filled(Rect(x: 8, y: 8, width: 64, height: 40))], scale: scale)
            #expect(samePixels(split, whole), "a seam at \(scale)×")
        }
    }

    @Test func thePatternIsAnchoredToThePageNotTheObject() {
        // Moving an object by a fraction of a cell does not move its pattern.
        let a = renderSurface([filled(Rect(x: 8, y: 8, width: 64, height: 40))], scale: 4)
        let b = renderSurface([.path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 64, height: 40)), appearance: Appearance([.fill(FillPaint(paint: .pattern(PatternPaint(bitmap: .diagonal, color: .black))))]), transform: .translation(x: 8.5, y: 8)))], scale: 4)
        let c = renderSurface([filled(Rect(x: 8.5, y: 8, width: 64, height: 40), .diagonal)], scale: 4)
        #expect(samePixels(b, c), "the object's transform does not carry the pattern")
        #expect(!samePixels(a, c))
        // One pattern pixel is one device pixel at 4×.
        let pixel = a.pixel(x: 40, y: 40)
        let neighbour = a.pixel(x: 41, y: 40)
        #expect(pixel != neighbour, "a checkerboard alternates every device pixel at 4×")
    }

    /// PDF output keeps patterns vector (a Core Graphics pattern); reopened, it agrees with the
    /// screen's per-pixel coverage within REND-007's tile tolerance (interior 2/255, edges
    /// 40/255, at most 0.1% of pixels off): interiors differ by rounding only (1/255).
    @Test func pdfExportAndScreenAgree() throws {
        let reference = try #require(ReferenceCorpus.cases.first { $0.name == "patterns" })
        let viewport = Viewport(size: reference.viewSize)
        let pdf = try #require(reference.renderer.renderPDF(reference.list, viewport: viewport))
        for scale in [1.0, 2] {
            let image = try #require(reference.renderer.renderBitmap(reference.list, viewport: viewport, scale: scale))
            let screen = try #require(BitmapSurface(drawing: image))
            let reopened = try #require(PDFRasterizer.rasterize(pdf, scale: scale))
            let parity = TileParity(reference: screen, candidate: reopened)
            #expect(parity.passes, "\(scale)×: \(parity)")
            #expect(parity.maxInteriorDifference <= 1)
        }
    }

    @Test func aPatternStrokeFillsTheStrokeOutline() {
        let line = DisplayPath(polygon: [Point(x: 10, y: 48), Point(x: 118, y: 48)], closed: false)
        let stroke = StrokePaint(paint: .pattern(PatternPaint(bitmap: .solid, color: red)), style: StrokeStyle(width: 10))
        let surface = renderSurface([.path(PathItem(path: line, appearance: Appearance([.stroke(stroke)])))])
        #expect(surface.pixel(x: 60, y: 48).green < 60, "inside the outline the solid pattern paints")
        #expect(surface.pixel(x: 60, y: 60) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255))
        #expect(renderSurface([filled(Rect(x: 0, y: 0, width: 50, height: 50), PatternBitmap(rows: []))]).pixel(x: 25, y: 25) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255), "an empty bitmap paints nothing")
    }
}

/// ATTR-018: the ten Custom fills and eight textures at a fixed page size, clipped to the path.
@Suite struct CustomFillTests {
    static let backdrop = DisplayItem.path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 128, height: 96)), appearance: Appearance([.fill(FillPaint(paint: .solid(Color(red: 1, green: 0, blue: 0))))])))

    func over(_ paint: Paint) -> BitmapSurface {
        renderSurface([Self.backdrop, .path(PathItem(path: DisplayPath(rect: Rect(x: 16, y: 16, width: 96, height: 64)), appearance: Appearance([.fill(FillPaint(paint: paint))])))], scale: 1)
    }

    /// How many interior pixels still show the pure red beneath.
    func redShowing(_ surface: BitmapSurface) -> Int {
        var count = 0
        for y in 24..<72 {
            for x in 24..<104 where surface.pixel(x: x, y: y) == RGBA8(red: 255, green: 0, blue: 0, alpha: 255) {
                count += 1
            }
        }
        return count
    }

    static let everyPattern: [CustomFill] = CustomFillPattern.allCases.map { pattern in
        CustomFill(pattern: pattern, color: blue, color2: .white, count: 200, seed: 3)
    }

    @Test func opaquePatternsFullyCoverAndTransparentOnesPaintOnlyTheirMarks() {
        for fill in Self.everyPattern {
            let surface = over(.custom(fill))
            if fill.pattern.isOpaque {
                #expect(redShowing(surface) == 0, "\(fill.pattern) hides what is beneath")
            } else {
                #expect(redShowing(surface) > 0, "\(fill.pattern) lets the backdrop through")
                #expect(redShowing(surface) < 48 * 80, "\(fill.pattern) paints marks")
            }
        }
        for texture in Texture.allCases {
            #expect(redShowing(over(.textured(TexturedFill(texture: texture, color: Color(red: 0.4, green: 0.5, blue: 0.3))))) == 0, "\(texture) is opaque")
        }
    }

    @Test func rendersAreStableAndSeedsChangeTheRandomMarks() {
        for fill in Self.everyPattern {
            #expect(samePixels(over(.custom(fill)), over(.custom(fill))), "\(fill.pattern) draws the same every time")
        }
        var reseeded = CustomFill(pattern: .randomGrass, count: 100, seed: 1)
        let first = over(.custom(reseeded))
        reseeded.seed = 2
        #expect(!samePixels(first, over(.custom(reseeded))))
    }

    @Test func noiseIsStableAcrossTilesAndPlacement() {
        // The same page region drawn as one view and as a tile agrees: noise hangs off page
        // coordinates, not off the object or the tile.
        let item = DisplayItem.path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 128, height: 96)), appearance: Appearance([.fill(FillPaint(paint: .custom(CustomFill(pattern: .noise, whiteness: 100))))])))
        let list = DisplayList(canvas: "noise", items: [item])
        let geometry = TileGeometry(zoomStep: ZoomStep(nearest: 1), rotationDegrees: 0)
        let key = geometry.tiles(coveringPasteboardRect: Rect(x: 10, y: 10, width: 1, height: 1), canvas: "noise")[0]
        let renderer = CoreGraphicsRenderer(background: .white)
        let tile = BitmapSurface(drawing: renderer.renderTile(list, key: key, geometry: geometry)!)!
        let view = renderSurface([item])
        let origin = geometry.pasteboardBounds(of: key)
        var compared = 0
        for y in 20..<60 {
            for x in 20..<60 {
                let tx = x - Int(origin.minX)
                let ty = y - Int(origin.minY)
                guard (1..<255).contains(tx), (1..<255).contains(ty) else { continue }
                #expect(tile.pixel(x: tx, y: ty) == view.pixel(x: x, y: y))
                compared += 1
            }
        }
        #expect(compared > 0)
    }

    @Test func defaultsFillInZeroLengths() {
        #expect(ProceduralFills.length(0, default: 5) == 5)
        #expect(ProceduralFills.length(.nan, default: 5) == 5)
        #expect(ProceduralFills.length(3, default: 5) == 3)
        // Zero lengths still draw each regular pattern.
        for pattern in [CustomFillPattern.bricks, .circles, .hatch, .squares] {
            #expect(redShowing(over(.custom(CustomFill(pattern: pattern, color: blue)))) < 48 * 80)
        }
    }

    @Test func noiseHelpersStayInRange() {
        for index in 0..<200 {
            let x = Double(index) * 0.37 - 20
            let y = Double(index) * 0.91 - 50
            #expect((0..<1).contains(NoiseHash.value(Int(x), Int(y))))
            #expect((0...1).contains(NoiseHash.smooth(x, y)))
            #expect((0...1.0001).contains(NoiseHash.fractal(x, y)))
            for texture in Texture.allCases {
                #expect((0...1).contains(ProceduralFills.shade(texture, at: Point(x: x, y: y))), "\(texture)")
            }
        }
        #expect(NoiseHash.value(3, 4) == NoiseHash.value(3, 4))
        #expect(NoiseHash.value(3, 4, salt: 1) != NoiseHash.value(3, 4, salt: 2))
    }

    @Test func rasterGridsCoverTheRegionAndCoarsenWhenHuge() throws {
        let grid = RasterPaint.grid(CGRect(x: 0.5, y: 1, width: 10, height: 4), resolution: 2)
        #expect(grid.x0 == -1 && grid.y0 == 0 && grid.width == 24 && grid.height == 12)
        // A clip larger than the cap coarsens the grid instead of allocating it.
        let surface = try #require(BitmapSurface(width: 32, height: 32))
        var samples = 0
        RasterPaint.fill(surface.context, space: .identity, rasterScale: 1, interpolation: .none, resolution: 4, maxEdge: 64) { _ in
            samples += 1
            return SIMD4(0, 0, 0, 1)
        }
        #expect(samples == 38 * 38, "halved twice to one sample per unit, padded by three")
        // A context whose clip is empty samples nothing.
        surface.context.clip(to: CGRect.zero)
        var none = 0
        RasterPaint.fill(surface.context, space: .identity, rasterScale: 1, interpolation: .none) { _ in
            none += 1
            return SIMD4(0, 0, 0, 1)
        }
        #expect(none == 0)
        let flat = try #require(BitmapSurface(width: 4, height: 4))
        flat.context.scaleBy(x: 0, y: 0)
        #expect(RasterPaint.resolution(for: flat.context, space: .identity, rasterScale: 1) == 1)
    }
}
