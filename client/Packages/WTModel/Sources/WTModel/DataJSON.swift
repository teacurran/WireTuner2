import Foundation

// DATA-004: the JSON file reader and the JSONPath subset (data-merge.adoc, "A JSON file";
// "Pagination engine and extraction", the grammar shared with the server).  JSON is parsed into
// an order-keeping tree whose numbers keep their source text, so a record read from a file is
// the same text the server's extraction produces (`12.990` stays `12.990`, members keep their
// order); the shared vectors (`server/api/src/test/resources/jsonpath-vectors`) run unchanged.

/// A JSON value with members in source order and numbers as their source text.
public indirect enum JSONNode: Hashable, Sendable {
    case object([(String, JSONNode)])
    case array([JSONNode])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public static func == (a: JSONNode, b: JSONNode) -> Bool { a.compact == b.compact }
    public func hash(into hasher: inout Hasher) { hasher.combine(compact) }

    /// Compact JSON: no whitespace, members in source order, numbers as their source text,
    /// strings escaping only `"`, `\` and the control characters.
    public var compact: String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .object(let members):
            out += "{"
            for (index, (name, value)) in members.enumerated() {
                if index > 0 { out += "," }
                JSONNode.quote(name, into: &out)
                out += ":"
                value.write(into: &out)
            }
            out += "}"
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .string(let text): JSONNode.quote(text, into: &out)
        case .number(let text): out += text
        case .bool(let value): out += value ? "true" : "false"
        case .null: out += "null"
        }
    }

    static func quote(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        out += "\""
    }

    /// The value as record text: strings unquoted, numbers as written, booleans `true`/`false`,
    /// objects and arrays as compact JSON; nil for null.
    public var recordText: String? {
        switch self {
        case .string(let text): text
        case .null: nil
        default: compact
        }
    }

    /// The member `name` (the first of that name), when this is an object holding it.
    public func member(_ name: String) -> JSONNode? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.0 == name }?.1
    }
}

/// Why JSON text could not be read.
public struct JSONSyntaxError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The UTF-8 byte offset where reading stopped.
    public var offset: Int
    public var description: String { "The JSON is not valid (at byte \(offset))" }
}

/// An order-keeping JSON parser over UTF-8 bytes.
struct JSONTreeParser {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        self.bytes = bytes
    }

    static func parse(_ data: Data) throws -> JSONNode {
        var parser = JSONTreeParser(data)
        parser.skipSpace()
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw JSONSyntaxError(offset: parser.index) }
        return value
    }

    private var failure: JSONSyntaxError { JSONSyntaxError(offset: index) }

    private mutating func skipSpace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private mutating func expect(_ literal: String) throws {
        for byte in literal.utf8 {
            guard index < bytes.count, bytes[index] == byte else { throw failure }
            index += 1
        }
    }

    private mutating func value(depth: Int) throws -> JSONNode {
        guard depth < 100, index < bytes.count else { throw failure }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            index += 1
            var members: [(String, JSONNode)] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw failure }
                let name = try string()
                skipSpace()
                try expect(":")
                skipSpace()
                members.append((name, try value(depth: depth + 1)))
                skipSpace()
                guard index < bytes.count else { throw failure }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                } else if bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return .object(members)
                } else {
                    throw failure
                }
            }
        case UInt8(ascii: "["):
            index += 1
            var items: [JSONNode] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                skipSpace()
                items.append(try value(depth: depth + 1))
                skipSpace()
                guard index < bytes.count else { throw failure }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                } else if bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return .array(items)
                } else {
                    throw failure
                }
            }
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"):
            try expect("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try expect("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try expect("null")
            return .null
        default: return .number(try number())
        }
    }

    private mutating func digits() -> Int {
        let start = index
        while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
        return index - start
    }

    private mutating func number() throws -> String {
        let start = index
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count else { throw failure }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else if digits() == 0 {
            throw failure
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard digits() > 0 else { throw failure }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard digits() > 0 else { throw failure }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index..<(index + 4)], as: UTF8.self), radix: 16) else { throw failure }
        index += 4
        return value
    }

    private mutating func string() throws -> String {
        index += 1
        var out = String.UnicodeScalarView()
        var run = index
        func flush(_ end: Int) {
            out.append(contentsOf: String(decoding: bytes[run..<end], as: UTF8.self).unicodeScalars)
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                flush(index)
                index += 1
                return String(out)
            }
            guard byte >= 0x20 else { throw failure }
            guard byte == UInt8(ascii: "\\") else {
                index += 1
                continue
            }
            flush(index)
            index += 1
            guard index < bytes.count else { throw failure }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): out.append("\"")
            case UInt8(ascii: "\\"): out.append("\\")
            case UInt8(ascii: "/"): out.append("/")
            case UInt8(ascii: "b"): out.append("\u{08}")
            case UInt8(ascii: "f"): out.append("\u{0C}")
            case UInt8(ascii: "n"): out.append("\n")
            case UInt8(ascii: "r"): out.append("\r")
            case UInt8(ascii: "t"): out.append("\t")
            case UInt8(ascii: "u"):
                var code = try hex4()
                if (0xD800...0xDBFF).contains(code), index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                    index += 2
                    let low = try hex4()
                    guard (0xDC00...0xDFFF).contains(low) else { throw failure }
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                }
                guard let scalar = Unicode.Scalar(code) else { throw failure }
                out.append(scalar)
            default: throw failure
            }
            run = index
        }
        throw failure
    }
}

