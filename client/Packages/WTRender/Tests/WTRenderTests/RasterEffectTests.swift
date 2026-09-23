import WTGeometry
import CoreGraphics
import Foundation
import Testing
@testable import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// FX-009, FX-010, FX-011 and FX-015: the raster stage, its filters, cache and preview modes,
/// and transparency.
@Suite struct RasterEffectTests {
    typealias C = ReferenceCorpus
    static let white = RGBA8(red: 255, green: 255, blue: 255, alpha: 255)

    static func item(_ path: DisplayPath, _ stack: [AppearanceItem], _ effects: [EffectElement], raster: RasterSettings = RasterSettings()) -> DisplayItem {
        .path(PathItem(path: path, appearance: Appearance(stack, effects: effects, raster: raster)))
    }

    static func render(_ items: [DisplayItem], size: Size = Size(width: 80, height: 80), scale: Double = 1, renderer: CoreGraphicsRenderer = CoreGraphicsRenderer(background: .white)) -> BitmapSurface {
        BitmapSurface(drawing: renderer.renderBitmap(DisplayList(canvas: "raster", items: items), viewport: Viewport(size: size), scale: scale)!)!
    }

    static func brightness(_ pixel: RGBA8) -> Int { Int(pixel.red) + Int(pixel.green) + Int(pixel.blue) }

    static let square = DisplayPath(rect: Rect(x: 20, y: 20, width: 40, height: 40))

    // MARK: Spread and identities

    @Test func spreadIsThreeSigmaForGaussianBlurs() {
        let node = RasterNode(operations: [.blur(.init(style: .gaussian, radius: 4))], content: [], settings: RasterSettings())
        #expect(RasterEffectStage.spread(of: node) == 3 * 4 + 1)
        // Pixel radii are pixels at the object's resolution: at 144 ppi half as many points.
        let fine = RasterNode(operations: [.blur(.init(style: .gaussian, radius: 4))], content: [], settings: RasterSettings(resolution: 144))
        #expect(RasterEffectStage.spread(of: fine) == 3 * 2 + 1)
        let box = RasterNode(operations: [.blur(.init(style: .basic, radius: 4)), .sharpen(.init(style: .basic, amount: 10)), .sharpen(.init(style: .unsharpMask, amount: 10, pixelRadius: 2)), .shadow(.init(style: .innerShadow, offset: 9, opacity: 50)), .shadow(.init(style: .glow, offset: 2, opacity: 50, softness: 3)), .bevelEmboss(.init(style: .outerBevel, width: 5)), .bevelEmboss(.init(style: .innerBevel, width: 5, softness: 4)), .feather(radius: 5, softness: 5)], content: [], settings: RasterSettings())
        let expected: Double = 26  // 4 + 2 + 6 + 0 + 5 + 5 + 3 + 0, plus the 1 pt margin
        #expect(approx(RasterEffectStage.spread(of: box), expected, tolerance: 1e-9))
    }

    @Test func zeroSettingsAreIdentity() {
        let context = RasterCore.managed
        let pixels = RasterPixels(width: 3, height: 3, data: (0..<36).map { Float($0 % 4 == 3 ? 1 : 0.5) })
        let image = RasterCore.image(pixels)
        #expect(RasterCore.gaussian(image, sigma: 0) === image)
        #expect(RasterCore.box(image, radius: 0) === image)
        #expect(RasterCore.dilate(image, radius: 0) === image)
        #expect(RasterCore.render(image, width: 3, height: 3, context: context).bytes == pixels.bytes)
        #expect(RasterFilters.unsharp(pixels, blurred: pixels, amount: 5, threshold: 0).data == pixels.data)
    }

