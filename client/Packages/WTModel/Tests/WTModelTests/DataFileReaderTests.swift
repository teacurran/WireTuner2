import Foundation
import Testing
@testable import WTModel
import WTProto

/// DATA-004: the CSV/TSV reader with encoding and delimiter detection, the JSON reader and the
/// JSONPath subset (the server's shared vectors, unchanged), and file bookmarks.
@Suite struct DataFileReaderTests {
    static func file(_ name: String, _ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "DataFileReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    static func utf16(_ text: String, littleEndian: Bool, bom: Bool) -> Data {
        var data = Data(bom ? (littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]) : [])
        for unit in text.utf16 {
            data.append(contentsOf: littleEndian ? [UInt8(unit & 0xFF), UInt8(unit >> 8)] : [UInt8(unit >> 8), UInt8(unit & 0xFF)])
        }
        return data
    }

    // MARK: Encodings and delimiters

    @Test func encodingsAreDetectedByBomValidityAndFallback() {
        #expect(DataTextEncoding.detect(Data([0xEF, 0xBB, 0xBF, 0x41])) == (.utf8, 3))
        #expect(DataTextEncoding.detect(Data([0xFF, 0xFE, 0x41, 0x00])) == (.utf16LittleEndian, 2))
        #expect(DataTextEncoding.detect(Data([0xFE, 0xFF, 0x00, 0x41])) == (.utf16BigEndian, 2))
        #expect(DataTextEncoding.detect(Self.utf16("name,city\n", littleEndian: true, bom: false)) == (.utf16LittleEndian, 0))
        #expect(DataTextEncoding.detect(Self.utf16("name,city\n", littleEndian: false, bom: false)) == (.utf16BigEndian, 0))
        #expect(DataTextEncoding.detect(Data("Zoë,Köln".utf8)) == (.utf8, 0))
        #expect(DataTextEncoding.detect(Data("Zoë".utf8).dropLast()) == (.utf8, 0), "a sequence cut at the end of the sample is allowed")
        #expect(DataTextEncoding.detect(Data([0x5A, 0x6F, 0xEB, 0x2C, 0x4B])) == (.windows1252, 0), "Zoë in Windows-1252 is not UTF-8")
        #expect(DataTextEncoding.detect(Data([0xC3, 0x28])).encoding == .windows1252, "a bad continuation byte")
        #expect(DataTextEncoding.detect(Data([0xFF, 0x41])).encoding == .windows1252, "a byte UTF-8 never starts with")
        #expect(DataTextEncoding.detect(Data()) == (.utf8, 0))
        #expect(DataTextEncoding.allCases.map(\.title) == ["UTF-8", "UTF-16 (little-endian)", "UTF-16 (big-endian)", "Windows Latin-1"])
    }

    @Test func theDelimiterIsTheMostConsistentSplit() {
        #expect(DataFileReader.detectDelimiter("a,b,c\n1,2,3\n4,5,6\n") == ",")
        #expect(DataFileReader.detectDelimiter("a;b;c\n1,5;2;3\n4;5,5;6\n") == ";", "decimal commas do not fool it")
        #expect(DataFileReader.detectDelimiter("a\tb\n1\t2\n") == "\t")
        #expect(DataFileReader.detectDelimiter("just one column\nanother\n") == ",", "nothing splits: comma")
        #expect(DataFileReader.detectDelimiter("\"a;b\",c\n\"1;2\",3\n") == ",", "delimiters inside quotes do not count")
        let many = (0..<80).map { "\($0),x" }.joined(separator: "\n")
        #expect(DataFileReader.detectDelimiter(many) == ",", "only the first 50 rows are compared")
    }

    @Test func theByteParserHandlesQuotesAndLineBreaksInAnyChunks() {
        let text = "name,note\r\n\"Ann\",\"say \"\"hi\"\"\"\r\n\r\nBo,\"two\nlines, and a comma\"\nCy,plain\"quote\nlast,row"
        var rows: [[String]] = []
        var parser = DelimitedByteParser(delimiter: UInt8(ascii: ","))
        for byte in text.utf8 { parser.feed([byte]) { rows.append($0.map { String(decoding: $0, as: UTF8.self) }); return true } }
        parser.finish { rows.append($0.map { String(decoding: $0, as: UTF8.self) }); return true }
        #expect(rows == [["name", "note"], ["Ann", "say \"hi\""], ["Bo", "two\nlines, and a comma"], ["Cy", "plain\"quote"], ["last", "row"]])
        // Stopping mid-stream.
        var stopped = DelimitedByteParser(delimiter: UInt8(ascii: ","))
        var count = 0
        #expect(!stopped.feed(Array("a\nb\nc\n".utf8)) { _ in count += 1; return count < 2 })
        #expect(count == 2)
        var empty = DelimitedByteParser(delimiter: UInt8(ascii: ","))
        empty.finish { _ in Issue.record("nothing to emit"); return true }
        // A quoted field left open at the end is closed.
        var open = DelimitedByteParser(delimiter: UInt8(ascii: ","))
        var last: [String] = []
        open.feed(Array("\"unterminated".utf8)) { _ in true }
        open.finish { last = $0.map { String(decoding: $0, as: UTF8.self) }; return true }
        #expect(last == ["unterminated"])
    }

    // MARK: Files

    @Test func csvFilesInEveryEncodingReadAlike() throws {
        let text = "first_name;city\nZoë;Köln\n\"Ann\nMarie\";Paris\n"
        let expected = [DataRecord(["first_name": "Zoë", "city": "Köln"]), DataRecord(["first_name": "Ann\nMarie", "city": "Paris"])]
        let bomUTF8 = try Self.file("bom.csv", Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8))
        let plain = try Self.file("plain.csv", Data(text.utf8))
        let little = try Self.file("little.csv", Self.utf16(text, littleEndian: true, bom: true))
        let big = try Self.file("big.csv", Self.utf16(text, littleEndian: false, bom: true))
        let latin = try Self.file("latin.csv", text.data(using: .windowsCP1252)!)
        for (url, encoding) in [(bomUTF8, DataTextEncoding.utf8), (plain, .utf8), (little, .utf16LittleEndian), (big, .utf16BigEndian), (latin, .windows1252)] {
            let contents = try DataFileReader.read(url, options: DataFileOptions())
            #expect(contents.encoding == encoding && contents.delimiter == ";", "\(url.lastPathComponent)")
            #expect(contents.table.columns == ["first_name", "city"] && contents.table.records == expected, "\(url.lastPathComponent)")
        }
        // Settings given are used as they are; no header row names the columns column_1 ...
        let given = try DataFileReader.read(plain, options: DataFileOptions(delimiter: ";", encoding: "utf-8", headerRow: false), limit: 2)
        #expect(given.table.columns == ["column_1", "column_2"] && given.table.records.count == 2 && given.table.records[0]["column_1"] == "first_name")
        let limited = try DataFileReader.read(plain, options: DataFileOptions(), limit: 1)
        #expect(limited.table.records.count == 1)
        let tsv = try Self.file("t.tsv", Data("a\tb\n1\t\n".utf8))
        #expect(try DataFileReader.detect(tsv, format: .tsv).delimiter == "\t")
        let read = try DataFileReader.read(tsv, options: DataFileOptions(format: .tsv))
        #expect(read.table.records == [DataRecord(["a": "1"])], "an empty value is absent")
        #expect(try DataFileReader.read(try Self.file("empty.csv", Data()), options: DataFileOptions()).table.columns.isEmpty)
        #expect(throws: DataFileError.unreadable("missing.csv")) { try DataFileReader.read(URL(filePath: "/no/such/missing.csv"), options: DataFileOptions()) }
        #expect(throws: DataFileError.unreadable("gone.csv")) { try DataFileReader.forEachRow(URL(filePath: "/no/such/gone.csv"), encoding: .utf8, delimiter: ",") { _ in true } }
    }

    @Test func utf16SurrogatesAcrossChunksSurvive() throws {
        // A surrogate pair straddling the 1 MiB chunk boundary, then more rows.
        let head = String(repeating: "a", count: (DataFileReader.chunkSize - 2) / 2 - 1)
        let text = "x\n" + head + "😀\nb\n"
        let url = try Self.file("wide.csv", Self.utf16(text, littleEndian: true, bom: true))
        var rows: [String] = []
        try DataFileReader.forEachRow(url, encoding: .utf16LittleEndian, delimiter: ",") { rows.append($0[0]); return true }
        #expect(rows == ["x", head + "😀", "b"])
        let big = try Self.file("wide-be.csv", Self.utf16(text, littleEndian: false, bom: false))
        var count = 0
        try DataFileReader.forEachRow(big, encoding: .utf16BigEndian, delimiter: ",") { _ in count += 1; return count < 2 }
        #expect(count == 2, "stopping ends the read")
    }

    @Test func aLargeFileStreamsRowByRow() throws {
        var text = "id,name\n"
        for index in 0..<200_000 { text += "\(index),name \(index)\n" }
        let url = try Self.file("large.csv", Data(text.utf8))
        var count = 0
        var last = ""
        try DataFileReader.forEachRow(url, encoding: .utf8, delimiter: ",") { row in
            count += 1
            last = row[0]
            return true
        }
        #expect(count == 200_001 && last == "199999")
    }

    @Test func jsonFilesReadThroughTheirRecordsPath() throws {
        let json = #"{"result":{"items":[{"id":1,"name":"Ann","address":{"city":"Paris"},"tags":["a","b"]},{"id":2,"name":"Bo","$ref":"x"}]}}"#
        let url = try Self.file("data.json", Data(json.utf8))
        let contents = try DataFileReader.read(url, options: DataFileOptions(format: .json, recordsPath: "$.result.items"), paths: ["$.address.city", "$.tags[*]", "name"])
        #expect(contents.table.columns == ["id", "name", "address", "tags", "$ref"])
        #expect(contents.table.records[0] == DataRecord(["id": "1", "name": "Ann", "address": #"{"city":"Paris"}"#, "tags": #"["a","b"]"#,
                                                         "$.address.city": "Paris", "$.tags[*]": #"["a","b"]"#]))
        #expect(contents.table.records[1]["$ref"] == "x", "a member whose name starts with $ is a column, not a path")
        #expect(try DataFileReader.read(url, options: DataFileOptions(format: .json, recordsPath: "result.items"), limit: 1).table.records.isEmpty,
                "a bare records path names one member")
        let limited = try DataFileReader.read(url, options: DataFileOptions(format: .json, recordsPath: "$.result.items"), limit: 1)
        #expect(limited.table.records.count == 1 && limited.encoding == .utf8)
        let wide = try Self.file("wide.json", Self.utf16(#"[{"a":"é"}]"#, littleEndian: true, bom: true))
        #expect(try DataFileReader.read(wide, options: DataFileOptions(format: .json)).table.records == [DataRecord(["a": "é"])])
        #expect(try DataFileReader.detect(wide, format: .json).delimiter == nil)
        #expect(throws: JSONPath.Refusal(kind: .filter, path: "$[?(@.a)]")) {
            try DataFileReader.read(url, options: DataFileOptions(format: .json), paths: ["$[?(@.a)]"])
        }
        #expect(throws: DataFileError.unreadable("none.json")) { try DataFileReader.read(URL(filePath: "/no/none.json"), options: DataFileOptions(format: .json)) }
        // Over 64 MiB: refused with the size.
        let huge = try Self.file("huge.json", Data())
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(DataJSON.maxFileSize + 1))
        try handle.close()
        #expect(throws: DataFileError.tooLarge(bytes: DataJSON.maxFileSize + 1)) { try DataFileReader.read(huge, options: DataFileOptions(format: .json)) }
        #expect(DataFileError.tooLarge(bytes: DataJSON.maxFileSize + 1).description.contains("64 MB"))
        #expect(DataFileError.unreadable("x.csv").description == "“x.csv” could not be read")
        #expect(DataFileError.bookmarkUnresolved.description.contains("could not be found"))
    }

    @Test func optionsComeFromTheFileSource() {
        var file = Wiretuner_Doc_V1_FileSource()
        file.delimiter = ";"
        file.encoding = "windows-1252"
        file.headerRow = true
        file.recordsPath = "$.x"
        #expect(DataFileOptions(file) == DataFileOptions(format: .csv, delimiter: ";", encoding: "windows-1252", headerRow: true, recordsPath: "$.x"))
        file.format = .json
        #expect(DataFileOptions(file).format == .json)
        #expect(DataFileOptions.format(forFileName: "a.JSON") == .json && DataFileOptions.format(forFileName: "a.tsv") == .tsv
            && DataFileOptions.format(forFileName: "a.tab") == .tsv && DataFileOptions.format(forFileName: "a.csv") == .csv)
    }

    // MARK: JSON and JSONPath

    struct Vectors: Decodable {
        struct PathCase: Decodable {
            var name: String
            var document: String?
            var path: String
            var matches: [String]?
            var error: String?
        }

        struct RecordCase: Decodable {
            var name: String
            var document: String
            var records_path: String
            var paths: [String]
            var records: [[String: String]]
        }

        var paths: [PathCase]
        var records: [RecordCase]
    }

    static var vectorsURL: URL {
        var url = URL(filePath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url.appending(path: "server/api/src/test/resources/jsonpath-vectors/vectors.json")
    }

    @Test func theSharedJSONPathVectorsPassUnchanged() throws {
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: Self.vectorsURL))
        #expect(vectors.paths.count >= 40 && vectors.records.count >= 9)
        for vector in vectors.paths {
            let root = try DataJSON.parse(Data((vector.document ?? "null").utf8))
            do {
                let path = try JSONPath(vector.path)
                #expect(vector.error == nil, "\(vector.name): refused")
                #expect(path.matches(in: root).map(\.compact) == vector.matches, "\(vector.name)")
            } catch let refusal as JSONPath.Refusal {
                #expect(refusal.kind.rawValue == vector.error, "\(vector.name)")
                #expect(!refusal.description.isEmpty)
            }
        }
        for vector in vectors.records {
            let root = try DataJSON.parse(Data(vector.document.utf8))
            let records = try DataJSON.records(in: root, recordsPath: vector.records_path, paths: vector.paths)
            #expect(records.map(\.values) == vector.records, "\(vector.name)")
        }
    }

    @Test func refusalsAreDescribed() {
        for kind in [JSONPath.Refusal.Kind.filter, .script, .slice, .union, .negativeIndex, .syntax] {
            #expect(JSONPath.Refusal(kind: kind, path: "$").description.contains("“$”"))
        }
    }

    @Test func theParserKeepsOrderAndSourceTextAndRefusesBadJSON() throws {
        let node = try DataJSON.parse(Data([0xEF, 0xBB, 0xBF] + Array(#" { "b" : 1.50e+3 , "a" : [ true , false , null , -0 , "\ud83d\ude00\/" ] , "e" : { } , "f" : [ ] } "#.utf8)))
        #expect(node.compact == #"{"b":1.50e+3,"a":[true,false,null,-0,"😀/"],"e":{},"f":[]}"#)
        #expect(node == (try DataJSON.parse(Data(node.compact.utf8))) && Set([node]).count == 1)
        #expect(node.member("b")?.recordText == "1.50e+3" && node.member("zz") == nil && JSONNode.null.recordText == nil && JSONNode.array([]).member("a") == nil)
        for bad in ["", "{", "[1,", "[1 2]", "{\"a\" 1}", "{\"a\":1,}", "{1:2}", "tru", "01x", "-", "1.", "1e", "\"abc", "\"\\x\"", "\"\\u12\"", "\"\\ud83dx\"",
                    "\"\\ud83d\\u0041\"", "\"a\u{01}\"", "[1]]", "{\"a\":1 \"b\":2}", "[1;2]", "\"\\"] {
            #expect(throws: JSONSyntaxError.self, "\(bad)") { try DataJSON.parse(Data(bad.utf8)) }
        }
        #expect(JSONSyntaxError(offset: 3).description.contains("byte 3"))
        let deep = String(repeating: "[", count: 150) + String(repeating: "]", count: 150)
        #expect(throws: JSONSyntaxError.self) { try DataJSON.parse(Data(deep.utf8)) }
    }

    @Test func recordsPathsAndColumns() throws {
        let root = try DataJSON.parse(Data(#"{"data":[{"a":1,"b":2},{"c":3},7]}"#.utf8))
        #expect(try DataJSON.records(in: root, recordsPath: "$.data").count == 3)
        #expect(DataJSON.columns(of: try DataJSON.records(in: root, recordsPath: "$.data")) == ["a", "b", "c"])
        #expect(DataJSON.columns(of: try DataJSON.records(in: root, recordsPath: "$.data"), sample: 1) == ["a", "b"])
        #expect(try DataJSON.records(in: root, recordsPath: "$.data[0].a").map(\.compact) == ["1"])
        let path = try JSONPath("$..a")
        #expect(!path.isDefinite && path.text(in: .object([])) == nil)
        #expect(try JSONPath("$.data[*]").isDefinite == false && JSONPath("$.data[0]['x']").isDefinite)
        #expect(try JSONPath("plain name").steps == [.member("plain name")])
    }

    // MARK: Bookmarks

    @Test func bookmarksFindTheFileAgain() throws {
        let url = try Self.file("bookmarked.csv", Data("a\n1\n".utf8))
        let bookmark = try DataFileBookmarks.make(url)
        let resolved = try DataFileBookmarks.resolve(bookmark)
        #expect(resolved.url.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path)
        let rows = try DataFileBookmarks.withAccess(bookmark) { try DataFileReader.read($0, options: DataFileOptions()).table.records.count }
        #expect(rows == 1)
        #expect(throws: DataFileError.bookmarkUnresolved) { try DataFileBookmarks.resolve(Data("not a bookmark".utf8)) }
    }
}
