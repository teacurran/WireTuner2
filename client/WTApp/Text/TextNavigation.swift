import Foundation
import WTGeometry
import WTText

/// Where the keyboard moves the insertion point (editing-text.adoc, "Keyboard selection and
/// movement"; TYPE-010).
enum TextMove: Hashable, Sendable, CaseIterable {
    case left, right
    case wordLeft, wordRight
    case lineStart, lineEnd
    case up, down
    case paragraphStart, paragraphEnd
    case documentStart, documentEnd
}

/// How far a click or drag selects: characters, whole words (double-click) or whole paragraphs
/// (triple-click).
enum TextGranularity: Hashable, Sendable {
    case character, word, paragraph

    init(clickCount: Int) {
        switch clickCount {
        case ...1: self = .character
        case 2: self = .word
        default: self = .paragraph
        }
    }
}

/// The text boundaries movement and selection use, over the live scalars of a text node (offsets
/// are live offsets in Unicode scalars, as `TextNode` counts them) and its layout.  Pure: the
/// session asks, then turns the offsets back into anchors.
enum TextNavigation {
    /// Letters, digits and combining marks make words; everything else separates them.
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "'" || scalar == "\u{2019}"
    }

    /// The start of the word before `offset` (Option-Left, Option-Delete): back over separators,
    /// then over the word.
    static func wordStart(before offset: Int, in scalars: [Unicode.Scalar]) -> Int {
        var index = min(max(offset, 0), scalars.count)
        while index > 0, !isWordScalar(scalars[index - 1]) { index -= 1 }
        while index > 0, isWordScalar(scalars[index - 1]) { index -= 1 }
        return index
    }

    /// The end of the word after `offset` (Option-Right): forward over separators, then over the
    /// word.
    static func wordEnd(after offset: Int, in scalars: [Unicode.Scalar]) -> Int {
        var index = min(max(offset, 0), scalars.count)
        while index < scalars.count, !isWordScalar(scalars[index]) { index += 1 }
        while index < scalars.count, isWordScalar(scalars[index]) { index += 1 }
        return index
    }

    /// The word a double-click at `offset` selects: the run of word scalars around it, or the run
    /// of separators when it sits on one (a newline selects itself).
    static func wordRange(at offset: Int, in scalars: [Unicode.Scalar]) -> Range<Int> {
        guard !scalars.isEmpty else { return 0..<0 }
        let clamped = min(max(offset, 0), scalars.count)
        // At the end of a word the click belongs to it.
        let index = clamped == scalars.count || (clamped > 0 && isWordScalar(scalars[clamped - 1]) && !isWordScalar(scalars[clamped])) ? clamped - 1 : clamped
        if scalars[index] == "\n" { return index..<index + 1 }
        let word = isWordScalar(scalars[index])
        var lower = index
        var upper = index + 1
        while lower > 0, isWordScalar(scalars[lower - 1]) == word, scalars[lower - 1] != "\n" { lower -= 1 }
        while upper < scalars.count, isWordScalar(scalars[upper]) == word, scalars[upper] != "\n" { upper += 1 }
        return lower..<upper
    }

    /// The paragraph holding `offset`, its terminating newline included (a triple-click).
    static func paragraphRange(at offset: Int, in scalars: [Unicode.Scalar]) -> Range<Int> {
        let clamped = min(max(offset, 0), scalars.count)
        var lower = clamped
        while lower > 0, scalars[lower - 1] != "\n" { lower -= 1 }
        var upper = clamped
        while upper < scalars.count, scalars[upper] != "\n" { upper += 1 }
        return lower..<min(upper + 1, scalars.count)
    }

    /// Option-Up: the start of the paragraph, or of the one before when already there.
    static func paragraphStart(before offset: Int, in scalars: [Unicode.Scalar]) -> Int {
        var index = min(max(offset, 0), scalars.count)
        if index > 0, scalars[index - 1] == "\n" { index -= 1 }
        while index > 0, scalars[index - 1] != "\n" { index -= 1 }
        return index
    }

    /// Option-Down: the end of the paragraph (before its newline), or of the next one when already
    /// there.
    static func paragraphEnd(after offset: Int, in scalars: [Unicode.Scalar]) -> Int {
        var index = min(max(offset, 0), scalars.count)
        if index < scalars.count, scalars[index] == "\n" { index += 1 }
        while index < scalars.count, scalars[index] != "\n" { index += 1 }
        return index
    }

    /// The index in `lines` (global offset ranges, `TextLayout.lineRanges`) of the line holding
    /// the caret at `offset`; `upstream` keeps a soft line break's boundary on the earlier line.
    static func lineIndex(of offset: Int, in lines: [Range<Int>], upstream: Bool) -> Int? {
        guard !lines.isEmpty else { return nil }
        if upstream, let index = lines.firstIndex(where: { $0.upperBound == offset && $0.lowerBound < offset }) { return index }
        return lines.lastIndex { $0.lowerBound <= offset } ?? 0
    }

    /// Cmd-Left: the start of the line.
    static func lineStart(of offset: Int, in lines: [Range<Int>], upstream: Bool) -> Int {
        guard let index = lineIndex(of: offset, in: lines, upstream: upstream) else { return 0 }
        return lines[index].lowerBound
    }

    /// Cmd-Right: the end of the line (a line's range ends before its paragraph's newline), before
    /// a wrapped trailing space or end of line; the boundary is upstream when the line wraps
    /// softly into the next.
    static func lineEnd(of offset: Int, in lines: [Range<Int>], scalars: [Unicode.Scalar], upstream: Bool) -> (offset: Int, upstream: Bool) {
        guard let index = lineIndex(of: offset, in: lines, upstream: upstream) else { return (scalars.count, false) }
        let line = lines[index]
        var end = line.upperBound
        let wraps = index + 1 < lines.count && lines[index + 1].lowerBound == end
        if wraps, end > line.lowerBound, scalars[end - 1].properties.isWhitespace { end -= 1 }
        return (end, wraps && end == line.upperBound)
    }

    /// The offset on the line above or below the caret nearest `goalX` (the x in container space
    /// the vertical movement keeps), or the text's start or end past the first or last line.
    static func vertical(from offset: Int, down: Bool, goalX: Double, layout: TextLayout, upstream: Bool) -> Int {
        let lines = layout.lineRanges
        let target = (lineIndex(of: offset, in: lines, upstream: upstream) ?? 0) + (down ? 1 : -1)
        guard lines.indices.contains(target) else { return down ? layout.characterCount : 0 }
        // The line exists, so the container has a nearest boundary on it.
        return layout.offset(at: Point(x: goalX, y: layout.lineOrigins[target].y), inContainer: 0) ?? offset
    }

    // MARK: UTF-16 (NSTextInputClient speaks UTF-16 ranges)

    /// The UTF-16 offset of scalar offset `offset`.
    static func utf16Offset(_ offset: Int, in scalars: [Unicode.Scalar]) -> Int {
        scalars.prefix(max(0, min(offset, scalars.count))).reduce(0) { $0 + $1.utf16.count }
    }

    /// The scalar offset at or after UTF-16 offset `utf16` (inside a surrogate pair: after it).
    static func scalarOffset(_ utf16: Int, in scalars: [Unicode.Scalar]) -> Int {
        var units = 0
        for (index, scalar) in scalars.enumerated() {
            if units >= utf16 { return index }
            units += scalar.utf16.count
        }
        return scalars.count
    }

    /// The scalar range of a UTF-16 range, clamped to the text.
    static func scalarRange(_ range: NSRange, in scalars: [Unicode.Scalar]) -> Range<Int> {
        let lower = scalarOffset(max(range.location, 0), in: scalars)
        let upper = scalarOffset(max(range.location, 0) + max(range.length, 0), in: scalars)
        return lower..<max(lower, upper)
    }
}
