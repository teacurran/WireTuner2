import WTGeometry
import CoreGraphics
import Foundation
import Metal
import Testing
@testable import WTRender

@Suite(.enabled(if: MetalAvailability.isAvailable, "no Metal device: Metal renderer run incomplete"))
struct MetalRendererTests {
    /// The REND-001 corpus (legacy fill and stroke items, clips with both rules, nested and
    /// translucent groups, placeholders, empty and off-screen lists) through the whole-view
    /// entry point, against Core Graphics, under the parity tolerance.
    @Test(arguments: Corpus.all.map(\.name))
    func viewportRendersMatchCoreGraphics(name: String) throws {
        let context = try #require(MetalAvailability.context)
        let list = try #require(Corpus.all.first { $0.name == name }?.list)
        let cg = CoreGraphicsRenderer(background: .white)
        let metal = MetalRenderer(context: context, background: .white)
        for (viewportName, viewport) in Corpus.viewports {
            for mode in [ViewMode.preview, .fastPreview, .keyline] {
                let reference = try #require(cg.with(viewMode: mode).renderBitmap(list, viewport: viewport, scale: 2).flatMap(BitmapSurface.init(drawing:)))
                let candidate = try #require(BitmapSurface(width: reference.width, height: reference.height))
                candidate.context.scaleBy(x: 2, y: 2)
                metal.with(viewMode: mode).render(list, viewport: viewport, into: candidate.context)
                let parity = TileParity(reference: reference, candidate: candidate)
                if !parity.passes {
                    Triptych.write(reference: reference, candidate: candidate, name: "view-\(name)-\(viewportName)-\(mode)")
                }
                #expect(parity.passes, "\(name)/\(viewportName)/\(mode): \(parity)")
            }
        }
    }

    /// Sibling and nested layers reuse offscreen surfaces per depth; the result still matches.
    @Test func siblingAndNestedLayersComposite() throws {
        let context = try #require(MetalAvailability.context)
        func square(_ x: Double, _ y: Double, _ color: Color) -> DisplayItem {
            .fill(FillItem(path: DisplayPath(rect: Rect(x: x, y: y, width: 50, height: 50)), paint: .solid(color)))
        }
        let list = DisplayList(canvas: "layers", items: [
            .group(GroupItem(children: [square(10, 10, red), square(30, 30, blue)], opacity: 0.5)),
            .group(GroupItem(children: [
                square(60, 20, green),
                .group(GroupItem(children: [square(70, 30, red)], clip: DisplayPath(ellipseIn: Rect(x: 60, y: 20, width: 60, height: 50)), opacity: 0.7)),
            ], clip: DisplayPath(rect: Rect(x: 55, y: 15, width: 70, height: 70)), opacity: 0.6)),
        ])
        let geometry = TileGeometry(zoomStep: ZoomStep(nearest: 2), rotationDegrees: 15)
        for key in geometry.tiles(coveringPasteboardRect: list.bounds!, canvas: "layers") {
            let reference = try #require(CoreGraphicsRenderer(background: .white).renderTile(list, key: key, geometry: geometry).flatMap(BitmapSurface.init(drawing:)))
            let candidate = try #require(MetalRenderer(context: context, background: .white).renderTile(list, key: key, geometry: geometry).flatMap(BitmapSurface.init(drawing:)))
            let parity = TileParity(reference: reference, candidate: candidate)
            #expect(parity.passes, "\(key): \(parity)")
        }
    }

    @Test func tileEntryPointsAgree() throws {
        let context = try #require(MetalAvailability.context)
        let metal = MetalRenderer(context: context, background: .white)
        let geometry = TileGeometry(zoomStep: ZoomStep(nearest: 2), rotationDegrees: 15)
        let key = geometry.key(containing: Point(x: 10, y: 10), canvas: Corpus.canvas)
        let image = try #require(metal.renderTile(Corpus.strokes, key: key, geometry: geometry))
        #expect(image.width == 256 && image.height == 256)
        let direct = try #require(BitmapSurface(drawing: image))
        let drawn = try #require(BitmapSurface(width: 256, height: 256))
        metal.render(Corpus.strokes, tile: key, geometry: geometry, into: drawn.context)
        #expect(TileParity(reference: direct, candidate: drawn).failures == 0)
    }

    @Test func settingsAreRendererState() throws {
        let context = try #require(MetalAvailability.context)
        let metal = MetalRenderer(context: context)
        #expect(metal.viewMode == .preview && !metal.overprintPreview && metal.background == nil)
        #expect(metal.flatteningTolerance == .standard)
        #expect(metal.with(viewMode: .keyline).viewMode == .keyline)
        #expect(metal.with(overprintPreview: true).overprintPreview)
    }

