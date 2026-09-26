import WTCRDT
import WTProto

/// Copy and paste of text attributes (copying-type.adoc; TYPE-031): the character attributes of
/// the source's first character and the paragraph settings of its first paragraph, captured as a
/// value the attribute clipboard carries, and applied to ranges or whole blocks.  With a block as
/// the source its block appearance rides along as an attribute stack, which only a path takes
/// (`PasteAttributes`); text targets never take it.
public struct TextAttributeSet: Hashable, Sendable {
    /// One value per character attribute the source sets (feature marks one per tag).
    public var character: [Wiretuner_Doc_V1_TextMarkValue]
    /// The source's first paragraph; nil when the set carries no paragraph attributes.
    public var paragraph: Wiretuner_Doc_V1_ParagraphProps?
    /// The source block's fills and strokes, bottom first, for a path target.
    public var stack: [AttributePayload.Element]?

    public init(character: [Wiretuner_Doc_V1_TextMarkValue], paragraph: Wiretuner_Doc_V1_ParagraphProps?, stack: [AttributePayload.Element]? = nil) {
        self.character = character
        self.paragraph = paragraph
        self.stack = stack
    }

    /// Whether a mark attribute travels with Copy Attributes: the look attributes of the table
    /// (font, face, size, leading, range kerning, baseline shift, horizontal scale, effect, fill,
    /// stroke, small caps, axes and features, character style) and the language.  Pair kerning,
    /// links, inline graphics, data fields and line-breaking controls belong to the words.
    public static func travels(_ value: Wiretuner_Doc_V1_TextMarkValue) -> Bool {
        if case .language? = value.value { return true }
        return AttributePayload.isTypeAttribute(value)
    }

    /// The attributes of `text` at the start of `range` (the whole text when nil): the first
    /// character's values and the first paragraph's settings; `block` adds the block appearance.
    public static func capture(from text: TextNode, range: Range<Int>? = nil, block: Bool = false, in state: EngineState) -> TextAttributeSet {
        let start = min(range?.lowerBound ?? 0, max(text.length - 1, 0))
        let character = text.length == 0 ? [] : text.values(at: start).filter(travels)
        let paragraph = text.paragraphs[text.paragraphIndex(at: range?.lowerBound ?? 0)].props
        var stack: [AttributePayload.Element]?
        if block {
            let appearance = text.props.blockAppearance
            stack = TextBlockAppearance.rows(text.id, in: state).compactMap { row in
                switch row.list {
                case .fills: appearance.fills.first { OpID(element: $0.id) == row.element }.map(AttributePayload.Element.fill)
                case .strokes: appearance.strokes.first { OpID(element: $0.id) == row.element }.map(AttributePayload.Element.stroke)
                case .effects: nil
                }
            }
        }
        return TextAttributeSet(character: character, paragraph: paragraph, stack: stack)
    }

    /// The set with only the character attributes (kbd:[Shift] with the Eyedropper) or only the
    /// paragraph ones (kbd:[Cmd]).
    public func filtered(character keepsCharacter: Bool, paragraph keepsParagraph: Bool) -> TextAttributeSet {
        TextAttributeSet(character: keepsCharacter ? character : [], paragraph: keepsParagraph ? paragraph : nil, stack: stack)
    }

    // MARK: Pasteboard

    /// The set as the attribute clipboard's payload: `AttributePayload`'s shape (a text node's marks
    /// and block appearance) with the paragraph in `tail_paragraph`, so a copy made here pastes the
    /// stack onto paths through `PasteAttributes` too.
    public func clipboard(sourceDocument: String = "") -> ClipboardPayload {
        var payload = AttributePayload(stack: stack, textAttributes: character).clipboard(sourceDocument: sourceDocument)
        if let paragraph { payload.nodes[0].props.text.tailParagraph = paragraph }
        return payload
    }

    /// The set a payload carries; nil unless it is a text attribute copy.
    public init?(_ payload: ClipboardPayload) {
        guard let attributes = AttributePayload(payload), let character = attributes.textAttributes else { return nil }
        let text = payload.nodes[0].props.text
        self.init(character: character, paragraph: text.hasTailParagraph ? text.tailParagraph : nil, stack: attributes.stack)
    }

    /// The stack part as an object payload (what a path takes).
    public var stackPayload: AttributePayload? {
        stack.map { AttributePayload(stack: $0) }
    }
}

