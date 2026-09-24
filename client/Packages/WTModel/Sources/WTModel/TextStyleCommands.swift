import WTCRDT
import WTProto

// The text style commands of TYPE-034 (type/text-styles.adoc, "Merge semantics" and "Client"):
// creating, editing, renaming and removing styles, the Normal Text style, and applying styles to
// text.  Applying writes the reference (caching the style's resolution for REF_FALLBACK_CACHED)
// and clears what the style governs -- the paragraph's own registers and, with one covering mark
// per governed character attribute, the character marks -- so re-clicking a style removes the
// overrides and later edits of the style show through.

/// Why a style command refused to build its change.
public enum TextStyleError: Error, Hashable, Sendable {
    /// Not a live text style (of the kind the command needs).
    case notStyle(OpID)
    /// The Normal Text style cannot be removed or given a parent.
    case normalText
    /// A value out of range: the field or parameter named.
    case invalidValue(String)
}

/// Building blocks of the style commands.
enum TextStyleEditing {
    /// The live text style `id` of `kind` (any kind when nil), or throws.
    static func style(_ id: OpID, kind: TextStyleKind?, in resolver: TextStyleResolver) throws -> TextStyle {
        guard resolver.isLive(id), let style = resolver.style(id), kind == nil || style.kind == kind else { throw TextStyleError.notStyle(id) }
        return style
    }

    /// The register base of a paragraph: its terminator's `paragraph`, or `tail_paragraph`.
    static func base(_ paragraph: TextParagraph) -> RegisterPath {
        paragraph.terminator.map(TextFields.paragraph) ?? TextFields.tailParagraph
    }

    /// Writes `ref` into the paragraph's `style` register and clears the registers `governed`
    /// (`ParagraphProps` field numbers; 9 deletes its tab stops).
    static func applyParagraph(_ ref: Wiretuner_Doc_V1_NodeRef, governed: [UInt32], to paragraph: TextParagraph, node: OpID,
                               state: EngineState, builder: inout ChangeBuilder) {
        let base = base(paragraph)
        var props = Wiretuner_Doc_V1_ParagraphProps()
        props.style = ref
        builder.append(Ops.set(node, [base.child(17)], values: TextEditing.paragraphValues(props, newline: paragraph.terminator != nil)))
        let cleared = governed.filter { $0 != TextFields.tabsField && TextStyleAttributes.setFields(paragraph.props).contains($0) }
        if !cleared.isEmpty {
            builder.append(Ops.set(node, cleared.map { base.child($0) }, values: Wiretuner_Doc_V1_NodeProps()))
        }
        if governed.contains(TextFields.tabsField) {
            let tabs = state.liveElements(node, base.child(TextFields.tabsField))
            if !tabs.isEmpty { builder.append(Ops.elementDelete(node, tabs.map { base.child(TextFields.tabsField).element($0) })) }
        }
    }

    /// One mark of the cleared value of each attribute `values` names over the live range.
    static func clearMarks(_ values: [Wiretuner_Doc_V1_TextMarkValue], over range: Range<Int>, in text: TextNode, builder: inout ChangeBuilder) {
        guard !range.isEmpty else { return }
        let next = text.sequence.successor(of: text.chars[range.upperBound - 1])
        for value in values {
            builder.append(TextEditing.mark(text.id, TextMarks.cleared(value), first: text.chars[range.lowerBound],
                                            last: text.chars[range.upperBound - 1], next: next))
        }
    }

    /// The `ParagraphProps` fields a resolved paragraph style governs.
    static func governedParagraph(_ attrs: Wiretuner_Doc_V1_TextStyleAttrs) -> [UInt32] {
        TextStyleAttributes.paragraph(attrs.paragraph).fields
    }

