import Foundation
import Testing
import WTCRDT
@testable import WTModel
import WTProto

/// DATA-003: record resolution -- mapping, coercion, formats in two locales, Boolean spellings,
/// transforms -- and the embedded-records codec.
@Suite struct DataRecordTests {
    struct Upper: FieldTransforming {
        func transform(script: OpID, value: String?, record: [String: String], field: String) throws -> String? {
            if field == "greeting" { return "\(record["title"] ?? "") \(record["last"] ?? "")" }
            if value == "boom" { throw ScriptError.exception(message: "boom", line: 1, column: 1) }
            if value == "slow" { throw ScriptError.timeout }
            return value?.uppercased()
        }
    }

    @Test func formatsInTwoLocalesAndBooleans() throws {
        var a = Replica(0xA)
        let ids = try DataFixture.fields(&a, ["amount", "day", "vip", "stamp", "plain"], kinds: [.number, .date, .boolean, .date, .number])
        try a.perform(SetFieldFormat(ids[0], pattern: "#,##0.00"))
        try a.perform(SetFieldFormat(ids[1], pattern: "d MMMM yyyy"))
        try a.perform(SetFieldFormat(ids[3], pattern: "Short"))
        let raw = [DataRecord(["amount": "1234.5", "day": "2026-09-21", "vip": "Yes", "stamp": "2026-09-21T14:30:00Z", "plain": "7"]),
                   DataRecord(["amount": "abc", "day": "not a date", "vip": "no"])]
        let us = RecordSet(model: DataModel(a.state), source: nil, raw: raw, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        let first = try #require(us.record(at: 0))
        #expect(first.value(ids[0]).text == "1,234.50" && first.value(ids[1]).text == "21 September 2026" && first.value(ids[2]).isTrue)
        #expect(first.value(ids[3]).text == "9/21/26" && first.value(ids[4]).text == "7", "an empty pattern places the value as it is")
        let second = try #require(us.record(at: 5), "past the last record reads as the last")
        #expect(second.number == 2 && second.value(ids[0]).text == "abc" && !second.value(ids[2]).isTrue && second.value(ids[3]).text == "")
        #expect(us.issues == [MergeIssue(record: 2, field: "amount", kind: .unparsableNumber(value: "abc")),
                              MergeIssue(record: 2, field: "day", kind: .unparsableDate(value: "not a date"))])
        #expect(us.count == 2 && !us.isEmpty && us.record(at: -1)?.number == 1)
        // The field's own locale wins over the merging user's.
        try a.perform(SetFieldFormat(ids[0], locale: "de_DE"))
        try a.perform(SetFieldFormat(ids[1], locale: "de_DE"))
        let de = RecordSet(model: DataModel(a.state), source: nil, raw: raw, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(de.records[0].value(ids[0]).text == "1.234,50" && de.records[0].value(ids[1]).text == "21 September 2026")
        // Boolean spellings.
        for spelling in ["true", "YES", "1", "x", " on "] { #expect(DataCoercion.isTrue(spelling), "\(spelling)") }
        for spelling in ["false", "no", "0", "", "maybe"] { #expect(!DataCoercion.isTrue(spelling), "\(spelling)") }
        #expect(RecordSet(model: DataModel(a.state), source: nil, raw: []).record(at: 0) == nil)
    }

    @Test func parsingNumbersAndDates() {
        let de = Locale(identifier: "de_DE")
        #expect(DataCoercion.number("1e3", locale: de) == 1000 && DataCoercion.number("1.234,5", locale: de) == 1234.5)
        #expect(DataCoercion.number("  ", locale: de) == nil && DataCoercion.number("x", locale: de) == nil)
        #expect(DataCoercion.date("2026-09-21T14:30:00.250Z", locale: de)?.dateOnly == false)
        #expect(DataCoercion.date("2026-09-21T14:30:00+02:00", locale: de) != nil)
        #expect(DataCoercion.date("21.09.26", locale: de)?.dateOnly == true)
        #expect(DataCoercion.date("", locale: de) == nil)
        #expect(DataCoercion.formatDate("2026-09-21", pattern: "medium", locale: Locale(identifier: "en_US"), timeZone: .current) == "Sep 21, 2026")
        #expect(DataCoercion.formatDate("2026-09-21", pattern: "LONG", locale: Locale(identifier: "en_US"), timeZone: .current) == "September 21, 2026")
        #expect(DataCoercion.formatDate("2026-09-21", pattern: "", locale: de, timeZone: .current) == "2026-09-21")
        #expect(DataCoercion.formatNumber("-3", pattern: "0.0", locale: Locale(identifier: "en_US")) == "-3.0")
        #expect(DataCoercion.formatNumber("0.25", pattern: "0%", locale: Locale(identifier: "en_US")) == "25%")
    }

    @Test func mappingAndTransforms() throws {
        var a = Replica(0xA)
        let ids = try DataFixture.fields(&a, ["title", "last", "greeting", "code"])
        let script = try #require(try a.perform(SaveScript(name: "T", source: ""))).createdNodes[0]
        for id in ids.dropFirst(2) { try a.perform(SetFieldTransform(id, script: script)) }
        let source = try DataFixture.source(&a)
        try a.perform(SetMapping(source, field: ids[1], path: "surname"))
        let model = DataModel(a.state)
        let raw = [DataRecord(["title": "Dr", "surname": "Who", "code": "ab"]), DataRecord(["code": "boom"]), DataRecord(["code": "slow"])]
        let set = RecordSet(model: model, source: model.activeSource, raw: raw, transforms: Upper())
        #expect(set.records[0].value(ids[2]).text == "Dr Who" && set.records[0].value(ids[3]).text == "AB")
        #expect(set.records[0].byName == ["title": "Dr", "last": "Who", "code": "ab"])
        #expect(set.records[1].value(ids[3]).text == "boom", "a transform that throws leaves the raw value")
        #expect(set.issues.contains(MergeIssue(record: 2, field: "code", kind: .transformFailed(message: "boom (line 1, column 1)"))))
        #expect(set.issues.contains(MergeIssue(record: 3, field: "code", kind: .transformTimeout)))
        // Without a transformer the raw values are placed.
        #expect(RecordSet(model: model, source: model.activeSource, raw: raw).records[0].value(ids[3]).text == "ab")
    }

    @Test func suggestedFieldsAndGuessing() throws {
        var a = Replica(0xA)
        try DataFixture.fields(&a, ["name"])
        let raw = [DataRecord(["name": "A", "Zip Code": "12345", "vip": "yes", "joined": "2026-01-02", "photo": "a.png", "site": "https://x.y", "1st": "q"]),
                   DataRecord(["name": "B", "Zip Code": "54321", "vip": "no", "joined": "2026-02-03", "photo": "b.JPG", "site": "http://z", "1st": "r"])]
        let suggested = RecordSet.suggestedFields(for: raw, model: DataModel(a.state), source: nil)
        let kinds = Dictionary(uniqueKeysWithValues: suggested.map { ($0.name, $0.kind) })
        #expect(kinds == ["Zip_Code": .number, "vip": .boolean, "joined": .date, "photo": .image, "site": .link, "_1st": .text])
        #expect(RecordSet.suggestedFields(for: raw, columns: ["name", "a b", "a_b"], model: DataModel(a.state), source: nil).map(\.name) == ["a_b"])
        #expect(DataCoercion.guess([]) == .text && DataCoercion.guess(["1", "0"]) == .number && DataCoercion.guess([" ", "x y"]) == .text)
        #expect(RecordSet.fieldName(for: "") == "_" && RecordSet.fieldName(for: String(repeating: "a", count: 70)).count == 64)
        try a.perform(AddFields(suggested))
        #expect(DataModel(a.state).fields.count == 7)
    }

    @Test func delimitedJSONAndEmbeddedCodec() throws {
        let csv = "\u{FEFF}name,note,city\r\n\"Doe, Jane\",\"said \"\"hi\"\"\nthen left\",Paris\r\nBo,,\r\n\r\n"
        let table = DataTable.delimited(csv)
        #expect(table.columns == ["name", "note", "city"] && table.records.count == 2)
        #expect(table.records[0]["name"] == "Doe, Jane" && table.records[0]["note"] == "said \"hi\"\nthen left" && table.records[1]["note"] == nil)
        let round = DataTable.delimited(table.csv())
        #expect(round == table)
        #expect(table.csv(bom: true).hasPrefix("\u{FEFF}name,note,city\r\n"))
        let pasted = DataTable.pasted("a\tb\n1\t2\n3")
        #expect(pasted.columns == ["a", "b"] && pasted.records.map { $0["a"] } == ["1", "3"])
        let headless = DataTable.delimited("x;y\nz", delimiter: ";", headerRow: false)
        #expect(headless.columns == ["column_1", "column_2"] && headless.records.count == 2)
        #expect(DataTable.delimited("").records.isEmpty && DataTable.delimited("\"open").records.isEmpty)
        #expect(DataTable.delimited("a\n\"q\"x").records[0]["a"] == "qx")
        let json = Data(#"{"data": [{"n": "A", "age": 3, "ok": true, "tags": ["x"], "none": null}, {"n": "B"}]}"#.utf8)
        let parsed = try DataTable.json(json, recordsPath: "data")
        #expect(parsed.columns == ["age", "n", "none", "ok", "tags"] && parsed.records[0]["age"] == "3" && parsed.records[0]["ok"] == "true")
        #expect(parsed.records[0]["tags"] == #"["x"]"# && parsed.records[0]["none"] == nil)
        #expect(throws: DataTable.ReadError.shape) { try DataTable.json(json, recordsPath: "missing") }
        #expect(throws: DataTable.ReadError.shape) { try DataTable.json(Data("[1]".utf8)) }
        #expect(throws: DataTable.ReadError.shape) { try DataTable.json(Data("{".utf8)) }
        #expect(throws: DataTable.ReadError.shape) { try DataTable.json(Data("{}".utf8)) }
        let written = DataTable(columns: ["k", "q"], records: [DataRecord(["k": "a\"b\\\n\r\t\u{01}"]), DataRecord(["q": "z"])]).json()
        let back = try DataTable.json(written)
        #expect(back.records[0]["k"] == "a\"b\\\n\r\t\u{01}" && back.records[1]["q"] == "z")
        #expect(try DataTable.embedded(Data("a\n1".utf8), mediaType: "text/csv").records.count == 1)
        #expect(try DataTable.embedded(written, mediaType: "application/json").records.count == 2)
        #expect(throws: DataTable.ReadError.mediaType("x")) { try DataTable.embedded(Data(), mediaType: "x") }
        #expect(throws: DataTable.ReadError.encoding) { try DataTable.embedded(Data([0xFF, 0xFE, 0xFD]), mediaType: "text/csv") }
        #expect(table.prefix(1).records.count == 1)
    }
}
