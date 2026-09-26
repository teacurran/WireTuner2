import WTCRDT
import WTProto

/// The register paths of a text node (`NodeProps.text = 130`, `TextProps` in text.proto;
/// type/creating-text.adoc, "Data model").
public enum TextFields {
    /// `NodeProps.text`.
    public static let kind: UInt32 = 130
    /// `TextProps.text`: the MERGE_TEXT field (Fugue characters and Peritext marks).
    public static let text = RegisterPath([130, 2])
    /// `TextProps.block`: the container settings (STRUCT).
    public static let block = RegisterPath([130, 3])
    /// `TextProps.tail_paragraph`: the last paragraph's properties (STRUCT).
    public static let tailParagraph = RegisterPath([130, 8])
    /// `TextChar.paragraph`.
    static let paragraphField: UInt32 = 6
    /// `ParagraphProps.tabs` (a SEQUENCE, edited by element ops rather than register writes).
    static let tabsField: UInt32 = 9

    /// The paragraph registers on newline character `newline`: `[130, 2, newline, 6]`.
    public static func paragraph(_ newline: OpID) -> RegisterPath {
        text.element(newline).child(paragraphField)
    }
}

/// Why a text command refused to build its change.  Thrown before anything is appended.
public enum TextEditError: Error, Hashable, Sendable {
    /// The node does not exist or is not a text node.
    case notText(OpID)
    /// An anchor names a character this text does not hold.
    case unknownAnchor(Anchor)
    /// A value a command was given is out of range: the field or parameter named.
    case invalidValue(String)
}

/// One paragraph of a text node as read from the merged state: its live characters, the newline
/// that terminates it (nil for the last paragraph, governed by `tail_paragraph`) and its
/// properties.
public struct TextParagraph: Hashable, Sendable {
    /// Live offsets of its characters, the terminating newline included.
    public var range: Range<Int>
    /// The terminating U+000A; nil for the last paragraph.
    public var terminator: OpID?
    /// The merged `ParagraphProps` registers of the terminator (or of `tail_paragraph`).
    public var props: Wiretuner_Doc_V1_ParagraphProps
}

/// A run of live characters with the same winning marks, decoded: what the Object panel and
/// layout read (`TextSequence.runs` with each attribute's `TextMarkValue`).
public struct TextMarkRun: Hashable, Sendable {
    /// Live offsets.
    public var range: Range<Int>
    /// The winning value of each attribute, cleared attributes left out, ascending by key.
    public var values: [Wiretuner_Doc_V1_TextMarkValue]
}

/// A text node read from the merged state (TYPE-002): the typed wrapper over the engine's
/// `TextSequence` for the `TextProps.text` field, the node's registers and its paragraphs.
/// Positions are live offsets in Unicode scalars; carets and selections are Peritext `Anchor`s,
/// which `offset(of:)` and `anchor(at:)` convert (a caret is a `(node, Anchor)`, creating-text
/// "Layout").
public struct TextNode: Sendable {
    public let id: OpID
    /// The merged registers (`TextProps` without its TEXT field, which `sequence` holds).
    public let props: Wiretuner_Doc_V1_TextProps
    /// The characters and marks.
    public let sequence: TextSequence
    /// The live characters, in document order.
    public let chars: [OpID]
    private let newlineProps: [OpID: Wiretuner_Doc_V1_ParagraphProps]

    /// The text node `id` of `state`; nil when it does not exist or is not a text node.  A
    /// deleted node reads like a live one (typing into a block someone deleted keeps its text).
    public init?(_ id: OpID, in state: EngineState) {
        guard state.store.kind(id) == TextFields.kind else { return nil }
        self.id = id
        props = state.props(id).text
        sequence = state.text(id, TextFields.text) ?? TextSequence()
        chars = sequence.liveChars
        newlineProps = Self.paragraphRegisters(id, in: state)
    }

    /// Text node `id` (its registers: block, tail paragraph) holding the characters of another
    /// node's TEXT field instead of its own -- an instance's text override (LIB-025): `field` of
    /// `holder`, whose newlines carry their own paragraph registers.
    init?(_ id: OpID, text holder: OpID, field: RegisterPath, in state: EngineState) {
        guard state.store.kind(id) == TextFields.kind else { return nil }
        self.id = id
        props = state.props(id).text
        sequence = state.text(holder, field) ?? TextSequence()
        chars = sequence.liveChars
        newlineProps = Self.paragraphRegisters(holder, field: field, in: state)
    }

    /// The live text.
    public var string: String { sequence.string }

    /// How many live characters (Unicode scalars).
    public var length: Int { chars.count }

    /// The scalar of live character `offset`.
    public func scalar(at offset: Int) -> Unicode.Scalar? {
        guard chars.indices.contains(offset), let value = sequence.codepoint(chars[offset]) else { return nil }
        return Unicode.Scalar(value)
    }

    // MARK: Positions

