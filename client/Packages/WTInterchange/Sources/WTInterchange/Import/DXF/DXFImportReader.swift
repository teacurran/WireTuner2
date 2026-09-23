// The DXF group-code reader (import-formats.adoc, "Client", *DXF*; IMG-013): ASCII DXF (LF or CRLF,
// UTF-8 for 2007 and later, Windows-1252 with `\U+XXXX` escapes before) and binary DXF (R12's
// one-byte group codes and R13's two-byte ones), both read into the same list of pairs, then
// split into sections, the header variables, the layer table, block definitions and entities.
// Entities that own sub-entities (POLYLINE's VERTEXes, INSERT's ATTRIBs) are gathered under
// their owner here, so the converter sees one record per drawn thing.

import Foundation
import WTGeometry

/// One group-code pair.
struct DXFImportPair: Hashable, Sendable {
    var code: Int
    var value: String

    /// The value as a number (0 when it is not one).
    var double: Double { Double(value.trimmingCharacters(in: .whitespaces)) ?? 0 }
    var int: Int { Int(value.trimmingCharacters(in: .whitespaces)) ?? Int(double) }
}

/// One entity with its own pairs (the leading `0` pair excluded) and owned sub-entities.
struct DXFImportEntity: Hashable, Sendable {
    var type: String
    var pairs: [DXFImportPair]
    var children: [DXFImportEntity] = []

    /// The first value of `code`.
    func string(_ code: Int) -> String? { pairs.first { $0.code == code }?.value }
    func double(_ code: Int, _ fallback: Double = 0) -> Double { pairs.first { $0.code == code }?.double ?? fallback }
    func int(_ code: Int, _ fallback: Int = 0) -> Int { pairs.first { $0.code == code }?.int ?? fallback }
    func has(_ code: Int) -> Bool { pairs.contains { $0.code == code } }
    /// The point of `code` (x) and `code + 10` (y).
    func point(_ code: Int) -> Point { Point(x: double(code), y: double(code + 10)) }

    var layer: String { string(8) ?? "0" }
}

/// A layer table record.
struct DXFImportLayer: Hashable, Sendable {
    var name: String
    /// ACI (absolute value), or 7.
    var colorIndex: Int
    var trueColor: Int?
    /// Hundredths of a millimetre; negative is default.
    var lineweight: Int
    /// Off (negative colour) or frozen (flag 1).
    var hidden: Bool
}

/// A block definition.
struct DXFImportBlock: Hashable, Sendable {
    var name: String
    var base: Point
    var entities: [DXFImportEntity]
}

/// A parsed DXF drawing.
struct DXFImportDrawing: Sendable {
    var header: [String: [DXFImportPair]] = [:]
    var layers: [DXFImportLayer] = []
    var blocks: [String: DXFImportBlock] = [:]
    var entities: [DXFImportEntity] = []

    /// Reads `data` as ASCII or binary DXF; nil when it is not DXF or is cut short.
    init?(_ data: Data) {
        guard let pairs = DXFImportDrawing.pairs(data) else {
            return nil
        }
        guard parse(pairs) else {
            return nil
        }
    }

    // MARK: Pairs

    static let binarySentinel = Array("AutoCAD Binary DXF\r\n".utf8) + [0x1A, 0x00]

    static func pairs(_ data: Data) -> [DXFImportPair]? {
        let bytes = [UInt8](data)
        if bytes.starts(with: binarySentinel) {
            return binaryPairs(bytes)
        }
        return asciiPairs(bytes)
    }

