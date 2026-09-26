import Foundation
import WTCRDT
import WTProto
import WTText

// TYPE-018: the leading and kerning drags of a text block's handles (type-tools.adoc, "Adjusting
// by dragging").  The arithmetic is here, the handles in WTApp: a drag of the top or bottom centre
// handle moves the block's leading, a drag of a side handle its range kerning, each written at
// mouse-up as one mark over the whole text.

/// What a text block handle drag adjusts, and the value it lands on.
public enum TypeHandleDrag {
    /// Which setting a handle drag adjusts.
    public enum Kind: Hashable, Sendable {
        /// The top or bottom centre handle: leading.
        case leading
        /// A side handle: range kerning.
        case kerning
    }

    /// The leading a percent-mode or unset leading reads as (auto).
    public static let autoPercent = 120.0

    /// The leading change per line for a drag of `distance` points away from the block (negative:
    /// toward its centre) over `lines` laid-out lines, so the dragged edge follows the pointer.
    public static func leadingDelta(distance: Double, lines: Int) -> Double {
        distance / Double(max(lines, 1))
    }

    /// The range kerning change, percent of an em, for a drag of `distance` points away from the
    /// block over a line of `characters` characters at `size` points, so the dragged side follows
    /// the pointer.
    public static func kerningDelta(distance: Double, size: Double, characters: Int) -> Double {
        guard size > 0 else { return 0 }
        return distance / size * 100 / Double(max(characters - 1, 1))
    }

    /// The leading of the first character's attributes moved by `delta` points per line, in the
    /// mode it has (unset reads as auto, 120%).  Fine drags land on tenths; `coarse` (kbd:[Shift])
    /// on whole points (+ and =) or whole percent (%).  The line never goes below zero height.
    public static func leading(_ attributes: TextAttributes, delta: Double, coarse: Bool) -> Wiretuner_Doc_V1_Leading {
        let current = attributes.leading ?? WTText.Leading(mode: .percent, value: autoPercent)
        let size = max(attributes.size, 0.1)
        var result = Wiretuner_Doc_V1_Leading()
        let step = coarse ? 1.0 : 10.0
        switch current.mode {
        case .extra:
            result.mode = .extra
            result.value = max(round(current.value + delta, step), -size)
        case .fixed:
            result.mode = .fixed
            result.value = max(round(current.value + delta, step), 0)
        case .percent:
            result.mode = .percent
            result.value = max(round(current.value + delta / size * 100, step), 0)
        }
        return result
    }

    /// The range kerning of the first character's attributes moved by `delta` percent; tenths, or
    /// whole percent when `coarse`.
    public static func rangeKerning(_ attributes: TextAttributes, delta: Double, coarse: Bool) -> Double {
        round(attributes.rangeKerning + delta, coarse ? 1 : 10)
    }

    /// The readout while dragging: "+2 pt", "=14 pt", "130%" for leading; "5%" for kerning.
    public static func readout(_ value: Wiretuner_Doc_V1_TextMarkValue) -> String {
        switch value.value {
        case .leading(let leading)?:
            let number = format(leading.value)
            switch leading.mode {
            case .fixed: return "Leading =\(number) pt"
            case .percent: return "Leading \(number)%"
            default: return "Leading \(leading.value >= 0 ? "+" : "")\(number) pt"
            }
        case .rangeKerning(let kerning)?: return "Range kerning \(format(kerning))%"
        default: return ""
        }
    }

    /// The mark a drag of `kind` by `delta` (points of leading per line, or percent of kerning)
    /// writes, read from the text's first character; nil for an empty text.
    public static func mark(_ kind: Kind, text: TextNode, delta: Double, coarse: Bool) -> Wiretuner_Doc_V1_TextMarkValue? {
        guard text.length > 0 else { return nil }
        let attributes = TextLayoutReading.attributes(text.values(at: 0))
        var value = Wiretuner_Doc_V1_TextMarkValue()
        switch kind {
        case .leading: value.leading = leading(attributes, delta: delta, coarse: coarse)
        case .kerning: value.rangeKerning = rangeKerning(attributes, delta: delta, coarse: coarse)
        }
        return value
    }

    /// The one change a drag writes: `value` over the whole text, "Leading" or "Kern".  Nil for an
    /// empty text.
    public static func command(node: OpID, text: TextNode, value: Wiretuner_Doc_V1_TextMarkValue) -> ApplyMark? {
        guard text.length > 0 else { return nil }
        let label = if case .rangeKerning? = value.value { "Kern" } else { "Leading" }
        return ApplyMark(node: node, from: text.anchor(at: 0), to: text.anchor(at: text.length), value: value, label: label)
    }

    static func round(_ value: Double, _ perUnit: Double) -> Double {
        (value * perUnit).rounded() / perUnit
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