/// A path of the JSONPath subset (data-merge.adoc, "Pagination engine and extraction"):
/// `""` (the root), `$` with steps (`.name`, `['name']`, `[n]`, `[*]`, `..name`), or a bare name.
/// Filters, scripts, slices, unions, negative indices and anything else are refused.
public struct JSONPath: Hashable, Sendable {
    public enum Step: Hashable, Sendable {
        case member(String)
        case index(Int)
        case wildcard
        case descendant(String)
    }

    /// Why a path was refused; the kinds the shared vectors name.
    public struct Refusal: Error, Hashable, Sendable, CustomStringConvertible {
        public enum Kind: String, Hashable, Sendable {
            case filter, script, slice, union
            case negativeIndex = "negative_index"
            case syntax
        }

        public var kind: Kind
        public var path: String

        public var description: String {
            switch kind {
            case .filter: "“\(path)” uses a filter, which is not supported"
            case .script: "“\(path)” uses a script expression, which is not supported"
            case .slice: "“\(path)” uses a slice, which is not supported"
            case .union: "“\(path)” lists several members or indices, which is not supported"
            case .negativeIndex: "“\(path)” uses a negative index, which is not supported"
            case .syntax: "“\(path)” is not a valid path"
            }
        }
    }

    public let steps: [Step]

    /// Whether the path names at most one value (no `[*]` and no `..`).
    public var isDefinite: Bool {
        !steps.contains { if case .wildcard = $0 { true } else if case .descendant = $0 { true } else { false } }
    }

    public init(_ text: String) throws {
        if text.isEmpty {
            steps = []
            return
        }
        guard text.hasPrefix("$") else {
            steps = [.member(text)]
            return
        }
        var parser = PathParser(text)
        steps = try parser.steps()
    }

    /// Every value the path matches in `root`, in document order.
    public func matches(in root: JSONNode) -> [JSONNode] {
        var current = [root]
        for step in steps {
            var next: [JSONNode] = []
            for node in current {
                switch step {
                case .member(let name):
                    if let value = node.member(name) { next.append(value) }
                case .index(let index):
                    if case .array(let items) = node, index < items.count { next.append(items[index]) }
                case .wildcard:
                    if case .array(let items) = node { next += items }
                    if case .object(let members) = node { next += members.map(\.1) }
                case .descendant(let name):
                    Self.descend(node, name: name, into: &next)
                }
            }
            current = next
        }
        return current
    }

    private static func descend(_ node: JSONNode, name: String, into out: inout [JSONNode]) {
        switch node {
        case .object(let members):
            if let value = node.member(name) { out.append(value) }
            for (_, value) in members { descend(value, name: name, into: &out) }
        case .array(let items):
            for item in items { descend(item, name: name, into: &out) }
        default: break
        }
    }

    /// The text of the value this path reads in `record`: a definite path's first match (nil
    /// for null or nothing), an indefinite path's matches as a compact JSON array (nil for none).
    public func text(in record: JSONNode) -> String? {
        let found = matches(in: record)
        if isDefinite { return found.first?.recordText }
        return found.isEmpty ? nil : JSONNode.array(found).compact
    }
}

/// The path grammar after `$`.
private struct PathParser {
    let text: String
    let scalars: [Unicode.Scalar]
    var index = 1

    init(_ text: String) {
        self.text = text
        scalars = Array(text.unicodeScalars)
    }

    func refuse(_ kind: JSONPath.Refusal.Kind) -> JSONPath.Refusal { JSONPath.Refusal(kind: kind, path: text) }