    @Test func unsharpThreshold255LeavesAFlatImageUnchanged() {
        var flat = RasterPixels(width: 4, height: 4)
        for index in 0..<16 { flat.data[index * 4 ..< index * 4 + 4] = [0.2, 0.4, 0.6, 1] }
        var edgy = flat
        edgy.data[0] = 1
        #expect(RasterFilters.unsharp(flat, blurred: edgy, amount: 5, threshold: 255).data == flat.data)
        // Below the threshold nothing changes; above it the difference is amplified and kept
        // premultiplied.
        let sharpened = RasterFilters.unsharp(edgy, blurred: flat, amount: 1, threshold: 10)
        #expect(sharpened.data[0] == 1)
        #expect(sharpened.data[4] == flat.data[4])
    }

    // MARK: Shadows and glows

    @Test func dropShadowFallsAlongItsAngle() {
        let shadowed = Self.render([Self.item(Self.square, [C.fill(C.orange)], [EffectElement(.shadow(.init(style: .dropShadow, color: .black, offset: 8, opacity: 100, softness: 0, angle: 315)))])])
        // 315°: down and to the right.
        #expect(Self.brightness(shadowed.pixel(x: 64, y: 64)) < 100)
        #expect(shadowed.pixel(x: 16, y: 16) == Self.white)
        // The object itself stays vector on top.
        #expect(shadowed.pixel(x: 40, y: 40).red > 200)
        let up = Self.render([Self.item(Self.square, [C.fill(C.orange)], [EffectElement(.shadow(.init(color: .black, offset: 8, opacity: 100, angle: 90)))])])
        #expect(Self.brightness(up.pixel(x: 40, y: 15)) < 100)
        #expect(up.pixel(x: 40, y: 65) == Self.white)
    }

    @Test func innerEffectsStayInsideAndGlowsSurround() {
        let inner = Self.render([Self.item(Self.square, [C.fill(C.yellow)], [EffectElement(.shadow(.init(style: .innerShadow, color: .black, offset: 6, opacity: 100, softness: 0, angle: 315)))])])
        #expect(inner.pixel(x: 64, y: 64) == Self.white)
        #expect(Self.brightness(inner.pixel(x: 22, y: 40)) < Self.brightness(inner.pixel(x: 58, y: 40)))
        let glow = Self.render([Self.item(Self.square, [C.fill(C.cyan)], [EffectElement(.shadow(.init(style: .glow, color: .black, offset: 6, opacity: 100, softness: 1)))])])
        #expect(Self.brightness(glow.pixel(x: 16, y: 40)) < 300)
        #expect(Self.brightness(glow.pixel(x: 64, y: 40)) < 300)
        let innerGlow = Self.render([Self.item(Self.square, [C.fill(.black)], [EffectElement(.shadow(.init(style: .innerGlow, color: .white, offset: 5, opacity: 100, softness: 1)))])])
        #expect(Self.brightness(innerGlow.pixel(x: 22, y: 40)) > Self.brightness(innerGlow.pixel(x: 40, y: 40)))
        #expect(innerGlow.pixel(x: 10, y: 10) == Self.white)
    }

    // MARK: Bevels

    @Test func bevelLightComesFromItsAngle() {
        for (angle, lit, shaded) in [(0.0, Point(x: 57, y: 40), Point(x: 23, y: 40)), (90, Point(x: 40, y: 23), Point(x: 40, y: 57)), (180, Point(x: 23, y: 40), Point(x: 57, y: 40)), (270, Point(x: 40, y: 57), Point(x: 40, y: 23))] {
            let image = Self.render([Self.item(Self.square, [C.fill(Color(white: 0.5))], [EffectElement(.bevelEmboss(.init(style: .innerBevel, width: 8, contrast: 80, angle: angle)))])])
            let bright = Self.brightness(image.pixel(x: Int(lit.x), y: Int(lit.y)))
            let dark = Self.brightness(image.pixel(x: Int(shaded.x), y: Int(shaded.y)))
            #expect(bright > dark + 60, "angle \(angle): \(bright) vs \(dark)")
            // The flat top keeps the fill.
            #expect(abs(Self.brightness(image.pixel(x: 40, y: 40)) - 3 * 128) < 12)
        }
    }

