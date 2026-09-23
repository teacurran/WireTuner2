// SVG attribute value grammars for the importer (IMG-012): number lists in SVG's compact syntax
// (`1.5.5`, `1e-3`, `10-5`), lengths with units at 96 px/in, colours (CSS Color 4: named, hex,
// `rgb()`, `hsl()`, `color(display-p3 …)`), transform lists, and path data.  Every parser is
// total: bad input yields nil or stops at the error, as SVG's error handling asks, never a trap.

import Foundation
import WTGeometry
import WTRender

enum SVGImportValues {
    // MARK: Numbers

    /// The numbers in `text` in SVG's number-list syntax, stopping at the first thing that is not
    /// a number, a separator or a flag.
    static func numbers(_ text: String) -> [Double] {
        var scanner = NumberScanner(text)
        var result: [Double] = []
        while let value = scanner.number() {
            result.append(value)
        }
        return result
    }

    /// A scanner over SVG number syntax.
    struct NumberScanner {
        let chars: [UInt8]
        var index = 0

        init(_ text: String) {
            chars = Array(text.utf8)
        }

        mutating func skipSeparators() {
            while index < chars.count, chars[index] == 0x20 || chars[index] == 0x2C || chars[index] == 0x09 || chars[index] == 0x0A || chars[index] == 0x0D {
                index += 1
            }
        }

        /// The next character after separators, without consuming it.
        mutating func peek() -> UInt8? {
            skipSeparators()
            return index < chars.count ? chars[index] : nil
        }

