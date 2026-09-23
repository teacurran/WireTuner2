// The PDF object model and file structure (export-pdf.adoc, "Client"; D-039): values, indirect
// objects, streams, the cross-reference table and the trailer.  The writer builds objects in any
// order -- a font's number is reserved when a page first uses it and its dictionary written once
// every page is done -- and serializes them in number order.

import CryptoKit
import Foundation

/// A PDF value.
indirect enum PDFValue {
    case null
    case bool(Bool)
    case int(Int)
    case real(Double)
    case name(String)
    /// A text string: ASCII as a literal, anything else as UTF-16BE with a byte-order mark.
    case string(String)
    /// A byte string written in hex.
    case bytes(Data)
    case array([PDFValue])
    /// Keys in order (without the slash).
    case dictionary([(String, PDFValue)])
    case reference(Int)

    static func numbers(_ values: [Double]) -> PDFValue {
        .array(values.map { .real($0) })
    }

    static func rect(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) -> PDFValue {
        numbers([minX, minY, maxX, maxY])
    }

    /// The value serialized.
    var text: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .real(let value): return PDFValue.number(value)
        case .name(let name): return "/" + PDFValue.escapeName(name)
        case .string(let string): return PDFValue.literal(string)
        case .bytes(let data): return "<" + data.map { String(format: "%02X", $0) }.joined() + ">"
        case .array(let values): return "[" + values.map(\.text).joined(separator: " ") + "]"
        case .dictionary(let entries): return "<<" + entries.map { "/\(PDFValue.escapeName($0.0)) \($0.1.text)" }.joined(separator: " ") + ">>"
        case .reference(let number): return "\(number) 0 R"
        }
    }

    /// A number with at most 5 decimals (content streams and dictionaries).
    static func number(_ value: Double) -> String {
        Numbers.format(value, places: 5)
    }

    /// A name's characters outside `!`…`~`, and the delimiters, as `#xx`.
    static func escapeName(_ name: String) -> String {
        var result = ""
        for byte in name.utf8 {
            if byte < 0x21 || byte > 0x7E || "#()<>[]{}/%".utf8.contains(byte) {
                result += String(format: "#%02X", byte)
            } else {
                result.unicodeScalars.append(UnicodeScalar(byte))
            }
        }
        return result
    }

    /// A text string: printable ASCII as `( … )` with escapes, otherwise UTF-16BE hex with BOM.
    static func literal(_ string: String) -> String {
        if string.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) {
            var result = "("
            for character in string {
                switch character {
                case "\\": result += "\\\\"
                case "(": result += "\\("
                case ")": result += "\\)"
                default: result.append(character)
                }
            }
            return result + ")"
        }
        var bytes = Data([0xFE, 0xFF])
        for unit in string.utf16 {
            bytes.append(UInt8(unit >> 8))
            bytes.append(UInt8(unit & 0xFF))
        }
        return PDFValue.bytes(bytes).text
    }
}

/// The objects of one PDF file.
final class PDFObjects {
    private var bodies: [Int: Data] = [:]
    private(set) var count = 0
    /// Compress streams with FlateDecode (off only for debugging).
    let compress: Bool

    init(compress: Bool) {
        self.compress = compress
    }

    /// A number for an object written later.
    func reserve() -> Int {
        count += 1
        return count
    }

    /// Writes object `number`.
    func set(_ number: Int, _ value: PDFValue) {
        bodies[number] = Data("\(number) 0 obj\n\(value.text)\nendobj\n".utf8)
    }

    /// Writes stream object `number`: `data` compressed unless `raw` (already encoded, its
    /// filter in `dictionary`) or compression is off.
    func setStream(_ number: Int, _ dictionary: [(String, PDFValue)], data: Data, raw: Bool = false) {
        var entries = dictionary
        var payload = data
        if !raw && compress {
            payload = Zlib.compress(data)
            entries.append(("Filter", .name("FlateDecode")))
        }
        entries.append(("Length", .int(payload.count)))
        var body = Data("\(number) 0 obj\n\(PDFValue.dictionary(entries).text)\nstream\n".utf8)
        body.append(payload)
        body.append(Data("\nendstream\nendobj\n".utf8))
        bodies[number] = body
    }

    func add(_ value: PDFValue) -> Int {
        let number = reserve()
        set(number, value)
        return number
    }

    func addStream(_ dictionary: [(String, PDFValue)], data: Data, raw: Bool = false) -> Int {
        let number = reserve()
        setStream(number, dictionary, data: data, raw: raw)
        return number
    }

    /// The file: header, objects in number order, cross-reference table and trailer.  Every
    /// reserved number must have been written.
    func file(version: String, root: Int, info: Int?) -> Data {
        var file = Data("%PDF-\(version)\n%".utf8)
        file.append(contentsOf: [0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int] = []
        for number in 1...count {
            offsets.append(file.count)
            file.append(bodies[number]!)
        }
        let digest = Data(Insecure.MD5.hash(data: file))
        let xref = file.count
        var table = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            table += String(format: "%010d 00000 n \n", offset)
        }
        var trailer: [(String, PDFValue)] = [("Size", .int(offsets.count + 1)), ("Root", .reference(root))]
        if let info {
            trailer.append(("Info", .reference(info)))
        }
        trailer.append(("ID", .array([.bytes(digest), .bytes(digest)])))
        table += "trailer\n\(PDFValue.dictionary(trailer).text)\nstartxref\n\(xref)\n%%EOF\n"
        file.append(Data(table.utf8))
        return file
    }
}
