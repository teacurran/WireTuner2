import Synchronization
import WTCRDT
import WTGeometry
import WTProto

// The text commands of TYPE-002 (type/creating-text.adoc, "Merge semantics", "Undo grouping of
// typing"): each builds one change against the merged state; positions are Peritext anchors,
// resolved to live offsets when the command runs.

/// The key a run of typing or deleting in one TEXT field stays open under
/// (`UndoCoalescing.text`): the character the next keystroke must continue from.  An insert
/// continues from its left origin and leaves the step open at the last character it typed; a
/// backspace continues from the last character it deletes and leaves the step open at the live
/// character before the first one it deleted.  `afterWhitespace` carries the word rule: a letter
/// typed after whitespace starts a new step, whitespace typed after whitespace does not.
public struct TextEditKey: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case typing
        case deleting
    }

    public var node: OpID
    public var field: RegisterPath
    public var kind: Kind
    /// The character the keystroke continues from (zero: the start of the text).
    public var caret: OpID
    public var afterWhitespace: Bool

    public init(node: OpID, field: RegisterPath = TextFields.text, kind: Kind, caret: OpID, afterWhitespace: Bool = false) {
        self.node = node
        self.field = field
        self.kind = kind
        self.caret = caret
        self.afterWhitespace = afterWhitespace
    }
}

/// Building blocks the text commands share.
enum TextEditing {
    /// The text node `node` of `state`, or `TextEditError.notText`.
    static func text(_ node: OpID, in state: EngineState) throws -> TextNode {
        guard let text = TextNode(node, in: state) else { throw TextEditError.notText(node) }
        return text
    }

    /// Whether a scalar is whitespace for the word rule.
    static func isWhitespace(_ scalar: Unicode.Scalar?) -> Bool {
        scalar?.properties.isWhitespace ?? false
    }

    /// Scalars that always close an undo group (creating-text: kbd:[Return], kbd:[Tab] and the
    /// special characters): newline, tab, end of line (U+2028), column break (U+000C) and the
    /// inline-graphic placeholder (U+FFFC).
    static let groupClosing: Set<Unicode.Scalar> = ["\n", "\t", "\u{2028}", "\u{0C}", "\u{FFFC}"]

    /// Appends the `TextInsert` of `string` at live offset `offset`, the copy of the split
    /// paragraph's properties onto every newline it types (creating-text: kbd:[Return] copies the
    /// terminator's `ParagraphProps` explicitly) and one mark per `marks` value over the typed
    /// characters.  Returns the typed characters' ids.
    @discardableResult
    static func insert(_ string: String, at offset: Int, in text: TextNode, marks: [Wiretuner_Doc_V1_TextMarkValue],
                       state: EngineState, builder: inout ChangeBuilder) -> [OpID] {
        insert(string, node: text.id, origins: state.insertionOrigins(text.id, TextFields.text, at: offset, stableSeq: 0),
               split: text.paragraphs[text.paragraphIndex(at: offset)], marks: marks, state: state, builder: &builder)
    }

    /// `insert(_:at:in:...)` between explicit origins, splitting `split`.
    static func insert(_ string: String, node: OpID, origins: (left: OpID, right: OpID), split: TextParagraph,
                       marks: [Wiretuner_Doc_V1_TextMarkValue], state: EngineState, builder: inout ChangeBuilder) -> [OpID] {
        let scalars = Array(string.unicodeScalars)
        guard !scalars.isEmpty else { return [] }
        let first = builder.append(Ops.textInsert(node, TextFields.text, string, left: origins.left, right: origins.right))
        let ids = (0..<scalars.count).map { OpID(counter: first.counter + UInt64($0), replica: first.replica) }
        for (id, scalar) in zip(ids, scalars) where scalar == "\n" {
            copyParagraph(split, to: id, node: node, state: state, builder: &builder)
        }
        for value in marks {
            builder.append(mark(node, value, first: ids[0], last: ids[ids.count - 1], next: origins.right))
        }
        return ids
    }

