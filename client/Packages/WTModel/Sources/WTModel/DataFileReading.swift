import Foundation
import WTProto

// DATA-004: file sources on this Mac (data-merge.adoc, "A CSV or TSV file", "A JSON file";
// "Parsers (client-side sources)").  CSV and TSV are read row by row -- the byte-level RFC 4180
// state machine never holds more than one row -- after the encoding (byte-order mark, then UTF-8
// validity, then Windows-1252) and the delimiter (the most consistent column count over the first
// 50 rows among `,`, `;` and tab) are detected.  JSON files up to 64 MiB are parsed once and
// addressed with the JSONPath subset.  A file is remembered by a security-scoped bookmark
// (`FileSource.bookmark`, local only), never by its path.

/// A text encoding a file source can be in (`FileSource.encoding` holds its IANA name).
public enum DataTextEncoding: String, Hashable, Sendable, CaseIterable {
    case utf8 = "utf-8"
    case utf16LittleEndian = "utf-16le"
    case utf16BigEndian = "utf-16be"
    case windows1252 = "windows-1252"

    /// The sheet's pop-up title.
    public var title: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16LittleEndian: "UTF-16 (little-endian)"
        case .utf16BigEndian: "UTF-16 (big-endian)"
        case .windows1252: "Windows Latin-1"
        }
    }

    var foundation: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16LittleEndian: .utf16LittleEndian
        case .utf16BigEndian: .utf16BigEndian
        case .windows1252: .windowsCP1252
        }
    }

    /// The encoding of bytes starting `prefix`, and how many byte-order-mark bytes to skip: a BOM
    /// decides; else valid UTF-8 (a sequence cut off at the end of the sample is allowed); else
    /// a BOM-less UTF-16 guessed from zero bytes on one side; else Windows-1252.
    public static func detect(_ prefix: Data) -> (encoding: DataTextEncoding, bom: Int) {
        let bytes = [UInt8](prefix)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if bytes.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if bytes.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        let pairs = bytes.count / 2
        if pairs >= 2 {
            let evenZeros = stride(from: 0, to: pairs * 2, by: 2).count { bytes[$0] == 0 }
            let oddZeros = stride(from: 1, to: pairs * 2, by: 2).count { bytes[$0] == 0 }
            if oddZeros * 10 >= pairs * 3, evenZeros * 10 < pairs { return (.utf16LittleEndian, 0) }
            if evenZeros * 10 >= pairs * 3, oddZeros * 10 < pairs { return (.utf16BigEndian, 0) }
        }
        return (isUTF8(bytes) ? .utf8 : .windows1252, 0)
    }

    /// Whether `bytes` are UTF-8, allowing one incomplete sequence at the very end.
    static func isUTF8(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            let length: Int
            switch byte {
            case 0x00...0x7F: length = 1
            case 0xC2...0xDF: length = 2
            case 0xE0...0xEF: length = 3
            case 0xF0...0xF4: length = 4
            default: return false
            }
            for offset in 1..<length {
                guard index + offset < bytes.count else { return true }
                guard bytes[index + offset] & 0xC0 == 0x80 else { return false }
            }
            index += length
        }
        return true
    }
}

/// The byte-level RFC 4180 reader: quoted fields, doubled quotes, delimiters and line breaks
/// inside quotes, CRLF or LF rows.  Bytes go in in any chunks; each complete row comes out as its
/// fields' bytes.  Valid for ASCII-compatible encodings (UTF-8 and Windows-1252: the structural
/// characters are single bytes that never occur inside a multi-byte sequence).
public struct DelimitedByteParser: Sendable {
    public let delimiter: UInt8
    private var row: [[UInt8]] = []
    private var field: [UInt8] = []
    private var quoted = false
    /// A quote seen inside a quoted field: the next byte decides (another quote, or the end).
    private var quoteInQuoted = false
    private var atFieldStart = true
    private var afterCR = false

    public init(delimiter: UInt8) {
        self.delimiter = delimiter
    }

