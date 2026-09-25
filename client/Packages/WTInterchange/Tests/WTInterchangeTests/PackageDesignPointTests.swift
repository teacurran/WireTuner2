// IO-005, the rest: the package writer at the design point -- 50,000 objects on page 1 (drawn into
// the thumbnail and `preview.pdf`), a design-point-sized snapshot and a set of blobs -- written in
// under 5 s (held in the perf run; correctness runs use a tenth of the volume), and `preview.pdf`
// passing `qpdf --check` (CGPDFDocument where qpdf is not installed).  The snapshot's state hash is
// carried through untouched; that it matches the live state is WTModel's test
// (`PackageExportTests`), since WTInterchange never decodes a snapshot.

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct PackageDesignPointTests {
    /// The design point's object count, or a tenth of it outside the perf run.
    static var objects: Int { PerfBudget.isMeasuring ? 50_000 : 5_000 }

    static func contents() -> PackageContents {
        let count = objects
        let columns = 250
        let items = (0..<count).map { index -> DisplayItem in
            let x = Double(index % columns) * 3.2, y = Double(index / columns) * 3.2
            let color = [Corpus.red, Corpus.blue, Corpus.green, Corpus.yellow][index % 4]
            return Corpus.path(Corpus.rect(x, y, 2.5, 2.5), [Corpus.fill(.solid(color))])
        }
        let page = Corpus.page(items, width: 800, height: Double(count / columns + 1) * 3.2)
        // About 160 bytes a node, incompressible, as a zstd frame is.
        var generator = SystemRandomNumberGenerator()
        let snapshot = Data((0..<(count * 160)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let blobs = (0..<(count / 2_500)).map { index in
            PackageBlobSource(data: Data((0..<262_144).map { UInt8(truncatingIfNeeded: $0 &* (index + 3)) }), mediaType: "image/png", name: "image-\(index).png")
        }
        let manifest = PackageManifest(originDocumentID: "01926a3c-0000-7000-8000-000000000002", title: "Design point", exportedBy: "user-1",
                                       exportedByName: "Terry", exportedAtMs: 1_790_000_000_000, appVersion: "1.0", featureLevel: 1, mergeTableVersion: 1,
                                       headServerSeq: 50_000, unsyncedChanges: 0, stateHash: Data(repeating: 0x5A, count: 32))
        return PackageContents(manifest: manifest, snapshot: snapshot, blobs: blobs, firstPage: Corpus.scene([page]))
    }

    @Test func theDesignPointWritesInUnderFiveSeconds() throws {
        let contents = Self.contents()
        let start = ContinuousClock.now
        let (data, summary) = try PackageWriter().data(contents)
        let elapsed = ContinuousClock.now - start
        PerfBudget.expect(elapsed, within: .seconds(5), "\(Self.objects) objects")
        #expect(summary.wrotePreview)
        let opened = try PackageReader(featureLevel: 1, mergeTableVersion: 1).open(data)
        #expect(opened.snapshot == contents.snapshot)
        #expect(opened.manifest.stateHash == contents.manifest.stateHash)
        #expect(opened.blobs.count == contents.blobs.count)
        let preview = try #require(opened.preview)
        if QPDF.isAvailable {
            let check = try QPDF.check(preview)
            #expect(check.status == 0, "\(check.output)")
        }
        let document = try #require(CGPDFDocument(CGDataProvider(data: preview as CFData)!))
        #expect(document.numberOfPages == 1)
    }

    @Test func previewsPassQPDF() throws {
        guard QPDF.isAvailable else { return }
        let scene = Corpus.scene([Corpus.page(Corpus.basics + [Corpus.text("Preview")], name: "Cover")])
        let check = try QPDF.check(try PackageWriter.preview(scene))
        #expect(check.status == 0, "\(check.output)")
        #expect(check.output.contains("No syntax or stream encoding errors found"))
    }
}