    /// Writes `paragraph`'s properties onto newline `newline`: one `SetFields` of every field it
    /// holds and one `ElementInsert` of its tab stops (a SEQUENCE is copied element by element, at
    /// the source's positions).
    static func copyParagraph(_ paragraph: TextParagraph, to newline: OpID, node: OpID, state: EngineState,
                              builder: inout ChangeBuilder) {
        var props = paragraph.props
        let tabs = props.tabs
        props.tabs = []
        let fields = Self.presentFields(props)
        if !fields.isEmpty {
            builder.append(Ops.set(node, fields.map { TextFields.paragraph(newline).child($0) },
                                   values: paragraphValues(props, newline: true)))
        }
        guard !tabs.isEmpty else { return }
        let source = (paragraph.terminator.map { TextFields.paragraph($0) } ?? TextFields.tailParagraph).child(TextFields.tabsField)
        let positions = tabs.map { tab in OpID(element: tab.id).flatMap { state.position(node, source, $0) } ?? [0x80] }
        let copies = tabs.map { tab in
            var stop = tab
            stop.clearID()
            return stop
        }
        builder.append(Ops.elementInsert(node, TextFields.paragraph(newline).child(TextFields.tabsField), positions: positions,
                                         values: paragraphValues(.with { $0.tabs = copies }, newline: true)))
    }

    /// The `NodeProps` carrying `props` for a write at a newline (`text.chars[0].paragraph`) or
    /// at `tail_paragraph`.
    static func paragraphValues(_ props: Wiretuner_Doc_V1_ParagraphProps, newline: Bool) -> Wiretuner_Doc_V1_NodeProps {
        var values = Wiretuner_Doc_V1_NodeProps()
        if newline {
            var char = Wiretuner_Doc_V1_TextChar()
            char.paragraph = props
            values.text.text.chars = [char]
        } else {
            values.text.tailParagraph = props
        }
        return values
    }

    /// The field numbers of the non-SEQUENCE `ParagraphProps` fields `props` sets, ascending.
    static func presentFields(_ props: Wiretuner_Doc_V1_ParagraphProps) -> [UInt32] {
        var fields: [UInt32] = []
        if props.alignment != .unspecified { fields.append(1) }
        if props.raggedWidth != 0 { fields.append(2) }
        if props.flushZone != 0 { fields.append(3) }
        if props.leftIndent != 0 { fields.append(4) }
        if props.rightIndent != 0 { fields.append(5) }
        if props.firstLineIndent != 0 { fields.append(6) }
        if props.spaceAbove != 0 { fields.append(7) }
        if props.spaceBelow != 0 { fields.append(8) }
        if props.hasHyphenation { fields.append(10) }
        if props.hasRule { fields.append(11) }
        if props.hangPunctuation { fields.append(12) }
        if props.keepLines != 0 { fields.append(13) }
        if props.keepWithNext { fields.append(14) }
        if props.hasWordSpacing { fields.append(15) }
        if props.hasLetterSpacing { fields.append(16) }
        if props.hasStyle { fields.append(17) }
        return fields
    }

    /// A `TextMark` of `value` over the live characters `first` ... `last`, with the end anchor
    /// the attribute's expansion rule gives (creating-text, "Marks"): before `next` (the
    /// character after `last`, tombstones included; zero: the end of the text) for an expanding
    /// attribute, after `last` for one that never grows.
    static func mark(_ node: OpID, _ value: Wiretuner_Doc_V1_TextMarkValue, first: OpID, last: OpID, next: OpID) -> Wiretuner_Doc_V1_Op {
        var mark = Wiretuner_Doc_V1_TextMark()
        mark.node = node.proto
        mark.text = TextFields.text.proto
        mark.start.char = first.elementID
        mark.start.before = true
        if TextMarks.expands(value) {
            if next != .zero {
                mark.end.char = next.elementID
                mark.end.before = true
            }
        } else {
            mark.end.char = last.elementID
        }
        mark.value = value
        var op = Wiretuner_Doc_V1_Op()
        op.textMark = mark
        return op
    }