    @Test func bevelStylesAndPresets() {
        let base = LiveEffect.BevelEmboss(width: 6, contrast: 90, angle: 135)
        for style in LiveEffect.BevelEmboss.Style.allCases {
            for preset in LiveEffect.BevelEmboss.ButtonPreset.allCases {
                var bevel = base
                bevel.style = style
                bevel.buttonPreset = preset
                let image = Self.render([Self.item(Self.square, [C.fill(C.orange)], [EffectElement(.bevelEmboss(bevel))])])
                if style == .outerBevel {
                    #expect(image.pixel(x: 17, y: 40) != Self.white, "\(style) \(preset)")
                }
                if style == .raisedEmboss || style == .insetEmboss {
                    // The fill disappears: only the relief over the page.
                    #expect(Self.brightness(image.pixel(x: 40, y: 40)) > 700, "\(style) \(preset)")
                }
            }
        }
    }

    @Test func edgeShapesArePureCurves() {
        for shape in LiveEffect.BevelEmboss.EdgeShape.allCases {
            #expect(BevelShading.height(shape, at: 0) == 0 || shape == .ruffle)
            for x in stride(from: -0.5, through: 1.5, by: 0.05) {
                let h = BevelShading.height(shape, at: x)
                #expect(h >= 0 && h <= 1, "\(shape) at \(x)")
            }
        }
        #expect(BevelShading.height(.flat, at: 0.5) == 0.5)
        #expect(approx(BevelShading.height(.smooth, at: 1), 1))
        #expect(BevelShading.height(.sloped, at: 0.5) == 0.5)
        #expect(BevelShading.height(.frame1, at: 0.5) == 0.5)
        #expect(approx(BevelShading.height(.frame1, at: 0.2), 0.3))
        #expect(approx(BevelShading.height(.frame1, at: 1), 1))
        #expect(BevelShading.height(.frame2, at: 0.4) == 1)
        #expect(BevelShading.height(.frame2, at: 0.6) == 0.5)
        #expect(BevelShading.height(.frame2, at: 0.2) == 0.5)
        #expect(approx(BevelShading.height(.ring, at: 0.5), 1))
        #expect(approx(BevelShading.height(.ring, at: 1), 0, tolerance: 1e-12))
        #expect(approx(BevelShading.height(.ruffle, at: 1), 1, tolerance: 1e-12))
    }

    @Test func presetToneTables() {
        #expect(BevelShading.tones(.raised) == .init(highlight: 1, shadow: 1, inverted: false))
        #expect(BevelShading.tones(.highlighted) == .init(highlight: 1.5, shadow: 0.6, inverted: false))
        #expect(BevelShading.tones(.inset) == .init(highlight: 1, shadow: 1, inverted: true))
        #expect(BevelShading.tones(.inverted) == .init(highlight: 0.6, shadow: 1.5, inverted: true))
        let light = BevelShading.light(degrees: 90)
        #expect(approx(light.x * light.x + light.y * light.y + light.z * light.z, 1))
        #expect(light.y < 0)
        #expect(BevelShading.light(degrees: .nan).x > 0)
        // Flat ground is neither lit nor shaded.
        #expect(BevelShading.shade([2, 2, 2, 2], width: 2, height: 2, degrees: 30).allSatisfy { abs($0) < 1e-12 })
        #expect(BevelShading.blur([1, 2, 3], width: 3, height: 1, sigma: 0) == [1, 2, 3])
    }

    // MARK: Feather and transparency