    /// The live offset `anchor` stands for: before a character is its offset, after a live
    /// character one more (after a tombstone, where it was); the zero id is the start (`before`)
    /// or the end (`after`).
    public func offset(of anchor: Anchor) throws -> Int {
        if anchor.char == .zero { return anchor.before ? 0 : length }
        guard let offset = sequence.offset(of: anchor.char) else { throw TextEditError.unknownAnchor(anchor) }
        return anchor.before || sequence.isDeleted(anchor.char) ? offset : offset + 1
    }

    /// The caret anchor at live offset `offset`: before the character there, or the end.
    public func anchor(at offset: Int) -> Anchor {
        guard offset >= 0, offset < length else { return offset <= 0 && length > 0 ? Anchor(char: chars[0], before: true) : .end }
        return Anchor(char: chars[offset], before: true)
    }

    /// The live range between two anchors, ordered.
    public func range(_ start: Anchor, _ end: Anchor) throws -> Range<Int> {
        let (a, b) = (try offset(of: start), try offset(of: end))
        return min(a, b)..<max(a, b)
    }

    // MARK: Paragraphs

    /// The paragraphs in order; there is always at least one.
    public var paragraphs: [TextParagraph] {
        var result: [TextParagraph] = []
        var start = 0
        for (offset, char) in chars.enumerated() where sequence.codepoint(char) == 0x0A {
            result.append(TextParagraph(range: start..<offset + 1, terminator: char, props: newlineProps[char] ?? .init()))
            start = offset + 1
        }
        result.append(TextParagraph(range: start..<length, terminator: nil, props: props.tailParagraph))
        return result
    }

    /// The index in `paragraphs` of the paragraph holding live offset `offset` (a caret just
    /// after a newline is in the next paragraph).
    public func paragraphIndex(at offset: Int) -> Int {
        paragraphs.firstIndex { offset < $0.range.upperBound } ?? paragraphs.count - 1
    }

    /// The paragraphs a live range touches: every one it overlaps, or the one holding an empty
    /// range's caret.
    public func paragraphs(touching range: Range<Int>) -> [TextParagraph] {
        let all = paragraphs
        let first = paragraphIndex(at: range.lowerBound)
        let last = range.isEmpty ? first : paragraphIndex(at: range.upperBound - 1)
        return Array(all[first...last])
    }

    // MARK: Marks

    /// The decoded runs (`TextSequence.runs`).
    public var runs: [TextMarkRun] {
        sequence.runs.map { run in
            TextMarkRun(range: run.start..<run.start + run.length,
                        values: run.attributes.compactMap { try? Wiretuner_Doc_V1_TextMarkValue(serializedBytes: $0.value) })
        }
    }

    /// The winning values over live offset `offset`.
    public func values(at offset: Int) -> [Wiretuner_Doc_V1_TextMarkValue] {
        runs.first { $0.range.contains(offset) }?.values ?? []
    }

    // MARK: Reading paragraph registers

    /// The `ParagraphProps` each newline's registers hold, in one pass over the node's registers
    /// (tab stops, a SEQUENCE under the newline, in their order).  `field` is the TEXT field
    /// (`TextProps.text` unless given: an override's text has paragraphs too).
    static func paragraphRegisters(_ node: OpID, field: RegisterPath = TextFields.text,
                                   in state: EngineState) -> [OpID: Wiretuner_Doc_V1_ParagraphProps] {
        var trees: [OpID: PropsTree] = [:]
        func tree(_ newline: OpID) -> PropsTree {
            if let existing = trees[newline] { return existing }
            let root = PropsTree(path: field.element(newline).child(TextFields.paragraphField))
            trees[newline] = root
            return root
        }
        for (path, element) in state.store.elements(node) where !element.isDeleted {
            if let (newline, suffix) = paragraphSuffix(path, field: field) { tree(newline).markElement(at: suffix) }
        }
        for (path, register) in state.store.registers(node) {
            guard let value = register.value, let (newline, suffix) = paragraphSuffix(path, field: field) else { continue }
            tree(newline).leafNode(at: suffix)?.leaf = value
        }
        return trees.compactMapValues { root in
            let bytes = root.encodeMessage { state.liveElements(node, $0) }
            return try? Wiretuner_Doc_V1_ParagraphProps(serializedBytes: bytes)
        }
    }

    /// The newline and the path below `TextChar.paragraph` of a register or element path under
    /// `[<field>, <newline>, 6]` (`field` `[130, 2]` unless given).
    static func paragraphSuffix(_ path: RegisterPath, field: RegisterPath = TextFields.text) -> (OpID, RegisterPath)? {
        let segments = path.segments
        let depth = field.segments.count
        guard segments.count > depth + 2, Array(segments[..<depth]) == field.segments,
              case .element(let newline) = segments[depth], segments[depth + 1] == .field(TextFields.paragraphField) else { return nil }
        return (newline, RegisterPath(segments: Array(segments[(depth + 2)...])))
    }
}

extension EngineState {
    /// The text node `id` (`TextNode`), or nil.
    public func textNode(_ id: OpID) -> TextNode? {
        TextNode(id, in: self)
    }
}
