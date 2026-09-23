import Foundation
import WTRender

/// Colours as text (COLOR-002): the default swatch names of swatches.adoc ("Names"), the value
/// field's form, and the CSS Color 4 parser the Color Mixer's field and the Object panel's value
/// field share (color-mixer.adoc, applying-color.adoc).  Every default name parses back to the
/// colour it names, which formats to the same string.
public enum ColorText {
    // MARK: Formatting

    /// The default name of a colour in its own space: `0c 80m 90y 0k` (CMYK percentages),
    /// `230r 57g 70b` (sRGB, 0--255), `p3(0.90 0.22 0.27)`, `lab(54 63 32)` and
    /// `oklch(62% 0.22 25)` (OKLab in its polar form).
    public static func defaultName(_ color: Color) -> String {
        let c = color.clampedToSpace.components
        switch color.space {
        case .cmyk:
            return "\(percent(c.x))c \(percent(c.y))m \(percent(c.z))y \(percent(c.w))k"
        case .sRGB:
            return "\(byte(c.x))r \(byte(c.y))g \(byte(c.z))b"
        case .displayP3, .lab, .oklab:
            return field(color)
        }
    }

    /// The value field's form of a colour (applying-color.adoc, "The Object panel's color
    /// controls"): `#E63946` for sRGB, otherwise the default name.
    public static func field(_ color: Color) -> String {
        let c = color.clampedToSpace.components
        switch color.space {
        case .cmyk:
            return defaultName(color)
        case .sRGB:
            return String(format: "#%02X%02X%02X", byte(c.x), byte(c.y), byte(c.z))
        case .displayP3:
            return "p3(\(fixed(c.x)) \(fixed(c.y)) \(fixed(c.z)))"
        case .lab:
            return "lab(\(whole(c.x)) \(whole(c.y)) \(whole(c.z)))"
        case .oklab:
            let lch = WTColor.Math.oklch(fromOKLab: SIMD3(c.x, c.y, c.z))
            let chroma = (lch.y * 100).rounded() / 100
            var hue = chroma == 0 ? 0 : Int(lch.z.rounded())
            hue = ((hue % 360) + 360) % 360
            return "oklch(\(Int((lch.x * 100).rounded()))% \(fixed(chroma)) \(hue))"
        }
    }

    /// A tint's derived name (tints.adoc): the percentage, then the base's name -- `40% Grape`.
    public static func tintName(percent: Double, base: String) -> String {
        "\(Int(percent.rounded()))% \(base)"
    }

    /// `name`, or `name-1`, `name-2` ... -- the first that `isTaken` refuses.
    public static func unique(_ name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        var n = 1
        while isTaken("\(name)-\(n)") {
            n += 1
        }
        return "\(name)-\(n)"
    }

    private static func percent(_ v: Double) -> Int { Int((v * 100).rounded()) }
    private static func byte(_ v: Double) -> Int { Int((v * 255).rounded()) }
    private static func whole(_ v: Double) -> Int { Int(v.rounded()) }
    private static func fixed(_ v: Double) -> String { String(format: "%.2f", v) }

    // MARK: Parsing