    /// The *Next style* half of a split at `at`: when the caret is at the end of its paragraph and
    /// the paragraph's style names a live paragraph style as `next`, the paragraph after the new
    /// newline (the original terminator, or `tail_paragraph`) takes it, its governed registers
    /// cleared.
    static func applyNext(node: OpID, at: Anchor, state: EngineState, builder: inout ChangeBuilder) throws {
        let text = try TextEditing.text(node, in: state)
        let offset = try text.offset(of: at)
        let paragraph = text.paragraphs[text.paragraphIndex(at: offset)]
        guard offset == paragraph.range.upperBound - (paragraph.terminator == nil ? 0 : 1) else { return }
        let resolver = TextStyleResolver(state)
        let current = resolver.paragraphStyle(paragraph.props).attrs
        guard current.hasNext else { return }
        let next = OpID(current.next.id)
        guard resolver.isLive(next), resolver.style(next)?.kind == .paragraph, let attrs = resolver.resolved(next) else { return }
        applyParagraph(resolver.ref(next), governed: governedParagraph(attrs), to: paragraph, node: node, state: state, builder: &builder)
    }

    /// `ElementInsert` of tab stops into a style's `ParagraphSettings.tabs` (a SEQUENCE is written
    /// element by element), in order.
    static func insertTabs(_ tabs: [Wiretuner_Doc_V1_TabStop], into style: OpID, builder: inout ChangeBuilder) throws {
        guard !tabs.isEmpty else { return }
        let keys = try PathEditing.keys(between: nil, and: nil, count: tabs.count)
        let copies = tabs.map { stop in
            var copy = stop
            copy.clearID()
            return copy
        }
        builder.append(Ops.elementInsert(style, TextStyleFields.paragraph.child(9), positions: keys,
                                         values: TextStyleFields.values { $0.text.paragraph.tabs = copies }))
    }

    /// The `FeatureSettings` field number of feature `index` of `TextStyleAttributes.features`.
    static func featureField(_ index: Int) -> UInt32 { index < 11 ? UInt32(index + 1) : UInt32(index + 10) }
}

/// Creates a text style under `styles` (0:6), at the end: menu:Options[New Paragraph Style] or
/// *New Character Style*, from given settings (from a selection or from a selected style, whose
/// child it becomes with `basedOn`).  An empty name takes the next free *Style-N*.  A character
/// style keeps no paragraph settings.  Labels "New Paragraph Style" / "New Character Style".
public struct CreateTextStyle: Command {
    public var kind: TextStyleKind
    public var name: String
    public var attrs: Wiretuner_Doc_V1_TextStyleAttrs
    public var basedOn: OpID?
    public var label: String { kind == .paragraph ? "New Paragraph Style" : "New Character Style" }

    public init(_ kind: TextStyleKind, name: String = "", attrs: Wiretuner_Doc_V1_TextStyleAttrs = .init(), basedOn: OpID? = nil) {
        self.kind = kind
        self.name = name
        self.attrs = attrs
        self.basedOn = basedOn
    }

    /// The first *Style-N* no live text style is named.
    public static func nextName(in resolver: TextStyleResolver) -> String {
        let names = Set((resolver.styles(.paragraph) + resolver.styles(.character)).map(\.name))
        var number = 1
        while names.contains("Style-\(number)") { number += 1 }
        return "Style-\(number)"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard name.unicodeScalars.count <= 256 else { throw TextStyleError.invalidValue("name") }
        let resolver = TextStyleResolver(state)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.style.common.name = name.isEmpty ? Self.nextName(in: resolver) : name
        props.style.kind = kind.stored
        var text = attrs
        if kind == .character { text.clearParagraph() }
        let tabs = text.paragraph.tabs
        text.paragraph.tabs = []
        props.style.text = text
        if let basedOn {
            _ = try TextStyleEditing.style(basedOn, kind: kind, in: resolver)
            props.style.basedOn.id = basedOn.proto
        }
        let position = try PathEditing.topPosition(in: TextStyleFields.collection, state: state)
        let style = builder.append(Ops.create(parent: TextStyleFields.collection, position: position, props: props))
        try TextStyleEditing.insertTabs(tabs, into: style, builder: &builder)
    }
}