    /// `TextDelete` ops for the live characters `ids` (document order): one range per run of
    /// consecutive counters of one replica.
    static func deletes(_ node: OpID, _ ids: [OpID]) -> [Wiretuner_Doc_V1_Op] {
        var ops: [Wiretuner_Doc_V1_Op] = []
        var index = 0
        while index < ids.count {
            let first = ids[index]
            var count: UInt64 = 1
            while index + Int(count) < ids.count, ids[index + Int(count)] == OpID(counter: first.counter + count, replica: first.replica) {
                count += 1
            }
            ops.append(Ops.textDelete(node, TextFields.text, first: first, count: count))
            index += Int(count)
        }
        return ops
    }
}

/// Reading and building `TextMarkValue`s.
public enum TextMarks {
    /// Whether a mark of `value`'s attribute grows when text is typed at its end (start before,
    /// end before the next character); `link`, `no_break`, `no_hyphen`, `inline_graphic`,
    /// `kerning`, `field` and `mention` never grow (end after the last character).
    public static func expands(_ value: Wiretuner_Doc_V1_TextMarkValue) -> Bool {
        switch value.value {
        case .link?, .noBreak?, .noHyphen?, .inlineGraphic?, .kerning?, .field?, .mention?: false
        default: true
        }
    }

    /// The value clearing `value`'s attribute: the same case holding its default (for a
    /// `feature`, nothing but its tag -- the font's default).  A mark of it supersedes the
    /// attribute by OpId and reads as no mark (crdt-model.adoc, "Text").
    public static func cleared(_ value: Wiretuner_Doc_V1_TextMarkValue) -> Wiretuner_Doc_V1_TextMarkValue {
        var result = Wiretuner_Doc_V1_TextMarkValue()
        switch value.value {
        case .fontFamily?: result.fontFamily = ""
        case .fontStyle?: result.fontStyle = ""
        case .size?: result.size = 0
        case .leading?: result.leading = .init()
        case .kerning?: result.kerning = 0
        case .rangeKerning?: result.rangeKerning = 0
        case .baselineShift?: result.baselineShift = 0
        case .horizontalScale?: result.horizontalScale = 0
        case .fill?: result.fill = .init()
        case .stroke?: result.stroke = .init()
        case .effect?: result.effect = .init()
        case .style?: result.style = .init()
        case .language?: result.language = ""
        case .noBreak?: result.noBreak = false
        case .case?: result.case = .unspecified
        case .inlineGraphic?: result.inlineGraphic = .init()
        case .overprint?: result.overprint = false
        case .noHyphen?: result.noHyphen = false
        case .axes?: result.axes = .init()
        case .feature(let feature)?: result.feature = .with { $0.tag = feature.tag }
        case .link?: result.link = ""
        case .field?: result.field = .init()
        case .mention?: result.mention = ""
        case nil: break
        }
        return result
    }

    /// The Edit menu label of formatting with `value`.
    public static func label(_ value: Wiretuner_Doc_V1_TextMarkValue) -> String {
        switch value.value {
        case .fontFamily?: "Font"
        case .fontStyle?: "Font Style"
        case .size?: "Size"
        case .leading?: "Leading"
        case .kerning?: "Kerning"
        case .rangeKerning?: "Range Kerning"
        case .baselineShift?: "Baseline Shift"
        case .horizontalScale?: "Horizontal Scale"
        case .fill?: "Text Color"
        case .stroke?: "Text Stroke"
        case .effect?: "Text Effect"
        case .style?: "Character Style"
        case .language?: "Language"
        case .noBreak?: "No Break"
        case .case?: "Change Case"
        case .inlineGraphic?: "Inline Graphic"
        case .overprint?: "Overprint"
        case .noHyphen?: "No Hyphen"
        case .axes?: "Axes"
        case .feature?: "OpenType Feature"
        case .link?: "Link"
        case .field?: "Data Field"
        case .mention?: "Mention"
        case nil: "Format"
        }
    }
}

// MARK: - Commands

/// Creates a text block (creating-text, "Two kinds of text block"): a click makes an
/// auto-expanding block at the point, a drag a fixed-size block of the rectangle.  With
/// `text`, the block and its first characters are one change labelled "Type" (creating-text,
/// "Creation"); `marks` (the pending format) cover the text and `paragraph` is the block's
/// paragraph properties, copied onto every newline of `text`.
public struct CreateTextBlock: Command {
    public enum Frame: Hashable, Sendable {
        /// Auto-expanding in both directions, its top-left at the point.
        case point(Point)
        /// Fixed-size: width and height set, top-left at the rectangle's origin.
        case area(Rect)
    }

