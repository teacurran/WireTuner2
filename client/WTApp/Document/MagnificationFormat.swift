import Foundation
import WTRender

/// The status bar magnification field (workspace.adoc, "Client"): `"400"`, `"400%"` and
/// `"4x"` all mean 400%; values are clamped to 6%--25,600% and rounded to two decimals of a
/// percent.
enum MagnificationFormat {
    struct Parsed: Equatable {
        /// Zoom factor (1 = 100%), in range.
        let zoom: Double
        /// Whether the typed value was outside the range and clamped (the field beeps).
        let wasClamped: Bool
    }

    /// `nil` for text that is not a magnification.
    static func parse(_ text: String) -> Parsed? {
        var body = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "").lowercased()
        var multiplier = false
        if body.hasSuffix("x") || body.hasSuffix("×") {
            multiplier = true
            body.removeLast()
        } else if body.hasSuffix("%") {
            body.removeLast()
        }
        body = body.trimmingCharacters(in: .whitespaces)
        guard let number = Double(body), number.isFinite else { return nil }
        let percent = multiplier ? number * 100 : number
        let range = Viewport.zoomRange
        let requested = percent / 100
        let clampedZoom = min(max(requested, range.lowerBound), range.upperBound)
        let rounded = (clampedZoom * 100 * 100).rounded() / 100 / 100
        return Parsed(zoom: rounded, wasClamped: clampedZoom != requested)
    }

    /// `"150%"`, `"6%"`, `"33.33%"`, `"25600%"`.
    static func string(for zoom: Double) -> String {
        let percent = (zoom * 100 * 100).rounded() / 100
        if percent == percent.rounded() {
            return "\(Int(percent))%"
        }
        var text = String(format: "%.2f", percent)
        while text.hasSuffix("0") { text.removeLast() }
        return text + "%"
    }

    /// The presets the field's pop-up lists (the full zoom ladder).
    static var presetTitles: [String] { ZoomLadder.presets.map(string(for:)) }
}
