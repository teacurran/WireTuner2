// The PostScript-syntax lexer shared by the PDF importer's content streams, CMaps and calculator
// functions and by the legacy Illustrator reader (import-formats.adoc, "Client"; IMG-009,
// IMG-010).  Reading content streams ourselves rather than through `CGPDFScanner` gives the
// importer inline images, marked content and the operators' raw operands, and lets one
// interpreter be exercised directly by tests.

import Foundation

/// One lexical token.
enum PDFImportToken: Hashable, Sendable {
    case number(Double)
    case name(String)
    case string(Data)
    case keyword(String)
    case arrayOpen
    case arrayClose
    case dictOpen
    case dictClose
    case procOpen
    case procClose
    case comment(String)
}

/// A parsed operand.
indirect enum PDFImportOperand: Hashable, Sendable {
    case number(Double)
    case name(String)
    case string(Data)
    case bool(Bool)
    case null
    case array([PDFImportOperand])
    case dict([String: PDFImportOperand])
    case proc([PDFImportOperand])
    /// An executable name inside a procedure (`add`, `if`…).
    case keyword(String)

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var name: String? {
        if case .name(let value) = self { return value }
        return nil
    }

    var string: Data? {
        if case .string(let value) = self { return value }
        return nil
    }

    var array: [PDFImportOperand]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var dict: [String: PDFImportOperand]? {
        if case .dict(let value) = self { return value }
        return nil
    }

    /// A text string: UTF-16BE with its byte-order mark, else Latin-1 (PDFDocEncoding's printable
    /// range).
    static func text(_ data: Data) -> String {
        let bytes = [UInt8](data)
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return String(decoding: stride(from: 2, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }, as: UTF16.self)
        }
        return String(bytes.map { Character(Unicode.Scalar($0)) })
    }
}

/// Splits PostScript-syntax bytes into tokens.
struct PDFImportLexer {
    let bytes: [UInt8]
    var position = 0
    /// Whether `%` comments are returned (Illustrator structure) or skipped (PDF).
    var keepComments: Bool

    init(_ data: Data, keepComments: Bool = false) {
        bytes = [UInt8](data)
        self.keepComments = keepComments
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0 || byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 32
    }

    static func isDelimiter(_ byte: UInt8) -> Bool {
        "()<>[]{}/%".utf8.contains(byte)
    }

    /// The next token, nil at the end.
    mutating func next() -> PDFImportToken? {
        while position < bytes.count {
            let byte = bytes[position]
            if PDFImportLexer.isWhitespace(byte) {
                position += 1
                continue
            }
            if byte == UInt8(ascii: "%") {
                let start = position + 1
                while position < bytes.count, bytes[position] != 10, bytes[position] != 13 {
                    position += 1
                }
                if keepComments {
                    return .comment(String(decoding: bytes[start..<position], as: UTF8.self))
                }
                continue
            }
            return token(at: byte)
        }
        return nil
    }

    private mutating func token(at byte: UInt8) -> PDFImportToken {
        switch byte {
        case UInt8(ascii: "("):
            position += 1
            return .string(literalString())
        case UInt8(ascii: "<"):
            if position + 1 < bytes.count, bytes[position + 1] == UInt8(ascii: "<") {
                position += 2
                return .dictOpen
            }
            position += 1
            return .string(hexString())
        case UInt8(ascii: ">"):
            position += position + 1 < bytes.count && bytes[position + 1] == UInt8(ascii: ">") ? 2 : 1
            return .dictClose
        case UInt8(ascii: "["):
            position += 1
            return .arrayOpen
        case UInt8(ascii: "]"):
            position += 1
            return .arrayClose
        case UInt8(ascii: "{"):
            position += 1
            return .procOpen
        case UInt8(ascii: "}"):
            position += 1
            return .procClose
        case UInt8(ascii: "/"):
            position += 1
            return .name(regular(decodeHex: true))
        default:
            let word = regular(decodeHex: false)
            if word.isEmpty {
                // A stray `)`: skip it.
                position += 1
                return .keyword(String(UnicodeScalar(byte)))
            }
            if let number = PDFImportLexer.number(word) {
                return .number(number)
            }
            return .keyword(word)
        }
    }

