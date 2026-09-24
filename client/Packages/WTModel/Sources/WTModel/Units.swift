import Foundation
import WTCRDT
import WTProto

/// A unit of length for display and entry (document-panel.adoc, "Document units"; rulers.adoc).
/// Stored values are always points; a unit only changes how numbers are shown and typed.
public enum LengthUnit: Hashable, Sendable {
    case points
    /// Picas and points, 12 points to the pica, written `7p6`.
    case picas
    /// Inches.  Shown to four decimals, like *Decimal inches* at one more place.
    case inches
    case decimalInches
    case millimeters
    case centimeters
    /// Kyus: 0.25 mm.
    case kyus
    /// Pixels: 1 px = 1 pt at 72 dpi.
    case pixels
    /// An element of `SettingsProps.custom_units`.
    case custom(OpID)

    /// The built-in units, in the order of the *Units* pop-up.
    public static let standard: [LengthUnit] = [.points, .picas, .inches, .decimalInches, .millimeters, .centimeters, .kyus, .pixels]

    /// The name the *Units* pop-up shows (a custom unit's is its own name, `Units.name(of:)`).
    public var name: String {
        switch self {
        case .points: "Points"
        case .picas: "Picas"
        case .inches: "Inches"
        case .decimalInches: "Decimal inches"
        case .millimeters: "Millimeters"
        case .centimeters: "Centimeters"
        case .kyus: "Kyus"
        case .pixels: "Pixels"
        case .custom: "Custom"
        }
    }

    /// The suffix formatting appends and parsing reads first (`pt`, `p`, `in`, `mm` ...); empty
    /// for a custom unit, whose suffix is its name.
    public var abbreviation: String {
        switch self {
        case .points: "pt"
        case .picas: "p"
        case .inches, .decimalInches: "in"
        case .millimeters: "mm"
        case .centimeters: "cm"
        case .kyus: "q"
        case .pixels: "px"
        case .custom: ""
        }
    }

    /// Points in one of this unit; nil for a custom unit (it depends on its definition).
    public var pointsPerUnit: Double? {
        switch self {
        case .points, .pixels: 1
        case .picas: 12
        case .inches, .decimalInches: 72
        case .millimeters: 72 / 25.4
        case .centimeters: 720 / 25.4
        case .kyus: 18 / 25.4
        case .custom: nil
        }
    }

    /// The step a value in this unit is rounded to when shown (document-panel.adoc, "Client").
    public var displayPrecision: Double {
        switch self {
        case .points, .pixels, .picas, .millimeters, .custom: 0.01
        case .inches: 0.0001
        case .decimalInches, .centimeters: 0.001
        case .kyus: 0.1
        }
    }

    /// The stored enum of a built-in unit (`.custom` stores `UNIT_CUSTOM` with its element).
    public var stored: Wiretuner_Doc_V1_Unit {
        switch self {
        case .points: .points
        case .picas: .picas
        case .inches: .inches
        case .decimalInches: .decimalInches
        case .millimeters: .millimeters
        case .centimeters: .centimeters
        case .kyus: .kyus
        case .pixels: .pixels
        case .custom: .custom
        }
    }

    /// The built-in unit `stored` names; `UNSPECIFIED`, `CUSTOM` and unknown values read as points.
    public init(builtIn stored: Wiretuner_Doc_V1_Unit) {
        switch stored {
        case .picas: self = .picas
        case .inches: self = .inches
        case .decimalInches: self = .decimalInches
        case .millimeters: self = .millimeters
        case .centimeters: self = .centimeters
        case .kyus: self = .kyus
        case .pixels: self = .pixels
        default: self = .points
        }
    }

    /// The stored `UnitChoice` of this unit.
    public var choice: Wiretuner_Doc_V1_UnitChoice {
        var choice = Wiretuner_Doc_V1_UnitChoice()
        choice.unit = stored
        if case .custom(let id) = self { choice.custom = id.elementID }
        return choice
    }
}

/// A user-defined unit (rulers.adoc, *Edit Units*): one of it equals `amount` of `base`.
public struct CustomUnit: Identifiable, Hashable, Sendable {
    public var id: OpID
    public var name: String
    public var amount: Double
    /// Never `.custom`: a custom base reads as points (document.proto, `UnitDefinition.base`).
    public var base: LengthUnit

    public init(id: OpID, name: String, amount: Double, base: LengthUnit) {
        self.id = id
        self.name = name
        self.amount = amount
        if case .custom = base { self.base = .points } else { self.base = base }
    }

    /// Points in one of this unit; a non-positive or non-finite amount reads as one point.
    public var pointsPerUnit: Double {
        let value = amount * (base.pointsPerUnit ?? 1)
        return value.isFinite && value > 0 ? value : 1
    }
}

