import Foundation
import WTCRDT
import WTModel
import WTProto

/// The text a Text menu or Object panel command acts on: the Text tool's selection while it edits a
/// selected block (a caret: its paragraph for paragraph commands), else every selected block whole.
struct TextTarget: Equatable {
    let node: OpID
    let from: Anchor
    let to: Anchor
    /// Live offsets.
    let range: Range<Int>
}

extension ObjectPanelModel {
    /// The targets of the selection's text; empty when no selected object is text.
    var textTargets: [TextTarget] {
        let state = document.state
        if let session = editingText, let node = session.node, let text = session.text {
            let range = session.selectedRange
            return [TextTarget(node: node, from: text.anchor(at: range.lowerBound), to: text.anchor(at: range.upperBound), range: range)]
        }
        return selection.ids.compactMap { id -> TextTarget? in
            guard let text = state.textNode(id.opID) else { return nil }
            return TextTarget(node: id.opID, from: .start, to: .end, range: 0..<text.length)
        }
    }

    /// The paragraphs the targets touch, with their text.
    var targetParagraphs: [(text: TextNode, index: Int)] {
        let state = document.state
        return textTargets.flatMap { target -> [(text: TextNode, index: Int)] in
            guard let text = state.textNode(target.node) else { return [] }
            let first = text.paragraphIndex(at: target.range.lowerBound)
            let last = target.range.isEmpty ? first : text.paragraphIndex(at: max(target.range.upperBound - 1, target.range.lowerBound))
            return (first...last).map { (text, $0) }
        }
    }

    /// The runs the targets cover (a caret: the run before it).
    var targetRuns: [[Wiretuner_Doc_V1_TextMarkValue]] {
        let state = document.state
        return textTargets.flatMap { target -> [[Wiretuner_Doc_V1_TextMarkValue]] in
            guard let text = state.textNode(target.node) else { return [] }
            if target.range.isEmpty { return [text.values(at: max(target.range.lowerBound - 1, 0))] }
            return text.runs.filter { $0.range.overlaps(target.range) }.map(\.values)
        }
    }
}

/// *New Paragraph Style* and *Redefine…* take the attributes the selection shares (text-styles.adoc,
/// "Creating a style"; TYPE-035): a field every run (or paragraph) agrees on is set, one they
/// disagree on is left unset -- "no selection" -- so the style leaves it alone.
enum SharedTextAttributes {
    static func attrs(runs: [[Wiretuner_Doc_V1_TextMarkValue]], paragraphs: [Wiretuner_Doc_V1_ParagraphProps]) -> Wiretuner_Doc_V1_TextStyleAttrs {
        var attrs = Wiretuner_Doc_V1_TextStyleAttrs()
        func shared<Value: Equatable>(_ read: (Wiretuner_Doc_V1_TextMarkValue.OneOf_Value) -> Value?) -> Value? {
            let values = runs.map { run in run.compactMap { $0.value.flatMap(read) }.first }
            guard let first = values.first, let value = first, values.allSatisfy({ $0 == value }) else { return nil }
            return value
        }
        if let v = shared({ if case .fontFamily(let x) = $0 { x } else { nil } }) { attrs.character.fontFamily = v }
        if let v = shared({ if case .fontStyle(let x) = $0 { x } else { nil } }) { attrs.character.fontStyle = v }
        if let v = shared({ if case .size(let x) = $0 { x } else { nil } }) { attrs.character.size = v }
        if let v = shared({ if case .leading(let x) = $0 { x } else { nil } }) { attrs.character.leading = v }
        if let v = shared({ if case .rangeKerning(let x) = $0 { x } else { nil } }) { attrs.character.rangeKerning = v }
        if let v = shared({ if case .baselineShift(let x) = $0 { x } else { nil } }) { attrs.character.baselineShift = v }
        if let v = shared({ if case .horizontalScale(let x) = $0 { x } else { nil } }) { attrs.character.horizontalScale = v }
        if let v = shared({ if case .fill(let x) = $0 { x } else { nil } }) {
            attrs.character.fill = v
            attrs.affectsColor = true
        }
        if let v = shared({ if case .stroke(let x) = $0 { x } else { nil } }) { attrs.character.stroke = v }
        if let v = shared({ if case .effect(let x) = $0 { x } else { nil } }) { attrs.character.effect = v }
        if let v = shared({ if case .case(let x) = $0 { x } else { nil } }) { attrs.character.case = v }
        if let v = shared({ if case .language(let x) = $0 { x } else { nil } }) { attrs.character.language = v }
        func paragraph<Value: Equatable>(_ read: (Wiretuner_Doc_V1_ParagraphProps) -> Value) -> Value? {
            guard let first = paragraphs.first.map(read), paragraphs.allSatisfy({ read($0) == first }) else { return nil }
            return first
        }
        if let v = paragraph(\.alignment) { attrs.paragraph.alignment = v }
        if let v = paragraph(\.leftIndent) { attrs.paragraph.leftIndent = v }
        if let v = paragraph(\.rightIndent) { attrs.paragraph.rightIndent = v }
        if let v = paragraph(\.firstLineIndent) { attrs.paragraph.firstLineIndent = v }
        if let v = paragraph(\.spaceAbove) { attrs.paragraph.spaceAbove = v }
        if let v = paragraph(\.spaceBelow) { attrs.paragraph.spaceBelow = v }
        return attrs
    }

    /// The `TextStyleAttrs` field paths `attrs` sets (what *Redefine* writes): character fields under
    /// 2, paragraph fields under 3, and *Style affects text color* (4).
    static func fields(_ attrs: Wiretuner_Doc_V1_TextStyleAttrs) -> [[UInt32]] {
        let c = attrs.character, p = attrs.paragraph
        let character: [(Bool, UInt32)] = [
            (c.hasFontFamily, 1), (c.hasFontStyle, 2), (c.hasSize, 3), (c.hasLeading, 4), (c.hasRangeKerning, 5), (c.hasBaselineShift, 6),
            (c.hasHorizontalScale, 7), (c.hasFill, 8), (c.hasStroke, 9), (c.hasEffect, 10), (c.hasCase, 11), (c.hasLanguage, 12),
        ]
        let paragraph: [(Bool, UInt32)] = [
            (p.hasAlignment, 1), (p.hasLeftIndent, 4), (p.hasRightIndent, 5), (p.hasFirstLineIndent, 6), (p.hasSpaceAbove, 7), (p.hasSpaceBelow, 8),
        ]
        return character.filter(\.0).map { [2, $0.1] } + paragraph.filter(\.0).map { [3, $0.1] } + (attrs.affectsColor ? [[4]] : [])
    }
}
