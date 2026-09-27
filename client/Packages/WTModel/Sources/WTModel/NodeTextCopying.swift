import WTCRDT
import WTProto

/// One TEXT field's live contents as plain values: what a deep copy carries for it (copying.adoc,
/// "Data model"; `NodeTree.texts`).  Tombstones and mark history are left behind: the copy is the
/// text as merged at copy time, re-inserted as fresh characters with one mark per span of each
/// winning value and the paragraph registers on each newline.
public struct CopiedText: Hashable, Sendable {
    /// The live characters.
    public var string: String
    /// The winning mark values, by live offsets into `string` (runs may overlap; read from a
    /// document, one run per span of one value).
    public var runs: [TextMarkRun]
    /// The `ParagraphProps` of each U+000A of `string`, in order (tab stops included, their ids
    /// ignored).  A paragraph past the end of the list has none.
    public var paragraphs: [Wiretuner_Doc_V1_ParagraphProps]

    public init(string: String, runs: [TextMarkRun] = [], paragraphs: [Wiretuner_Doc_V1_ParagraphProps] = []) {
        self.string = string
        self.runs = runs
        self.paragraphs = paragraphs
    }

    /// The TEXT field `field` of `node` as merged; nil when it holds no live character.
    public init?(_ node: OpID, _ field: RegisterPath, in state: EngineState) {
        guard let sequence = state.text(node, field), sequence.liveCount > 0 else { return nil }
        let registers = TextNode.paragraphRegisters(node, field: field, in: state)
        self.init(string: sequence.string,
                  runs: sequence.runs.compactMap { run in
                      let values = run.attributes.compactMap { try? Wiretuner_Doc_V1_TextMarkValue(serializedBytes: $0.value) }
                      return values.isEmpty ? nil : TextMarkRun(range: run.start..<run.start + run.length, values: values)
                  },
                  paragraphs: sequence.liveChars.filter { sequence.codepoint($0) == 0x0A }.map { registers[$0] ?? .init() })
        // One run per span, as the pasteboard carries it (so a payload decodes equal).
        runs = spans.map { TextMarkRun(range: $0.range, values: [$0.value]) }
    }

    /// A merge record's text (`MergeText` after substitution): its runs' format values, a
    /// paragraph's last run also covering its newline, and each paragraph's properties on its
    /// newline.
    init(_ text: MergeText) {
        var runs: [TextMarkRun] = []
        var paragraphs: [Wiretuner_Doc_V1_ParagraphProps] = []
        var offset = 0
        for (index, paragraph) in text.paragraphs.enumerated() {
            let terminated = index < text.paragraphs.count - 1
            for (runIndex, run) in paragraph.runs.enumerated() {
                let length = run.text.unicodeScalars.count
                let covers = length + (terminated && runIndex == paragraph.runs.count - 1 ? 1 : 0)
                let formats = run.formats
                if covers > 0, !formats.isEmpty { runs.append(TextMarkRun(range: offset..<offset + covers, values: formats)) }
                offset += length
            }
            if terminated {
                paragraphs.append(paragraph.props)
                offset += 1
            }
        }
        self.init(string: text.string, runs: runs, paragraphs: paragraphs)
    }

    /// One span per value: runs holding the same value back to back are joined, except a
    /// `kerning` mark, whose span is one character pair.  In run order.
    var spans: [(range: Range<Int>, value: Wiretuner_Doc_V1_TextMarkValue)] {
        var spans: [(range: Range<Int>, value: Wiretuner_Doc_V1_TextMarkValue)] = []
        var open: [Wiretuner_Doc_V1_TextMarkValue: Int] = [:]
        let count = string.unicodeScalars.count
        for run in runs where !run.range.isEmpty && run.range.lowerBound >= 0 && run.range.upperBound <= count {
            for value in run.values where value.value != nil {
                if case .kerning? = value.value {
                    spans.append((run.range, value))
                } else if let index = open[value], spans[index].range.upperBound == run.range.lowerBound {
                    spans[index].range = spans[index].range.lowerBound..<run.range.upperBound
                } else {
                    open[value] = spans.count
                    spans.append((run.range, value))
                }
            }
        }
        return spans
    }

    // MARK: Pasteboard