/// Where pasted text attributes go: a range of a block (the whole text from `.start` to `.end`).
public struct TextAttributeTarget: Hashable, Sendable {
    public var node: OpID
    public var from: Anchor
    public var to: Anchor

    public init(node: OpID, from: Anchor = .start, to: Anchor = .end) {
        self.node = node
        self.from = from
        self.to = to
    }
}

/// Paste Attributes onto text (copying-type, "Merge semantics"): per target, one mark per copied
/// character attribute over its characters (and a cleared mark for each travelling attribute the
/// target sets and the set does not, so the look is reproduced), and on every paragraph it
/// touches one `SetFields` of the copied settings -- tabs rewritten as a replacement of the
/// sequence: its live stops deleted and copies inserted.  One change, "Paste attributes".
public struct PasteTextAttributes: Command {
    public var set: TextAttributeSet
    public var targets: [TextAttributeTarget]
    public var label: String { "Paste attributes" }

    public init(_ set: TextAttributeSet, to targets: [TextAttributeTarget]) {
        self.set = set
        self.targets = targets
    }

    /// The registers of `ParagraphProps` a paste writes, tabs aside: every setting, the STRUCTs
    /// (hyphenation, rule and its stroke) by their fields.
    static let paragraphFields: [[UInt32]] = [[1], [2], [3], [4], [5], [6], [7], [8]]
        + (1...4).map { [10, $0] } + (1...5).map { [11, $0] } + (1...9).map { [11, 6, $0] }
        + [[12], [13], [14], [15], [16], [17]]

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let order = LayerOrder(state)
        for target in targets where !Objects.isEffectivelyLocked(target.node, in: state, layers: order) {
            let text = try TextEditing.text(target.node, in: state)
            let range = try text.range(target.from, target.to)
            if !set.character.isEmpty || set.paragraph == nil { try pasteCharacter(text, range: range, target: target, state: state, builder: &builder) }
            if let paragraph = set.paragraph { try pasteParagraph(paragraph, text: text, range: range, target: target, state: state, builder: &builder) }
        }
    }

    private func pasteCharacter(_ text: TextNode, range: Range<Int>, target: TextAttributeTarget, state: EngineState, builder: inout ChangeBuilder) throws {
        guard !range.isEmpty else { return }
        let named = Set(set.character.map(Self.identity))
        var cleared: Set<String> = []
        for run in text.runs where run.range.overlaps(range) {
            for value in run.values where TextAttributeSet.travels(value) {
                let key = Self.identity(value)
                guard !named.contains(key), cleared.insert(key).inserted else { continue }
                try ApplyMark(node: target.node, from: target.from, to: target.to, value: TextMarks.cleared(value)).execute(&builder, state: state)
            }
        }
        for value in set.character {
            try ApplyMark(node: target.node, from: target.from, to: target.to, value: value).execute(&builder, state: state)
        }
    }

    private func pasteParagraph(_ paragraph: Wiretuner_Doc_V1_ParagraphProps, text: TextNode, range: Range<Int>, target: TextAttributeTarget,
                                state: EngineState, builder: inout ChangeBuilder) throws {
        var props = paragraph
        props.tabs = []
        try SetParagraph(node: target.node, from: target.from, to: target.to, props: props, fields: Self.paragraphFields, label: label)
            .execute(&builder, state: state)
        let copies = paragraph.tabs.map { tab -> Wiretuner_Doc_V1_TabStop in
            var stop = tab
            stop.clearID()
            stop.position = max(stop.position, 0)
            return stop
        }.sorted { $0.position < $1.position }
        for touched in text.paragraphs(touching: range) {
            let sequence = TextTabs.sequence(touched)
            let live = state.liveElements(target.node, sequence)
            if !live.isEmpty { builder.append(Ops.elementDelete(target.node, live.map { sequence.element($0) })) }
            guard !copies.isEmpty else { continue }
            let last = live.last.flatMap { state.position(target.node, sequence, $0) }
            let keys = try PathEditing.keys(between: last, and: nil, count: copies.count)
            builder.append(Ops.elementInsert(target.node, sequence, positions: keys,
                                             values: TextEditing.paragraphValues(.with { $0.tabs = copies }, newline: touched.terminator != nil)))
        }
    }

    /// A mark attribute's identity: its case (a feature: and its tag).
    static func identity(_ value: Wiretuner_Doc_V1_TextMarkValue) -> String {
        if case .feature(let feature)? = value.value { return "feature:\(feature.tag)" }
        return String(describing: TextMarks.cleared(value))
    }
}
