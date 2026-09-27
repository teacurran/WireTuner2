import Foundation
import WTCRDT
import WTProto
import WTRender
import WTText

/// The Text suite of the scripting object model (scripting.adoc, "AppleScript", the Text suite;
/// DOC-026): a text block's `paragraph`, `word` and `character` elements -- and the whole text --
/// with `contents`, `font`, `size`, `leading` and `color`.  Every set is the `WTModel` command the
/// Text panel runs over the same range (`ApplyMark`, `TextColor.fill`, a delete and insert for
/// `contents`), so a script edit is one change like an edit by hand.
extension ScriptObjects {
    /// A text element class.
    public enum TextUnit: String, CaseIterable, Sendable {
        /// The whole text of the block.
        case text
        /// A paragraph, without its closing return.
        case paragraph
        /// A run of letters and digits (an apostrophe between letters stays in the word).
        case word
        /// One character (a Unicode scalar, as the text model counts).
        case character
    }

    /// The family a character without a font mark reads as (the built-in text default).
    public static let defaultFontFamily = "Helvetica"

    /// No element at that index: the documented "no such object", never a silent no-op.
    public struct NoSuchObject: Error, CustomStringConvertible, Hashable {
        public var element: String
        public var index: Int
        public var description: String { "There is no \(element) \(index + 1)" }

        public init(element: String, index: Int) {
            self.element = element
            self.index = index
        }
    }

    /// The live ranges of `unit` in `text`, in order.
    public static func textRanges(_ unit: TextUnit, in text: TextNode) -> [Range<Int>] {
        switch unit {
        case .text:
            return [0..<text.length]
        case .character:
            return (0..<text.length).map { $0..<$0 + 1 }
        case .paragraph:
            return text.paragraphs.map { paragraph in
                paragraph.range.lowerBound..<(paragraph.terminator == nil ? paragraph.range.upperBound : paragraph.range.upperBound - 1)
            }
        case .word:
            let scalars = (0..<text.length).map { text.scalar(at: $0) ?? " " }
            return words(scalars)
        }
    }

    /// The word ranges of `scalars`: runs of letters, digits and marks, an apostrophe inside.
    static func words(_ scalars: [Unicode.Scalar]) -> [Range<Int>] {
        func letter(_ index: Int) -> Bool { index < scalars.count && CharacterSet.alphanumerics.contains(scalars[index]) }
        var result: [Range<Int>] = []
        var start: Int?
        for index in scalars.indices {
            let apostrophe = (scalars[index] == "'" || scalars[index] == "\u{2019}") && start != nil && letter(index + 1)
            if letter(index) || apostrophe {
                if start == nil { start = index }
            } else if let first = start {
                result.append(first..<index)
                start = nil
            }
        }
        if let first = start { result.append(first..<scalars.count) }
        return result
    }

    /// How many `unit` elements the text block `id` has; 0 for a node that is not text.
    public static func textCount(_ unit: TextUnit, of id: OpID, in state: EngineState) -> Int {
        TextNode(id, in: state).map { textRanges(unit, in: $0).count } ?? 0
    }

    /// Property `property` (`contents`, `font`, `size`, `leading` in points, `color` as sRGB
    /// red, green and blue 0...1) of element `index` of `unit` in text block `id`; nil when
    /// there is no such element or property.  An empty element reads the character before it.
    public static func textGet(_ id: OpID, _ unit: TextUnit, _ index: Int, _ property: String, in state: EngineState) -> Any? {
        guard let text = TextNode(id, in: state) else { return nil }
        let ranges = textRanges(unit, in: text)
        guard ranges.indices.contains(index) else { return nil }
        let range = ranges[index]
        if property == "contents" {
            return String(String.UnicodeScalarView((range).compactMap { text.scalar(at: $0) }))
        }
        let offset = range.isEmpty ? max(range.lowerBound - 1, 0) : range.lowerBound
        let attributes = TextLayoutReading.attributes(text.length == 0 ? [] : text.values(at: offset), colors: ColorResolver(state))
        let size = (1...10_000).contains(attributes.size) ? attributes.size : defaultTypeSize
        switch property {
        case "font": return attributes.fontFamily.flatMap { $0.isEmpty ? nil : $0 } ?? defaultFontFamily
        case "size": return size
        case "leading":
            guard let leading = attributes.leading else { return size * 1.2 }
            switch leading.mode {
            case .extra: return size + leading.value
            case .fixed: return leading.value
            case .percent: return size * leading.value / 100
            }
        case "color":
            let rgb = attributes.fill.srgb
            return [rgb.x, rgb.y, rgb.z]
        default: return nil
        }
    }

    /// The command setting `property` of element `index` of `unit` in text block `id`.
    public static func textSetting(_ id: OpID, _ unit: TextUnit, _ index: Int, _ property: String, to value: Any?,
                                   in state: EngineState) throws -> Edit {
        guard let text = TextNode(id, in: state) else { throw TextEditError.notText(id) }
        let ranges = textRanges(unit, in: text)
        guard ranges.indices.contains(index) else { throw NoSuchObject(element: unit.rawValue, index: index) }
        let range = ranges[index]
        let start = text.anchor(at: range.lowerBound)
        let end = text.anchor(at: range.upperBound)
        var mark = Wiretuner_Doc_V1_TextMarkValue()
        switch property {
        case "contents":
            let formats = text.length > 0 ? text.values(at: max(min(range.lowerBound, text.length - 1), 0)).filter {
                if case .field? = $0.value { return false } else { return true }
            } : []
            var commands: [any Command] = range.isEmpty ? [] : [DeleteText(node: id, from: start, to: end)]
            commands.append(InsertText(node: id, text: try string(value), at: start, marks: formats))
            return Edit(CompositeCommand("Script", commands), immediate: true)
        case "font":
            let family = try string(value)
            guard !family.isEmpty else { throw InvalidValue(property: property) }
            mark.fontFamily = family
        case "size":
            mark.size = try points(value, property, in: 1...10_000)
        case "leading":
            var leading = Wiretuner_Doc_V1_Leading()
            leading.mode = .fixed
            leading.value = try points(value, property, in: 0...10_000)
            mark.leading = leading
        case "color":
            guard let components = value as? [Any], components.count == 3 else { throw InvalidValue(property: property) }
            let rgb = try components.map { try points($0, property, in: 0...1) }
            var ref = Wiretuner_Doc_V1_ColorRef()
            ref.inline = ColorValues.stored(Color(red: rgb[0], green: rgb[1], blue: rgb[2]))
            return Edit(TextColor.fill(node: id, from: start, to: end, ref))
        default:
            throw ReadOnly(property: property, kind: unit.rawValue)
        }
        return Edit(ApplyMark(node: id, from: start, to: end, value: mark))
    }

    /// A number in `range`, else the documented invalid value.
    static func points(_ value: Any?, _ property: String, in range: ClosedRange<Double>) throws -> Double {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite, range.contains(number) else { throw InvalidValue(property: property) }
        return number
    }
}