    /// A PDF or PostScript number (`12`, `-3.5`, `.5`, `4.`), nil for anything else.
    static func number(_ word: String) -> Double? {
        var digits = 0
        var dots = 0
        for (index, character) in word.enumerated() {
            if character.isASCII && character.isNumber {
                digits += 1
            } else if character == "." {
                dots += 1
            } else if (character == "-" || character == "+") && index == 0 {
                continue
            } else {
                return nil
            }
        }
        guard digits > 0, dots <= 1 else {
            return nil
        }
        return Double(word.hasSuffix(".") ? word + "0" : word)
    }

    /// Regular characters up to the next whitespace or delimiter; names decode `#xx`.
    private mutating func regular(decodeHex: Bool) -> String {
        var result: [UInt8] = []
        while position < bytes.count {
            let byte = bytes[position]
            if PDFImportLexer.isWhitespace(byte) || PDFImportLexer.isDelimiter(byte) {
                break
            }
            if decodeHex, byte == UInt8(ascii: "#"), position + 2 < bytes.count,
               let value = UInt8(String(decoding: bytes[(position + 1)...(position + 2)], as: UTF8.self), radix: 16) {
                result.append(value)
                position += 3
                continue
            }
            result.append(byte)
            position += 1
        }
        return String(decoding: result, as: UTF8.self)
    }

    private mutating func literalString() -> Data {
        var result: [UInt8] = []
        var depth = 1
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            switch byte {
            case UInt8(ascii: "("):
                depth += 1
                result.append(byte)
            case UInt8(ascii: ")"):
                depth -= 1
                if depth == 0 {
                    return Data(result)
                }
                result.append(byte)
            case UInt8(ascii: "\\"):
                guard position < bytes.count else { break }
                let escaped = bytes[position]
                position += 1
                switch escaped {
                case UInt8(ascii: "n"): result.append(10)
                case UInt8(ascii: "r"): result.append(13)
                case UInt8(ascii: "t"): result.append(9)
                case UInt8(ascii: "b"): result.append(8)
                case UInt8(ascii: "f"): result.append(12)
                case 13:
                    if position < bytes.count, bytes[position] == 10 { position += 1 }
                case 10:
                    break
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var value = Int(escaped - UInt8(ascii: "0"))
                    for _ in 0..<2 where position < bytes.count && (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(bytes[position]) {
                        value = value * 8 + Int(bytes[position] - UInt8(ascii: "0"))
                        position += 1
                    }
                    result.append(UInt8(value & 0xFF))
                default:
                    result.append(escaped)
                }
            default:
                result.append(byte)
            }
        }
        return Data(result)
    }

    private mutating func hexString() -> Data {
        var digits: [UInt8] = []
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            if byte == UInt8(ascii: ">") {
                break
            }
            if let value = PDFImportLexer.hexValue(byte) {
                digits.append(value)
            }
        }
        if digits.count % 2 == 1 {
            digits.append(0)
        }
        return Data(stride(from: 0, to: digits.count, by: 2).map { digits[$0] << 4 | digits[$0 + 1] })
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// The bytes of an inline image after `ID`: one whitespace byte, then everything up to
    /// the `EI` that is preceded by whitespace and followed by whitespace or the end.
    mutating func inlineImageData() -> Data {
        if position < bytes.count, PDFImportLexer.isWhitespace(bytes[position]) {
            position += 1
        }
        let start = position
        var index = position
        while index + 1 < bytes.count {
            if bytes[index] == UInt8(ascii: "E"), bytes[index + 1] == UInt8(ascii: "I"),
               index > start, PDFImportLexer.isWhitespace(bytes[index - 1]),
               index + 2 >= bytes.count || PDFImportLexer.isWhitespace(bytes[index + 2]) {
                position = index + 2
                return Data(bytes[start..<(index - 1)])
            }
            index += 1
        }
        position = bytes.count
        return Data(bytes[start..<bytes.count])
    }
}

/// Builds operands from tokens and hands each operator its operands.
struct PDFImportParser {
    var lexer: PDFImportLexer
    /// Whether an array, dictionary or procedure nested deeper than `ImportNesting.limit` was
    /// read as null (its contents skipped): the caller notes it where it matters, and may reset it.
    var nestingTruncated = false

    init(_ data: Data, keepComments: Bool = false) {
        lexer = PDFImportLexer(data, keepComments: keepComments)
    }

    /// One item of a content stream.
    enum Item: Equatable {
        case operand(PDFImportOperand)
        case op(String)
        case comment(String)
    }

    /// The next operand, operator or comment.
    mutating func next() -> Item? {
        guard let token = lexer.next() else {
            return nil
        }
        return item(token)
    }