    static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        !scalar.isASCII || ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || "_-$".unicodeScalars.contains(scalar)
    }

    var peek: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

    mutating func name() throws -> String {
        var out = String.UnicodeScalarView()
        while let scalar = peek, Self.isNameScalar(scalar) {
            out.append(scalar)
            index += 1
        }
        guard !out.isEmpty else { throw refuse(.syntax) }
        return String(out)
    }

    mutating func steps() throws -> [JSONPath.Step] {
        var steps: [JSONPath.Step] = []
        while let scalar = peek {
            if scalar == "." {
                index += 1
                if peek == "." {
                    index += 1
                    steps.append(.descendant(try name()))
                } else {
                    steps.append(.member(try name()))
                }
            } else if scalar == "[" {
                index += 1
                steps.append(try bracket())
            } else {
                throw refuse(.syntax)
            }
        }
        return steps
    }

    mutating func bracket() throws -> JSONPath.Step {
        guard let first = peek else { throw refuse(.syntax) }
        switch first {
        case "?": throw refuse(.filter)
        case "(": throw refuse(.script)
        case "*":
            index += 1
            try close()
            return .wildcard
        case "'", "\"":
            let member = try quoted(first)
            if peek == "," { throw refuse(.union) }
            try close()
            return .member(member)
        case "-": throw refuse(.negativeIndex)
        case ":": throw refuse(.slice)
        default:
            var digits = ""
            while let scalar = peek, ("0"..."9").contains(scalar) {
                digits.unicodeScalars.append(scalar)
                index += 1
            }
            if peek == ":" { throw refuse(.slice) }
            if peek == "," { throw refuse(.union) }
            guard !digits.isEmpty, digits.count <= 9, digits == "0" || !digits.hasPrefix("0"), let value = Int(digits) else { throw refuse(.syntax) }
            try close()
            return .index(value)
        }
    }

    mutating func close() throws {
        guard peek == "]" else { throw refuse(.syntax) }
        index += 1
    }

    mutating func quoted(_ quote: Unicode.Scalar) throws -> String {
        index += 1
        var out = String.UnicodeScalarView()
        while let scalar = peek {
            index += 1
            if scalar == quote { return String(out) }
            if scalar == "\\" {
                guard let escaped = peek, escaped == "\\" || escaped == "'" || escaped == "\"" else { throw refuse(.syntax) }
                out.append(escaped)
                index += 1
            } else {
                out.append(scalar)
            }
        }
        throw refuse(.syntax)
    }
}

/// Reading records out of JSON (a JSON file source; the same extraction the server applies to an
/// API response).
public enum DataJSON {
    /// The largest JSON file read (larger files are refused with their size).
    public static let maxFileSize = 64 * 1024 * 1024

    /// Parses JSON text (a UTF-8 byte-order mark is skipped).
    public static func parse(_ data: Data) throws -> JSONNode {
        try JSONTreeParser.parse(data)
    }

    /// The records `recordsPath` selects in `root`: every match, except that a definite path
    /// matching one array selects its elements (so `$.data` reads like `$.data[*]`, and the empty
    /// path reads a root array's elements, or a root object as one record).
    public static func records(in root: JSONNode, recordsPath: String) throws -> [JSONNode] {
        let path = try JSONPath(recordsPath)
        let found = path.matches(in: root)
        if path.isDefinite, found.count == 1, case .array(let items) = found[0] { return items }
        return found
    }

    /// Each record's values at `paths`, keyed by path (absent where nothing or null matched).
    public static func records(in root: JSONNode, recordsPath: String, paths: [String]) throws -> [DataRecord] {
        let compiled = try paths.map { ($0, try JSONPath($0)) }
        return try records(in: root, recordsPath: recordsPath).map { record in
            var values: [String: String] = [:]
            for (text, path) in compiled {
                if let value = path.text(in: record) { values[text] = value }
            }
            return DataRecord(values)
        }
    }

    /// The member names of the first `sample` records, in first-seen order: the columns *Add
    /// Fields from Source* offers for a JSON source.
    public static func columns(of records: [JSONNode], sample: Int = 20) -> [String] {
        var columns: [String] = []
        var seen: Set<String> = []
        for record in records.prefix(sample) {
            guard case .object(let members) = record else { continue }
            for (name, _) in members where seen.insert(name).inserted { columns.append(name) }
        }
        return columns
    }

    /// A JSON file's records as a table: its columns are the first records' member names, and
    /// each record holds those members plus the values at `paths` (a mapping's JSONPaths).
    public static func table(_ data: Data, recordsPath: String, paths: [String] = []) throws -> DataTable {
        let found = try records(in: parse(data), recordsPath: recordsPath)
        let columns = columns(of: found)
        let compiled = try paths.filter { !columns.contains($0) }.map { ($0, try JSONPath($0)) }
        let records = found.map { record in
            var values: [String: String] = [:]
            for column in columns {
                if let value = record.member(column)?.recordText { values[column] = value }
            }
            for (text, path) in compiled {
                if let value = path.text(in: record) { values[text] = value }
            }
            return DataRecord(values)
        }
        return DataTable(columns: columns, records: records)
    }
}