/// Creates the Normal Text paragraph style (role NORMAL_TEXT, text-styles.adoc) when the document
/// has none: part of the document template, not an undo step.
public struct CreateNormalTextStyle: Command {
    public init() {}

    public var label: String { "New Paragraph Style" }
    public var recordsUndo: Bool { false }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard TextStyleResolver(state).normalText == nil else { return }
        var props = Wiretuner_Doc_V1_NodeProps()
        props.style.common.name = TextStyleFields.normalTextName
        props.style.kind = .paragraph
        props.style.role = .normalText
        let position = try PathEditing.topPosition(in: TextStyleFields.collection, state: state)
        builder.append(Ops.create(parent: TextStyleFields.collection, position: position, props: props))
    }
}

/// Edits a style's settings (the Object panel's style editing mode, Style Behavior, Redefine):
/// writes the registers `fields` name below `TextStyleAttrs` from `attrs` -- `[2, 3]` the size,
/// `[3, 1]` the alignment, `[4]` *Style affects text color* -- a field `attrs` leaves unset is
/// cleared ("no selection").  Tab stops (`[3, 9]`, a SEQUENCE) are `SetTextStyleTabs`'s.  Every
/// paragraph using the style updates on read with no ops to the text.  One change,
/// "Edit style <name>".
public struct EditTextStyle: Command {
    public var style: OpID
    public var attrs: Wiretuner_Doc_V1_TextStyleAttrs
    public var fields: [[UInt32]]
    private let name: String

    public init(_ style: OpID, attrs: Wiretuner_Doc_V1_TextStyleAttrs, fields: [[UInt32]], name: String = "") {
        self.style = style
        self.attrs = attrs
        self.fields = fields
        self.name = name
    }

    public var label: String { name.isEmpty ? "Edit style" : "Edit style \(name)" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !fields.isEmpty, fields.allSatisfy({ !$0.isEmpty }) else { throw TextStyleError.invalidValue("fields") }
        let current = try TextStyleEditing.style(style, kind: nil, in: TextStyleResolver(state))
        if current.kind == .character, fields.contains(where: { $0[0] == 3 }) { throw TextStyleError.invalidValue("fields") }
        if fields.contains([3, 9]) { throw TextStyleError.invalidValue("fields") }
        builder.append(Ops.set(style, fields.map { $0.reduce(TextStyleFields.text) { $0.child($1) } },
                               values: TextStyleFields.values { $0.text = attrs }))
    }
}

/// Sets a paragraph style's tab stops (the Style Behavior sheet's text ruler): deletes its stop
/// elements, inserts `tabs` in order and writes `tabs_set`; nil sets "no selection" (no stops,
/// `tabs_set` false).  "Edit style".
public struct SetTextStyleTabs: Command {
    public var style: OpID
    public var tabs: [Wiretuner_Doc_V1_TabStop]?
    public var label: String { "Edit style" }

    public init(_ style: OpID, tabs: [Wiretuner_Doc_V1_TabStop]?) {
        self.style = style
        self.tabs = tabs
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try TextStyleEditing.style(style, kind: .paragraph, in: TextStyleResolver(state))
        let path = TextStyleFields.paragraph.child(9)
        let existing = state.liveElements(style, path)
        if !existing.isEmpty { builder.append(Ops.elementDelete(style, existing.map { path.element($0) })) }
        builder.append(Ops.set(style, [TextStyleFields.paragraph.child(10)], values: TextStyleFields.values { $0.text.paragraph.tabsSet = tabs != nil }))
        try TextStyleEditing.insertTabs(tabs ?? [], into: style, builder: &builder)
    }
}

/// Renames a style: one ATOMIC write of `CommonProps.name`.  "Rename style".
public struct RenameTextStyle: Command {
    public var style: OpID
    public var name: String
    public var label: String { "Rename style" }

