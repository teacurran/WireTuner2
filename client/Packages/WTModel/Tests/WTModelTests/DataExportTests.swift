import Foundation
import Testing
import WTCRDT
@testable import WTModel

/// DATA-022: *Export Data…* -- the resolved records with field and range selection and the optional
/// `record` column, read back as a CSV source to the same records.
@Suite struct DataExportTests {
    @Test func theExportReimportedResolvesToTheSameRecords() throws {
        var a = Replica(0xA)
        let ids = try DataFixture.fields(&a, ["name", "amount", "city"], kinds: [.text, .number, .text])
        try a.perform(SetFieldFormat(ids[1], pattern: "#,##0.00"))
        let raw = [DataRecord(["name": "Zoë \"Z\"", "amount": "1234.5", "city": "Köln, DE"]), DataRecord(["name": "Bo", "amount": "7"]),
                   DataRecord(["name": "Cy", "amount": "12", "city": "Oslo"])]
        let locale = Locale(identifier: "en_US")
        let records = RecordSet(model: DataModel(a.state), source: nil, raw: raw, locale: locale, timeZone: TimeZone(identifier: "UTC")!)
        let all = DataExport()
        let csv = all.csv(records)
        #expect(csv.hasPrefix("\u{FEFF}"), "a byte-order mark for spreadsheets")
        #expect(all.table(records).columns == ["record", "name", "amount", "city"])
        // Re-imported as a CSV source with plain text fields of the same names, the records read the
        // same formatted values.
        let back = DataTable.delimited(String(csv.dropFirst()))
        #expect(back.columns == ["record", "name", "amount", "city"] && back.records.count == 3)
        var b = Replica(0xB)
        let plain = try DataFixture.fields(&b, ["name", "amount", "city"])
        let reread = RecordSet(model: DataModel(b.state), source: nil, raw: back.records, locale: locale)
        for (original, copy) in zip(records.records, reread.records) {
            for (field, copied) in zip(ids, plain) { #expect(original.value(field).text == copy.value(copied).text) }
        }
        #expect(back.records[0]["record"] == "1" && back.records[1]["city"] == nil, "an empty value writes an empty cell")
        // Fields and a range, without the record column.
        let some = DataExport(fields: [ids[2], ids[0]], range: 2...9, recordColumn: false)
        let table = some.table(records)
        #expect(table.columns == ["name", "city"], "the panel's order")
        #expect(table.records.map { $0["name"] } == ["Bo", "Cy"] && some.rows(of: records).map(\.number) == [2, 3])
        #expect(DataExport(range: 5...6).table(records).records.isEmpty)
    }
}