    @Test func featherRamps() {
        #expect(Feather.exponent(softness: 100) == 1)
        #expect(approx(Feather.exponent(softness: 0), 0.15))
        #expect(Feather.ramp(distance: 5, radius: 10, softness: 100) == 0.5)
        #expect(Feather.ramp(distance: 50, radius: 10, softness: 0) == 1)
        #expect(Feather.ramp(distance: 0, radius: 10, softness: 50) == 0)
        #expect(Feather.ramp(distance: 3, radius: 0, softness: 50) == 1)
        let feathered = Self.render([Self.item(Self.square, [C.fill(.black)], [EffectElement(.transparency(.init(style: .feather, radius: 10, softness: 100)))])])
        #expect(Self.brightness(feathered.pixel(x: 21, y: 40)) > Self.brightness(feathered.pixel(x: 26, y: 40)))
        #expect(Self.brightness(feathered.pixel(x: 40, y: 40)) < 10)
    }

    @Test func objectLevelTransparencyDoesNotShowTheStrokeThroughTheFill() {
        let stack: [AppearanceItem] = [C.stroke(.black, width: 10), C.fill(C.orange)]
        let object = Self.render([Self.item(Self.square, stack, [EffectElement(.transparency(.init(amount: 50)))])])
        let fill = Self.render([Self.item(Self.square, stack, [EffectElement(.transparency(.init(amount: 50)), target: .element(1))])])
        // Just inside the edge, where the stroke's inner half lies under the fill.
        let objectPixel = object.pixel(x: 23, y: 40)
        let fillPixel = fill.pixel(x: 23, y: 40)
        let centre = object.pixel(x: 40, y: 40)
        #expect(objectPixel.maxChannelDifference(to: centre) <= 2)
        #expect(Self.brightness(fillPixel) < Self.brightness(objectPixel) - 60)
    }

    @Test func groupTransparencyDoesNotDoubleAtOverlaps() {
        let group = DisplayItem.group(GroupItem(children: [
            C.path(DisplayPath(rect: Rect(x: 10, y: 10, width: 40, height: 40)), [C.fill(C.cyan)]),
            C.path(DisplayPath(rect: Rect(x: 30, y: 30, width: 40, height: 40)), [C.fill(C.cyan)]),
        ], appearance: Appearance(effects: [EffectElement(.transparency(.init(amount: 50)))])))
        let image = Self.render([group])
        #expect(image.pixel(x: 40, y: 40) == image.pixel(x: 15, y: 15))
        #expect(image.pixel(x: 40, y: 40) != Self.white)
        // Fast Preview composites member by member at the group's alpha instead.
        let fast = Self.render([group], renderer: CoreGraphicsRenderer(background: .white, viewMode: .fastPreview))
        #expect(fast.pixel(x: 40, y: 40) != fast.pixel(x: 15, y: 15))
    }

    @Test func gradientMaskUsesInverseLuminance() {
        #expect(TransparencyStage.luminance(.white) == 1)
        #expect(TransparencyStage.luminance(.black) == 0)
        #expect(approx(TransparencyStage.luminance(Color(red: 1, green: 0, blue: 0)), 0.2126))
        #expect(TransparencyStage.factor(red: 0, green: 0, blue: 0, alpha: 0) == 1)
        #expect(TransparencyStage.factor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.5) == 0.5)
        let masked = Self.render([Self.item(Self.square, [C.fill(.black)], [EffectElement(.transparency(.init(style: .gradientMask, mask: Gradient(.linear, from: .black, to: .white))))])])
        #expect(Self.brightness(masked.pixel(x: 21, y: 40)) < 30)
        #expect(Self.brightness(masked.pixel(x: 58, y: 40)) > 700)
        // Fewer than two stops: Basic at the stop's luminance.
        let single = EffectPipeline.transparencyStage(.init(style: .gradientMask, mask: Gradient(stops: [.init(offset: 0, color: Color(white: 0.25))])), content: [.item(.path(PathItem(path: Self.square, appearance: Appearance([C.fill(.black)]))))], settings: RasterSettings(), frame: .identity, region: Self.square, rule: .nonZero)
        guard case .layer(let opacity, _) = single[0] else {
            Issue.record("expected a layer")
            return
        }
        #expect(approx(opacity, 0.75))
        let black = EffectPipeline.transparencyStage(.init(style: .gradientMask, mask: Gradient(stops: [.init(offset: 0, color: .black)])), content: [], settings: RasterSettings(), frame: .identity, region: Self.square, rule: .nonZero)
        #expect(black.isEmpty)
    }