    public init(_ style: OpID, to name: String) {
        self.style = style
        self.name = name
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !name.isEmpty, name.unicodeScalars.count <= 256 else { throw TextStyleError.invalidValue("name") }
        _ = try TextStyleEditing.style(style, kind: nil, in: TextStyleResolver(state))
        builder.append(Ops.set(style, [TextStyleFields.name], values: TextStyleFields.values { $0.common.name = name }))
    }
}

/// Applies a paragraph style to every paragraph the range between two anchors touches (the caret's
/// paragraph for an empty range): writes each paragraph's `style` reference with the style's
/// resolution cached, clears the paragraph registers the style governs and writes a cleared mark
/// per governed character attribute over the whole paragraphs -- so overrides go and the style's
/// settings show.  Registers and marks the style leaves as "no selection" are kept.  "Apply style".
public struct ApplyParagraphStyle: Command {
    public var node: OpID
    public var start: Anchor
    public var end: Anchor
    public var style: OpID
    public var label: String { "Apply style" }

    public init(node: OpID, from start: Anchor, to end: Anchor, style: OpID) {
        self.node = node
        self.start = start
        self.end = end
        self.style = style
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let text = try TextEditing.text(node, in: state)
        let resolver = TextStyleResolver(state)
        _ = try TextStyleEditing.style(style, kind: .paragraph, in: resolver)
        let attrs = resolver.resolved(style)!
        let ref = resolver.ref(style)
        let governed = TextStyleEditing.governedParagraph(attrs)
        let marks = TextStyleAttributes.markValues(attrs)
        let paragraphs = text.paragraphs(touching: try text.range(start, end))
        for paragraph in paragraphs {
            TextStyleEditing.applyParagraph(ref, governed: governed, to: paragraph, node: node, state: state, builder: &builder)
        }
        // The touched paragraphs are consecutive: one covering mark per attribute spans them all.
        TextStyleEditing.clearMarks(marks, over: paragraphs[0].range.lowerBound..<paragraphs[paragraphs.count - 1].range.upperBound,
                                    in: text, builder: &builder)
    }
}

/// Applies a character style to the live characters between two anchors: a `style` mark with the
/// style's resolution cached, and a cleared mark per character attribute the style governs.  An
/// empty range writes nothing (the tool's pending format).  "Apply style".
public struct ApplyCharacterStyle: Command {
    public var node: OpID
    public var start: Anchor
    public var end: Anchor
    public var style: OpID
    public var label: String { "Apply style" }

    public init(node: OpID, from start: Anchor, to end: Anchor, style: OpID) {
        self.node = node
        self.start = start
        self.end = end
        self.style = style
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let text = try TextEditing.text(node, in: state)
        let resolver = TextStyleResolver(state)
        _ = try TextStyleEditing.style(style, kind: .character, in: resolver)
        let range = try text.range(start, end)
        guard !range.isEmpty else { return }
        var value = Wiretuner_Doc_V1_TextMarkValue()
        value.style = resolver.ref(style)
        let next = text.sequence.successor(of: text.chars[range.upperBound - 1])
        builder.append(TextEditing.mark(node, value, first: text.chars[range.lowerBound], last: text.chars[range.upperBound - 1], next: next))
        TextStyleEditing.clearMarks(TextStyleAttributes.markValues(resolver.resolved(style)!), over: range, in: text, builder: &builder)
    }
}

/// Removes a text style (menu:Options[Remove]; "Remove style"): deletes the node, re-parents its
/// children to its parent -- folding into each child the settings the removed style set and the
/// child did not, so the children resolve as before -- and refreshes the cached resolution of
/// every reference to it (paragraph `style` registers, and `style` marks over the runs where they
/// win), so text that used it renders identically through the cache and reads as *Normal Text +*.
/// Normal Text cannot be removed.  Undo restores the style and its links.
public struct RemoveTextStyle: Command {
    public var style: OpID
    public var label: String { "Remove style" }