    /// Feeds `bytes`; `emit` receives each completed row and returns false to stop (the parser is
    /// then left mid-stream).  Returns whether it was not stopped.
    @discardableResult
    public mutating func feed(_ bytes: some Collection<UInt8>, emit: ([[UInt8]]) throws -> Bool) rethrows -> Bool {
        for byte in bytes {
            if afterCR {
                afterCR = false
                if byte == 0x0A { continue }
            }
            if quoteInQuoted {
                quoteInQuoted = false
                if byte == 0x22 {
                    field.append(0x22)
                    continue
                }
                quoted = false
            }
            if quoted {
                if byte == 0x22 { quoteInQuoted = true } else { field.append(byte) }
                continue
            }
            switch byte {
            case 0x22 where atFieldStart:
                quoted = true
                atFieldStart = false
            case delimiter:
                endField()
            case 0x0A, 0x0D:
                afterCR = byte == 0x0D
                if try !endRow(emit) { return false }
            default:
                field.append(byte)
                atFieldStart = false
            }
        }
        return true
    }

    /// Ends the input: a last row without a line break is emitted.
    public mutating func finish(emit: ([[UInt8]]) throws -> Bool) rethrows {
        quoteInQuoted = false
        quoted = false
        if !row.isEmpty || !field.isEmpty { _ = try endRow(emit) }
    }

    private mutating func endField() {
        row.append(field)
        field = []
        atFieldStart = true
    }

    private mutating func endRow(_ emit: ([[UInt8]]) throws -> Bool) rethrows -> Bool {
        endField()
        let done = row
        row = []
        // A blank line is no row.
        if done.count == 1, done[0].isEmpty { return true }
        return try emit(done)
    }
}

/// How a file source is read (`FileSource`'s settings): a detected value is used where one is
/// empty.
public struct DataFileOptions: Hashable, Sendable {
    public var format: Wiretuner_Doc_V1_FileFormat
    /// `,`, `;` or a tab; "" detects.
    public var delimiter: String
    /// An IANA name (`DataTextEncoding`); "" detects.
    public var encoding: String
    public var headerRow: Bool
    /// JSON: the path to the records array; "" is the root.
    public var recordsPath: String

    public init(format: Wiretuner_Doc_V1_FileFormat = .csv, delimiter: String = "", encoding: String = "", headerRow: Bool = true, recordsPath: String = "") {
        self.format = format
        self.delimiter = delimiter
        self.encoding = encoding
        self.headerRow = headerRow
        self.recordsPath = recordsPath
    }

    /// The options a file source stores.
    public init(_ file: Wiretuner_Doc_V1_FileSource) {
        self.init(format: file.format == .unspecified ? .csv : file.format, delimiter: file.delimiter, encoding: file.encoding, headerRow: file.headerRow,
                  recordsPath: file.recordsPath)
    }

    /// The format a file name suggests: `.json` JSON, `.tsv` and `.tab` TSV, else CSV.
    public static func format(forFileName name: String) -> Wiretuner_Doc_V1_FileFormat {
        switch (name as NSString).pathExtension.lowercased() {
        case "json": .json
        case "tsv", "tab": .tsv
        default: .csv
        }
    }
}

/// Why a file source could not be read.
public enum DataFileError: Error, Hashable, Sendable, CustomStringConvertible {
    /// A JSON file over the 64 MiB limit.
    case tooLarge(bytes: Int)
    /// The file could not be opened.
    case unreadable(String)
    /// The bookmark no longer resolves (the file moved to another volume or was deleted).
    case bookmarkUnresolved

    public var description: String {
        switch self {
        case .tooLarge(let bytes):
            "The JSON file is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)); files over 64 MB cannot be read"
        case .unreadable(let name): "“\(name)” could not be read"
        case .bookmarkUnresolved: "The file could not be found on this Mac"
        }
    }
}

/// What reading a file found: the records, and the encoding and delimiter used (detected or
/// given), for the source sheet to show and correct.
public struct DataFileContents: Sendable {
    public var table: DataTable
    public var encoding: DataTextEncoding
    /// CSV and TSV only.
    public var delimiter: Character?
}

