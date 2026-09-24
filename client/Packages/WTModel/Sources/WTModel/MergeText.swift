import Foundation
import WTCRDT
import WTProto
import WTText

// DATA-016/019: a text node's contents as paragraphs of formatted runs, so placeholders can be
// replaced by a record's values (preview, merge to pages, merge to output) and blank lines
// removed, then laid out (`content`) or written into a copy (`MergeToPages`).

/// A text node's characters as paragraphs of runs, each run with its winning mark values and
/// the ids of the characters it came from.
public struct MergeText: Hashable, Sendable {
    public struct Run: Hashable, Sendable {
        public var text: String
        /// The winning mark values, `field` marks included until substitution removes them.
        public var values: [Wiretuner_Doc_V1_TextMarkValue]
        /// One id per scalar of `text`: the source characters (a substituted value repeats the
        /// placeholder's first character id).
        public var ids: [OpID]

        public init(text: String, values: [Wiretuner_Doc_V1_TextMarkValue], ids: [OpID]) {
            self.text = text
            self.values = values
            self.ids = ids
        }

        /// The stored field id of the run's `field` mark (the zero id reads as a missing field).
        var field: Wiretuner_Doc_V1_ElementId? {
            values.lazy.compactMap { value -> Wiretuner_Doc_V1_ElementId? in
                if case .field(let id)? = value.value { return id }
                return nil
            }.first
        }

        /// The values without the `field` mark.
        var formats: [Wiretuner_Doc_V1_TextMarkValue] {
            values.filter { if case .field? = $0.value { return false } else { return true } }
        }
    }

    public struct Paragraph: Hashable, Sendable {
        public var runs: [Run]
        public var props: Wiretuner_Doc_V1_ParagraphProps
        /// The terminating newline's id (nil for the last paragraph).
        public var terminator: OpID?
        /// The paragraph held at least one placeholder before substitution.
        public var hadPlaceholder = false

        public var string: String { runs.map(\.text).joined() }
    }

    public var paragraphs: [Paragraph]

    /// The live text, paragraphs joined by newlines.
    public var string: String { paragraphs.map(\.string).joined(separator: "\n") }

    /// The contents of `text` as merged.
    public init(_ text: TextNode) {
        let scalars = Array(text.string.unicodeScalars)
        let source = text.paragraphs
        var paragraphs = source.map { Paragraph(runs: [], props: $0.props, terminator: $0.terminator) }
        var index = 0
        for run in text.runs {
            var offset = run.range.lowerBound
            while offset < run.range.upperBound {
                // Move to the paragraph holding `offset`.
                while index < paragraphs.count - 1, offset >= source[index].range.upperBound { index += 1 }
                let end = min(run.range.upperBound, source[index].range.upperBound)
                // The terminator is implicit between paragraphs.
                let bodyEnd = paragraphs[index].terminator != nil && end == source[index].range.upperBound ? end - 1 : end
                if bodyEnd > offset {
                    var view = String.UnicodeScalarView()
                    view.append(contentsOf: scalars[offset..<bodyEnd])
                    paragraphs[index].runs.append(Run(text: String(view), values: run.values, ids: Array(text.chars[offset..<bodyEnd])))
                }
                offset = end
            }
        }
        for index in paragraphs.indices where paragraphs[index].runs.contains(where: { $0.field != nil }) {
            paragraphs[index].hadPlaceholder = true
        }
        self.paragraphs = paragraphs
    }

    public init(paragraphs: [Paragraph]) {
        self.paragraphs = paragraphs
    }

    // MARK: Substitution

    /// The text with every placeholder replaced: by `value(field)` for a live field when a value
    /// is given, `{{missing}}` for a missing field.  A value's line breaks become line
    /// separators (U+2028) so the paragraph structure is the template's.  Adjacent runs of one
    /// placeholder are replaced once, in the first run's formatting.
    public func substituting(_ value: (Wiretuner_Doc_V1_ElementId) -> String?) -> MergeText {
        var result = self
        for index in result.paragraphs.indices {
            var runs: [Run] = []
            var previous: Wiretuner_Doc_V1_ElementId?
            for run in result.paragraphs[index].runs {
                guard let field = run.field else {
                    runs.append(run)
                    previous = nil
                    continue
                }
                if field == previous { continue }
                previous = field
                guard let text = value(field) else {
                    runs.append(run)
                    continue
                }
                let placed = Self.oneLine(text)
                runs.append(Run(text: placed, values: run.formats, ids: Array(repeating: run.ids.first ?? .zero, count: placed.unicodeScalars.count)))
            }
            result.paragraphs[index].runs = runs.filter { !$0.text.isEmpty }
        }
        return result
    }