/// Field entry and display in document units (DOC-003; document-panel.adoc, "Typing values in
/// another unit" and "Arithmetic in fields").
///
/// Parsing reads a decimal number with an optional unit suffix (the longest match among the
/// built-in suffixes and the custom units' names, ignoring case), pica notation `7p6` (7 picas 6
/// points) and the infix operators `+ - * /` with multiplication and division first.  A number
/// without a suffix is in the document's unit, except as a factor of `*` or divisor of `/`,
/// where it is a plain number (`4*50-49` is 151 document units; `2i * 3` is 6 inches).
/// Formatting rounds to the unit's display precision.
public struct Units: Hashable, Sendable {
    /// The unit a number without a suffix is in, and the one values are shown in.
    public var documentUnit: LengthUnit
    /// The document's custom units, in sequence order.
    public var customUnits: [CustomUnit]

    public init(documentUnit: LengthUnit = .points, customUnits: [CustomUnit] = []) {
        self.documentUnit = documentUnit
        self.customUnits = customUnits
    }

    /// The units `settings` choose.
    public init(_ settings: DocumentSettings) {
        self.init(documentUnit: settings.units, customUnits: settings.customUnits)
    }

    /// The built-in suffixes (document-panel.adoc, the suffix table).
    static let builtInSuffixes: [(String, LengthUnit)] = [
        ("pt", .points), ("p", .picas), ("in", .inches), ("i", .inches), ("mm", .millimeters), ("m", .millimeters),
        ("cm", .centimeters), ("c", .centimeters), ("q", .kyus), ("px", .pixels), ("x", .pixels),
    ]

    /// The custom unit `id` names, if it is one of the document's.
    public func custom(_ id: OpID) -> CustomUnit? {
        customUnits.first { $0.id == id }
    }

    /// The custom unit a suffix names: the one with the smaller element id among duplicates
    /// (rulers.adoc, "Read-time normalizations").
    public func custom(named name: String) -> CustomUnit? {
        let key = name.lowercased()
        return customUnits.filter { $0.name.lowercased() == key && !$0.name.isEmpty }.min { $0.id < $1.id }
    }

    /// The name of `unit` as shown: a custom unit's own name.
    public func name(of unit: LengthUnit) -> String {
        if case .custom(let id) = unit { return custom(id)?.name ?? "Custom" }
        return unit.name
    }

    /// The suffix of `unit` as formatting writes it.
    public func suffix(of unit: LengthUnit) -> String {
        if case .custom(let id) = unit { return custom(id)?.name ?? "pt" }
        return unit.abbreviation
    }

    /// Points in one `unit`; a custom unit the document no longer has counts as a point.
    public func pointsPerUnit(_ unit: LengthUnit) -> Double {
        if case .custom(let id) = unit { return custom(id)?.pointsPerUnit ?? 1 }
        return unit.pointsPerUnit ?? 1
    }

    /// `value` in `from` expressed in `to`.
    public func convert(_ value: Double, from: LengthUnit, to: LengthUnit) -> Double {
        value * pointsPerUnit(from) / pointsPerUnit(to)
    }

    // MARK: Formatting

    /// `points` shown in `unit` (the document's by default), rounded to the unit's display
    /// precision; picas as `NpM`.  With `suffix` the unit's suffix follows (`12 pt`, `3p6`).
    public func format(_ points: Double, in unit: LengthUnit? = nil, suffix: Bool = false) -> String {
        let unit = unit ?? documentUnit
        guard points.isFinite else { return "0" }
        if unit == .picas { return Self.formatPicas(points) }
        let precision = unit.displayPrecision
        let value = (points / pointsPerUnit(unit) / precision).rounded() * precision
        let text = Self.decimal(value, places: Self.places(precision))
        return suffix ? "\(text) \(self.suffix(of: unit))" : text
    }

    /// `points` rounded to what `format` would show, in points (the round-trip reference).
    public func rounded(_ points: Double, in unit: LengthUnit? = nil) -> Double {
        let unit = unit ?? documentUnit
        if unit == .picas { return (points * 100).rounded() / 100 }
        let precision = unit.displayPrecision
        return (points / pointsPerUnit(unit) / precision).rounded() * precision * pointsPerUnit(unit)
    }

    static func formatPicas(_ points: Double) -> String {
        let negative = points < 0
        let hundredths = (abs(points) * 100).rounded()
        let picas = (hundredths / 1200).rounded(.down)
        let rest = (hundredths - picas * 1200) / 100
        return (negative && hundredths > 0 ? "-" : "") + "\(Int(picas))p" + decimal(rest, places: 2)
    }

    static func places(_ precision: Double) -> Int {
        max(0, Int((-log10(precision)).rounded()))
    }