    public var frame: Frame
    public var text: String
    public var marks: [Wiretuner_Doc_V1_TextMarkValue]
    public var paragraph: Wiretuner_Doc_V1_ParagraphProps
    /// The layer to create on (the active layer), as for `CreateShape`.
    public var layer: OpID?
    public var label: String { text.isEmpty ? "Text Block" : "Type" }

    public init(_ frame: Frame, text: String = "", marks: [Wiretuner_Doc_V1_TextMarkValue] = [],
                paragraph: Wiretuner_Doc_V1_ParagraphProps = .init(), layer: OpID? = nil) {
        self.frame = frame
        self.text = text
        self.marks = marks
        self.paragraph = paragraph
        self.layer = layer
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var props = Wiretuner_Doc_V1_NodeProps()
        let origin: Point
        switch frame {
        case .point(let point):
            origin = point
            props.text.block.autoWidth = true
            props.text.block.autoHeight = true
        case .area(let rect):
            guard rect.width > 0, rect.height > 0, rect.width.isFinite, rect.height.isFinite else { throw TextEditError.invalidValue("frame") }
            origin = Point(x: rect.minX, y: rect.minY)
            props.text.block.width = rect.width
            props.text.block.height = rect.height
        }
        guard origin.x.isFinite, origin.y.isFinite else { throw TextEditError.invalidValue("frame") }
        if origin != .zero {
            props.text.common.transform = PathEditing.proto(AffineTransform.translation(x: origin.x, y: origin.y))
        }
        var tail = paragraph
        tail.tabs = []
        props.text.tailParagraph = tail
        let layer = try PathEditing.ensureLayer(&builder, state: state, preferred: self.layer)
        let position = try PathEditing.topPosition(in: layer, state: state)
        let node = builder.append(Ops.create(parent: layer, position: position, props: props))
        guard !text.isEmpty else { return }
        TextEditing.insert(text, node: node, origins: (.zero, .zero), split: TextParagraph(range: 0..<0, terminator: nil, props: tail),
                           marks: marks, state: state, builder: &builder)
    }
}

/// The undo grouping a text command decides while it builds its change (it needs the change's
/// ids), read by `DocumentCore` after `execute`.
final class CoalescingBox: Sendable {
    private let value = Mutex<UndoCoalescing>(.none)