    /// The contents as a `RichText` (the pasteboard's `ClipboardNode.texts`): the live characters
    /// with ids `1 ... n` of replica 0, each newline carrying its paragraph, and one mark per span
    /// from before its first character to after its last.
    var richText: Wiretuner_Doc_V1_RichText {
        var rich = Wiretuner_Doc_V1_RichText()
        var newline = 0
        for (index, scalar) in string.unicodeScalars.enumerated() {
            var char = Wiretuner_Doc_V1_TextChar()
            char.id = OpID(counter: UInt64(index + 1), replica: 0).elementID
            char.codepoint = scalar.value
            if scalar == "\n" {
                if newline < paragraphs.count { char.paragraph = paragraphs[newline] }
                newline += 1
            }
            rich.chars.append(char)
        }
        for span in spans {
            var mark = Wiretuner_Doc_V1_RichTextMark()
            mark.start.char = OpID(counter: UInt64(span.range.lowerBound + 1), replica: 0).elementID
            mark.start.before = true
            mark.end.char = OpID(counter: UInt64(span.range.upperBound), replica: 0).elementID
            mark.value = span.value
            rich.marks.append(mark)
        }
        return rich
    }

    /// The contents a pasteboard `RichText` holds (tombstones skipped; a mark whose anchors name
    /// no character it holds, or that covers nothing, dropped).
    init(_ rich: Wiretuner_Doc_V1_RichText) {
        var scalars = String.UnicodeScalarView()
        var index: [OpID: Int] = [:]
        var paragraphs: [Wiretuner_Doc_V1_ParagraphProps] = []
        for char in rich.chars where !char.deleted {
            guard let scalar = Unicode.Scalar(char.codepoint) else { continue }
            if let id = OpID(element: char.id) { index[id] = scalars.count }
            scalars.append(scalar)
            if scalar == "\n" { paragraphs.append(char.paragraph) }
        }
        let count = scalars.count
        func offset(_ anchor: Wiretuner_Doc_V1_Anchor) -> Int? {
            guard let id = OpID(element: anchor.char) else { return anchor.before ? 0 : count }
            return index[id].map { anchor.before ? $0 : $0 + 1 }
        }
        let runs = rich.marks.compactMap { mark -> TextMarkRun? in
            guard let start = offset(mark.start), let end = offset(mark.end), start < end, mark.value.value != nil else { return nil }
            return TextMarkRun(range: start..<end, values: [mark.value])
        }
        self.init(string: String(scalars), runs: runs, paragraphs: paragraphs)
    }
}

extension NodeTree {
    /// Every TEXT field of `node` in `state` holding live characters, by path.
    static func texts(of node: OpID, in state: EngineState) -> [RegisterPath: CopiedText] {
        var texts: [RegisterPath: CopiedText] = [:]
        for path in state.store.textPaths(node) {
            if let content = CopiedText(node, path, in: state) { texts[path] = content }
        }
        return texts
    }
}

extension NodeCopier {
    /// Scalars per `TextInsert` (the op carries at most 65,536; creating-text.adoc splits long
    /// inserts).
    static let insertChunk = 16_384

    /// Writes `text` into the empty TEXT field `field` of the new node `node`: `TextInsert`s of the
    /// characters (in chunks, each after the one before), one `TextMark` per span with the
    /// attribute's expansion rule, and each newline's paragraph registers and tab stops.  An
    /// `inline_graphic` naming a node copied in the same operation (`mapping`) names the copy;
    /// one naming anything else is left out -- an unset reference, which reads as no mark, so the
    /// placeholder draws the empty box as a dangling one does.
    static func write(_ text: CopiedText, into node: OpID, field: RegisterPath, mapping: [OpID: OpID], builder: inout ChangeBuilder) {
        let scalars = Array(text.string.unicodeScalars)
        guard !scalars.isEmpty else { return }
        var ids: [OpID] = []
        ids.reserveCapacity(scalars.count)
        var start = 0
        while start < scalars.count {
            let end = min(start + insertChunk, scalars.count)
            var chunk = String.UnicodeScalarView()
            chunk.append(contentsOf: scalars[start..<end])
            let first = builder.append(Ops.textInsert(node, field, String(chunk), left: ids.last ?? .zero))
            ids += (0..<(end - start)).map { OpID(counter: first.counter + UInt64($0), replica: first.replica) }
            start = end
        }
        for span in text.spans {
            var value = span.value
            if case .inlineGraphic(let ref)? = value.value {
                guard let copy = mapping[OpID(ref.id)] else { continue }
                value.inlineGraphic.id = copy.proto
            }
            let next = span.range.upperBound < ids.count ? ids[span.range.upperBound] : .zero
            builder.append(TextEditing.mark(node, value, first: ids[span.range.lowerBound], last: ids[span.range.upperBound - 1], next: next,
                                            field: field))
        }
        var newline = 0
        for (offset, scalar) in scalars.enumerated() where scalar == "\n" {
            defer { newline += 1 }
            guard newline < text.paragraphs.count else { break }
            writeParagraph(text.paragraphs[newline], newline: ids[offset], node: node, field: field, builder: &builder)
        }
    }

