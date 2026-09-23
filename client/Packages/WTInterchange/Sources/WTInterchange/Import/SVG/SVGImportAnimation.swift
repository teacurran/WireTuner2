// Animated-SVG detection (svg-animation.adoc, "Client", *Import*; WEB-025 reuses it): which
// animation mechanisms a file uses -- CSS (`@keyframes`, `animation`, `transition`), SMIL
// (`animate`, `animateTransform`, `animateMotion`, `animateColor`, `set`) and script (`<script>`,
// `on…` event attributes) -- and its declared duration: the largest of every SMIL end
// (`begin` + `dur` × `repeatCount`, or `end`) and every CSS animation's delay + duration ×
// iteration count, 0 when any of them is indefinite.  The importer places an animated file
// rather than converting it; the poster is WEB-025's.

import Foundation

/// What `SVGImporter.animationInfo(_:)` found.
public struct SVGAnimationInfo: Hashable, Sendable {
    public var css: Bool
    public var smil: Bool
    public var script: Bool
    /// The declared duration in milliseconds; 0 = indefinite (or nothing timed).
    public var durationMs: UInt64

    public init(css: Bool = false, smil: Bool = false, script: Bool = false, durationMs: UInt64 = 0) {
        self.css = css
        self.smil = smil
        self.script = script
        self.durationMs = durationMs
    }

    /// Whether the file animates at all.
    public var isAnimated: Bool { css || smil || script }

    /// The placed-file kind for this analysis.
    public var placedKind: ImportedPlacedFile.Kind {
        .svgAnimation(css: css, smil: smil, script: script, durationMs: durationMs)
    }
}

enum SVGImportAnimation {
    static let smilElements: Set<String> = ["animate", "animateTransform", "animateMotion", "animateColor", "set"]

    /// The analysis of a parsed file.
    static func scan(_ root: SVGImportElement) -> SVGAnimationInfo {
        var info = SVGAnimationInfo()
        var ends: [Double?] = []
        for element in root.descendants {
            if smilElements.contains(element.name) {
                info.smil = true
                ends.append(smilEnd(element))
            }
            if element.name == "script" {
                info.script = true
            }
            if element.attributes.keys.contains(where: { $0.lowercased().hasPrefix("on") }) {
                info.script = true
            }
            var css: [String] = []
            if element.name == "style" {
                css.append(element.text)
                if element.text.contains("@keyframes") {
                    info.css = true
                }
            }
            if let style = element.attributes["style"] {
                css.append(style)
            }
            for text in css {
                let declarations = SVGImportStyleSheet.declarations(declarationText(text))
                if declarations.contains(where: { $0.property.hasPrefix("animation") || $0.property.hasPrefix("transition") }) {
                    info.css = true
                }
                ends += cssEnds(declarations)
            }
        }
        if ends.contains(where: { $0 == nil }) {
            info.durationMs = 0
        } else {
            let longest = ends.compactMap { $0 }.max() ?? 0
            info.durationMs = UInt64(max(longest, 0) * 1000 + 0.5)
        }
        return info
    }

    /// The declarations inside a style sheet's blocks (every block, at-rules included, flattened)
    /// or a `style` attribute.
    static func declarationText(_ text: String) -> String {
        guard text.contains("{") else {
            return text
        }
        var result: [String] = []
        var depth = 0
        var current = ""
        for character in SVGImportStyleSheet.stripComments(text) {
            switch character {
            case "{":
                depth += 1
                current = ""
            case "}":
                depth -= 1
                result.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        return result.joined(separator: ";")
    }

    /// A SMIL element's end in seconds; nil when indefinite.
    static func smilEnd(_ element: SVGImportElement) -> Double? {
        let begin = element.attributes["begin"].flatMap { clock($0.split(separator: ";").first.map(String.init) ?? "") } ?? 0
        if let end = element.attributes["end"] {
            return clock(end)
        }
        guard let durText = element.attributes["dur"] else {
            // No duration: a `set` or an unbounded animation holds from its begin.
            return element.name == "set" ? begin : nil
        }
        guard let dur = clock(durText) else {
            return nil
        }
        if let repeatCount = element.attributes["repeatCount"] {
            guard let count = Double(repeatCount.trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return begin + dur * count
        }
        if let repeatDur = element.attributes["repeatDur"] {
            return clock(repeatDur).map { begin + $0 }
        }
        return begin + dur
    }

    /// Every CSS animation's and transition's end in seconds (nil when infinite).
    static func cssEnds(_ declarations: [SVGImportDeclaration]) -> [Double?] {
        var durations: [Double] = []
        var delays: [Double] = []
        var counts: [Double?] = []
        var ends: [Double?] = []
        for declaration in declarations {
            switch declaration.property {
            case "animation", "transition":
                for item in declaration.value.split(separator: ",") {
                    let tokens = item.split(whereSeparator: \.isWhitespace).map(String.init)
                    let times = tokens.compactMap(cssTime)
                    let infinite = tokens.contains("infinite")
                    let count = tokens.compactMap { Double($0) }.first ?? 1
                    let duration = times.first ?? 0
                    let delay = times.count > 1 ? times[1] : 0
                    ends.append(infinite ? nil : delay + duration * count)
                }
            case "animation-duration", "transition-duration":
                durations += declaration.value.split(separator: ",").compactMap { cssTime(String($0).trimmingCharacters(in: .whitespaces)) }
            case "animation-delay", "transition-delay":
                delays += declaration.value.split(separator: ",").compactMap { cssTime(String($0).trimmingCharacters(in: .whitespaces)) }
            case "animation-iteration-count":
                counts += declaration.value.split(separator: ",").map { item -> Double? in
                    let text = item.trimmingCharacters(in: .whitespaces)
                    return text == "infinite" ? nil : (Double(text) ?? 1)
                }
            default:
                break
            }
        }
        for (index, duration) in durations.enumerated() {
            let count: Double?? = counts.isEmpty ? .some(1) : counts[index % counts.count]
            let delay = delays.isEmpty ? 0 : delays[index % delays.count]
            ends.append(count.flatMap { $0 }.map { delay + duration * $0 })
        }
        return ends
    }

    /// `1.5s`, `200ms`.
    static func cssTime(_ text: String) -> Double? {
        if text.hasSuffix("ms") {
            return Double(text.dropLast(2))
                .map { $0 / 1000 }
        }
        if text.hasSuffix("s") {
            return Double(text.dropLast())
        }
        return nil
    }

    /// A SMIL clock value in seconds: `2s`, `150ms`, `0.5min`, `1h`, `02:30`, `00:01:02.5`, a
    /// bare number of seconds; nil for `indefinite` and anything unreadable.
    static func clock(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.contains(":") {
            let parts = text.split(separator: ":").map { Double($0) }
            guard parts.allSatisfy({ $0 != nil }), (2...3).contains(parts.count) else {
                return nil
            }
            return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        }
        for (suffix, scale) in [("ms", 0.001), ("min", 60.0), ("h", 3600.0), ("s", 1.0)] where text.hasSuffix(suffix) {
            return Double(text.dropLast(suffix.count)).map { $0 * scale }
        }
        return Double(text)
    }
}