    static func asciiPairs(_ bytes: [UInt8]) -> [DXFImportPair]? {
        let text = String(validating: bytes, as: UTF8.self) ?? String(String.UnicodeScalarView(bytes.compactMap { Unicode.Scalar(DXFImportDrawing.windows1252($0)) }))
        // "\r\n" is one Character, so line ends are normalized before splitting.
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        guard lines.count >= 2, lines.count % 2 == 0 else {
            return nil
        }
        var pairs: [DXFImportPair] = []
        pairs.reserveCapacity(lines.count / 2)
        var index = 0
        while index < lines.count {
            guard let code = Int(lines[index].trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            pairs.append(DXFImportPair(code: code, value: unescape(lines[index + 1])))
            index += 2
        }
        return pairs
    }

    /// Windows-1252's mapping of the bytes 0x80...0x9F; every other byte is Latin-1.
    static func windows1252(_ byte: UInt8) -> UInt32 {
        let table: [UInt32] = [0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
                               0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178]
        return (0x80...0x9F).contains(byte) ? table[Int(byte) - 0x80] : UInt32(byte)
    }

    /// `\U+XXXX` escapes (DXF before 2007) replaced by their characters.
    static func unescape(_ value: String) -> String {
        guard value.contains("\\U+") else {
            return value
        }
        var result = ""
        var rest = Substring(value)
        while let range = rest.range(of: "\\U+") {
            result += rest[..<range.lowerBound]
            let hex = rest[range.upperBound...].prefix(4)
            if hex.count == 4, let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
                rest = rest[range.upperBound...].dropFirst(4)
            } else {
                result += "\\U+"
                rest = rest[range.upperBound...]
            }
        }
        return result + rest
    }

    enum BinaryValue {
        case string, double, int16, int32, int64, bool, chunk

        /// The byte count of a fixed-size value.
        var size: Int {
            switch self {
            case .double, .int64: return 8
            case .int32: return 4
            case .int16: return 2
            default: return 1
            }
        }

        /// A fixed-size value's little-endian bits as text.
        func text(_ bits: UInt64) -> String {
            switch self {
            case .double: return String(Double(bitPattern: bits))
            case .int16: return String(Int16(truncatingIfNeeded: bits))
            case .int32: return String(Int32(truncatingIfNeeded: bits))
            case .int64: return String(Int64(bitPattern: bits))
            default: return String(bits)
            }
        }
    }

    /// The binary encoding of a group code's value, or nil for a code DXF does not define.
    static func binaryValue(_ code: Int) -> BinaryValue? {
        switch code {
        case 0...9, 100...109, 300...309, 320...369, 390...399, 410...419, 430...439, 470...481, 999, 1000...1003, 1005...1009: return .string
        case 10...59, 110...149, 210...239, 460...469, 1010...1059: return .double
        case 60...79, 170...179, 270...289, 370...389, 400...409, 1060...1070: return .int16
        case 90...99, 420...429, 440...459, 1071: return .int32
        case 160...169: return .int64
        case 290...299: return .bool
        case 310...319, 1004: return .chunk
        default: return nil
        }
    }

