import WTGeometry
import CoreGraphics
import Foundation
import Testing
@testable import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// ATTR-019: backdrop capture, the six composites, centerpoint, objects only, snapshots, the
/// nesting cap and invalidation of a lens when what is beneath it changes.
@Suite(.serialized) struct LensFillTests {
    static let stripes: [DisplayItem] = [
        .path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 64, height: 96)), appearance: Appearance([.fill(FillPaint(paint: .solid(Color(red: 1, green: 0, blue: 0))))]))),
        .path(PathItem(path: DisplayPath(rect: Rect(x: 64, y: 0, width: 64, height: 96)), appearance: Appearance([.fill(FillPaint(paint: .solid(Color(red: 0, green: 0, blue: 1))))]))),
    ]

    func lens(_ fill: LensFill, rect: Rect = Rect(x: 16, y: 16, width: 96, height: 64)) -> DisplayItem {
        .path(PathItem(path: DisplayPath(rect: rect), appearance: Appearance([.fill(FillPaint(paint: .lens(fill)))])))
    }

    func pixel(_ items: [DisplayItem], _ x: Int, _ y: Int, scale: Double = 1) -> RGBA8 {
        renderSurface(items, scale: scale).pixel(x: x, y: y)
    }

    @Test func theSixCompositesOverAKnownBackdrop() {
        let white = RGBA8(red: 255, green: 255, blue: 255, alpha: 255)
        #expect(pixel(Self.stripes + [lens(LensFill(type: .invert))], 30, 40) == RGBA8(red: 0, green: 255, blue: 255, alpha: 255))
        #expect(pixel(Self.stripes + [lens(LensFill(type: .invert))], 100, 40) == RGBA8(red: 255, green: 255, blue: 0, alpha: 255))
        #expect(pixel(Self.stripes + [lens(LensFill(type: .lighten, amount: 100))], 30, 40) == white)
        #expect(pixel(Self.stripes + [lens(LensFill(type: .darken, amount: 100))], 30, 40) == RGBA8(red: 0, green: 0, blue: 0, alpha: 255))
        #expect(pixel(Self.stripes + [lens(LensFill(type: .darken, amount: 50))], 30, 40).red == 128)
        #expect(pixel(Self.stripes + [lens(LensFill(type: .transparency, color: Color(red: 0, green: 1, blue: 0), amount: 100))], 30, 40) == RGBA8(red: 0, green: 255, blue: 0, alpha: 255))
        let tinted = pixel(Self.stripes + [lens(LensFill(type: .transparency, color: Color(red: 0, green: 1, blue: 0), amount: 25))], 30, 40)
        #expect(tinted.red == 191 && tinted.green == 64)
        // Monochrome: red's luminance mapped onto a tint of blue.
        let mono = pixel(Self.stripes + [lens(LensFill(type: .monochrome, color: Color(red: 0, green: 0, blue: 1)))], 30, 40)
        #expect(mono.blue == 255 && mono.red == 54 && mono.green == 54)
        // Beyond the lens nothing changes.
        #expect(pixel(Self.stripes + [lens(LensFill(type: .invert))], 4, 4) == RGBA8(red: 255, green: 0, blue: 0, alpha: 255))
    }

    @Test func magnifyScalesAboutTheCenterpoint() {
        // The red/blue boundary at x = 64 moves away from a centerpoint left of it.
        let centred = renderSurface(Self.stripes + [lens(LensFill(type: .magnify, magnification: 2))])
        #expect(centred.pixel(x: 60, y: 40).red == 255 && centred.pixel(x: 68, y: 40).blue == 255, "about the middle the boundary stays put")
        let offset = renderSurface(Self.stripes + [lens(LensFill(type: .magnify, magnification: 2, centerpoint: Point(x: 48, y: 48)))])
        #expect(offset.pixel(x: 76, y: 40).red == 255, "48 + (76 - 48) / 2 = 62: red beneath")
        #expect(offset.pixel(x: 84, y: 40).blue == 255, "48 + (84 - 48) / 2 = 66: blue beneath")
    }

    @Test func objectsOnlyLeavesEmptyPageAlone() {
        let half = [Self.stripes[0]]
        let everything = renderSurface(half + [lens(LensFill(type: .invert))])
        let objects = renderSurface(half + [lens(LensFill(type: .invert, objectsOnly: true))])
        #expect(everything.pixel(x: 100, y: 40) == RGBA8(red: 0, green: 0, blue: 0, alpha: 255), "inverted paper")
        #expect(objects.pixel(x: 100, y: 40) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255), "paper stays white")
        #expect(objects.pixel(x: 30, y: 40) == RGBA8(red: 0, green: 255, blue: 255, alpha: 255))
    }

    @Test func aSnapshotShowsItsCapturedItemsWhateverIsBeneath() {
        let captured: [DisplayItem] = [.path(PathItem(path: DisplayPath(rect: Rect(x: 16, y: 16, width: 96, height: 64)), appearance: Appearance([.fill(FillPaint(paint: .solid(Color(red: 0, green: 1, blue: 0))))])))]
        let snapshot = lens(LensFill(type: .darken, amount: 0, snapshot: captured))
        let overStripes = renderSurface(Self.stripes + [snapshot])
        let overNothing = renderSurface([snapshot])
        #expect(overStripes.pixel(x: 30, y: 40) == RGBA8(red: 0, green: 255, blue: 0, alpha: 255))
        #expect(overNothing.pixel(x: 30, y: 40) == overStripes.pixel(x: 30, y: 40))
    }

    @Test func eightNestedLensesRenderAndANinthRendersAsBasic() {
        let before = LensRendering.depthCapCount
        let eight = Self.stripes + (0..<8).map { _ in lens(LensFill(type: .invert)) }
        let even = renderSurface(eight)
        #expect(even.pixel(x: 30, y: 40) == RGBA8(red: 255, green: 0, blue: 0, alpha: 255), "eight inversions cancel")
        #expect(LensRendering.depthCapCount == before)
        let nine = Self.stripes + (0..<9).map { _ in lens(LensFill(type: .invert, color: Color(red: 0, green: 0.5, blue: 0), amount: 100)) }
        _ = renderSurface(nine)
        #expect(LensRendering.depthCapCount > before, "the ninth level renders as Basic, with a log entry")
    }

    @Test func aLensInsideNestedContentRendersAsBasic() {
        let tinted = LensFill(type: .invert, color: Color(red: 0, green: 0, blue: 1), amount: 100)
        #expect(tinted.basicColor == Color(red: 0, green: 0, blue: 1))
        #expect(LensFill(type: .invert, color: .black, amount: 0).basicColor == .white)
        let tile = TiledFill(tile: [lens(tinted, rect: Rect(x: 0, y: 0, width: 8, height: 8))])
        let surface = renderSurface(Self.stripes + [.path(PathItem(path: DisplayPath(rect: Rect(x: 16, y: 16, width: 96, height: 64)), appearance: Appearance([.fill(FillPaint(paint: .tiled(tile)))])))])
        #expect(surface.pixel(x: 30, y: 40) == RGBA8(red: 0, green: 0, blue: 255, alpha: 255))
    }

    @Test func amountsClamp() {
        #expect(LensFill(type: .darken, amount: 250).fraction == 1)
        #expect(LensFill(type: .darken, amount: .nan).fraction == 0)
        #expect(LensFill(type: .magnify, magnification: 0).effectiveMagnification == 1)
        #expect(LensFill(type: .magnify, magnification: 50).effectiveMagnification == 20)
    }

    @Test func movingAnObjectUnderALensRepaintsTheWholeLens() {
        let magnify = lens(LensFill(type: .magnify, magnification: 3), rect: Rect(x: 100, y: 100, width: 200, height: 200))
        let small = DisplayItem.path(PathItem(path: DisplayPath(rect: Rect(x: 110, y: 110, width: 10, height: 10)), appearance: Appearance([.fill(FillPaint(paint: .solid(red)))])))
        let moved = DisplayItem.path(PathItem(path: DisplayPath(rect: Rect(x: 120, y: 110, width: 10, height: 10)), appearance: Appearance([.fill(FillPaint(paint: .solid(red)))])))
        let before = DisplayList(canvas: "c", items: [small, magnify], nodeIDs: [NodeID(counter: 1, replica: 1), NodeID(counter: 2, replica: 1)])
        let after = DisplayList(canvas: "c", items: [moved, magnify], nodeIDs: [NodeID(counter: 1, replica: 1), NodeID(counter: 2, replica: 1)])
        var summary = ChangeSummary(origin: .remote)
        summary.touch(NodeID(counter: 1, replica: 1), fields: [])
        let region = InvalidationMapper().dirtyRegion(for: summary, before: [before], after: [after])
        let rects = region.rects(for: "c")
        #expect(rects.contains { $0.contains(Rect(x: 100, y: 100, width: 200, height: 200)) }, "the lens's whole bounds, not just the object's")
        // The tiles of the lens all repaint on the next frame.
        let geometry = TileGeometry(zoomStep: ZoomStep(nearest: 1), rotationDegrees: 0)
        #expect(region.tiles(for: "c", geometry: geometry) == Set(geometry.tiles(coveringPasteboardRect: after.itemBounds[1]!, canvas: "c")))
        // An unrelated change far away leaves the lens alone.
        var elsewhere = ChangeSummary(origin: .remote)
        elsewhere.touch(NodeID(counter: 3, replica: 1), fields: [])
        let far = DisplayItem.path(PathItem(path: DisplayPath(rect: Rect(x: 900, y: 900, width: 10, height: 10)), appearance: Appearance([.fill(FillPaint(paint: .solid(red)))])))
        let withFar = DisplayList(canvas: "c", items: [small, magnify, far], nodeIDs: [NodeID(counter: 1, replica: 1), NodeID(counter: 2, replica: 1), NodeID(counter: 3, replica: 1)])
        #expect(InvalidationMapper().dirtyRegion(for: elsewhere, before: [withFar], after: [withFar]).rects(for: "c") == [far.bounds!])
    }

    @Test func lensesPaintThroughTheMetalLoweringAsTextures() {
        let builder = PaintListBuilder(viewMode: .preview, overprintPreview: false, tolerance: .standard, surface: Rect(x: 0, y: 0, width: 128, height: 96))
        let list = DisplayList(canvas: "x", items: Self.stripes + [lens(LensFill(type: .invert))])
        let operations = builder.operations(for: list, pasteboardTransform: .identity, cull: Rect(x: -10, y: -10, width: 300, height: 300))
        guard case .texture(let texture) = operations.last else {
            Issue.record("the lens is a texture")
            return
        }
        #expect(texture.origin == SIMD2(16, 16) && texture.image.width == 96 && texture.image.height == 64)
        #expect(Array(texture.image.bytes[0..<4]) == [0, 255, 255, 255], "inverted red")
    }
}