/// Reading CSV, TSV and JSON files.
public enum DataFileReader {
    /// How much of a file detection reads.
    public static let sampleSize = 64 * 1024
    /// The rows delimiter detection compares.
    public static let detectionRows = 50
    static let chunkSize = 1 << 20

    /// The delimiter of delimited text: among `,`, `;` and tab, the one whose count of fields is
    /// the same on the most of the first 50 rows (more than one field), preferring more fields and
    /// then that order.  Comma when none splits anything.
    public static func detectDelimiter(_ text: String) -> Character {
        var best: (delimiter: Character, rows: Int, fields: Int) = (",", 0, 0)
        for candidate in [",", ";", "\t"] as [Character] {
            var parser = DelimitedByteParser(delimiter: candidate.asciiValue!)
            var counts: [Int: Int] = [:]
            var seen = 0
            let bytes = Array(text.utf8)
            let rowCount: ([[UInt8]]) -> Bool = { row in
                counts[row.count, default: 0] += 1
                seen += 1
                return seen < detectionRows
            }
            if parser.feed(bytes, emit: rowCount) { parser.finish(emit: rowCount) }
            guard let (fields, rows) = counts.filter({ $0.key > 1 }).max(by: { ($0.value, $0.key) < ($1.value, $1.key) }) else { continue }
            if (rows, fields) > (best.rows, best.fields) { best = (candidate, rows, fields) }
        }
        return best.delimiter
    }

    /// The encoding and delimiter of the file at `url`, from its first 64 KiB.
    public static func detect(_ url: URL, format: Wiretuner_Doc_V1_FileFormat = .csv) throws -> (encoding: DataTextEncoding, delimiter: Character?) {
        let prefix = try sample(url)
        let (encoding, bom) = DataTextEncoding.detect(prefix)
        guard format != .json else { return (encoding, nil) }
        if format == .tsv { return (encoding, "\t") }
        let text = decode(prefix.dropFirst(bom), encoding: encoding, partial: true)
        return (encoding, detectDelimiter(text))
    }