    public init(_ style: OpID) {
        self.style = style
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let resolver = TextStyleResolver(state)
        let removed = try TextStyleEditing.style(style, kind: nil, in: resolver)
        guard !removed.isNormalText else { throw TextStyleError.normalText }
        let ref = resolver.ref(style)
        builder.append(Ops.setDeleted(style))
        for child in resolver.children(of: style) {
            reparent(child, removed: removed, resolver: resolver, builder: &builder)
        }
        for node in state.store.nodes.sorted() where state.store.kind(node) == TextFields.kind && state.isLive(node) {
            refresh(TextNode(node, in: state)!, ref: ref, builder: &builder)
        }
    }

    /// Points `child` at the removed style's parent and writes into it what the removed style set
    /// and it does not.
    private func reparent(_ child: OpID, removed: TextStyle, resolver: TextStyleResolver, builder: inout ChangeBuilder) {
        let own = resolver.style(child)!.attrs
        var parent = Wiretuner_Doc_V1_StyleProps()
        if let grandparent = removed.parent { parent.basedOn.id = grandparent.proto }
        builder.append(Ops.set(child, [TextStyleFields.basedOn], values: TextStyleFields.values { $0 = parent }))
        let folded = TextStyleAttributes.overlay(removed.attrs, own)
        var paths: [RegisterPath] = []
        let ownCharacter = Set(TextStyleAttributes.characterFields(own.character))
        for field in TextStyleAttributes.characterFields(folded.character) where field != 15 && !ownCharacter.contains(field) {
            paths.append(TextStyleFields.character.child(field))
        }
        for (index, feature) in TextStyleAttributes.features.enumerated()
        where folded.character.features[keyPath: feature.has] && !own.character.features[keyPath: feature.has] {
            paths.append(TextStyleFields.character.child(15).child(TextStyleEditing.featureField(index)))
        }
        let ownParagraph = Set(TextStyleAttributes.paragraphSettingsFields(own.paragraph))
        for field in TextStyleAttributes.paragraphSettingsFields(folded.paragraph) where !ownParagraph.contains(field) {
            paths.append(TextStyleFields.paragraph.child(field))
        }
        if folded.hasNext && !own.hasNext { paths.append(TextStyleFields.text.child(1)) }
        if folded.affectsColor && !own.affectsColor { paths.append(TextStyleFields.text.child(4)) }
        if !paths.isEmpty {
            var values = folded
            values.paragraph.tabs = []
            builder.append(Ops.set(child, paths, values: TextStyleFields.values { $0.text = values }))
        }
        // Tab stops are a SEQUENCE: the removed style's are copied element by element.
        if !own.paragraph.tabsSet && removed.attrs.paragraph.tabsSet {
            try? TextStyleEditing.insertTabs(folded.paragraph.tabs, into: child, builder: &builder)
        }
    }

    /// Rewrites every reference to the removed style in `text` with the refreshed cache.
    private func refresh(_ text: TextNode, ref: Wiretuner_Doc_V1_NodeRef, builder: inout ChangeBuilder) {
        var props = Wiretuner_Doc_V1_ParagraphProps()
        props.style = ref
        for paragraph in text.paragraphs where paragraph.props.hasStyle && OpID(paragraph.props.style.id) == style {
            builder.append(Ops.set(text.id, [TextStyleEditing.base(paragraph).child(17)],
                                   values: TextEditing.paragraphValues(props, newline: paragraph.terminator != nil)))
        }
        var value = Wiretuner_Doc_V1_TextMarkValue()
        value.style = ref
        for run in text.runs where !run.range.isEmpty && run.values.contains(where: { mark in
            if case .style(let current)? = mark.value { OpID(current.id) == style } else { false }
        }) {
            let next = text.sequence.successor(of: text.chars[run.range.upperBound - 1])
            builder.append(TextEditing.mark(text.id, value, first: text.chars[run.range.lowerBound], last: text.chars[run.range.upperBound - 1], next: next))
        }
    }
}
