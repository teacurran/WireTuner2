// IMG-024: *Rasterize* -- the selection drawn alone over its rendered bounds matches the screen
// render at that scale; background, colour mode, the readout, the size refusal and cancellation.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct SelectionRasterizerTests {
    /// Strokes, a gradient, transparency and a live effect, one node each, plus an unselected
    /// object that must not show.
    static let list: DisplayList = {
        let items = Corpus.basics.prefix(2) + Corpus.gradients.prefix(1) + Corpus.transparency.prefix(1) + Corpus.effects.prefix(1)
        let all = Array(items) + [Corpus.path(Corpus.rect(0, 0, 400, 400), [Corpus.fill(.solid(Corpus.yellow))])]
        return DisplayList(canvas: "page", items: all, nodeIDs: all.indices.map { Corpus.node(UInt64($0 + 1)) })
    }()

    static let selected = Set((1...5).map { Corpus.node(UInt64($0)) })

    @Test func matchesTheScreenRenderAtThatScale() throws {
        let selection = SelectionRasterizer.selection(Self.list, nodes: Self.selected)
        #expect(selection.count == 5)
        let rendered = try #require(selection.bounds)
        let options = RasterizeOptions(resolution: .custom(150), antiAliasing: .high)
        let image = try SelectionRasterizer.rasterize(selection, options: options)
        // The image's bounds are the selection's rendered bounds (widened to whole pixels).
        #expect(image.bounds.origin == rendered.origin)
        #expect(image.bounds.width >= rendered.width && image.bounds.width - rendered.width < 72.0 / 150)
        #expect(image.ppi == 150 && image.pixels.hasAlpha && image.pixels.mode == .rgb && image.pixels.blob.uti == UTType.png.identifier)
        #expect(image.pixels.width == Int((rendered.width * 150 / 72).rounded(.up)))
        var screen = CoreGraphicsRenderer()
        screen.rasterPreview = .document
        let reference = try #require(screen.renderBitmap(selection, viewport: Viewport(scrollOrigin: image.bounds.origin, zoom: 1, size: image.bounds.size), scale: 150.0 / 72))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(image.pixels.blob.data as CFData, nil)!, 0, nil))
        let failing = Corpus.difference(reference, decoded, tolerance: 40)
        if failing > 0.02 { Corpus.dump(decoded, "rasterize-selection") }
        #expect(failing <= 0.02, "\(failing)")
    }

    @Test func backgroundAndColorModes() throws {
        let selection = SelectionRasterizer.selection(Self.list, nodes: [Corpus.node(1)])
        let white = try SelectionRasterizer.rasterize(selection, options: RasterizeOptions(resolution: .screen, background: .white))
        #expect(!white.pixels.hasAlpha)
        let press = WTColor.OutputContext(cmykProfile: OutputPress.profile)
        let cmyk = try SelectionRasterizer.rasterize(selection, options: RasterizeOptions(resolution: .screen, colorMode: .cmyk), output: press)
        #expect(cmyk.pixels.blob.uti == UTType.tiff.identifier && cmyk.pixels.mode == .cmyk && !cmyk.pixels.hasAlpha)
        #expect(WTColor.OutputContext.embeddedProfile(in: cmyk.pixels.blob.data)?.sha256 == OutputPress.profile.sha256)
        let gray = try SelectionRasterizer.rasterize(selection, options: RasterizeOptions(resolution: .proof, antiAliasing: .none, colorMode: .grayscale))
        #expect(gray.pixels.mode == .grayscale && gray.pixels.blob.uti == UTType.png.identifier && gray.ppi == 144)
    }

    @Test func readoutRefusalAndCancellation() async throws {
        #expect(RasterizeOptions.Resolution.screen.ppi == 72 && RasterizeOptions.Resolution.proof.ppi == 144 && RasterizeOptions.Resolution.print.ppi == 300)
        #expect(RasterizeOptions().hasAlpha && !RasterizeOptions(colorMode: .grayscale).hasAlpha)
        #expect(throws: RasterizeError.invalidResolution) { try RasterizeOptions(resolution: .custom(20)).validate() }
        let selection = SelectionRasterizer.selection(Self.list, nodes: [Corpus.node(6)])
        let plan = try #require(SelectionRasterizer.plan(selection, options: RasterizeOptions(resolution: .screen)))
        #expect(plan.pixelWidth == 400 && plan.pixelHeight == 400 && plan.pixelCount == 160_000 && plan.bytes == 640_000)
        #expect(plan.readout == "400 × 400 pixels (0.16 MP)")
        #expect(plan.exceeds(downsampleLimit: 100_000) && !plan.exceeds(downsampleLimit: nil) && !plan.isRefused)
        #expect(SelectionRasterizer.plan(SelectionRasterizer.selection(Self.list, nodes: []), options: RasterizeOptions()) == nil)
        #expect(throws: RasterizeError.nothingToRasterize) { try SelectionRasterizer.rasterize(SelectionRasterizer.selection(Self.list, nodes: []), options: RasterizeOptions()) }
        // 400 points at 2400 ppi is 13,334 pixels a side: far over 200 MiB.
        let huge = RasterizeOptions(resolution: .custom(2400))
        #expect(SelectionRasterizer.plan(selection, options: huge)!.isRefused)
        #expect(throws: RasterizeError.self) { try SelectionRasterizer.rasterize(selection, options: huge) }
        #expect(throws: CancellationError.self) { try SelectionRasterizer.rasterize(selection, options: RasterizeOptions(resolution: .screen)) { _ in false } }
        let background = try await SelectionRasterizer.rasterizeInBackground(selection, options: RasterizeOptions(resolution: .screen, antiAliasing: .none))
        #expect(background.pixels.width == 400)
    }
}