    /// Writes `paragraph` on newline `newline` of TEXT field `field`: one `SetFields` of the
    /// registers it holds and one `ElementInsert` of its tab stops (fresh ids, in order).
    static func writeParagraph(_ paragraph: Wiretuner_Doc_V1_ParagraphProps, newline: OpID, node: OpID, field: RegisterPath,
                               builder: inout ChangeBuilder) {
        var props = paragraph
        let tabs = props.tabs
        props.tabs = []
        let base = field.element(newline).child(TextFields.paragraphField)
        // `field`'s value holding one character whose paragraph is `body` (a `RichText.chars`
        // element: the register path's element segment below a TEXT field).
        func values(_ body: [UInt8]) -> Wiretuner_Doc_V1_NodeProps {
            (try? Wiretuner_Doc_V1_NodeProps(serializedBytes: wrapped(field, Wire.field(1, Wire.field(TextFields.paragraphField, body))))) ?? .init()
        }
        let fields = TextEditing.presentFields(props)
        if !fields.isEmpty {
            builder.append(Ops.set(node, fields.map { base.child($0) }, values: values(Wire.bytes { try props.serializedBytes() })))
        }
        guard !tabs.isEmpty, let keys = try? PathEditing.keys(between: nil, and: nil, count: tabs.count) else { return }
        let body = tabs.flatMap { tab -> [UInt8] in
            var stop = tab
            stop.clearID()
            return Wire.field(TextFields.tabsField, Wire.bytes { try stop.serializedBytes() })
        }
        builder.append(Ops.elementInsert(node, base.child(TextFields.tabsField), positions: keys, values: values(body)))
    }

    /// Writes the registers `fields` (paths below `ParagraphProps`) of `props` on newline
    /// `newline` of TEXT field `field`, one `SetFields` (an override's paragraph settings, LIB-027).
    static func writeParagraphFields(_ props: Wiretuner_Doc_V1_ParagraphProps, fields: [[UInt32]], newline: OpID, node: OpID, field: RegisterPath,
                                     builder: inout ChangeBuilder) {
        var body = props
        body.tabs = []
        let base = field.element(newline).child(TextFields.paragraphField)
        let bytes = Wire.field(1, Wire.field(TextFields.paragraphField, Wire.bytes { try body.serializedBytes() }))
        let values = (try? Wiretuner_Doc_V1_NodeProps(serializedBytes: wrapped(field, bytes))) ?? .init()
        builder.append(Ops.set(node, fields.map { $0.reduce(base) { $0.child($1) } }, values: values))
    }

    /// `body` (a message's encoding) enclosed at `path` in a whole `NodeProps`: a field segment is
    /// a length-delimited record of it, an element segment an element of the SEQUENCE field before
    /// it, its id as field 1.
    static func wrapped(_ path: RegisterPath, _ body: [UInt8]) -> [UInt8] {
        var bytes = body
        var index = path.segments.count - 1
        while index >= 0 {
            switch path.segments[index] {
            case .field(let number):
                bytes = Wire.field(number, bytes)
                index -= 1
            case .element(let id):
                guard index > 0, case .field(let number) = path.segments[index - 1] else { return bytes }
                bytes = Wire.field(number, Wire.field(1, Wire.elementID(id)) + bytes)
                index -= 2
            }
        }
        return bytes
    }
}