    /// `value` with at most `places` decimals, trailing zeros dropped.
    static func decimal(_ value: Double, places: Int) -> String {
        var text = String(format: "%.\(places)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    // MARK: Parsing

    /// The value of the field text `text` in points, or nil when it cannot be evaluated (the
    /// field then shows its previous value; nothing is changed).
    public func parse(_ text: String) -> Double? {
        var parser = Parser(scalars: Array(text.unicodeScalars), units: self)
        guard let value = parser.expression(), parser.atEnd, value.value.isFinite else { return nil }
        return value.hasUnit ? value.value : value.value * pointsPerUnit(documentUnit)
    }

    /// An intermediate value: points when `hasUnit`, else a plain number.
    struct Quantity {
        var value: Double
        var hasUnit: Bool
    }

    /// A recursive-descent parser over `expression := term (('+'|'-') term)*`,
    /// `term := factor (('*'|'/') factor)*`, `factor := '-' factor | '(' expression ')' | number [suffix]`.
    struct Parser {
        let scalars: [Unicode.Scalar]
        let units: Units
        var index = 0

        init(scalars: [Unicode.Scalar], units: Units) {
            self.scalars = scalars
            self.units = units
        }

        var atEnd: Bool {
            mutating get {
                skipSpaces()
                return index == scalars.count
            }
        }

        mutating func skipSpaces() {
            while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
        }

        mutating func peek() -> Unicode.Scalar? {
            skipSpaces()
            return index < scalars.count ? scalars[index] : nil
        }

        /// Converts a unitless side of `+`/`-` to points in the document unit.
        func points(_ q: Quantity) -> Double {
            q.hasUnit ? q.value : q.value * units.pointsPerUnit(units.documentUnit)
        }

        mutating func expression() -> Quantity? {
            guard var left = term() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                index += 1
                guard let right = term() else { return nil }
                if left.hasUnit || right.hasUnit {
                    let sum = op == "+" ? points(left) + points(right) : points(left) - points(right)
                    left = Quantity(value: sum, hasUnit: true)
                } else {
                    left.value = op == "+" ? left.value + right.value : left.value - right.value
                }
            }
            return left
        }

        mutating func term() -> Quantity? {
            guard var left = factor() else { return nil }
            while let op = peek(), op == "*" || op == "/" {
                index += 1
                guard let right = factor() else { return nil }
                if op == "*" {
                    // A length times a length has no meaning in a length field.
                    guard !(left.hasUnit && right.hasUnit) else { return nil }
                    left = Quantity(value: left.value * right.value, hasUnit: left.hasUnit || right.hasUnit)
                } else {
                    guard right.value != 0 else { return nil }
                    // A length over a length is a plain ratio.
                    left = Quantity(value: left.value / right.value, hasUnit: left.hasUnit && !right.hasUnit)
                }
            }
            return left
        }

        mutating func factor() -> Quantity? {
            guard let next = peek() else { return nil }
            if next == "-" || next == "+" {
                index += 1
                guard var inner = factor() else { return nil }
                if next == "-" { inner.value = -inner.value }
                return inner
            }
            if next == "(" {
                index += 1
                guard let inner = expression(), peek() == ")" else { return nil }
                index += 1
                return inner
            }
            // Pica notation may omit the picas: `p6` is six points.
            guard let amount = number() ?? (isPicaStart ? 0 : nil) else { return nil }
            guard let (unit, length) = suffix() else { return Quantity(value: amount, hasUnit: false) }
            index += length
            if unit == .picas, let points = number() {
                return Quantity(value: amount * 12 + points, hasUnit: true)
            }
            return Quantity(value: amount * units.pointsPerUnit(unit), hasUnit: true)
        }

        var isPicaStart: Bool {
            index < scalars.count && (scalars[index] == "p" || scalars[index] == "P")
                && index + 1 < scalars.count && ("0"..."9").contains(scalars[index + 1])
        }

        /// An unsigned decimal at the cursor (no spaces skipped inside it).
        mutating func number() -> Double? {
            let start = index
            var digits = 0
            while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1; digits += 1 }
            if index < scalars.count, scalars[index] == "." {
                index += 1
                while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1; digits += 1 }
            }
            guard digits > 0, let value = Double(String(String.UnicodeScalarView(scalars[start..<index]))) else {
                index = start
                return nil
            }
            return value
        }

        /// The longest suffix at the cursor (spaces before it allowed) and its length, leaving the
        /// cursor before it.  A custom unit's name wins only when it is strictly longer than a
        /// built-in match.
        mutating func suffix() -> (LengthUnit, Int)? {
            skipSpaces()
            let rest = String(String.UnicodeScalarView(scalars[index...])).lowercased()
            var best: (LengthUnit, Int)?
            for (text, unit) in Units.builtInSuffixes where rest.hasPrefix(text) && text.count > (best?.1 ?? 0) {
                best = (unit, text.unicodeScalars.count)
            }
            for unit in units.customUnits.sorted(by: { $0.id < $1.id }) where !unit.name.isEmpty {
                let name = unit.name.lowercased()
                guard rest.hasPrefix(name), name.unicodeScalars.count > (best?.1 ?? 0),
                      let resolved = units.custom(named: unit.name) else { continue }
                best = (.custom(resolved.id), name.unicodeScalars.count)
            }
            guard let found = best else { return nil }
            // A suffix must end the word: `3pts` is not `3p` followed by `ts`.
            let end = index + found.1
            if end < scalars.count, scalars[end].properties.isAlphabetic, !(found.0 == .picas && ("0"..."9").contains(scalars[end])) {
                return nil
            }
            return found
        }
    }
}
