import WTGeometry
import CoreGraphics
import Foundation
import Testing
@testable import WTRender

/// REND-002 "Done when": reference renders match the golden corpus within anti-aliasing
/// tolerance (REND-001's policy: interior pixels exact, 4/255 inside translucent groups; edge
/// pixels within 16/255), at 1× and 4× (docs/spec/testing.adoc, "Geometry and rendering").
///
/// Run once with `WTRENDER_RECORD_GOLDENS=1` to (re)write the PNGs under Goldens/; commit them.
@Suite struct ReferenceRenderTests {
    static let edgeTolerance = CoreGraphicsRendererTests.edgeTolerance

    static func interiorTolerance(for list: DisplayList) -> Int {
        CoreGraphicsRendererTests.hasTranslucentGroup(list.items) ? CoreGraphicsRendererTests.translucentGroupInteriorTolerance : 0
    }

    @Test func corpusIsLargeAndNamedUniquely() {
        let names = ReferenceCorpus.cases.map(\.name)
        #expect(names.count >= 20)
        #expect(Set(names).count == names.count)
    }

    @Test(arguments: ReferenceCorpus.cases.map(\.name))
    func matchesGolden(name: String) throws {
        let reference = try #require(ReferenceCorpus.cases.first { $0.name == name })
        let viewport = Viewport(size: ReferenceCorpus.viewSize)
        for scale in ReferenceCorpus.scales {
            let image = try #require(reference.renderer.renderBitmap(reference.list, viewport: viewport, scale: scale))
            let url = GoldenStore.url(for: name, scale: scale)
            if GoldenStore.isRecording {
                #expect(GoldenStore.write(image, to: url), "could not write \(url.path)")
                continue
            }
            guard let golden = GoldenStore.read(url) else {
                Issue.record("missing golden \(url.lastPathComponent); run with \(GoldenStore.recordEnvironmentKey)=1 and commit it")
                continue
            }
            let candidate = try #require(BitmapSurface(drawing: image))
            #expect(golden.width == candidate.width && golden.height == candidate.height)
            let comparison = PixelComparison(
                reference: golden,
                candidate: candidate,
                interiorTolerance: Self.interiorTolerance(for: reference.list),
                edgeTolerance: Self.edgeTolerance
            )
            #expect(
                comparison.passes,
                "\(name)@\(Int(scale))×: \(comparison.interiorMismatches) interior (max Δ\(comparison.maxInteriorDifference)), \(comparison.edgeMismatches) edge (max Δ\(comparison.maxEdgeDifference)) of \(comparison.pixels)"
            )
        }
    }

    /// The PDF route draws the same attribute stacks: bitmap and rasterized PDF agree under
    /// REND-001's gate, at 1× and 2× (1× only for renders with hairlines: a hairline is one
    /// device pixel in a bitmap and one point on a PDF page).
    @Test(arguments: ReferenceCorpus.cases.map(\.name))
    func bitmapAndPDFAgree(name: String) throws {
        let reference = try #require(ReferenceCorpus.cases.first { $0.name == name })
        let viewport = Viewport(size: ReferenceCorpus.viewSize)
        let pdf = try #require(reference.renderer.renderPDF(reference.list, viewport: viewport))
        for scale in reference.hasHairlines ? [1.0] : [1.0, 2.0] {
            let bitmapImage = try #require(reference.renderer.renderBitmap(reference.list, viewport: viewport, scale: scale))
            let bitmap = try #require(BitmapSurface(drawing: bitmapImage))
            let rasterized = try #require(PDFRasterizer.rasterize(pdf, scale: scale))
            let comparison = PixelComparison(
                reference: bitmap,
                candidate: rasterized,
                interiorTolerance: Self.interiorTolerance(for: reference.list),
                edgeTolerance: Self.edgeTolerance
            )
            #expect(
                comparison.passes,
                "\(name)@\(Int(scale))×: \(comparison.interiorMismatches) interior (max Δ\(comparison.maxInteriorDifference)), \(comparison.edgeMismatches) edge (max Δ\(comparison.maxEdgeDifference)) of \(comparison.pixels)"
            )
        }
    }

    @Test func goldenStoreRefusesUnwritableAndUnreadablePaths() {
        let image = CoreGraphicsRenderer().renderBitmap(ReferenceCorpus.mixed, viewport: Viewport(size: ReferenceCorpus.viewSize))!
        #expect(!GoldenStore.write(image, to: URL(fileURLWithPath: "/nonexistent-root-dir/x.png")))
        #expect(GoldenStore.read(URL(fileURLWithPath: "/nonexistent-root-dir/x.png")) == nil)
    }
}