    var coalescing: UndoCoalescing {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// Types `text` at a caret (creating-text, "Typing"): one `TextInsert` between the Fugue origins
/// of the caret's live offset; every newline typed is a paragraph split that copies the split
/// paragraph's properties; `marks` (the pending format) cover the typed characters.  Label "Type".
///
/// With `typing` set (a keystroke from the Text tool) the undo grouping rule applies
/// (creating-text, "Undo grouping of typing"): one character joins the previous keystroke's step
/// while the caret has not moved (it continues from the character that keystroke typed), under
/// a second has passed and it is not a letter typed after whitespace (a word and its trailing
/// spaces are one step); newlines, tabs and special characters, and strings of more than one
/// character (a paste, a committed input-method string), are steps of their own.
public struct InsertText: Command {
    public var node: OpID
    public var text: String
    public var at: Anchor
    public var marks: [Wiretuner_Doc_V1_TextMarkValue]
    public var typing: Bool
    private let box = CoalescingBox()
    public var label: String { "Type" }
    public var coalescing: UndoCoalescing { box.coalescing }

    public init(node: OpID, text: String, at: Anchor, marks: [Wiretuner_Doc_V1_TextMarkValue] = [], typing: Bool = false) {
        self.node = node
        self.text = text
        self.at = at
        self.marks = marks
        self.typing = typing
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let current = try TextEditing.text(node, in: state)
        let offset = try current.offset(of: at)
        let left = state.insertionOrigins(node, TextFields.text, at: offset, stableSeq: 0).left
        let ids = TextEditing.insert(text, at: offset, in: current, marks: marks, state: state, builder: &builder)
        box.coalescing = typing ? key(typed: ids, after: left, in: current) : .none
    }

    /// The keys of one keystroke: it joins at the character before the caret and leaves the step
    /// open at the character it typed.
    private func key(typed ids: [OpID], after left: OpID, in current: TextNode) -> UndoCoalescing {
        let scalars = Array(text.unicodeScalars)
        guard text.count == 1, let last = scalars.last, let typed = ids.last,
              !scalars.contains(where: TextEditing.groupClosing.contains) else { return .none }
        let whitespace = TextEditing.isWhitespace(last)
        let previous = TextEditing.isWhitespace(current.sequence.codepoint(left).flatMap(Unicode.Scalar.init))
        return .text(joins: .text(TextEditKey(node: node, kind: .typing, caret: left, afterWhitespace: whitespace && previous)),
                     opens: .text(TextEditKey(node: node, kind: .typing, caret: typed, afterWhitespace: whitespace)))
    }
}

/// Deletes the live characters between two anchors (one `TextDelete` per run of consecutive
/// ids).  Deleting a newline joins its paragraphs; the surviving terminator keeps its properties.
/// Label "Delete text".  With `backspace` set (a Backspace keystroke from the Text tool, deleting
/// one character) backspace runs group like typing: the step stays open at the character before
/// the one deleted, and the next backspace joins it while the caret has not moved and under a
/// second has passed.
public struct DeleteText: Command {
    public var node: OpID
    public var start: Anchor
    public var end: Anchor
    public var backspace: Bool
    private let box = CoalescingBox()
    public var label: String { "Delete text" }
    public var coalescing: UndoCoalescing { box.coalescing }

    public init(node: OpID, from start: Anchor, to end: Anchor, backspace: Bool = false) {
        self.node = node
        self.start = start
        self.end = end
        self.backspace = backspace
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let text = try TextEditing.text(node, in: state)
        let range = try text.range(start, end)
        for op in TextEditing.deletes(node, Array(text.chars[range])) {
            builder.append(op)
        }
        guard backspace, range.count == 1 else {
            box.coalescing = .none
            return
        }
        let previous = range.lowerBound > 0 ? text.chars[range.lowerBound - 1] : .zero
        box.coalescing = .text(joins: .text(TextEditKey(node: node, kind: .deleting, caret: text.chars[range.lowerBound])),
                               opens: .text(TextEditKey(node: node, kind: .deleting, caret: previous)))
    }
}

/// kbd:[Return]: splits the paragraph at a caret by typing a newline whose `paragraph` registers
/// are an explicit copy of the split paragraph's terminator (creating-text, "Paragraphs").  Its
/// own undo step.  Label "Type".
public struct SplitParagraph: Command {
    public var node: OpID
    public var at: Anchor
    public var label: String { "Type" }

    public init(node: OpID, at: Anchor) {
        self.node = node
        self.at = at
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try InsertText(node: node, text: "\n", at: at).execute(&builder, state: state)
    }
}

/// Joins the paragraph holding a caret with the next one by deleting its terminating newline;
/// the next paragraph's terminator survives with its properties (creating-text, "Paragraphs").
/// Nothing happens in the last paragraph.  Label "Delete text".
public struct JoinParagraph: Command {
    public var node: OpID
    public var at: Anchor
    public var label: String { "Delete text" }

    public init(node: OpID, at: Anchor) {
        self.node = node
        self.at = at
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let text = try TextEditing.text(node, in: state)
        guard let terminator = text.paragraphs[text.paragraphIndex(at: try text.offset(of: at))].terminator else { return }
        builder.append(Ops.textDelete(node, TextFields.text, first: terminator, count: 1))
    }
}

/// Formats the live characters between two anchors with one attribute: one `TextMark` whose
/// anchors follow the attribute's expansion rule (creating-text, "Marks").  Later marks of the
/// same attribute win where they overlap; marks of different attributes (and `feature` marks of
/// different tags) stack.  A character style is a `style` mark (text-styles.adoc; resolving
/// its settings and clearing overrides on apply is TYPE-034).  An empty range writes nothing:
/// formatting at an insertion point is the tool's pending format.
public struct ApplyMark: Command {
    public var node: OpID
    public var start: Anchor
    public var end: Anchor
    public var value: Wiretuner_Doc_V1_TextMarkValue
    public var label: String

    public init(node: OpID, from start: Anchor, to end: Anchor, value: Wiretuner_Doc_V1_TextMarkValue, label: String? = nil) {
        self.node = node
        self.start = start
        self.end = end
        self.value = value
        self.label = label ?? TextMarks.label(value)
    }

    /// Removes the attribute `value` names from the range: a mark of its cleared value
    /// (`TextMarks.cleared`), which wins by OpId and reads as no mark.
    public static func remove(node: OpID, from start: Anchor, to end: Anchor, attribute value: Wiretuner_Doc_V1_TextMarkValue) -> ApplyMark {
        ApplyMark(node: node, from: start, to: end, value: TextMarks.cleared(value), label: TextMarks.label(value))
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard value.value != nil else { throw TextEditError.invalidValue("value") }
        let text = try TextEditing.text(node, in: state)
        let range = try text.range(start, end)
        guard !range.isEmpty else { return }
        let next = state.insertionOrigins(node, TextFields.text, at: range.upperBound, stableSeq: 0).right
        builder.append(TextEditing.mark(node, value, first: text.chars[range.lowerBound], last: text.chars[range.upperBound - 1], next: next))
    }
}

/// Writes paragraph properties on every paragraph the range between two anchors touches (the
/// caret's paragraph for an empty range): the registers `fields` name (paths below
/// `ParagraphProps`, such as `[1]` for alignment or `[10, 1]` for hyphenation's `enabled`) on each
/// paragraph's terminating newline, or on `tail_paragraph` for the last paragraph.  A paragraph
/// style is the `style` field (17); applying its settings and clearing overrides is TYPE-034.
/// Tab stops (field 9) are a SEQUENCE edited by their own element ops (tabs-indents.adoc) and are
/// refused here.  Label "Paragraph" unless given.
public struct SetParagraph: Command {
    public var node: OpID
    public var start: Anchor
    public var end: Anchor
    public var props: Wiretuner_Doc_V1_ParagraphProps
    public var fields: [[UInt32]]
    public var label: String

    public init(node: OpID, from start: Anchor, to end: Anchor, props: Wiretuner_Doc_V1_ParagraphProps, fields: [[UInt32]],
                label: String = "Paragraph") {
        self.node = node
        self.start = start
        self.end = end
        self.props = props
        self.fields = fields
        self.label = label
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !fields.isEmpty, fields.allSatisfy({ !$0.isEmpty && $0[0] != TextFields.tabsField }) else {
            throw TextEditError.invalidValue("fields")
        }
        let text = try TextEditing.text(node, in: state)
        for paragraph in text.paragraphs(touching: try text.range(start, end)) {
            let base = paragraph.terminator.map(TextFields.paragraph) ?? TextFields.tailParagraph
            let paths = fields.map { $0.reduce(base) { $0.child($1) } }
            builder.append(Ops.set(node, paths, values: TextEditing.paragraphValues(props, newline: paragraph.terminator != nil)))
        }
    }
}

/// Writes a text block's container settings (`TextProps.block`, STRUCT): the registers `fields`
/// name below `TextBlockProps` (`[3]` width, `[1]` auto width, `[5, 1]` left inset ...).
public struct SetTextBlock: Command {
    public var node: OpID
    public var block: Wiretuner_Doc_V1_TextBlockProps
    public var fields: [[UInt32]]
    public var label: String

    public init(node: OpID, block: Wiretuner_Doc_V1_TextBlockProps, fields: [[UInt32]], label: String = "Text Block") {
        self.node = node
        self.block = block
        self.fields = fields
        self.label = label
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !fields.isEmpty, fields.allSatisfy({ !$0.isEmpty }) else { throw TextEditError.invalidValue("fields") }
        guard state.store.kind(node) == TextFields.kind else { throw TextEditError.notText(node) }
        var values = Wiretuner_Doc_V1_NodeProps()
        values.text.block = block
        builder.append(Ops.set(node, fields.map { $0.reduce(TextFields.block) { $0.child($1) } }, values: values))
    }
}