        /// An arc flag: a single `0` or `1`, which may be followed directly by the next number.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < chars.count, chars[index] == 0x30 || chars[index] == 0x31 else {
                return nil
            }
            defer { index += 1 }
            return chars[index] == 0x31
        }

        mutating func number() -> Double? {
            skipSeparators()
            let start = index
            func isDigit(_ i: Int) -> Bool { i < chars.count && chars[i] >= 0x30 && chars[i] <= 0x39 }
            var i = index
            if i < chars.count, chars[i] == 0x2B || chars[i] == 0x2D {
                i += 1
            }
            var digits = false
            while isDigit(i) {
                i += 1
                digits = true
            }
            if i < chars.count, chars[i] == 0x2E {
                i += 1
                while isDigit(i) {
                    i += 1
                    digits = true
                }
            }
            guard digits else {
                return nil
            }
            if i < chars.count, chars[i] == 0x65 || chars[i] == 0x45 {
                var j = i + 1
                if j < chars.count, chars[j] == 0x2B || chars[j] == 0x2D {
                    j += 1
                }
                if isDigit(j) {
                    while isDigit(j) {
                        j += 1
                    }
                    i = j
                }
            }
            index = i
            // strtod over a terminated copy of exactly the scanned characters.
            let count = i - start
            return withUnsafeTemporaryAllocation(of: CChar.self, capacity: count + 1) { buffer in
                for offset in 0..<count {
                    buffer[offset] = CChar(bitPattern: chars[start + offset])
                }
                buffer[count] = 0
                return strtod(buffer.baseAddress!, nil)
            }
        }
    }

    // MARK: Lengths

    /// Pixels per unit as a fraction (user units are CSS pixels, 96 per inch), applied as
    /// `value × numerator / denominator` so points-sized files convert back exactly.
    static let unitScale: [String: (Double, Double)] = ["": (1, 1), "px": (1, 1), "pt": (4, 3), "pc": (16, 1), "mm": (96, 25.4), "cm": (96, 2.54), "in": (96, 1)]

    /// A length in user units; `percentOf` is what 100% is, `fontSize` what 1em is.
    static func length(_ text: String?, percentOf reference: Double = 0, fontSize: Double = 16) -> Double? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        var scanner = NumberScanner(text)
        guard let value = scanner.number() else {
            return nil
        }
        let unit = String(decoding: scanner.chars[scanner.index...], as: UTF8.self).trimmingCharacters(in: .whitespaces).lowercased()
        switch unit {
        case "%": return value / 100 * reference
        case "em": return value * fontSize
        case "ex": return value * fontSize / 2
        default: return unitScale[unit].map { value * $0.0 / $0.1 }
        }
    }

    /// A list of lengths (`x="1 2 3"`).
    static func lengths(_ text: String?, percentOf reference: Double = 0, fontSize: Double = 16) -> [Double] {
        guard let text else {
            return []
        }
        return text.split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline || $0 == "\t" }).compactMap { length(String($0), percentOf: reference, fontSize: fontSize) }
    }

    // MARK: Colours

    /// A colour, or nil for `none`, a paint server or anything unreadable.  `current` is
    /// `currentColor`'s value.
    static func color(_ raw: String, current: Color = .black) -> Color? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if text == "currentcolor" {
            return current
        }
        if text == "transparent" {
            return .clear
        }
        if text.hasPrefix("#") {
            return hex(String(text.dropFirst()))
        }
        if let open = text.firstIndex(of: "("), text.hasSuffix(")") {
            let function = String(text[..<open]).trimmingCharacters(in: .whitespaces)
            let arguments = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            return functional(function, arguments)
        }
        guard let rgb = namedColors[text] else {
            return nil
        }
        return Color(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    static func hex(_ digits: String) -> Color? {
        guard [3, 4, 6, 8].contains(digits.utf8.count), let value = UInt32(digits, radix: 16) else {
            return nil
        }
        var values: [Double]
        switch digits.utf8.count {
        case 3, 4:
            let count = digits.utf8.count
            values = (0..<count).map { Double((value >> UInt32(4 * (count - 1 - $0))) & 0xF) * 17 / 255 }
        default:
            let count = digits.utf8.count / 2
            values = (0..<count).map { Double((value >> UInt32(8 * (count - 1 - $0))) & 0xFF) / 255 }
        }
        if values.count == 3 {
            values.append(1)
        }
        return Color(red: values[0], green: values[1], blue: values[2], alpha: values[3])
    }

    /// `rgb()`, `rgba()`, `hsl()`, `hsla()` and `color(display-p3 …)` / `color(srgb …)`.
    static func functional(_ function: String, _ arguments: String) -> Color? {
        let parts = arguments.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" || $0 == "\t" }).map(String.init)
        func component(_ text: String, scale: Double) -> Double? {
            if text.hasSuffix("%") {
                return Double(text.dropLast()).map { $0 / 100 }
            }
            return Double(text).map { $0 / scale }
        }
        func alpha(_ index: Int) -> Double {
            parts.count > index ? (component(parts[index], scale: 1) ?? 1) : 1
        }
        switch function {
        case "rgb", "rgba":
            guard parts.count >= 3, let r = component(parts[0], scale: 255), let g = component(parts[1], scale: 255), let b = component(parts[2], scale: 255) else {
                return nil
            }
            return Color(red: r, green: g, blue: b, alpha: alpha(3))
        case "hsl", "hsla":
            guard parts.count >= 3, let h = Double(parts[0].replacingOccurrences(of: "deg", with: "")), let s = component(parts[1], scale: 100), let l = component(parts[2], scale: 100) else {
                return nil
            }
            let rgb = hslToRGB(h: h, s: s, l: l)
            return Color(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha(3))
        case "color":
            guard parts.count >= 4, let r = component(parts[1], scale: 1), let g = component(parts[2], scale: 1), let b = component(parts[3], scale: 1) else {
                return nil
            }
            switch parts[0] {
            case "display-p3": return Color(displayP3Red: r, green: g, blue: b, alpha: alpha(4))
            case "srgb": return Color(red: r, green: g, blue: b, alpha: alpha(4))
            default: return nil
            }
        default:
            return nil
        }
    }

    static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        let hue = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(hue + 1.0 / 3), channel(hue), channel(hue - 1.0 / 3))
    }

    /// The CSS / SVG named colours.
    static let namedColors: [String: UInt32] = [
        "aliceblue": 0xF0F8FF, "antiquewhite": 0xFAEBD7, "aqua": 0x00FFFF, "aquamarine": 0x7FFFD4, "azure": 0xF0FFFF,
        "beige": 0xF5F5DC, "bisque": 0xFFE4C4, "black": 0x000000, "blanchedalmond": 0xFFEBCD, "blue": 0x0000FF,
        "blueviolet": 0x8A2BE2, "brown": 0xA52A2A, "burlywood": 0xDEB887, "cadetblue": 0x5F9EA0, "chartreuse": 0x7FFF00,
        "chocolate": 0xD2691E, "coral": 0xFF7F50, "cornflowerblue": 0x6495ED, "cornsilk": 0xFFF8DC, "crimson": 0xDC143C,
        "cyan": 0x00FFFF, "darkblue": 0x00008B, "darkcyan": 0x008B8B, "darkgoldenrod": 0xB8860B, "darkgray": 0xA9A9A9,
        "darkgreen": 0x006400, "darkgrey": 0xA9A9A9, "darkkhaki": 0xBDB76B, "darkmagenta": 0x8B008B, "darkolivegreen": 0x556B2F,
        "darkorange": 0xFF8C00, "darkorchid": 0x9932CC, "darkred": 0x8B0000, "darksalmon": 0xE9967A, "darkseagreen": 0x8FBC8F,
        "darkslateblue": 0x483D8B, "darkslategray": 0x2F4F4F, "darkslategrey": 0x2F4F4F, "darkturquoise": 0x00CED1, "darkviolet": 0x9400D3,
        "deeppink": 0xFF1493, "deepskyblue": 0x00BFFF, "dimgray": 0x696969, "dimgrey": 0x696969, "dodgerblue": 0x1E90FF,
        "firebrick": 0xB22222, "floralwhite": 0xFFFAF0, "forestgreen": 0x228B22, "fuchsia": 0xFF00FF, "gainsboro": 0xDCDCDC,
        "ghostwhite": 0xF8F8FF, "gold": 0xFFD700, "goldenrod": 0xDAA520, "gray": 0x808080, "grey": 0x808080,
        "green": 0x008000, "greenyellow": 0xADFF2F, "honeydew": 0xF0FFF0, "hotpink": 0xFF69B4, "indianred": 0xCD5C5C,
        "indigo": 0x4B0082, "ivory": 0xFFFFF0, "khaki": 0xF0E68C, "lavender": 0xE6E6FA, "lavenderblush": 0xFFF0F5,
        "lawngreen": 0x7CFC00, "lemonchiffon": 0xFFFACD, "lightblue": 0xADD8E6, "lightcoral": 0xF08080, "lightcyan": 0xE0FFFF,
        "lightgoldenrodyellow": 0xFAFAD2, "lightgray": 0xD3D3D3, "lightgreen": 0x90EE90, "lightgrey": 0xD3D3D3, "lightpink": 0xFFB6C1,
        "lightsalmon": 0xFFA07A, "lightseagreen": 0x20B2AA, "lightskyblue": 0x87CEFA, "lightslategray": 0x778899, "lightslategrey": 0x778899,
        "lightsteelblue": 0xB0C4DE, "lightyellow": 0xFFFFE0, "lime": 0x00FF00, "limegreen": 0x32CD32, "linen": 0xFAF0E6,
        "magenta": 0xFF00FF, "maroon": 0x800000, "mediumaquamarine": 0x66CDAA, "mediumblue": 0x0000CD, "mediumorchid": 0xBA55D3,
        "mediumpurple": 0x9370DB, "mediumseagreen": 0x3CB371, "mediumslateblue": 0x7B68EE, "mediumspringgreen": 0x00FA9A, "mediumturquoise": 0x48D1CC,
        "mediumvioletred": 0xC71585, "midnightblue": 0x191970, "mintcream": 0xF5FFFA, "mistyrose": 0xFFE4E1, "moccasin": 0xFFE4B5,
        "navajowhite": 0xFFDEAD, "navy": 0x000080, "oldlace": 0xFDF5E6, "olive": 0x808000, "olivedrab": 0x6B8E23,
        "orange": 0xFFA500, "orangered": 0xFF4500, "orchid": 0xDA70D6, "palegoldenrod": 0xEEE8AA, "palegreen": 0x98FB98,
        "paleturquoise": 0xAFEEEE, "palevioletred": 0xDB7093, "papayawhip": 0xFFEFD5, "peachpuff": 0xFFDAB9, "peru": 0xCD853F,
        "pink": 0xFFC0CB, "plum": 0xDDA0DD, "powderblue": 0xB0E0E6, "purple": 0x800080, "rebeccapurple": 0x663399,
        "red": 0xFF0000, "rosybrown": 0xBC8F8F, "royalblue": 0x4169E1, "saddlebrown": 0x8B4513, "salmon": 0xFA8072,
        "sandybrown": 0xF4A460, "seagreen": 0x2E8B57, "seashell": 0xFFF5EE, "sienna": 0xA0522D, "silver": 0xC0C0C0,
        "skyblue": 0x87CEEB, "slateblue": 0x6A5ACD, "slategray": 0x708090, "slategrey": 0x708090, "snow": 0xFFFAFA,
        "springgreen": 0x00FF7F, "steelblue": 0x4682B4, "tan": 0xD2B48C, "teal": 0x008080, "thistle": 0xD8BFD8,
        "tomato": 0xFF6347, "turquoise": 0x40E0D0, "violet": 0xEE82EE, "wheat": 0xF5DEB3, "white": 0xFFFFFF,
        "whitesmoke": 0xF5F5F5, "yellow": 0xFFFF00, "yellowgreen": 0x9ACD32,
    ]

    // MARK: Transforms

    /// A transform list (`translate(10) rotate(45 5 5) matrix(…)`), applied right to left as
    /// SVG composes it; an unreadable function ends the list (keeping what came before).
    static func transform(_ text: String?) -> AffineTransform {
        guard let text else {
            return .identity
        }
        var result = AffineTransform.identity
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            let v = numbers(String(rest[rest.index(after: open)..<close]))
            guard let function = function(name, v) else {
                break
            }
            // The list reads left to right as outer to inner: the rightmost applies first.
            result = function.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    static func function(_ name: String, _ v: [Double]) -> AffineTransform? {
        switch (name, v.count) {
        case ("matrix", 6):
            return AffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        case ("translate", 1), ("translate", 2):
            return .translation(x: v[0], y: v.count > 1 ? v[1] : 0)
        case ("scale", 1), ("scale", 2):
            return .scale(x: v[0], y: v.count > 1 ? v[1] : v[0])
        case ("rotate", 1):
            return .rotation(radians: v[0] * .pi / 180)
        case ("rotate", 3):
            return .rotation(radians: v[0] * .pi / 180, around: Point(x: v[1], y: v[2]))
        case ("skewX", 1):
            return AffineTransform(a: 1, b: 0, c: tan(v[0] * .pi / 180), d: 1, tx: 0, ty: 0)
        case ("skewY", 1):
            return AffineTransform(a: 1, b: tan(v[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
        default:
            return nil
        }
    }

    // MARK: Path data

    /// Path data (SVG 1.1 §8.3 grammar) as contours.  Parsing stops at the first error and keeps
    /// what was read, as SVG's error rules say.
    static func pathData(_ text: String) -> [ImportedContour] {
        var scanner = NumberScanner(text)
        var builder = ImportPathBuilder()
        var command: UInt8 = 0
        var current = Point.zero
        var subpathStart = Point.zero
        var lastControl: Point?
        var lastCommand: UInt8 = 0
        while true {
            guard let next = scanner.peek() else {
                break
            }
            let isLetter = (next >= 0x41 && next <= 0x5A) || (next >= 0x61 && next <= 0x7A)
            if isLetter {
                command = next
                scanner.index += 1
            } else if command == 0 {
                break
            }
            let relative = command >= 0x61
            let base = relative ? current : .zero
            func point() -> Point? {
                guard let x = scanner.number(), let y = scanner.number() else {
                    return nil
                }
                return Point(x: base.x + x, y: base.y + y)
            }
            let upper = relative ? command - 0x20 : command
            var control: Point?
            switch upper {
            case 0x4D: // M
                guard let p = point() else { return builder.build() }
                builder.move(to: p)
                current = p
                subpathStart = p
                // Further pairs are implicit line-tos.
                command = relative ? 0x6C : 0x4C
            case 0x4C: // L
                guard let p = point() else { return builder.build() }
                builder.line(to: p)
                current = p
            case 0x48: // H
                guard let x = scanner.number() else { return builder.build() }
                current = Point(x: base.x + x, y: current.y)
                builder.line(to: current)
            case 0x56: // V
                guard let y = scanner.number() else { return builder.build() }
                current = Point(x: current.x, y: (relative ? current.y : 0) + y)
                builder.line(to: current)
            case 0x43: // C
                guard let c1 = point(), let c2 = point(), let p = point() else { return builder.build() }
                builder.cubic(c1, c2, p)
                control = c2
                current = p
            case 0x53: // S
                guard let c2 = point(), let p = point() else { return builder.build() }
                let c1 = [0x43, 0x53].contains(lastCommand) ? reflect(lastControl!, current) : current
                builder.cubic(c1, c2, p)
                control = c2
                current = p
            case 0x51: // Q
                guard let c = point(), let p = point() else { return builder.build() }
                builder.quad(c, p)
                control = c
                current = p
            case 0x54: // T
                guard let p = point() else { return builder.build() }
                let c = [0x51, 0x54].contains(lastCommand) ? reflect(lastControl!, current) : current
                builder.quad(c, p)
                control = c
                current = p
            case 0x41: // A
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = point() else {
                    return builder.build()
                }
                builder.svgArc(rx: rx, ry: ry, rotationDegrees: rotation, largeArc: large, sweep: sweep, to: p)
                current = p
            case 0x5A: // Z
                builder.close()
                current = subpathStart
                command = 0
            default:
                return builder.build()
            }
            lastControl = control
            lastCommand = upper
        }
        return builder.build()
    }

    /// `control` reflected about `around` (the previous curve's control, which S and T mirror).
    static func reflect(_ control: Point, _ around: Point) -> Point {
        return Point(x: 2 * around.x - control.x, y: 2 * around.y - control.y)
    }
}
