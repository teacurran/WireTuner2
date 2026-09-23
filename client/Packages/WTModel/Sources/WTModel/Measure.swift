import Foundation

/// A unit of measure numeric fields understand (object-panel.adoc, "Editing values"): the
/// document's unit, and the suffixes a typed value may carry.
public enum MeasureUnit: String, Sendable, CaseIterable, Hashable {
    case points, picas, inches, decimalInches, millimeters, centimeters, pixels

    /// Points per one of this unit (a pixel is a point, 72 per inch).
    public var points: Double {
        switch self {
        case .points, .pixels: 1
        case .picas: 12
        case .inches, .decimalInches: 72
        case .millimeters: 72 / 25.4
        case .centimeters: 72 / 2.54
        }
    }

    /// The suffix the unit formats with.
    public var suffix: String {
        switch self {
        case .points: "pt"
        case .picas: "p"
        case .inches, .decimalInches: "in"
        case .millimeters: "mm"
        case .centimeters: "cm"
        case .pixels: "px"
        }
    }

    /// The unit a typed suffix names.
    static func suffix(_ text: String) -> MeasureUnit? {
        switch text {
        case "pt": .points
        case "p", "pc": .picas
        case "in": .inches
        case "mm": .millimeters
        case "cm": .centimeters
        case "px": .pixels
        default: nil
        }
    }
}

/// Why a typed value was refused: what went wrong and the offset (in characters) of the caret
/// the field shows at the error.
public struct MeasureError: Error, Equatable, Sendable {
    public var message: String
    public var position: Int

    public init(_ message: String, at position: Int) {
        self.message = message
        self.position = position
    }
}

/// Parsing of numeric field input (OBJ-001, object-panel.adoc "Client"): numbers with unit
/// suffixes, the pica-point form `2p6`, `+ - * /` with parentheses, and a trailing `%` meaning a
/// percentage of the field's current value.  A bare number is in the document's unit; results are
/// in points, rounded to 1/1000 pt before they reach a register.
///
/// Grammar: `expr := term (('+'|'-') term)*`, `term := factor (('*'|'/') factor)*`,
/// `factor := ('+'|'-') factor | '(' expr ')' | number [unit | '%' | 'p' number]`.  Arithmetic is
/// done in the document unit (a suffixed number is converted first), so `2in*3` in an inch
/// document is 6 in.
public enum Measure {
    /// The rounding applied to every result: 1/1000 pt.
    public static let resolution = 0.001

    /// Rounds `points` to 1/1000 pt.
    public static func rounded(_ points: Double) -> Double {
        (points / resolution).rounded() * resolution
    }

    /// The value of `text` in points.  `unit` is the document unit bare numbers are in, `current`
    /// the field's value in points (what `%` is a percentage of).
    public static func parse(_ text: String, unit: MeasureUnit = .points, current: Double = 0) throws(MeasureError) -> Double {
        var parser = Parser(text: Array(text), unit: unit, current: current / unit.points)
        let value = try parser.expression()
        parser.skipSpaces()
        guard parser.index == parser.text.count else { throw MeasureError("Unexpected “\(parser.text[parser.index])”", at: parser.index) }
        guard value.isFinite else { throw MeasureError("Not a number", at: parser.text.count) }
        return rounded(value * unit.points)
    }

    /// `points` written in `unit` for a field: up to three decimals and the unit's suffix, picas in
    /// the pica-point form (`2p6`).
    public static func format(_ points: Double, unit: MeasureUnit, suffix: Bool = true) -> String {
        if unit == .picas {
            let total = rounded(points)
            let negative = total < 0
            let picas = (abs(total) / 12).rounded(.down)
            let rest = rounded(abs(total) - picas * 12)
            return (negative ? "-" : "") + "\(number(picas))p\(number(rest))"
        }
        let value = number(points / unit.points)
        return suffix ? "\(value) \(unit.suffix)" : value
    }

    /// A number with at most three decimals and no trailing zeros.
    static func number(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        if rounded == rounded.rounded() { return String(Int64(rounded)) }
        var text = String(format: "%.3f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    private struct Parser {
        let text: [Character]
        let unit: MeasureUnit
        /// The current value in document units.
        let current: Double
        var index = 0

        init(text: [Character], unit: MeasureUnit, current: Double) {
            self.text = text
            self.unit = unit
            self.current = current
        }

        mutating func skipSpaces() {
            while index < text.count, text[index].isWhitespace { index += 1 }
        }

        func peek() -> Character? { index < text.count ? text[index] : nil }

        mutating func expression() throws(MeasureError) -> Double {
            var value = try term()
            while true {
                skipSpaces()
                guard let op = peek(), op == "+" || op == "-" else { return value }
                index += 1
                let rhs = try term()
                value = op == "+" ? value + rhs : value - rhs
            }
        }

        mutating func term() throws(MeasureError) -> Double {
            var value = try factor()
            while true {
                skipSpaces()
                guard let op = peek(), op == "*" || op == "/" else { return value }
                let at = index
                index += 1
                let rhs = try factor()
                if op == "/" {
                    guard rhs != 0 else { throw MeasureError("Division by zero", at: at) }
                    value /= rhs
                } else {
                    value *= rhs
                }
            }
        }

        mutating func factor() throws(MeasureError) -> Double {
            skipSpaces()
            guard let c = peek() else { throw MeasureError("Expected a number", at: index) }
            if c == "-" || c == "+" {
                index += 1
                let value = try factor()
                return c == "-" ? -value : value
            }
            if c == "(" {
                index += 1
                let value = try expression()
                skipSpaces()
                guard peek() == ")" else { throw MeasureError("Expected “)”", at: index) }
                index += 1
                return value
            }
            return try quantity()
        }

        mutating func number() throws(MeasureError) -> Double {
            let start = index
            var seenDot = false
            while let c = peek(), c.isASCII, c.isNumber || (c == "." && !seenDot) {
                if c == "." { seenDot = true }
                index += 1
            }
            let digits = String(text[start..<index])
            guard let value = Double(digits), digits != "." else { throw MeasureError("Expected a number", at: start) }
            return value
        }

        /// A number with an optional unit suffix, `%`, or the pica-point form.
        mutating func quantity() throws(MeasureError) -> Double {
            let value = try number()
            skipSpaces()
            if peek() == "%" {
                index += 1
                return current * value / 100
            }
            let start = index
            while let c = peek(), c.isLetter { index += 1 }
            let word = String(text[start..<index]).lowercased()
            if word.isEmpty { return value }
            guard let suffix = MeasureUnit.suffix(word) else { throw MeasureError("Unknown unit “\(word)”", at: start) }
            var points = value * suffix.points
            if word == "p", let c = peek(), c.isASCII, c.isNumber || c == "." {
                points += try number()
            }
            return points / unit.points
        }
    }
}
