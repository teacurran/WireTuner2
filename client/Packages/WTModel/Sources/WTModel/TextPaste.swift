import WTCRDT
import WTGeometry
import WTInterchange
import WTProto

/// Text as the Text tool pastes it (importing-text.adoc, "Pasting", "Dragging text in"; TYPE-009):
/// the characters with every mark value and each newline's paragraph properties (`CopiedText`), the
/// inline graphics the characters name (their subtrees, read with their source ids), and whether
/// it is plain -- plain text takes the look of the text it lands in.  Read from a {product} copy it
/// keeps every attribute; from another application's rich text through `TextAttributeMapping` (the
/// import table); from plain text as characters alone.
///
/// On the pasteboard it is `pasteboardType`: a hand-encoded message of the `RichText` the object
/// clipboard carries for a TEXT field (field 1), the graphics as a `ClipboardPayload` (field 2) and
/// a plain marker (field 3).
public struct TextClip: Hashable, Sendable {
    /// The pasteboard type of a {product} text copy.
    public static let pasteboardType = "com.villagecompute.wiretuner.text"

    public var text: CopiedText
    /// The inline graphics' subtrees (`NodeTree.source` names the child each was read from).
    public var graphics: [NodeTree]
    /// Characters only: pasted in the insertion point's look.
    public var plain: Bool

    public init(text: CopiedText, graphics: [NodeTree] = [], plain: Bool = false) {
        self.text = text
        self.graphics = graphics
        self.plain = plain
    }

    /// Plain text, its line ends (CR LF, CR) read as paragraph ends.
    public init(plain string: String) {
        let normalized = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        self.init(text: CopiedText(string: normalized), plain: true)
    }

    /// The live characters `range` of text node `node`: their marks, the properties of each newline
    /// inside the range, and the live inline graphics they place.  Nil when `node` is not text or the
    /// range holds nothing.
    public init?(copying range: Range<Int>, of node: OpID, in state: EngineState) {
        guard let text = state.textNode(node) else { return nil }
        let clamped = range.clamped(to: 0..<text.length)
        guard !clamped.isEmpty else { return nil }
        let scalars = Array(text.string.unicodeScalars)
        var string = String.UnicodeScalarView()
        string.append(contentsOf: scalars[clamped])
        let runs = text.runs.compactMap { run -> TextMarkRun? in
            let overlap = run.range.clamped(to: clamped)
            guard !overlap.isEmpty, !run.values.isEmpty else { return nil }
            return TextMarkRun(range: overlap.lowerBound - clamped.lowerBound..<overlap.upperBound - clamped.lowerBound, values: run.values)
        }
        let paragraphs = text.paragraphs.filter { $0.terminator != nil && clamped.contains($0.range.upperBound - 1) }.map(\.props)
        let graphics = InlineGraphics.placements(text).filter { clamped.contains($0.offset) && state.isLive($0.graphic) }
            .map { NodeTree($0.graphic, state: state) }
        self.init(text: CopiedText(string: String(string), runs: runs, paragraphs: paragraphs), graphics: graphics)
    }

    /// Another application's text as read by `TextImporter`: each run's marks and each paragraph's
    /// properties through `TextAttributeMapping` (plain text: none).  Style names and an RTFD's
    /// pictures are left out (a paste into a block creates no styles or images; an import does).
    public init(_ file: ImportedTextFile) {
        var string = String.UnicodeScalarView()
        var runs: [TextMarkRun] = []
        var paragraphs: [Wiretuner_Doc_V1_ParagraphProps] = []
        for (index, paragraph) in file.paragraphs.enumerated() {
            let terminated = index < file.paragraphs.count - 1
            let kept = paragraph.runs.filter { $0.graphic == nil && $0.text != "\u{FFFC}" }
            for (runIndex, run) in kept.enumerated() {
                let scalars = Array((run.attributes.allCaps ? run.text.uppercased() : run.text).unicodeScalars)
                let covers = scalars.count + (terminated && runIndex == kept.count - 1 ? 1 : 0)
                let values = file.plain ? [] : TextAttributeMapping.marks(run.attributes, lineSpacing: paragraph.style.lineSpacing)
                if covers > 0, !values.isEmpty {
                    runs.append(TextMarkRun(range: string.count..<string.count + covers, values: values))
                }
                string.append(contentsOf: scalars)
            }
            if terminated {
                string.append("\n")
                paragraphs.append(file.plain ? .init() : TextAttributeMapping.paragraph(paragraph.style).props)
            }
        }
        self.init(text: CopiedText(string: String(string), runs: runs, paragraphs: paragraphs), plain: file.plain)
    }

