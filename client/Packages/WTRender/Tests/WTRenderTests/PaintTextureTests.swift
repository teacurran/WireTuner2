import WTGeometry
import CoreGraphics
import Testing
@testable import WTRender
import struct WTRender.StrokeStyle

/// The Metal renderer's per-item fallback: paints other than a solid colour are rasterized by
/// Core Graphics into a texture aligned with the surface's pixels and composited through
/// Metal's own coverage of the region.
@Suite struct PaintTextureTests {
    static let gradient = Paint.gradient(Gradient(.linear, from: Color(red: 1, green: 0, blue: 0), to: Color(red: 0, green: 0, blue: 1)))

    func lower(_ items: [DisplayItem], mode: ViewMode = .preview, overprint: Bool = false, swaps: Bool = false, transform: AffineTransform = .identity) -> [PaintOperation] {
        let builder = PaintListBuilder(viewMode: mode, overprintPreview: overprint, tolerance: .standard, surface: Rect(x: 0, y: 0, width: 128, height: 96), swapsFillRules: swaps)
        return builder.operations(for: DisplayList(canvas: "t", items: items), pasteboardTransform: transform, cull: Rect(x: -500, y: -500, width: 2000, height: 2000))
    }

    func textures(_ operations: [PaintOperation]) -> [PaintTexture] {
        operations.flatMap { operation -> [PaintTexture] in
            switch operation {
            case .texture(let texture): return [texture]
            case .group(let group): return textures(group.operations)
            case .fill: return []
            }
        }
    }

    func path(_ paint: Paint, rule: FillRule = .nonZero, overprint: Bool = false, rect: Rect = Rect(x: 10.5, y: 20.25, width: 50, height: 30)) -> DisplayItem {
        .path(PathItem(path: DisplayPath(rect: rect), appearance: Appearance([.fill(FillPaint(paint: paint, rule: rule, overprint: overprint))])))
    }

    @Test func aTextureCoversTheRegionsPixelsOnTheSurface() throws {
        let texture = try #require(textures(lower([path(Self.gradient)])).first)
        #expect(texture.origin == SIMD2(10, 20))
        #expect(texture.image.width == 51 && texture.image.height == 31)
        #expect(texture.image.bytes.count == 51 * 31 * 4)
        #expect(texture.alpha == 1 && texture.blend == .normal && texture.rule == .nonZero)
        // The left column is red, the right blue: the gradient drawn at the surface's pixels.
        #expect(texture.image.bytes[4 * (10 * 51 + 1)] > 200)
        #expect(texture.image.bytes[4 * (10 * 51 + 49) + 2] > 200)
    }

    @Test func offSurfaceAndNonePaintsLowerToNothing() {
        #expect(textures(lower([path(Self.gradient, rect: Rect(x: 500, y: 500, width: 10, height: 10))])).isEmpty)
        #expect(lower([path(.gradient(Gradient(stops: [])))]).isEmpty)
    }

    @Test func fastModeAlphaAndOverprintCarryToTheTexture() throws {
        let group = DisplayItem.group(GroupItem(children: [path(Self.gradient, overprint: true)], opacity: 0.5))
        let fast = try #require(textures(lower([group], mode: .fastPreview, overprint: true)).first)
        #expect(fast.alpha == 0.5 && fast.blend == .multiply)
        let layered = try #require(textures(lower([group], overprint: false)).first)
        #expect(layered.alpha == 1 && layered.blend == .normal, "inside a transparency layer the texture is opaque")
        #expect(lower([path(Self.gradient)], mode: .keyline).allSatisfy { if case .fill = $0 { return true } else { return false } }, "Keyline draws no paints")
    }

    @Test func swappingRulesSwapsTheTexturesDeclaredRule() throws {
        let swapped = try #require(textures(lower([path(Self.gradient, rule: .evenOdd)], swaps: true)).first)
        #expect(swapped.rule == .nonZero)
        let stroked = DisplayItem.path(PathItem(path: DisplayPath(rect: Rect(x: 10, y: 10, width: 50, height: 50)), appearance: Appearance([.stroke(StrokePaint(paint: Self.gradient, style: StrokeStyle(width: 6)))])))
        let outline = try #require(textures(lower([stroked], swaps: true)).first)
        #expect(outline.rule == .nonZero, "a stroke outline's rule is not a declared fill rule")
    }

    @Test func plannedTexturesIndexTheirImages() {
        let operations = lower([path(Self.gradient), path(.custom(CustomFill(pattern: .hatch)), rect: Rect(x: 60, y: 10, width: 40, height: 40))])
        var geometry = PaintGeometry()
        let plan = geometry.plan(operations, width: 128, height: 96)
        #expect(geometry.images.count == 2)
        let indices = plan.compactMap { operation -> Int? in
            if case .texture(let texture) = operation { return texture.texture }
            return nil
        }
        #expect(indices == [0, 1])
    }

    @Test(.enabled(if: MetalAvailability.isAvailable, "no Metal device"))
    func metalCompositesTheTextureThroughItsCoverage() throws {
        let context = try #require(MetalAvailability.context)
        let list = DisplayList(canvas: "t", items: [path(Self.gradient, rect: Rect(x: 8, y: 8, width: 112, height: 80))])
        let metal = MetalRenderer(context: context, background: .white)
        let cg = CoreGraphicsRenderer(background: .white)
        let geometry = TileGeometry(zoomStep: ZoomStep(nearest: 1), rotationDegrees: 0)
        let key = geometry.tiles(coveringPasteboardRect: Rect(x: 20, y: 20, width: 1, height: 1), canvas: "t")[0]
        let a = try #require(metal.renderTile(list, key: key, geometry: geometry).flatMap(BitmapSurface.init(drawing:)))
        let b = try #require(cg.renderTile(list, key: key, geometry: geometry).flatMap(BitmapSurface.init(drawing:)))
        #expect(TileParity(reference: b, candidate: a).passes)
        #expect(a.pixel(x: 60, y: 40) == b.pixel(x: 60, y: 40), "interior pixels are the texture's")
    }
}

@Suite struct CoreGraphicsBridgeExtraTests {
    @Test func rectanglesFromCoreGraphicsKeepNullAndBoundInfinity() {
        #expect(Rect(CGRect.null).isNull)
        #expect(Rect(CGRect.infinite).width == 2e12)
        #expect(Rect(CGRect(x: 1, y: 2, width: 3, height: 4)) == Rect(x: 1, y: 2, width: 3, height: 4))
        #expect(CGAffineTransform(scaleX: 0, y: 0).invertedIfPossible == nil)
        #expect(CGAffineTransform(scaleX: 2, y: 2).invertedIfPossible == CGAffineTransform(scaleX: 0.5, y: 0.5))
    }

    @Test func renderCachesStartOverWhenFull() {
        let cache = RenderCache<Int, Int>(capacity: 2)
        var computed = 0
        for key in [1, 2, 3, 1] {
            _ = cache.value(for: key) { computed += 1; return key }
        }
        #expect(computed == 4, "the third key cleared the cache, so the first recomputed")
        #expect(cache.value(for: 1) { -1 } == 1)
    }
}