    /// The whole text replaced by `value` (a TEXT binding): one paragraph in the first
    /// character's formatting and the last paragraph's properties.
    public func replacingAll(with value: String) -> MergeText {
        let first = paragraphs.lazy.flatMap(\.runs).first
        let placed = Self.oneLine(value)
        let run = Run(text: placed, values: first?.formats ?? [], ids: Array(repeating: first?.ids.first ?? .zero, count: placed.unicodeScalars.count))
        let last = paragraphs[paragraphs.count - 1]
        return MergeText(paragraphs: [Paragraph(runs: placed.isEmpty ? [] : [run], props: last.props, terminator: nil)])
    }

    /// *Remove blank lines*: every paragraph that held a placeholder and whose remaining
    /// characters are whitespace or punctuation is removed with its terminator (the last
    /// paragraph with the newline before it).  At least one paragraph always remains.
    public func removingBlankLines() -> MergeText {
        var kept = paragraphs.filter { paragraph in
            !(paragraph.hadPlaceholder && paragraph.string.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) || CharacterSet.punctuationCharacters.contains($0) })
        }
        if kept.isEmpty {
            var only = paragraphs[paragraphs.count - 1]
            only.runs = []
            only.terminator = nil
            kept = [only]
        } else if paragraphs.last?.terminator == nil, kept.last?.terminator != nil {
            // The last paragraph went: the paragraph before it becomes the last one.
            kept[kept.count - 1].terminator = nil
            kept[kept.count - 1].props = paragraphs[paragraphs.count - 1].props
        }
        return MergeText(paragraphs: kept)
    }

    /// The text with every `size` mark (and the default 12 pt where none is set) scaled by
    /// `factor` (shrink-to-fit).
    public func scaled(by factor: Double) -> MergeText {
        var result = self
        for p in result.paragraphs.indices {
            for r in result.paragraphs[p].runs.indices {
                var values = result.paragraphs[p].runs[r].values
                if let index = values.firstIndex(where: { if case .size? = $0.value { return true } else { return false } }) {
                    values[index].size *= factor
                } else {
                    var size = Wiretuner_Doc_V1_TextMarkValue()
                    size.size = 12 * factor
                    values.append(size)
                }
                result.paragraphs[p].runs[r].values = values
            }
        }
        return result
    }

    /// The largest type size in the text (12 where no size is set).
    public var largestSize: Double {
        paragraphs.flatMap(\.runs).map { run in
            run.values.lazy.compactMap { value -> Double? in
                if case .size(let size)? = value.value, size > 0 { return size }
                return nil
            }.first ?? 12
        }.max() ?? 12
    }

    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\u{2028}").replacingOccurrences(of: "\n", with: "\u{2028}").replacingOccurrences(of: "\r", with: "\u{2028}")
    }

    // MARK: Layout

    /// The contents as WTText lays them out, colours resolved through `colors`.
    public func content(colors: ColorResolver? = nil) -> TextContent {
        var runs: [WTText.TextRun] = []
        var ids: [CharID] = []
        for (index, paragraph) in paragraphs.enumerated() {
            for run in paragraph.runs {
                runs.append(WTText.TextRun(run.text, attributes: TextLayoutReading.attributes(run.formats, colors: colors)))
                ids += run.ids.map { CharID(counter: $0.counter, replica: $0.replica) }
            }
            if index < paragraphs.count - 1 {
                let values = paragraph.runs.last?.formats ?? []
                runs.append(WTText.TextRun("\n", attributes: TextLayoutReading.attributes(values, colors: colors)))
                let id = paragraph.terminator ?? .zero
                ids.append(CharID(counter: id.counter, replica: id.replica))
            }
        }
        return TextContent(runs: runs, paragraphs: paragraphs.map { TextLayoutReading.paragraphStyle($0.props) }, charIDs: ids)
    }
}