    /// The characters.
    public var string: String { text.string }

    public var isEmpty: Bool { text.string.isEmpty }

    // MARK: Encoding

    public func encoded() -> [UInt8] {
        var out = Wire.field(1, Wire.bytes { try text.richText.serializedBytes() })
        if !graphics.isEmpty { out += Wire.field(2, ClipboardPayload(nodes: graphics).encoded()) }
        if plain { out += Wire.field(3, [1]) }
        return out
    }

    /// The clip `bytes` encode; nil when they are not one.
    public init?(decoding bytes: [UInt8]) {
        guard let fields = WireReader.fields(bytes), fields.allSatisfy({ $0.wireType == 2 }) else { return nil }
        var text: CopiedText?
        var graphics: [NodeTree] = []
        var plain = false
        for field in fields {
            switch field.number {
            case 1:
                guard let rich = try? Wiretuner_Doc_V1_RichText(serializedBytes: field.payload) else { return nil }
                text = CopiedText(rich)
            case 2:
                guard let payload = ClipboardPayload(decoding: field.payload) else { return nil }
                graphics = payload.nodes
            case 3:
                plain = field.payload == [1]
            default:
                continue
            }
        }
        guard let text else { return nil }
        self.init(text: text, graphics: graphics, plain: plain)
    }

    // MARK: Looks

    /// The look text pasted at live offset `offset` of `text` takes with *Paste and Match Style*:
    /// the growing marks of the character before (at the start, of the first character) -- never a
    /// link, an inline graphic, a data field, a mention or the other marks that do not grow.
    public static func look(at offset: Int, in text: TextNode) -> [Wiretuner_Doc_V1_TextMarkValue] {
        guard text.length > 0 else { return [] }
        let source = min(max(offset - 1, 0), text.length - 1)
        return text.values(at: source).filter(TextMarks.expands)
    }
}

/// menu:Edit[Paste] and *Paste and Match Style* with the Text tool's insertion point or selection,
/// and a drop of text into a block (importing-text.adoc, "Merge semantics"): one change, "Paste".
/// The selection's characters are deleted (with the inline graphics they place); the clip's
/// characters go in as `TextInsert`s of at most 64 KiB between the characters around the insertion
/// point, so a collaborator typing elsewhere in the paragraph is untouched.  Rich text brings its
/// marks -- each span of each value one `TextMark`, over a clearing mark of every growing attribute
/// of the text before, so the pasted look is exactly the copied one -- and each pasted paragraph
/// break its own paragraph properties; the last pasted paragraph joins the paragraph it lands in
/// and keeps that paragraph's.  Plain text, and any text with `matchStyle`, takes `look` (the
/// pending format, or `TextClip.look`) and each break copies the paragraph it splits.  Inline
/// graphics are copied as children of the block and the copies placed.
public struct PasteText: Command {
    public var node: OpID
    public var start: Anchor
    public var end: Anchor
    public var clip: TextClip
    public var matchStyle: Bool
    /// The marks of plain (or matched) text; nil: `TextClip.look` at the insertion point.
    public var look: [Wiretuner_Doc_V1_TextMarkValue]?

    public init(node: OpID, from start: Anchor, to end: Anchor, clip: TextClip, matchStyle: Bool = false,
                look: [Wiretuner_Doc_V1_TextMarkValue]? = nil) {
        self.node = node
        self.start = start
        self.end = end
        self.clip = clip
        self.matchStyle = matchStyle
        self.look = look
    }

    public var label: String { "Paste" }

