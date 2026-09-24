import Foundation
import PDFKit
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender
import WTText

/// DATA-021's model half: merged output pages drawn from the template with a record applied,
/// written to PDF without a document change.
@Suite struct MergeOutputTests {
    @Test @MainActor func onePerPageAndGridPagesWriteNothing() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        let fields = try DataFixture.fields(&a, ["order_id", "day"], kinds: [.text, .date])
        try a.perform(SetFieldFormat(fields[1], pattern: "yyyy"))
        let block = try DataFixture.placeholderBlock(&a, "Invoice ", field: fields[0], at: 8)
        let code = try a.perform(InsertBarcode("x", symbology: .code128, at: Point(x: 50, y: 100)))!.createdObjects[0]
        try a.perform(BindToField([code], field: fields[0], kind: .text))
        let sent = a.sent.count
        let records = RecordSet(model: DataModel(a.state), source: nil,
                                raw: [DataRecord(["order_id": "A1", "day": "bad"]), DataRecord(["order_id": "é"]), DataRecord(["order_id": "A1"])])
        let output = try MergeOutput(state: a.state, records: records, options: MergeOptions(records: MergeRange("1-2")!), templates: [page])
        #expect(output.count == 2 && output.records(on: 1) == [1] && output.fieldValues(on: 0) == ["order_id": "A1", "day": "bad"])
        let engine = TextLayoutEngine()
        let first = output.page(0, textLayout: TextSceneLayout(engine: engine))
        #expect(first.bounds == PageList(a.state).pages[0].rect && first.name == " · 1" && !first.displayList.items.isEmpty)
        #expect(output.page(1).displayList.items.count >= 1)
        let issues = output.issues()
        #expect(issues == [MergeIssue(record: 1, field: "day", kind: .unparsableDate(value: "bad")), MergeIssue(record: 2, kind: .unencodableBarcode(node: code))])
        // Grid: the selection's items translated into each cell.
        let grid = try MergeOutput(state: a.state, records: records, options: MergeOptions(layout: .grid(columns: 2, rows: 1, gap: 10, margins: 20, order: .acrossThenDown)),
                                   templates: [page], selection: [code])
        #expect(grid.count == 2 && grid.records(on: 0) == [0, 1] && grid.page(1).name == " · 3" && grid.page(0).name == " · 1")
        let cells = grid.page(0).displayList.items.compactMap(\.bounds)
        #expect(cells.count == 2 && cells[1].minX > cells[0].minX)
        #expect(grid.fieldValues(on: 1) == ["order_id": "A1", "day": ""])
        // Written as one PDF per record through WTInterchange; the document is untouched.
        let directory = FileManager.default.temporaryDirectory.appending(component: "wt-mergeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pages = MergeExport.Pages(count: output.count, page: { output.page($0) }, fields: { output.fieldValues(on: $0) }, record: { output.records(on: $0)[0] })
        let summary = try MergeExport().write(pages, mode: .filePerRecord(pattern: "invoice-{order_id}"), to: directory)
        #expect(summary.files.map(\.lastPathComponent) == ["invoice-A1.pdf", "invoice-é.pdf"])
        #expect(PDFDocument(url: summary.files[0])?.pageCount == 1)
        #expect(a.sent.count == sent, "a merge to PDF writes no change")
        #expect(throws: PageSetupError.notAPage(.zero)) { try MergeOutput(state: a.state, records: records, templates: []) }
        #expect(throws: PageSetupError.notAPage(block)) { try MergeOutput(state: a.state, records: records, templates: [block]) }
        let sparse = try MergeOutput(state: a.state, records: RecordSet(model: DataModel(a.state), source: nil, raw: []), templates: [page])
        #expect(sparse.count == 0 && sparse.issues().isEmpty)
    }
}