/// ATTR-021: tiled fills from an embedded subtree display list.
@Suite struct TiledFillTests {
    static let cell: [DisplayItem] = [
        .path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 8, height: 8)), appearance: Appearance([.fill(FillPaint(paint: .solid(Color(red: 1, green: 1, blue: 0))))]))),
        .path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 4, height: 4)), appearance: Appearance([.fill(FillPaint(paint: .solid(Color(red: 0, green: 0, blue: 1))))]))),
    ]

    func tiled(_ fill: TiledFill, rect: Rect = Rect(x: 8, y: 8, width: 96, height: 64), transform: AffineTransform = .identity) -> DisplayItem {
        .path(PathItem(path: DisplayPath(rect: rect), appearance: Appearance([.fill(FillPaint(paint: .tiled(fill)))]), transform: transform))
    }

    @Test func tileBoundsAndScaleNormalizations() {
        #expect(TiledFill(tile: Self.cell).tileBounds == Rect(x: 0, y: 0, width: 8, height: 8))
        #expect(TiledFill(tile: [.fill(FillItem(path: DisplayPath(polygon: [.zero, Point(x: 5, y: 0)], closed: false), paint: .solid(red)))]).tileBounds == nil, "no area, no tile")
        #expect(TiledFill(tile: [], scaleX: 0, scaleY: -5).effectiveScale == (1, 1))
        #expect(TiledFill(tile: [], scaleX: 50, scaleY: 200).effectiveScale == (0.5, 2))
    }

    @Test func theTileRepeatsSeamFreeInObjectSpace() {
        for scale in [1.0, 2, 4] {
            let surface = renderSurface([tiled(TiledFill(tile: Self.cell))], scale: scale)
            let step = Int(8 * scale)
            // Every cell's blue quarter lands at the same place: (8 + 8k, 8 + 8k).
            for k in 1...4 {
                let x = Int((8 + 8 * Double(k) + 1) * scale)
                let y = Int((8 + 8 + 1) * scale)
                #expect(surface.pixel(x: x, y: y) == RGBA8(red: 0, green: 0, blue: 255, alpha: 255), "\(scale)× cell \(k)")
                #expect(surface.pixel(x: x + step / 2 + 1, y: y) == RGBA8(red: 255, green: 255, blue: 0, alpha: 255), "\(scale)× seam-free yellow")
            }
        }
    }

    @Test func offsetAngleAndScalePlaceThePattern() {
        let plain = renderSurface([tiled(TiledFill(tile: Self.cell))], scale: 2)
        let shifted = renderSurface([tiled(TiledFill(tile: Self.cell, offset: Point(x: 8, y: 0)))], scale: 2)
        #expect(samePixels(plain, shifted), "an offset of one cell looks the same")
        let half = renderSurface([tiled(TiledFill(tile: Self.cell, offset: Point(x: 4, y: 0)))], scale: 2)
        #expect(!samePixels(plain, half))
        #expect(!samePixels(plain, renderSurface([tiled(TiledFill(tile: Self.cell, angle: 45))], scale: 2)))
        #expect(!samePixels(plain, renderSurface([tiled(TiledFill(tile: Self.cell, scaleX: 50, scaleY: 50))], scale: 2)))
    }

    @Test func fillsOffKeepsThePatternOnThePage() {
        // The Transform panel's Fills-off move shifts the object and writes the opposite offset:
        // the pattern stays where it was on the page.
        let original = renderSurface([tiled(TiledFill(tile: Self.cell))], scale: 2)
        let movedWithFills = renderSurface([tiled(TiledFill(tile: Self.cell), transform: .translation(x: 3, y: 0))], scale: 2)
        let movedWithoutFills = renderSurface([tiled(TiledFill(tile: Self.cell, offset: Point(x: -3, y: 0)), transform: .translation(x: 3, y: 0))], scale: 2)
        // Compare an interior column both objects cover.
        var same = true
        var travelled = false
        for y in 40..<120 {
            same = same && original.pixel(x: 100, y: y) == movedWithoutFills.pixel(x: 100, y: y)
            travelled = travelled || original.pixel(x: 100, y: y) != movedWithFills.pixel(x: 100, y: y)
        }
        #expect(same, "Fills off: the pattern stays put")
        #expect(travelled, "Fills on: the pattern travels with the object")
    }

    @Test func aThousandNodeTileFillsAPage() {
        var tile: [DisplayItem] = []
        for index in 0..<1000 {
            let x = Double(index % 40) * 2
            let y = Double(index / 40) * 2
            tile.append(.path(PathItem(path: DisplayPath(ellipseIn: Rect(x: x, y: y, width: 1.5, height: 1.5)), appearance: Appearance([.fill(FillPaint(paint: .solid(Color(red: Double(index % 7) / 7, green: 0.4, blue: 0.6))))]))))
        }
        let page = tiled(TiledFill(tile: tile), rect: Rect(x: 0, y: 0, width: 612, height: 792))
        let renderer = CoreGraphicsRenderer(background: .white)
        let list = DisplayList(canvas: "x", items: [page])
        _ = renderer.renderBitmap(list, viewport: Viewport(size: Size(width: 612, height: 792)))
        let started = DispatchTime.now().uptimeNanoseconds
        let image = renderer.renderBitmap(list, viewport: Viewport(size: Size(width: 612, height: 792)))
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        #expect(image != nil)
        print("PERF tiled fill: a 1,000-node tile over a 612 × 792 pt page in \(String(format: "%.1f", milliseconds)) ms (budget 16 ms on M1, held in the perf run)")
        PerfBudget.expect(.milliseconds(milliseconds), within: .milliseconds(16))
    }
}