    /// Whether the clip's own formatting is written.
    var rich: Bool { !clip.plain && !matchStyle }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let text = try TextEditing.text(node, in: state)
        let range = try text.range(start, end)
        let scalars = Array(clip.string.unicodeScalars)
        guard !scalars.isEmpty else { throw TextEditError.invalidValue("clip") }
        // The selection goes, with its inline graphics.
        for op in TextEditing.deletes(node, Array(text.chars[range])) {
            builder.append(op)
        }
        for graphic in InlineGraphics.removed(by: range, in: text) where state.isLive(graphic) {
            builder.append(Ops.setDeleted(graphic))
        }
        let offset = range.upperBound
        let origins = state.insertionOrigins(node, TextFields.text, at: offset, stableSeq: 0)
        let split = text.paragraphs[text.paragraphIndex(at: offset)]
        // The inline graphics' copies, children of the block.
        var mapping: [OpID: OpID] = [:]
        if !clip.graphics.isEmpty {
            let last = state.store.children(node).last.flatMap { state.store.placement($0)?.position }
            let keys = try PathEditing.keys(between: last, and: nil, count: clip.graphics.count)
            for (tree, key) in zip(clip.graphics, keys) {
                _ = try NodeCopier.create(tree, parent: node, position: key, schema: state.schema, builder: &builder, mapping: &mapping)
            }
            NodeCopier.rewriteReferences(in: clip.graphics, mapping: mapping, builder: &builder)
        }
        // The characters.
        var ids: [OpID] = []
        ids.reserveCapacity(scalars.count)
        for chunk in ImportText.chunks(scalars) {
            var string = String.UnicodeScalarView()
            string.append(contentsOf: chunk)
            let first = builder.append(Ops.textInsert(node, TextFields.text, String(string), left: ids.last ?? origins.left, right: origins.right))
            ids += (0..<chunk.count).map { OpID(counter: first.counter + UInt64($0), replica: first.replica) }
        }
        // Paragraph breaks.
        var newline = 0
        for (index, scalar) in scalars.enumerated() where scalar == "\n" {
            defer { newline += 1 }
            if rich, newline < clip.text.paragraphs.count {
                NodeCopier.writeParagraph(clip.text.paragraphs[newline], newline: ids[index], node: node, field: TextFields.text, builder: &builder)
            } else {
                TextEditing.copyParagraph(split, to: ids[index], node: node, state: state, builder: &builder)
            }
        }
        // Marks.
        func mark(_ value: Wiretuner_Doc_V1_TextMarkValue, _ span: Range<Int>) {
            let next = span.upperBound < ids.count ? ids[span.upperBound] : origins.right
            builder.append(TextEditing.mark(node, value, first: ids[span.lowerBound], last: ids[span.upperBound - 1], next: next))
        }
        if rich {
            var cleared = Set<String>()
            for value in offset > 0 ? text.values(at: offset - 1) : [] where TextMarks.expands(value) {
                let key = TextStyleAttributes.key(value)
                if cleared.insert(key).inserted { mark(TextMarks.cleared(value), 0..<ids.count) }
            }
        } else {
            for value in look ?? TextClip.look(at: offset, in: text) {
                mark(value, 0..<ids.count)
            }
        }
        for span in clip.text.spans {
            var value = span.value
            if case .inlineGraphic(let ref)? = value.value {
                guard let copy = mapping[OpID(ref.id)] else { continue }
                value.inlineGraphic.id = copy.proto
            } else if !rich {
                continue
            }
            mark(value, span.range)
        }
    }
}

/// menu:Edit[Paste] of text with nothing being edited, and a drop of text on empty page space: a
/// new auto-expanding block at `point` holding the clip -- its characters, marks, paragraph
/// properties and inline graphics as `NodeCopier` writes a copied block's text -- on top of `layer`.
/// Plain text takes `defaults` (the default text attributes).  One change, "Paste".
public struct PasteTextBlock: Command {
    public var clip: TextClip
    public var point: Point
    public var defaults: [Wiretuner_Doc_V1_TextMarkValue]
    public var layer: OpID?

    public init(_ clip: TextClip, at point: Point, defaults: [Wiretuner_Doc_V1_TextMarkValue] = [], layer: OpID? = nil) {
        self.clip = clip
        self.point = point
        self.defaults = defaults
        self.layer = layer
    }

    public var label: String { "Paste" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !clip.isEmpty else { throw TextEditError.invalidValue("clip") }
        var props = Wiretuner_Doc_V1_NodeProps()
        props.text.block.autoWidth = true
        props.text.block.autoHeight = true
        if point != .zero { props.text.common.transform = PathEditing.proto(AffineTransform.translation(x: point.x, y: point.y)) }
        let layer = try PathEditing.ensureLayer(&builder, state: state, preferred: self.layer)
        let node = builder.append(Ops.create(parent: layer, position: try PathEditing.topPosition(in: layer, state: state), props: props))
        var mapping: [OpID: OpID] = [:]
        if !clip.graphics.isEmpty {
            let keys = try PathEditing.keys(between: nil, and: nil, count: clip.graphics.count)
            for (tree, key) in zip(clip.graphics, keys) {
                _ = try NodeCopier.create(tree, parent: node, position: key, schema: state.schema, builder: &builder, mapping: &mapping)
            }
            NodeCopier.rewriteReferences(in: clip.graphics, mapping: mapping, builder: &builder)
        }
        var text = clip.text
        if clip.plain, !defaults.isEmpty {
            let count = text.string.unicodeScalars.count
            text.runs.append(TextMarkRun(range: 0..<count, values: defaults))
        }
        NodeCopier.write(text, into: node, field: TextFields.text, mapping: mapping, builder: &builder)
    }
}