    /// The colour `text` names, or nil: `#rgb`, `#rrggbb` (and the forms with alpha, which is
    /// ignored) as sRGB; `rgb()`/`rgba()` (0--255 or percentages) as sRGB; `color(srgb …)` and
    /// `color(display-p3 …)`; the `p3(…)` shorthand; `lab()`, `oklab()` and `oklch()` (CSS Color
    /// 4 units, `%` included); and the default names `0c 80m 90y 0k` and `230r 57g 70b`.
    /// Case and surrounding space are ignored.
    public static func parse(_ text: String) -> Color? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") {
            return hex(String(s.dropFirst()))
        }
        if let open = s.firstIndex(of: "("), s.hasSuffix(")") {
            let name = s[..<open].trimmingCharacters(in: .whitespaces)
            let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
            let body = inner.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let args = body.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map(String.init)
            return functional(name, args)
        }
        return mixName(s.split(separator: " ").map(String.init))
    }

    private static func hex(_ digits: String) -> Color? {
        let values = digits.compactMap(\.hexDigitValue)
        guard values.count == digits.count else { return nil }
        let channels: [Int]
        switch values.count {
        case 3, 4: channels = values.prefix(3).map { $0 * 17 }
        case 6, 8: channels = (0..<3).map { values[2 * $0] * 16 + values[2 * $0 + 1] }
        default: return nil
        }
        return Color(red: Double(channels[0]) / 255, green: Double(channels[1]) / 255, blue: Double(channels[2]) / 255)
    }

    /// A number, or a percentage of `scale`; `none` is 0.
    private static func number(_ token: String, percent scale: Double) -> Double? {
        if token == "none" { return 0 }
        if token.hasSuffix("%") {
            return Double(token.dropLast()).map { $0 / 100 * scale }
        }
        return Double(token)
    }

    private static func functional(_ name: String, _ args: [String]) -> Color? {
        switch name {
        case "rgb", "rgba":
            guard args.count >= 3 else { return nil }
            var rgb: [Double] = []
            for token in args.prefix(3) {
                guard let value = token.hasSuffix("%") ? number(token, percent: 1) : Double(token).map({ $0 / 255 }) else { return nil }
                rgb.append(value)
            }
            return Color(red: rgb[0], green: rgb[1], blue: rgb[2]).clampedToSpace
        case "color":
            guard args.count >= 4 else { return nil }
            let space: Color.Space
            switch args[0] {
            case "srgb": space = .sRGB
            case "display-p3": space = .displayP3
            default: return nil
            }
            return triple(Array(args.dropFirst()), scales: (1, 1, 1)).map { Color(space: space, components: SIMD4($0.0, $0.1, $0.2, 0)).clampedToSpace }
        case "p3":
            return triple(args, scales: (1, 1, 1)).map { Color(displayP3Red: $0.0, green: $0.1, blue: $0.2).clampedToSpace }
        case "lab":
            return triple(args, scales: (100, 125, 125)).map { Color(labL: $0.0, a: $0.1, b: $0.2).clampedToSpace }
        case "oklab":
            return triple(args, scales: (1, 0.4, 0.4)).map { Color(oklabL: $0.0, a: $0.1, b: $0.2).clampedToSpace }
        case "oklch":
            guard args.count >= 3, let l = number(args[0], percent: 1), let c = number(args[1], percent: 0.4),
                  let h = number(args[2].hasSuffix("deg") ? String(args[2].dropLast(3)) : args[2], percent: 360) else { return nil }
            return Color(oklchL: l, chroma: max(c, 0), hue: h).clampedToSpace
        default:
            return nil
        }
    }

    private static func triple(_ args: [String], scales: (Double, Double, Double)) -> (Double, Double, Double)? {
        guard args.count >= 3, let x = number(args[0], percent: scales.0), let y = number(args[1], percent: scales.1),
              let z = number(args[2], percent: scales.2) else { return nil }
        return (x, y, z)
    }

    /// `0c 80m 90y 0k` or `230r 57g 70b`.
    private static func mixName(_ tokens: [String]) -> Color? {
        func values(_ suffixes: String, scale: Double) -> [Double]? {
            guard tokens.count == suffixes.count else { return nil }
            var result: [Double] = []
            for (token, suffix) in zip(tokens, suffixes) {
                guard token.last == suffix, let value = Double(token.dropLast()) else { return nil }
                result.append(value / scale)
            }
            return result
        }
        if let cmyk = values("cmyk", scale: 100) {
            return Color(cyan: cmyk[0], magenta: cmyk[1], yellow: cmyk[2], black: cmyk[3]).clampedToSpace
        }
        if let rgb = values("rgb", scale: 255) {
            return Color(red: rgb[0], green: rgb[1], blue: rgb[2]).clampedToSpace
        }
        return nil
    }
}
