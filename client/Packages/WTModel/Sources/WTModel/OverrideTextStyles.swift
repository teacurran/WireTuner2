import WTCRDT
import WTProto

/// Text styles applied inside an instance (library.adoc, "Text tool inside an instance"; LIB-027's
/// rest): the `OverrideTextEdit`s that write to an instance's `TEXT` override what
/// `ApplyParagraphStyle` and `ApplyCharacterStyle` write to a block.  A paragraph style is the
/// `style` register of every paragraph the range touches with the style's governed registers
/// cleared, and a cleared mark of each character attribute the style governs over those
/// paragraphs; a character style is a `style` mark with a cleared mark per governed attribute.
/// Deviation: an override's paragraphs keep their own tab stops (an `OverrideText` paragraph edit
/// writes registers, not the `tabs` sequence).
public enum OverrideTextStyles {
    /// Paragraph style `style` on the paragraphs of `text` that `range` touches (the caret's for an
    /// empty range).
    public static func paragraphStyle(_ style: OpID, range: Range<Int>, in text: TextNode, state: EngineState) throws -> [OverrideTextEdit] {
        let resolver = TextStyleResolver(state)
        _ = try TextStyleEditing.style(style, kind: .paragraph, in: resolver)
        let attrs = resolver.resolved(style)!
        var props = Wiretuner_Doc_V1_ParagraphProps()
        props.style = resolver.ref(style)
        let governed = TextStyleEditing.governedParagraph(attrs).filter { $0 != TextFields.tabsField && $0 != 17 }
        var edits: [OverrideTextEdit] = [.paragraph(range, props, fields: [[17]] + governed.map { [$0] })]
        let paragraphs = text.paragraphs(touching: range)
        if let first = paragraphs.first, let last = paragraphs.last {
            let span = first.range.lowerBound..<last.range.upperBound
            if !span.isEmpty { edits += TextStyleAttributes.markValues(attrs).map { .mark(span, TextMarks.cleared($0)) } }
        }
        return edits
    }

    /// Character style `style` over `range` -- *None* (nil) is the cleared `style` mark; nothing
    /// for an empty range.
    public static func characterStyle(_ style: OpID?, range: Range<Int>, state: EngineState) throws -> [OverrideTextEdit] {
        guard !range.isEmpty else { return [] }
        guard let style else { return [.mark(range, .with { $0.style = Wiretuner_Doc_V1_NodeRef() })] }
        let resolver = TextStyleResolver(state)
        _ = try TextStyleEditing.style(style, kind: .character, in: resolver)
        var value = Wiretuner_Doc_V1_TextMarkValue()
        value.style = resolver.ref(style)
        return [.mark(range, value)] + TextStyleAttributes.markValues(resolver.resolved(style)!).map { .mark(range, TextMarks.cleared($0)) }
    }
}