    @Test func aFailedCommandBufferYieldsNoImage() throws {
        let context = try #require(MetalContext(device: MTLCreateSystemDefaultDevice()))
        let metal = MetalRenderer(context: context, background: .white)
        let geometry = TileGeometry(zoomStep: ZoomStep(index: 0), rotationDegrees: 0)
        let key = geometry.key(containing: .zero, canvas: Corpus.canvas)
        context.injectCommandBufferFailures(1)
        #expect(metal.renderTile(Corpus.solidRect, key: key, geometry: geometry) == nil)
        #expect(metal.renderTile(Corpus.solidRect, key: key, geometry: geometry) != nil, "one fault, one failure")

        // Nothing is drawn into a context when the tile fails.
        let surface = try #require(BitmapSurface(width: 256, height: 256))
        context.injectCommandBufferFailures(2)
        metal.render(Corpus.solidRect, tile: key, geometry: geometry, into: surface.context)
        metal.render(Corpus.solidRect, viewport: Viewport(size: Corpus.viewSize), into: surface.context)
        #expect(surface.pixel(x: 20, y: 20).alpha == 0)
        context.injectCommandBufferFailures(-1)
        #expect(metal.renderTile(Corpus.solidRect, key: key, geometry: geometry) != nil)
    }

    @Test func surfacesThatCannotBeAllocatedYieldNothing() throws {
        let context = try #require(MetalAvailability.context)
        let metal = MetalRenderer(context: context)
        #expect(metal.renderImage(Corpus.solidRect, pasteboardTransform: .identity, cull: Rect(x: 0, y: 0, width: 1, height: 1), width: 0, height: 10) == nil)
        let surface = try #require(BitmapSurface(width: 4, height: 4))
        metal.render(Corpus.solidRect, viewport: Viewport(size: Size(width: 0, height: 0)), into: surface.context)
        #expect(surface.pixel(x: 0, y: 0).alpha == 0)
    }

    @Test func overprintMultipliesOverTransparencyToo() throws {
        // Multiply over a transparent tile is the source itself (Sc(1 − Da) with Da = 0), as
        // Core Graphics composites it.
        let context = try #require(MetalAvailability.context)
        let list = DisplayList(canvas: "overprint", items: [
            .path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 200, height: 200)), appearance: Appearance([
                .fill(FillPaint(paint: .solid(Color(red: 0.2, green: 0.6, blue: 0.9, alpha: 0.8)), overprint: true)),
            ]))),
        ])
        let geometry = TileGeometry(zoomStep: ZoomStep(index: 0), rotationDegrees: 0)
        let key = geometry.key(containing: .zero, canvas: "overprint")
        let cg = try #require(CoreGraphicsRenderer(overprintPreview: true).renderTile(list, key: key, geometry: geometry).flatMap(BitmapSurface.init(drawing:)))
        let metal = try #require(MetalRenderer(context: context, overprintPreview: true).renderTile(list, key: key, geometry: geometry).flatMap(BitmapSurface.init(drawing:)))
        #expect(metal.pixel(x: 50, y: 50).maxChannelDifference(to: cg.pixel(x: 50, y: 50)) <= 1, "\(metal.pixel(x: 50, y: 50)) vs \(cg.pixel(x: 50, y: 50))")
    }
}

/// Context construction, including the ways it refuses.
@Suite(.enabled(if: MetalAvailability.isAvailable, "no Metal device: Metal renderer run incomplete"))
struct MetalContextTests {
    @Test func buildsFromTheBundledShaderSource() throws {
        let source = try #require(MetalContext.shaderSource())
        #expect(source.contains("fanVertex") && source.contains("paintFragment"))
        let context = try #require(MetalContext(device: MTLCreateSystemDefaultDevice()))
        let pipeline = try #require(context.tilePipeline(for: .bgra8Unorm))
        #expect(context.tilePipeline(for: .bgra8Unorm) === pipeline, "built once per pixel format")
        let uncommitted = try #require(context.queue.makeCommandBuffer())
        #expect(!context.succeeded(uncommitted), "a buffer that did not complete is a failure")
    }

    @Test func refusesWithoutADeviceOrShaders() {
        #expect(MetalContext(device: nil) == nil)
        let device = MTLCreateSystemDefaultDevice()
        #expect(MetalContext(device: device, shaderSource: nil) == nil)
        #expect(MetalContext(device: device, shaderSource: "this is not metal") == nil)
        // Valid source missing the pipeline functions, then missing only the layer compositor.
        #expect(MetalContext(device: device, shaderSource: "#include <metal_stdlib>\nvertex float4 unused() { return float4(0); }") == nil)
        let bundled = MetalContext.shaderSource()!
        let withoutLayers = bundled.replacingOccurrences(of: "layerFragment", with: "renamedFragment")
        #expect(MetalContext(device: device, shaderSource: withoutLayers) == nil)
    }
}
