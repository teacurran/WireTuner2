import Foundation

// DATA-003: the codec of embedded records (data-merge.adoc, `EmbeddedRecords`: a blob of
// `text/csv` -- UTF-8, header row -- or `application/json`) and of a pasted table (TSV).  These
// are the records every collaborator can read offline.  DATA-004's streaming file readers (with
// delimiter and encoding detection) are separate; this reads and writes the blobs the document
// itself carries.

/// Records as a table: column names and rows, read from or written to CSV, TSV or JSON.
public struct DataTable: Hashable, Sendable {
    public var columns: [String]
    public var records: [DataRecord]

    public init(columns: [String], records: [DataRecord]) {
        self.columns = columns
        self.records = records
    }

    /// Why a blob could not be read.
    public enum ReadError: Error, Hashable, Sendable {
        /// Not UTF-8 text.
        case encoding
        /// JSON that is not an array of objects (or an object with such an array under
        /// `recordsPath`).
        case shape
        /// A media type other than `text/csv` and `application/json`.
        case mediaType(String)
    }

    // MARK: Delimited text

    /// Parses delimited text (RFC 4180: quoted fields, doubled quotes, newlines inside quotes;
    /// CRLF or LF rows).  With `headerRow` the first row names the columns, else they are
    /// `column_1`, `column_2` ...  A value that is empty reads as absent.  A byte-order mark is
    /// skipped.
    public static func delimited(_ text: String, delimiter: Character = ",", headerRow: Bool = true) -> DataTable {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var atFieldStart = true
        var iterator = text.hasPrefix("\u{FEFF}") ? Substring(text.dropFirst()).makeIterator() : Substring(text).makeIterator()
        var pending: Character? = nil
        func endField() {
            row.append(field)
            field = ""
            atFieldStart = true
        }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }
        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else {
                            quoted = false
                            pending = next
                        }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where atFieldStart:
                quoted = true
                atFieldStart = false
            case delimiter:
                endField()
            case "\n", "\r\n", "\r":
                endRow()
            default:
                field.append(character)
                atFieldStart = false
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        guard !rows.isEmpty else { return DataTable(columns: [], records: []) }
        let width = rows.map(\.count).max() ?? 0
        let columns = headerRow ? rows[0] : (1...max(width, 1)).map { "column_\($0)" }
        let body = headerRow ? rows.dropFirst() : rows[...]
        let records = body.map { cells in
            var values: [String: String] = [:]
            for (column, cell) in zip(columns, cells) where !cell.isEmpty && values[column] == nil {
                values[column] = cell
            }
            return DataRecord(values)
        }
        return DataTable(columns: columns, records: records)
    }

    /// A pasted table: tab-separated rows, the first naming the columns.
    public static func pasted(_ text: String) -> DataTable {
        delimited(text, delimiter: "\t", headerRow: true)
    }

    /// The table as CSV (RFC 4180, CRLF rows, a header row; fields quoted when they hold the
    /// delimiter, a quote or a line break).  `bom` prefixes a UTF-8 byte-order mark (for
    /// spreadsheets, *Export Data…*).
    public func csv(delimiter: Character = ",", bom: Bool = false) -> String {
        func quote(_ value: String) -> String {
            guard value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r") else { return value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = [columns.map(quote).joined(separator: String(delimiter))]
        for record in records {
            lines.append(columns.map { quote(record[$0] ?? "") }.joined(separator: String(delimiter)))
        }
        return (bom ? "\u{FEFF}" : "") + lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: JSON

    /// Reads JSON records: an array of objects, or the array at `recordsPath` (dot-separated
    /// member names; `data`, `result.items`).  Each member's value is its JSON text form
    /// (strings unquoted, numbers and booleans as written, objects and arrays as compact JSON);
    /// null is absent.  Columns are the members in first-seen order.
    public static func json(_ data: Data, recordsPath: String = "") throws -> DataTable {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { throw ReadError.shape }
        var node: Any = root
        for member in recordsPath.split(separator: ".").map(String.init) where !member.isEmpty && member != "$" {
            guard let object = node as? [String: Any], let next = object[member] else { throw ReadError.shape }
            node = next
        }
        guard let array = node as? [Any] else { throw ReadError.shape }
        var columns: [String] = []
        var seen: Set<String> = []
        var records: [DataRecord] = []
        for item in array {
            guard let object = item as? [String: Any] else { throw ReadError.shape }
            var values: [String: String] = [:]
            for key in object.keys.sorted() {
                if seen.insert(key).inserted { columns.append(key) }
                if let text = Self.jsonText(object[key]!) { values[key] = text }
            }
            records.append(DataRecord(values))
        }
        return DataTable(columns: columns, records: records)
    }

    /// The table as a JSON array of objects of strings, members in column order.
    public func json() -> Data {
        var out = "["
        for (index, record) in records.enumerated() {
            if index > 0 { out += "," }
            let members = columns.compactMap { column in record[column].map { Self.quoted(column) + ":" + Self.quoted($0) } }
            out += "{" + members.joined(separator: ",") + "}"
        }
        return Data((out + "]").utf8)
    }

    /// Reads an embedded blob of `mediaType`.
    public static func embedded(_ data: Data, mediaType: String) throws -> DataTable {
        switch mediaType {
        case "text/csv":
            guard let text = String(data: data, encoding: .utf8) else { throw ReadError.encoding }
            return delimited(text)
        case "application/json":
            return try json(data)
        default:
            throw ReadError.mediaType(mediaType)
        }
    }

    /// The first `count` records (an embedded sample: five by default).
    public func prefix(_ count: Int) -> DataTable {
        DataTable(columns: columns, records: Array(records.prefix(count)))
    }

    private static func quoted(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}