    // MARK: Resolution, preview modes and output

    @Test func previewResolutions() {
        let settings = RasterSettings(resolution: 300)
        #expect(RasterPreview.screen.resolution(for: settings, deviceScale: 2) == 144)
        #expect(RasterPreview.screen.resolution(for: settings, deviceScale: 8) == 300)
        #expect(RasterPreview.document.resolution(for: settings, deviceScale: 1) == 300)
        #expect(RasterPreview.draft.resolution(for: settings, deviceScale: 2) == 72)
        #expect(RasterPreview.off.resolution(for: settings, deviceScale: .nan) == 72)
        #expect(RasterSettings(resolution: 0).effectiveResolution == 72)
        #expect(RasterSettings(resolution: 9000).effectiveResolution == 2400)
    }

    static let shadowed = RasterEffectTests.item(RasterEffectTests.square, [C.fill(C.orange)], [EffectElement(.shadow(.init(color: .black, offset: 5, opacity: 80, softness: 4, angle: 315)))], raster: RasterSettings(resolution: 150))

    @Test func screenOutputAtDocumentResolutionEqualsExport() throws {
        var screen = CoreGraphicsRenderer(background: .white)
        screen.rasterPreview = .document
        let list = DisplayList(canvas: "raster", items: [Self.shadowed, Self.item(DisplayPath(ellipseIn: Rect(x: 5, y: 5, width: 30, height: 20)), [C.fill(C.cyan)], [EffectElement(.transparency(.init(style: .feather, radius: 6, softness: 40)))])])
        let geometry = TileGeometry(zoomStep: ZoomStep(nearest: 2), rotationDegrees: 0)
        let key = try #require(geometry.tiles(coveringPasteboardRect: Rect(x: 0, y: 0, width: 80, height: 80), canvas: "raster").first { $0.column == 0 && $0.row == 0 })
        let tile = try #require(screen.renderTile(list, key: key, geometry: geometry).flatMap(BitmapSurface.init(drawing:)))
        let export = try #require(BitmapSurface(drawing: screen.renderBitmap(list, viewport: Viewport(size: Size(width: 128, height: 128)), scale: 2)!))
        var mismatches = 0
        for y in 0..<min(tile.height, export.height) {
            for x in 0..<min(tile.width, export.width) where tile.pixel(x: x, y: y) != export.pixel(x: x, y: y) {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    @Test func offAndFastModesSkipRasterEffects() {
        let plain = Self.render([Self.item(Self.square, [C.fill(C.orange)], [])])
        var off = CoreGraphicsRenderer(background: .white)
        off.rasterPreview = .off
        let badged = Self.render([Self.shadowed], renderer: off)
        #expect(badged.pixel(x: 64, y: 64) == Self.white)
        // The badge: a grey disc at the content's top-right corner.
        #expect(Self.brightness(badged.pixel(x: 57, y: 22)) < 500)
        #expect(plain.pixel(x: 57, y: 22) != badged.pixel(x: 57, y: 22))
        let fast = Self.render([Self.shadowed], renderer: CoreGraphicsRenderer(background: .white, viewMode: .fastPreview))
        #expect(fast.pixel(x: 64, y: 64) == Self.white)
        let masked = Self.item(Self.square, [C.fill(.black)], [EffectElement(.transparency(.init(style: .gradientMask, mask: Gradient(.linear, from: .black, to: .white))))])
        let fastMask = Self.render([masked], renderer: CoreGraphicsRenderer(background: .white, viewMode: .fastPreview))
        #expect(Self.brightness(fastMask.pixel(x: 58, y: 40)) < 30)
    }

    @Test func pdfEmbedsRasterEffectsAsImagesAndMasksAsSoftMasks() throws {
        let list = DisplayList(canvas: "raster", items: [Self.shadowed])
        let viewport = Viewport(size: Size(width: 80, height: 80))
        let pdf = try #require(CoreGraphicsRenderer(background: .white).renderPDF(list, viewport: viewport))
        #expect(String(decoding: pdf, as: UTF8.self).contains("/Image"))
        let raster = try #require(PDFRasterizer.rasterize(pdf, scale: 1))
        #expect(Self.brightness(raster.pixel(x: 61, y: 61)) < 500)
        #expect(raster.pixel(x: 10, y: 10) == Self.white)
        let masked = Self.item(Self.square, [C.fill(.black)], [EffectElement(.transparency(.init(style: .gradientMask, mask: Gradient(.linear, from: .black, to: .white))))])
        let maskPDF = try #require(CoreGraphicsRenderer(background: .white).renderPDF(DisplayList(canvas: "raster", items: [masked]), viewport: viewport))
        let maskRaster = try #require(PDFRasterizer.rasterize(maskPDF, scale: 1))
        #expect(Self.brightness(maskRaster.pixel(x: 21, y: 40)) < 40)
        #expect(Self.brightness(maskRaster.pixel(x: 58, y: 40)) > 690)
        // A replacing effect (blur) places its image instead of the content.
        let blurred = Self.item(Self.square, [C.fill(.black)], [EffectElement(.blur(.init(radius: 3))), EffectElement(.shadow(.init(style: .innerGlow, color: .white, offset: 3, opacity: 90)))])
        let blurPDF = try #require(CoreGraphicsRenderer(background: .white).renderPDF(DisplayList(canvas: "raster", items: [blurred]), viewport: viewport))
        #expect(try #require(PDFRasterizer.rasterize(blurPDF, scale: 1)).pixel(x: 19, y: 40) != Self.white)
    }

    @Test func optimalCMYKAndCoarseGrids() {
        let cmyk = RasterNode(operations: [.blur(.init(radius: 2))], content: [.item(.path(PathItem(path: Self.square, appearance: Appearance([C.fill(C.orange)]))))], settings: RasterSettings(optimalCMYK: true))
        let result = RasterEffectStage.render(cmyk, resolution: 72) { context in
            CoreGraphicsRenderer().drawNodes(cmyk.content, state: .init(canvasToBase: context.ctm), cull: Rect(context.boundingBoxOfClipPath), into: context)
        }
        #expect(result?.replaced != nil)
        // Content larger than the grid cap renders at a coarser resolution.
        let huge = RasterNode(operations: [.blur(.init(radius: 1))], content: [.item(.path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 10_000, height: 10)), appearance: Appearance([C.fill(.black)]))))], settings: RasterSettings())
        let coarse = RasterEffectStage.render(huge, resolution: 72) { _ in }
        #expect((coarse?.replaced?.pixelSize ?? 0) > 1)
        #expect(RasterEffectStage.render(RasterNode(operations: [], content: [], settings: RasterSettings()), resolution: 72) { _ in } == nil)
        #expect(RasterEffectStage.grid(Rect(x: .nan, y: 0, width: 1, height: 1), resolution: 72).width == 0)
    }

    @Test func rasterImagesSampleBilinearly() {
        let image = RasterImage(origin: Point(x: 0, y: 0), pixelSize: 1, width: 2, height: 1, bytes: [0, 0, 0, 0, 255, 255, 255, 255])
        let middle: SIMD4<Double> = image.sample(Point(x: 1, y: 0.5))
        #expect(middle == SIMD4<Double>(repeating: 127.5))
        #expect(image.sample(Point(x: -5, y: 0)) == .zero)
        #expect(!image.isClear)
        #expect(RasterImage(origin: .zero, pixelSize: 1, width: 1, height: 1, bytes: [0, 0, 0, 0]).isClear)
        #expect(image.cgImage?.width == 2)
        #expect(RasterImage(origin: .zero, pixelSize: 1, width: 0, height: 0, bytes: []).cgImage == nil)
        #expect(PixelRect(covering: .null) == nil)
        #expect(PixelRect(covering: Rect(x: 0, y: 0, width: 0, height: 5)) == nil)
    }

    // MARK: Cache

    static func result(bytes: Int) -> RasterResult {
        RasterResult(below: [], replaced: RasterImage(origin: .zero, pixelSize: 1, width: bytes / 4, height: 1, bytes: [UInt8](repeating: 1, count: bytes)), above: [])
    }

    static func key(_ index: Int) -> RasterEffectCache.Key {
        RasterEffectCache.Key(node: RasterNode(operations: [.blur(.init(radius: Double(index)))], content: [], settings: RasterSettings()), resolution: 72)
    }

    @Test func cacheEvictsLeastRecentlyUsedUnderItsCap() {
        let cache = RasterEffectCache(capacity: 1000)
        for index in 0..<5 {
            _ = cache.result(for: Self.key(index)) { Self.result(bytes: 400) }
        }
        #expect(cache.byteCount <= 1000)
        #expect(cache.evictionCount == 3)
        #expect(cache.count == 2)
        // A hit refreshes an entry; the stalest goes first.
        _ = cache.result(for: Self.key(3)) { nil }
        _ = cache.result(for: Self.key(5)) { Self.result(bytes: 400) }
        #expect(cache.result(for: Self.key(3)) { nil } != nil)
        // Re-storing a key replaces its cost.
        let renders = cache.renderCount
        #expect(cache.result(for: Self.key(4)) { nil } == nil)
        #expect(cache.renderCount == renders + 1)
        cache.removeAll()
        #expect(cache.count == 0 && cache.byteCount == 0)
    }

    @Test func memoryStaysUnderTheCapWithTwoThousandEffectedObjects() {
        let cache = RasterEffectCache(capacity: 512 * 1024)
        var renderer = CoreGraphicsRenderer(background: .white)
        renderer.rasterCache = cache
        var items: [DisplayItem] = []
        for index in 0..<2000 {
            let rect = Rect(x: Double(index % 50) * 12, y: Double(index / 50) * 12, width: 6, height: 6)
            items.append(Self.item(DisplayPath(rect: rect), [C.fill(C.orange)], [EffectElement(.shadow(.init(offset: 1, opacity: 60, softness: 1)))]))
        }
        let list = DisplayList(canvas: "raster", items: items)
        _ = renderer.renderBitmap(list, viewport: Viewport(size: Size(width: 600, height: 480)), scale: 2)
        #expect(cache.renderCount == 2000)
        #expect(cache.byteCount <= cache.capacity)
        #expect(cache.evictionCount > 0)
        print("2,000 raster effects at 2×: \(cache.count) cached, \(cache.byteCount) bytes, \(cache.evictionCount) evicted")
    }

    @Test func progressiveRenderingDrawsTheVectorResultUntilReady() async {
        let cache = RasterEffectCache(capacity: RasterEffectCache.defaultCapacity)
        let ready = ReadyBox()
        var renderer = CoreGraphicsRenderer(background: .white)
        renderer.rasterCache = cache
        renderer.rasterEffectsReady = { rect in ready.fire(rect) }
        let pending = Self.render([Self.shadowed], renderer: renderer)
        #expect(pending.pixel(x: 64, y: 64) == Self.white)
        await ready.wait()
        #expect(ready.area?.contains(Rect(x: 20, y: 20, width: 40, height: 40)) == true)
        let done = Self.render([Self.shadowed], renderer: renderer)
        #expect(Self.brightness(done.pixel(x: 61, y: 61)) < 500)
    }
}

/// Waits for a progressive raster render's callback.
final class ReadyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false
    private(set) var area: Rect?

    func fire(_ rect: Rect) {
        lock.lock()
        area = rect
        fired = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
