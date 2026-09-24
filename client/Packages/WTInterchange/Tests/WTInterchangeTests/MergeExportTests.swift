import Foundation
import PDFKit
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

/// DATA-021's export half: merge file names and the one-file / file-per-record writer.
@Suite struct MergeExportTests {
    static func page(_ index: Int) -> ExportPage {
        let item = Corpus.path(Corpus.rect(10 + Double(index), 10, 50, 20), [Corpus.fill(.solid(.black))])
        return ExportPage(name: "p\(index)", bounds: Rect(x: 0, y: 0, width: 200, height: 100), displayList: DisplayList(canvas: "merge", items: [item]))
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(component: "wt-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func namesTakeFieldsAndCollisionsGetSuffixes() {
        let values = FileNamePattern.Values(name: "Invoices", page: 3)
        #expect(MergeFileNames.expand("invoice-{order_id}", values: values, fields: ["order_id": "A/17"]) == "invoice-A-17")
        #expect(MergeFileNames.expand("{name}-{page}-{missing}", values: values, fields: [:]) == "Invoices-3-{missing}")
        #expect(MergeFileNames.unique(["a", "b", "A", "a", "a 2"]) == ["a", "b", "A 2", "a 3", "a 2 2"])
    }

    @Test func oneFilePerRecordAndOneFile() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ids = ["7", "8", "7"]
        // Two pages per record (a two-page template set).
        let pages = MergeExport.Pages(count: 6, page: { Self.page($0) }, fields: { ["order_id": ids[$0 / 2]] }, record: { $0 / 2 })
        var info = ExportDocumentInfo()
        info.title = "Orders"
        let export = MergeExport(info: info)
        let summary = try export.write(pages, mode: .filePerRecord(pattern: "invoice-{order_id}"), to: directory)
        #expect(summary.files.map(\.lastPathComponent) == ["invoice-7.pdf", "invoice-8.pdf", "invoice-7 2.pdf"])
        #expect(summary.files.allSatisfy { PDFDocument(url: $0)?.pageCount == 2 })
        // Cancelled after the first record: what was written stays.
        let cancelled = try export.write(pages, mode: .filePerRecord(pattern: "c-{page}"), to: directory) { done, _ in done < 1 }
        #expect(cancelled.files.map(\.lastPathComponent) == ["c-1.pdf"])
        let single = try MergeExport().write(pages, mode: .oneFile(name: "all"), to: directory)
        #expect(single.files.count == 1 && PDFDocument(url: single.files[0])?.pageCount == 6)
        let partial = try MergeExport().write(pages, mode: .oneFile(name: "some"), to: directory) { done, _ in done < 2 }
        #expect(PDFDocument(url: partial.files[0])?.pageCount == 2)
        #expect(throws: ExportError.nothingToExport) { try MergeExport().write(MergeExport.Pages(count: 0, page: Self.page), mode: .oneFile(name: "x"), to: directory) }
        let defaults = MergeExport.Pages(count: 1, page: Self.page)
        #expect(defaults.fields(0).isEmpty && defaults.record(0) == 0)
    }
}