    static func binaryPairs(_ bytes: [UInt8]) -> [DXFImportPair]? {
        var index = binarySentinel.count
        // R13 and later write two-byte codes: the first pair is 0/"SECTION", so a second zero byte
        // means two-byte codes; R12 goes straight on to the string.
        guard index + 2 <= bytes.count else {
            return nil
        }
        let wide = bytes[index + 1] == 0
        func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard index + count <= bytes.count else { return nil }
            defer { index += count }
            return bytes[index..<(index + count)]
        }
        func little(_ slice: ArraySlice<UInt8>) -> UInt64 {
            slice.reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }
        var pairs: [DXFImportPair] = []
        while index < bytes.count {
            var code: Int
            if wide {
                guard let raw = take(2) else { return nil }
                code = Int(Int16(bitPattern: UInt16(little(raw))))
            } else {
                code = Int(bytes[index])
                index += 1
                if code == 255 {
                    guard let extended = take(2) else { return nil }
                    code = Int(little(extended))
                }
            }
            guard let kind = binaryValue(code) else {
                return nil
            }
            let value: String
            switch kind {
            case .string:
                guard let end = bytes[index...].firstIndex(of: 0) else { return nil }
                value = unescape(String(decoding: bytes[index..<end], as: UTF8.self))
                index = end + 1
            case .chunk:
                guard index < bytes.count, let raw = take(Int(bytes[index]) + 1) else { return nil }
                value = raw.dropFirst().map { String(format: "%02X", $0) }.joined()
            default:
                guard let raw = take(kind.size) else { return nil }
                value = kind.text(little(raw))
            }
            pairs.append(DXFImportPair(code: code, value: value))
        }
        return pairs
    }

    // MARK: Sections

    /// Splits `pairs` into sections; false when a section is not closed or no section exists.
    mutating func parse(_ pairs: [DXFImportPair]) -> Bool {
        var index = 0
        var sections = 0
        while index < pairs.count {
            let pair = pairs[index]
            guard pair.code == 0 else {
                index += 1
                continue
            }
            if pair.value == "EOF" {
                break
            }
            guard pair.value == "SECTION", index + 1 < pairs.count, pairs[index + 1].code == 2 else {
                index += 1
                continue
            }
            let name = pairs[index + 1].value
            guard let end = pairs[(index + 2)...].firstIndex(where: { $0.code == 0 && $0.value == "ENDSEC" }) else {
                return false
            }
            let body = Array(pairs[(index + 2)..<end])
            switch name {
            case "HEADER": readHeader(body)
            case "TABLES": readTables(body)
            case "BLOCKS": readBlocks(body)
            case "ENTITIES": entities = DXFImportDrawing.entities(body)
            default: break
            }
            sections += 1
            index = end + 1
        }
        return sections > 0
    }

    mutating func readHeader(_ body: [DXFImportPair]) {
        var name: String?
        for pair in body {
            if pair.code == 9 {
                name = pair.value
            } else if let name {
                header[name, default: []].append(pair)
            }
        }
    }

    mutating func readTables(_ body: [DXFImportPair]) {
        for record in DXFImportDrawing.records(body) where record.type == "LAYER" {
            guard let name = record.string(2) else { continue }
            let color = record.int(62, 7)
            layers.append(DXFImportLayer(
                name: name, colorIndex: abs(color), trueColor: record.has(420) ? record.int(420) : nil,
                lineweight: record.int(370, -3), hidden: color < 0 || record.int(70) & 1 != 0))
        }
    }

    mutating func readBlocks(_ body: [DXFImportPair]) {
        var index = 0
        let records = DXFImportDrawing.records(body)
        while index < records.count {
            let record = records[index]
            index += 1
            guard record.type == "BLOCK" else { continue }
            var contents: [DXFImportPair] = []
            while index < records.count, records[index].type != "ENDBLK" {
                contents.append(DXFImportPair(code: 0, value: records[index].type))
                contents += records[index].pairs
                index += 1
            }
            let name = record.string(2) ?? ""
            blocks[name] = DXFImportBlock(name: name, base: record.point(10), entities: DXFImportDrawing.entities(contents))
        }
    }

    /// Every `0`-introduced record in `body`.
    static func records(_ body: [DXFImportPair]) -> [DXFImportEntity] {
        var result: [DXFImportEntity] = []
        for pair in body {
            if pair.code == 0 {
                result.append(DXFImportEntity(type: pair.value, pairs: []))
            } else if !result.isEmpty {
                result[result.count - 1].pairs.append(pair)
            }
        }
        return result
    }

    /// The records of an entity list, VERTEXes gathered under their POLYLINE and ATTRIBs under
    /// their INSERT (up to the SEQEND).
    static func entities(_ body: [DXFImportPair]) -> [DXFImportEntity] {
        var result: [DXFImportEntity] = []
        var owner: DXFImportEntity?
        for record in records(body) {
            if var current = owner {
                if record.type == "VERTEX" || record.type == "ATTRIB" {
                    current.children.append(record)
                    owner = current
                    continue
                }
                // SEQEND ends the sequence; anything else ends one cut short.
                result.append(current)
                owner = nil
                if record.type == "SEQEND" {
                    continue
                }
            }
            if record.type == "POLYLINE" || (record.type == "INSERT" && record.int(66) == 1) {
                owner = record
            } else {
                result.append(record)
            }
        }
        if let owner {
            result.append(owner)
        }
        return result
    }
}