    private mutating func item(_ token: PDFImportToken) -> Item {
        switch token {
        case .keyword(let word):
            switch word {
            case "true": return .operand(.bool(true))
            case "false": return .operand(.bool(false))
            case "null": return .operand(.null)
            default: return .op(word)
            }
        case .comment(let text):
            return .comment(text)
        default:
            return .operand(operand(token))
        }
    }

    /// An array, dictionary or procedure being read: the token that closes it and its items.
    private struct Open {
        let close: PDFImportToken
        var items: [PDFImportOperand] = []
    }

    /// The token that closes a container `token` opens, nil for any other token.
    private static func closer(_ token: PDFImportToken) -> PDFImportToken? {
        switch token {
        case .arrayOpen: return .arrayClose
        case .procOpen: return .procClose
        case .dictOpen: return .dictClose
        default: return nil
        }
    }

    /// A token that neither opens nor closes the container being read, as an operand (a
    /// mismatched closing token reads as null).
    private static func scalar(_ token: PDFImportToken) -> PDFImportOperand {
        switch token {
        case .number(let value): return .number(value)
        case .name(let value): return .name(value)
        case .string(let value): return .string(value)
        case .keyword(let word):
            switch word {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: return .keyword(word)
            }
        case .arrayOpen, .arrayClose, .dictOpen, .dictClose, .procOpen, .procClose, .comment:
            return .null
        }
    }

    /// A finished container as an operand.
    private static func value(_ open: Open) -> PDFImportOperand {
        switch open.close {
        case .arrayClose:
            return .array(open.items)
        case .procClose:
            return .proc(open.items)
        default:
            var dictionary: [String: PDFImportOperand] = [:]
            var index = 0
            while index + 1 < open.items.count {
                if let key = open.items[index].name {
                    dictionary[key] = open.items[index + 1]
                }
                index += 2
            }
            return .dict(dictionary)
        }
    }

    /// The operand starting with `token`: arrays, dictionaries and procedures are read whole --
    /// with an explicit stack, not recursion, so input nesting cannot exhaust the thread's stack
    /// (import-formats.adoc, "Client", *Nesting*).  A container nested deeper than
    /// `ImportNesting.limit` is read to its closing token and becomes null; an unterminated one
    /// ends at the end of the data.
    private mutating func operand(_ token: PDFImportToken) -> PDFImportOperand {
        guard let close = PDFImportParser.closer(token) else {
            return PDFImportParser.scalar(token)
        }
        var open = [Open(close: close)]
        // The closing tokens of the containers past the limit, innermost last.
        var skipped: [PDFImportToken] = []
        while let token = lexer.next() {
            if let last = skipped.last {
                if token == last {
                    skipped.removeLast()
                    if skipped.isEmpty {
                        open[open.count - 1].items.append(.null)
                    }
                } else if let inner = PDFImportParser.closer(token) {
                    skipped.append(inner)
                }
                continue
            }
            if token == open[open.count - 1].close {
                let done = open.removeLast()
                guard !open.isEmpty else {
                    return PDFImportParser.value(done)
                }
                open[open.count - 1].items.append(PDFImportParser.value(done))
                continue
            }
            if case .comment = token {
                continue
            }
            if let inner = PDFImportParser.closer(token) {
                if open.count < ImportNesting.limit {
                    open.append(Open(close: inner))
                } else {
                    nestingTruncated = true
                    skipped.append(inner)
                }
                continue
            }
            open[open.count - 1].items.append(PDFImportParser.scalar(token))
        }
        // The data ended inside: what is open closes there.
        if !skipped.isEmpty {
            open[open.count - 1].items.append(.null)
        }
        while open.count > 1 {
            let done = open.removeLast()
            open[open.count - 1].items.append(PDFImportParser.value(done))
        }
        return PDFImportParser.value(open[0])
    }

    /// Every operator with its operands, in order; `ID` hands the inline image's data as a
    /// string operand after the image dictionary's entries.
    mutating func forEachOperator(_ body: (String, [PDFImportOperand]) -> Void) {
        var operands: [PDFImportOperand] = []
        while let item = next() {
            switch item {
            case .operand(let operand):
                operands.append(operand)
            case .op(let op):
                if op == "ID" {
                    operands.append(.string(lexer.inlineImageData()))
                }
                body(op, operands)
                operands.removeAll()
            case .comment:
                break
            }
        }
    }
}