    private static func sample(_ url: URL) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw DataFileError.unreadable(url.lastPathComponent) }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: sampleSize)) ?? Data()
    }

    /// `data` as text in `encoding`; with `partial`, an incomplete sequence at the end is dropped
    /// (a sample cut mid-character).
    static func decode(_ data: Data, encoding: DataTextEncoding, partial: Bool = false) -> String {
        var data = data
        if partial, encoding == .utf8 {
            // Drop an incomplete trailing sequence (at most three bytes).
            for _ in 0..<3 where String(data: data, encoding: .utf8) == nil && !data.isEmpty { data.removeLast() }
        }
        if partial, encoding == .utf16LittleEndian || encoding == .utf16BigEndian, data.count % 2 == 1 { data.removeLast() }
        return String(data: data, encoding: encoding.foundation) ?? String(decoding: data, as: UTF8.self)
    }

    /// Calls `row` with each row of the delimited file at `url`, read in 1 MiB chunks (a file of
    /// any size streams in constant memory); `row` returns false to stop.
    public static func forEachRow(_ url: URL, encoding: DataTextEncoding, delimiter: Character, row: ([String]) throws -> Bool) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw DataFileError.unreadable(url.lastPathComponent) }
        defer { try? handle.close() }
        var parser = DelimitedByteParser(delimiter: delimiter.asciiValue ?? 0x2C)
        let fieldEncoding: DataTextEncoding = encoding == .windows1252 ? .windows1252 : .utf8
        let emit: ([[UInt8]]) throws -> Bool = { fields in
            try row(fields.map { decode(Data($0), encoding: fieldEncoding) })
        }
        var first = true
        var pending = Data()
        while true {
            var chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            let atEnd = chunk.isEmpty
            if first {
                first = false
                chunk = chunk.dropFirst(bom(of: chunk, encoding: encoding))
            }
            let bytes: Data
            switch encoding {
            case .utf16LittleEndian, .utf16BigEndian:
                // Transcode to UTF-8, holding back an odd byte or a high surrogate for the next chunk.
                pending.append(chunk)
                var usable = pending.count - pending.count % 2
                if usable >= 2, !atEnd {
                    let last = encoding == .utf16LittleEndian ? UInt16(pending[pending.startIndex + usable - 1]) << 8 | UInt16(pending[pending.startIndex + usable - 2])
                        : UInt16(pending[pending.startIndex + usable - 2]) << 8 | UInt16(pending[pending.startIndex + usable - 1])
                    if (0xD800...0xDBFF).contains(last) { usable -= 2 }
                }
                let take = pending.prefix(usable)
                pending = Data(pending.dropFirst(usable))
                bytes = Data(decode(take, encoding: encoding).utf8)
            default:
                bytes = chunk
            }
            if try !parser.feed(bytes, emit: emit) { return }
            if atEnd { break }
        }
        try parser.finish(emit: emit)
    }

    private static func bom(of chunk: Data, encoding: DataTextEncoding) -> Int {
        let detected = DataTextEncoding.detect(chunk.prefix(4))
        return detected.encoding == encoding ? detected.bom : 0
    }

    /// Reads the file at `url` with `options` (empty settings detected): delimited text with the
    /// first row as the column names (or `column_1`, `column_2` ...), JSON through its records path
    /// with the values at `paths` added.  `limit` stops after that many records (the sheet's
    /// preview).
    public static func read(_ url: URL, options: DataFileOptions, paths: [String] = [], limit: Int? = nil) throws -> DataFileContents {
        if options.format == .json {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= DataJSON.maxFileSize else { throw DataFileError.tooLarge(bytes: size) }
            guard let data = try? Data(contentsOf: url) else { throw DataFileError.unreadable(url.lastPathComponent) }
            let encoding = DataTextEncoding(rawValue: options.encoding) ?? DataTextEncoding.detect(data.prefix(4)).encoding
            let utf8 = encoding == .utf8 ? data : Data(decode(data, encoding: encoding).utf8)
            var table = try DataJSON.table(utf8, recordsPath: options.recordsPath, paths: paths)
            if let limit { table = table.prefix(limit) }
            return DataFileContents(table: table, encoding: encoding, delimiter: nil)
        }
        let detected = options.encoding.isEmpty || options.delimiter.isEmpty ? try detect(url, format: options.format) : nil
        let encoding = DataTextEncoding(rawValue: options.encoding) ?? detected?.encoding ?? .utf8
        let delimiter = options.delimiter.first ?? detected?.delimiter ?? ","
        var columns: [String]?
        var records: [DataRecord] = []
        try forEachRow(url, encoding: encoding, delimiter: delimiter) { fields in
            guard let names = columns else {
                if options.headerRow {
                    columns = fields
                    return true
                }
                columns = fields.indices.map { "column_\($0 + 1)" }
                return try Self.append(fields, columns: columns!, to: &records, limit: limit)
            }
            return try Self.append(fields, columns: names, to: &records, limit: limit)
        }
        return DataFileContents(table: DataTable(columns: columns ?? [], records: records), encoding: encoding, delimiter: delimiter)
    }

    private static func append(_ fields: [String], columns: [String], to records: inout [DataRecord], limit: Int?) throws -> Bool {
        var values: [String: String] = [:]
        for (column, value) in zip(columns, fields) where !value.isEmpty { values[column] = value }
        records.append(DataRecord(values))
        return limit.map { records.count < $0 } ?? true
    }
}

/// Security-scoped bookmarks of file sources (`FileSource.bookmark`: local only, never on the
/// wire), so the file is read again on *Refresh* and merges after a relaunch.
public enum DataFileBookmarks {
    /// A bookmark of `url` (chosen in an open panel).
    public static func make(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The file a bookmark names, and whether the bookmark should be made again (stale).
    public static func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            throw DataFileError.bookmarkUnresolved
        }
        return (url, stale)
    }

    /// Runs `body` with access to the bookmarked file.
    public static func withAccess<T>(_ bookmark: Data, _ body: (URL) throws -> T) throws -> T {
        let url = try resolve(bookmark).url
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }
}
