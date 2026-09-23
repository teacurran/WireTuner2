// A flow split into paragraphs, each with what its shaping depends on as one hashable key, so
// an edit re-typesets only the paragraphs whose key changed (TXT-001, incremental relayout).

/// A range of a paragraph's scalars in one set of attributes.
struct AttributeSpan: Hashable, Sendable {
    var length: Int
    var attributes: TextAttributes
}

/// Everything a paragraph's typesetting depends on.  The hash is computed once: keys are
/// looked up on every layout.
struct ParagraphKey: Hashable, @unchecked Sendable {
    let text: String
    let spans: [AttributeSpan]
    /// The attributes at the paragraph's end (its newline's), which give an empty paragraph
    /// its height.
    let terminator: TextAttributes
    let style: ParagraphStyle
    let vertical: Bool
    private let hash: Int

    init(text: String, spans: [AttributeSpan], terminator: TextAttributes, style: ParagraphStyle, vertical: Bool) {
        self.text = text
        self.spans = spans
        self.terminator = terminator
        self.style = style
        self.vertical = vertical
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(spans)
        hasher.combine(terminator)
        hasher.combine(style)
        hasher.combine(vertical)
        hash = hasher.finalize()
    }

    /// The same paragraph for the other writing direction.
    func with(vertical: Bool) -> ParagraphKey {
        vertical == self.vertical ? self : ParagraphKey(text: text, spans: spans, terminator: terminator, style: style, vertical: vertical)
    }

    static func == (lhs: ParagraphKey, rhs: ParagraphKey) -> Bool {
        lhs.hash == rhs.hash && lhs.vertical == rhs.vertical && lhs.text == rhs.text && lhs.spans == rhs.spans
            && lhs.terminator == rhs.terminator && lhs.style == rhs.style
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(hash)
    }
}

/// One paragraph of a flow.
struct ParagraphSource: Sendable {
    let key: ParagraphKey
    /// Global scalar offset of the first character.
    let start: Int
    /// Scalars, without the terminating newline.
    let length: Int
    /// Whether a U+000A ends it (every paragraph but the tail).
    let terminated: Bool
}

extension TextContent {
    /// The flow's paragraphs, horizontal keys.  Missing paragraph styles read as the default;
    /// extra ones are ignored.
    func splitParagraphs() -> [ParagraphSource] {
        var result: [ParagraphSource] = []
        var text = ""
        var spans: [AttributeSpan] = []
        var length = 0
        var start = 0
        var lastAttributes = runs.last?.attributes.normalized ?? TextAttributes()

        func append(_ piece: Substring.UnicodeScalarView, count: Int, attributes: TextAttributes) {
            guard count > 0 else {
                return
            }
            text.unicodeScalars.append(contentsOf: piece)
            if let last = spans.last, last.attributes == attributes {
                spans[spans.count - 1].length += count
            } else {
                spans.append(AttributeSpan(length: count, attributes: attributes))
            }
            length += count
        }

        func finish(terminated: Bool, terminator: TextAttributes) {
            let index = result.count
            let style = index < paragraphs.count ? paragraphs[index] : ParagraphStyle()
            let key = ParagraphKey(text: text, spans: spans, terminator: terminator, style: style, vertical: false)
            result.append(ParagraphSource(key: key, start: start, length: length, terminated: terminated))
            start += length + (terminated ? 1 : 0)
            text = ""
            spans = []
            length = 0
        }

        for sourceRun in runs {
            let run = TextRun(sourceRun.text, attributes: sourceRun.attributes.normalized)
            let scalars = Substring(run.text).unicodeScalars
            var segmentStart = scalars.startIndex
            var count = 0
            var index = scalars.startIndex
            while index != scalars.endIndex {
                if scalars[index] == "\n" {
                    append(scalars[segmentStart..<index], count: count, attributes: run.attributes)
                    finish(terminated: true, terminator: run.attributes)
                    segmentStart = scalars.index(after: index)
                    count = 0
                } else {
                    count += 1
                }
                index = scalars.index(after: index)
            }
            append(scalars[segmentStart...], count: count, attributes: run.attributes)
            lastAttributes = run.attributes
        }
        finish(terminated: false, terminator: lastAttributes)
        return result
    }
}
