// One paragraph shaped by Core Text and broken into lines (TXT-001).  Core Text shapes and
// suggests breaks (UAX #14); WTText does the rest itself, as the type chapter's Client sections
// require: justification within the word and letter spacing ranges and the flush zone, the
// ragged width, hyphenation through `CFStringGetHyphenationLocationBeforeIndex` with the
// paragraph's locale (consecutive limit, capitalized words, inhibited spans, discretionary
// hyphens), "Selected words" that never break, tab leaders in the preceding character's font,
// hanging punctuation, baseline shift and per-line maximum leading.
//
// Lines are memoized by (start, column width, hyphens before): with columns of one width an
// unchanged paragraph is never re-broken, which is what makes incremental relayout cheap.

import WTGeometry
import struct WTGeometry.AffineTransform
import WTRender
import struct WTRender.StrokeStyle
import CoreText
import Foundation

/// Glyphs of one font and colour within a line.
struct LineGlyphRun: Sendable {
    /// Index into the paragraph's span attributes.
    let span: Int
    let font: GlyphFont
    let color: Color
    let glyphs: [CGGlyph]
    /// Glyph origins from the column's left edge, alignment and justification applied.
    let xs: [Double]
    let advances: [Double]
    /// The paragraph scalar each glyph came from.
    let charIndices: [Int]
    /// Baseline shift, y down.
    let yOffset: Double
    /// Set upright in vertical text.
    let upright: Bool
    /// The run's own ascent and descent (points).
    let ascent: Double
    let descent: Double
    /// The characters the glyphs came from.
    let text: String
}

/// One broken line of a paragraph, in column coordinates (x from the column's left edge after
/// inset, y from the baseline, y down).
final class TypesetLine: Sendable {
    /// Paragraph scalar range, trailing spaces and a cell break included.
    let start: Int
    let end: Int
    let runs: [LineGlyphRun]
    /// Caret x at each boundary `start...end`.
    let caretX: [Double]
    /// Left edge and width of the set text after alignment (justified lines fill the box).
    let left: Double
    let width: Double
    let ascent: Double
    let descent: Double
    /// Baseline-to-baseline distance above this line: the largest leading on it.
    let distance: Double
    /// The largest type size on the line.
    let size: Double
    let hyphenated: Bool
    let endsParagraph: Bool
    /// Ends at U+000C: the next line starts a new column or cell.
    let cellBreak: Bool
    /// Broken inside a word without a hyphen, because no word fitted.
    let emergency: Bool

    init(start: Int, end: Int, runs: [LineGlyphRun], caretX: [Double], left: Double, width: Double, ascent: Double, descent: Double, distance: Double, size: Double, hyphenated: Bool, endsParagraph: Bool, cellBreak: Bool, emergency: Bool = false) {
        self.start = start
        self.end = end
        self.runs = runs
        self.caretX = caretX
        self.left = left
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.distance = distance
        self.size = size
        self.hyphenated = hyphenated
        self.endsParagraph = endsParagraph
        self.cellBreak = cellBreak
        self.emergency = emergency
    }

    /// Caret x at paragraph boundary `index` (clamped to the line).
    func caret(at index: Int) -> Double {
        caretX[min(max(index - start, 0), caretX.count - 1)]
    }
}

/// What a line is asked for.
struct LineRequest: Hashable {
    let start: Int
    let columnWidth: Double
    let hyphensBefore: Int
}

/// Characters that hang outside the indents (paragraphs, "Hanging punctuation"): opening
/// quotation marks, apostrophes, hyphens and dashes.
let hangingPunctuation: Set<Unicode.Scalar> = [
    "\"", "'", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "\u{201A}", "\u{201E}", "\u{00AB}", "\u{00BB}",
    "\u{2039}", "\u{203A}", "-", "\u{2010}", "\u{2011}", "\u{2013}", "\u{2014}",
]

/// Whether `scalar` stands upright in vertical text (Unicode Vertical_Orientation U, by block:
/// Hangul, CJK, kana, fullwidth forms, compatibility ideographs and the supplementary planes'
/// ideographs); everything else is rotated with the line.
func isUpright(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x1100...0x11FF, 0x2E80...0xA4CF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFE10...0xFE1F,
         0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x3FFFF:
        return true
    default:
        return false
    }
}

/// Default tab stops: every half inch.
let defaultTabInterval = 36.0
/// How far the explicit default stops reach; Core Text's interval continues beyond.
let defaultTabsExtent = 2880.0

/// Large enough to never wrap, finite so Core Text accepts it.
let unboundedWidth = 1.0e7

nonisolated(unsafe) private let spanAttributeKey = "WTSpan" as CFString
nonisolated(unsafe) private let uprightAttributeKey = "WTUpright" as CFString

final class TypesetParagraph {
    let key: ParagraphKey
    let length: Int
    let scalars: [Unicode.Scalar]
    /// UTF-16 offset of each scalar boundary (count `length + 1`).
    let utf16Offsets: [Int]
    private let scalarAtUTF16: [Int32]
    /// Attributes per span; `spanStarts[i]` is span i's first scalar.
    let attributes: [TextAttributes]
    private let spanStarts: [Int]
    private let fonts: [CTFont]
    private let string: CFString
    private let typesetter: CTTypesetter
    private let locale: CFLocale
    private let sortedTabs: [TabStop]
    private var memo: [LineRequest: TypesetLine] = [:]
    /// Lines broken (memo misses): the incremental-relayout counter.
    private(set) var linesBroken = 0

    var style: ParagraphStyle { key.style }

    init(key: ParagraphKey) {
        self.key = key
        let scalars = Array(key.text.unicodeScalars)
        self.scalars = scalars
        length = scalars.count
        var offsets = [Int](repeating: 0, count: scalars.count + 1)
        var reverse: [Int32] = []
        reverse.reserveCapacity(scalars.count * 2 + 1)
        var utf16 = 0
        for (index, scalar) in scalars.enumerated() {
            offsets[index] = utf16
            let width = scalar.utf16.count
            for _ in 0..<width {
                reverse.append(Int32(index))
            }
            utf16 += width
        }
        offsets[scalars.count] = utf16
        reverse.append(Int32(scalars.count))
        utf16Offsets = offsets
        scalarAtUTF16 = reverse

        var attributes = key.spans.map(\.attributes)
        var starts: [Int] = []
        var position = 0
        for span in key.spans {
            starts.append(position)
            position += span.length
        }
        if attributes.isEmpty {
            attributes = [key.terminator]
            starts = [0]
        }
        self.attributes = attributes
        spanStarts = starts
        let resolver = FontResolver.shared
        fonts = attributes.map { resolver.font(for: $0) }
        sortedTabs = key.style.sortedTabs
        let language = key.style.hyphenation.language ?? attributes.first?.language ?? "en_US"
        locale = Locale(identifier: language) as CFLocale

        string = key.text as CFString
        let attributed = CFAttributedStringCreateMutable(nil, 0)!
        CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), string)
        CFAttributedStringBeginEditing(attributed)
        let paragraphStyle = TypesetParagraph.paragraphStyle(tabs: sortedTabs)
        let whole = CFRange(location: 0, length: utf16)
        if utf16 > 0 {
            CFAttributedStringSetAttribute(attributed, whole, kCTParagraphStyleAttributeName, paragraphStyle)
        }
        for (index, span) in attributes.enumerated() where index < key.spans.count {
            let first = starts[index]
            let last = first + key.spans[index].length
            let range = CFRange(location: offsets[first], length: offsets[last] - offsets[first])
            let font = fonts[index]
            let size = span.size
            let kern = size * (span.kerning + span.rangeKerning + key.style.letterSpacing.optimum) / 100
            CFAttributedStringSetAttribute(attributed, range, kCTFontAttributeName, font)
            CFAttributedStringSetAttribute(attributed, range, spanAttributeKey, NSNumber(value: index))
            if kern != 0 {
                CFAttributedStringSetAttribute(attributed, range, kCTKernAttributeName, NSNumber(value: kern))
            }
            if let language = span.language {
                CFAttributedStringSetAttribute(attributed, range, kCTLanguageAttributeName, language as CFString)
            }
            let wordExtra = (key.style.wordSpacing.optimum / 100 - 1) * TypesetParagraph.spaceAdvance(font)
            for scalarIndex in first..<last {
                let scalar = scalars[scalarIndex]
                let single = CFRange(location: offsets[scalarIndex], length: offsets[scalarIndex + 1] - offsets[scalarIndex])
                if scalar == " " && wordExtra != 0 {
                    CFAttributedStringSetAttribute(attributed, single, kCTKernAttributeName, NSNumber(value: kern + wordExtra))
                }
                if key.vertical && isUpright(scalar) {
                    CFAttributedStringSetAttribute(attributed, single, kCTFontAttributeName, resolver.font(for: span, upright: true))
                    CFAttributedStringSetAttribute(attributed, single, uprightAttributeKey, kCFBooleanTrue)
                }
            }
        }
        CFAttributedStringEndEditing(attributed)
        typesetter = CTTypesetterCreateWithAttributedString(attributed)
    }

    private static func paragraphStyle(tabs: [TabStop]) -> CTParagraphStyle {
        let terminators = CFCharacterSetCreateWithCharactersInString(nil, "." as CFString)!
        // Default tabs sit every half inch from the column edge, not from the last stop (Core
        // Text's default interval counts from the last stop): set them explicitly past it.
        let lastStop = tabs.last?.position ?? 0
        var defaults: [TabStop] = []
        var position = (lastStop / defaultTabInterval).rounded(.down) * defaultTabInterval + defaultTabInterval
        while position <= defaultTabsExtent {
            defaults.append(TabStop(.left, at: position))
            position += defaultTabInterval
        }
        let ctTabs: [CTTextTab] = (tabs + defaults).map { stop in
            switch stop.kind {
            case .left, .wrapping:
                return CTTextTabCreate(.left, stop.position, nil)
            case .right:
                return CTTextTabCreate(.right, stop.position, nil)
            case .center:
                return CTTextTabCreate(.center, stop.position, nil)
            case .decimal:
                // A right tab whose column ends at the decimal separator (NSTextTab's decimal).
                let options = [kCTTabColumnTerminatorsAttributeName: terminators] as CFDictionary
                return CTTextTabCreate(.right, stop.position, options)
            }
        }
        var tabArray = ctTabs as CFArray
        var interval = CGFloat(defaultTabInterval)
        return withUnsafeBytes(of: &tabArray) { tabBytes in
            withUnsafeBytes(of: &interval) { intervalBytes in
                let settings = [
                    CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: tabBytes.baseAddress!),
                    CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: intervalBytes.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }

    static func spaceAdvance(_ font: CTFont) -> Double {
        glyphAdvance(of: " ", in: font)?.advance ?? CTFontGetSize(font) / 4
    }

    /// The glyph and advance of `character` in `font`; nil when the font lacks it.
    static func glyphAdvance(of character: Character, in font: CTFont) -> (glyph: CGGlyph, advance: Double)? {
        let units = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count), glyphs[0] != 0 else {
            return nil
        }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, [glyphs[0]], &advance, 1)
        return (glyphs[0], Double(advance.width))
    }

    // MARK: Lookups

    /// The span holding scalar `index` (the last span for the end).
    func span(at index: Int) -> Int {
        var low = 0
        var high = spanStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if spanStarts[mid] <= index {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    func scalar(atUTF16 offset: Int) -> Int {
        Int(scalarAtUTF16[min(max(offset, 0), scalarAtUTF16.count - 1)])
    }

    /// The box a line starting at `start` is set in: left edge and width within the column.
    func box(start: Int, columnWidth: Double) -> (left: Double, width: Double) {
        let left = style.leftIndent + (start == 0 ? style.firstLineIndent : 0)
        return (left, max(columnWidth - left - style.rightIndent, 1))
    }

    // MARK: Lines

    /// The line starting at paragraph scalar `start` in a column `columnWidth` wide, after
    /// `hyphensBefore` consecutive hyphenated lines.
    func line(start: Int, columnWidth: Double, hyphensBefore: Int = 0) -> TypesetLine {
        let limited = style.hyphenation.consecutive > 0 ? min(hyphensBefore, style.hyphenation.consecutive) : 0
        let request = LineRequest(start: start, columnWidth: (columnWidth * 1000).rounded() / 1000, hyphensBefore: limited)
        if let cached = memo[request] {
            return cached
        }
        linesBroken += 1
        let line = breakLine(request)
        memo[request] = line
        return line
    }

    private func breakLine(_ request: LineRequest) -> TypesetLine {
        let start = request.start
        let (boxLeft, boxWidth) = box(start: start, columnWidth: request.columnWidth)
        guard start < length else {
            return emptyLine(at: start, boxLeft: boxLeft, boxWidth: boxWidth)
        }
        let justified = style.alignment == .justified
        let breakWidth = justified ? boxWidth : boxWidth * min(max(style.raggedWidth, 1), 100) / 100
        let utf16Start = utf16Offsets[start]
        let suggested = CTTypesetterSuggestLineBreakWithOffset(typesetter, utf16Start, breakWidth, boxLeft)
        var end = scalar(atUTF16: utf16Start + max(suggested, 1))
        end = keepingSelectedWords(start: start, end: end)
        var hyphenated = false
        if end < length, scalars[end - 1] == "\u{00AD}" {
            hyphenated = true
        } else if let hyphen = hyphenation(start: start, end: end, boxLeft: boxLeft, breakWidth: breakWidth, hyphensBefore: request.hyphensBefore) {
            end = hyphen
            hyphenated = true
        }
        return makeLine(start: start, end: end, boxLeft: boxLeft, boxWidth: boxWidth, hyphenated: hyphenated)
    }

    /// A break inside a "Selected words" span moves back to the span's start, unless that
    /// would leave the line empty.
    private func keepingSelectedWords(start: Int, end: Int) -> Int {
        guard end < length else {
            return end
        }
        let spanIndex = span(at: end)
        guard attributes[spanIndex].noBreak, span(at: end - 1) == spanIndex else {
            return end
        }
        let spanStart = spanStarts[spanIndex]
        return spanStart > start ? spanStart : end
    }

    /// Where to hyphenate the word at the break, if hyphenation is on and a hyphen point lets
    /// more of it fit.
    private func hyphenation(start: Int, end: Int, boxLeft: Double, breakWidth: Double, hyphensBefore: Int) -> Int? {
        let settings = style.hyphenation
        guard settings.enabled, end < length, !isMandatoryBreak(scalars[end - 1]),
              settings.consecutive == 0 || hyphensBefore < settings.consecutive
        else {
            return nil
        }
        var wordStart = end
        while wordStart > start && isLetter(scalars[wordStart - 1]) {
            wordStart -= 1
        }
        var wordEnd = end
        while wordEnd < length && isLetter(scalars[wordEnd]) {
            wordEnd += 1
        }
        guard wordEnd - wordStart >= 5,
              !(settings.skipCapitalized && scalars[wordStart].properties.isUppercase),
              !(wordStart..<wordEnd).contains(where: { attributes[span(at: $0)].noHyphen })
        else {
            return nil
        }
        let fits = scalar(atUTF16: utf16Offsets[start] + CTTypesetterSuggestClusterBreakWithOffset(typesetter, utf16Offsets[start], breakWidth, boxLeft))
        let limit = min(fits, wordEnd - 2)
        for candidate in hyphenPoints(wordStart: wordStart, wordEnd: wordEnd).reversed() where candidate <= limit && candidate >= wordStart + 2 {
            if measure(start: start, end: candidate, boxLeft: boxLeft) + hyphenAdvance(at: candidate - 1) <= breakWidth + 0.001 {
                return candidate
            }
        }
        return nil
    }

    /// The word's hyphenation points (scalar indices a hyphen may precede), ascending.
    private func hyphenPoints(wordStart: Int, wordEnd: Int) -> [Int] {
        let wordRange = CFRange(location: utf16Offsets[wordStart], length: utf16Offsets[wordEnd] - utf16Offsets[wordStart])
        var points: [Int] = []
        var before = utf16Offsets[wordEnd]
        while true {
            let location = CFStringGetHyphenationLocationBeforeIndex(string, before, wordRange, 0, locale, nil)
            if location == kCFNotFound || location >= before {
                break
            }
            points.append(scalar(atUTF16: location))
            before = location
        }
        return points.reversed()
    }

    private func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic
    }

    private func isMandatoryBreak(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{000C}" || scalar == "\u{2028}" || scalar == "\u{2029}" || scalar == "\u{000B}"
    }

    /// The visible width of `start..<end` set from `boxLeft`.
    private func measure(start: Int, end: Int, boxLeft: Double) -> Double {
        let range = CFRange(location: utf16Offsets[start], length: utf16Offsets[end] - utf16Offsets[start])
        let line = CTTypesetterCreateLineWithOffset(typesetter, range, boxLeft)
        return CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
    }

    private func hyphenGlyph(at index: Int) -> (glyph: CGGlyph, advance: Double, span: Int)? {
        let spanIndex = span(at: index)
        return TypesetParagraph.glyphAdvance(of: "-", in: fonts[spanIndex]).map { ($0.glyph, $0.advance, spanIndex) }
    }

    private func hyphenAdvance(at index: Int) -> Double {
        hyphenGlyph(at: index)?.advance ?? 0
    }

    private func emptyLine(at start: Int, boxLeft: Double, boxWidth: Double) -> TypesetLine {
        let attributes = length == 0 ? key.terminator : self.attributes[span(at: max(start - 1, 0))]
        let font = FontResolver.shared.font(for: attributes)
        let shift: Double
        switch style.alignment {
        case .center: shift = boxWidth / 2
        case .right: shift = boxWidth
        case .left, .justified: shift = 0
        }
        return TypesetLine(
            start: start, end: start, runs: [], caretX: [boxLeft + shift], left: boxLeft + shift, width: 0,
            ascent: Double(CTFontGetAscent(font)), descent: Double(CTFontGetDescent(font)),
            distance: attributes.lineDistance, size: attributes.size, hyphenated: false, endsParagraph: true, cellBreak: false
        )
    }

    // MARK: Assembly

    private struct RawGlyph {
        var glyph: CGGlyph
        var x: Double
        var advance: Double
        var char: Int
        var span: Int
        var font: CTFont
        var upright: Bool
    }

    private func makeLine(start: Int, end: Int, boxLeft: Double, boxWidth: Double, hyphenated: Bool) -> TypesetLine {
        let range = CFRange(location: utf16Offsets[start], length: utf16Offsets[end] - utf16Offsets[start])
        let ctLine = CTTypesetterCreateLineWithOffset(typesetter, range, boxLeft)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let typographicWidth = CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil)
        var naturalWidth = typographicWidth - CTLineGetTrailingWhitespaceWidth(ctLine)

        // Glyphs in line order, positions from the line origin (at boxLeft).
        var glyphs: [RawGlyph] = []
        for run in CTLineGetGlyphRuns(ctLine) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(), &ids)
            CTRunGetPositions(run, CFRange(), &positions)
            // A run in a font with a matrix (horizontal scale) reports positions in the
            // matrix's space.
            let textMatrix = CTRunGetTextMatrix(run)
            if !textMatrix.isIdentity {
                positions = positions.map { $0.applying(textMatrix) }
            }
            CTRunGetAdvances(run, CFRange(), &advances)
            CTRunGetStringIndices(run, CFRange(), &indices)
            let runAttributes = CTRunGetAttributes(run) as NSDictionary
            let font = runAttributes[kCTFontAttributeName] as! CTFont
            let spanIndex = (runAttributes[spanAttributeKey] as? NSNumber)?.intValue ?? span(at: scalar(atUTF16: indices.first ?? 0))
            let upright = runAttributes[uprightAttributeKey] != nil
            for index in 0..<count {
                glyphs.append(RawGlyph(
                    glyph: ids[index], x: Double(positions[index].x), advance: Double(advances[index].width),
                    char: scalar(atUTF16: indices[index]), span: spanIndex, font: font, upright: upright
                ))
            }
        }
        // Invisible controls draw nothing.
        glyphs.removeAll { raw in
            let scalar = scalars[raw.char]
            return scalar == "\u{000C}" || scalar == "\u{00AD}" || scalar == "\t" || scalar == "\u{2028}"
        }
        let tabStarts = tabLeaderGlyphs(start: start, end: end, boxLeft: boxLeft, line: ctLine)
        if hyphenated, let hyphen = hyphenGlyph(at: end - 1) {
            glyphs.append(RawGlyph(glyph: hyphen.glyph, x: naturalWidth, advance: hyphen.advance, char: end - 1, span: hyphen.span, font: fonts[hyphen.span], upright: false))
            naturalWidth += hyphen.advance
        }

        // Where the set text starts and how its slack is spent.
        let endsParagraph = end >= length
        let cellBreak = end > start && scalars[end - 1] == "\u{000C}"
        let visibleEnd = lastVisible(start: start, end: end)
        var hangLeft = 0.0
        var hangRight = 0.0
        if style.hangPunctuation, let first = glyphs.first, hangingPunctuation.contains(scalars[first.char]) {
            hangLeft = first.advance
        }
        if style.hangPunctuation, visibleEnd > start, hangingPunctuation.contains(scalars[visibleEnd - 1]) {
            hangRight = glyphs.last(where: { $0.char == visibleEnd - 1 })?.advance ?? 0
        }
        let setWidth = naturalWidth - hangLeft - hangRight
        let justify = style.alignment == .justified && !cellBreak
            && (!endsParagraph || (style.flushZone > 0 && naturalWidth >= boxWidth * style.flushZone / 100))
        var shifts = [Double](repeating: 0, count: glyphs.count + 1)
        var extraTotal = 0.0
        if justify && boxWidth < unboundedWidth / 2 {
            let lastTab = (start..<end).last { scalars[$0] == "\t" } ?? (start - 1)
            extraTotal = justification(glyphs: glyphs, spreadFrom: lastTab + 1, visibleEnd: visibleEnd, slack: boxWidth - setWidth, shifts: &shifts)
        }
        let alignShift: Double
        switch style.alignment {
        case _ where boxWidth >= unboundedWidth / 2: alignShift = 0
        case .left, .justified: alignShift = 0
        case .center: alignShift = (boxWidth - setWidth) / 2
        case .right: alignShift = boxWidth - setWidth
        }
        let origin = boxLeft + alignShift - hangLeft

        // Runs of one font, span and orientation.
        var runs: [LineGlyphRun] = []
        var current: [Int] = []
        func flush() {
            guard let firstIndex = current.first else {
                return  // a line of controls only
            }
            let first = glyphs[firstIndex]
            let attributes = self.attributes[first.span]
            runs.append(LineGlyphRun(
                span: first.span,
                font: GlyphFont(first.font, horizontalScale: Double(CTFontGetMatrix(first.font).a)),
                color: attributes.fill,
                glyphs: current.map { glyphs[$0].glyph },
                xs: current.map { origin + glyphs[$0].x + shifts[$0] },
                advances: current.map { glyphs[$0].advance },
                charIndices: current.map { glyphs[$0].char },
                yOffset: -attributes.baselineShift,
                upright: first.upright,
                ascent: Double(CTFontGetAscent(first.font)),
                descent: Double(CTFontGetDescent(first.font)),
                text: text(of: current.map { glyphs[$0].char })
            ))
            current = []
        }
        for (index, glyph) in glyphs.enumerated() {
            if let last = current.last, glyphs[last].span != glyph.span || glyphs[last].upright != glyph.upright || glyphs[last].font != glyph.font {
                flush()
            }
            current.append(index)
        }
        flush()
        runs.append(contentsOf: tabStarts.map { leader in
            LineGlyphRun(span: leader.span, font: leader.font, color: attributes[leader.span].fill, glyphs: leader.glyphs,
                         xs: leader.xs.map { $0 + alignShift - hangLeft }, advances: leader.advances,
                         charIndices: Array(repeating: leader.char, count: leader.glyphs.count), yOffset: 0, upright: false,
                         ascent: 0, descent: 0, text: "")
        })

        // Carets from Core Text's offsets plus the shift of the glyph at each boundary.
        var carets: [Double] = []
        carets.reserveCapacity(end - start + 1)
        var cursor = 0
        for boundary in start...end {
            while cursor < glyphs.count && glyphs[cursor].char < boundary {
                cursor += 1
            }
            let shift = cursor < glyphs.count ? shifts[cursor] : extraTotal
            let offset = boundary == end && hyphenated ? naturalWidth - (glyphs.last?.advance ?? 0) : Double(CTLineGetOffsetForStringIndex(ctLine, utf16Offsets[boundary], nil))
            carets.append(origin + offset + shift)
        }

        // Metrics: the tallest font, raised or lowered by its shift; the largest leading.
        var lineAscent = Double(ascent)
        var lineDescent = Double(descent)
        var distance = 0.0
        var size = 0.0
        for index in span(at: start)...span(at: max(end - 1, start)) {
            let attributes = self.attributes[index]
            distance = max(distance, attributes.lineDistance)
            size = max(size, attributes.size)
            let font = fonts[index]
            lineAscent = max(lineAscent, Double(CTFontGetAscent(font)) + attributes.baselineShift)
            lineDescent = max(lineDescent, Double(CTFontGetDescent(font)) - attributes.baselineShift)
        }
        return TypesetLine(
            start: start, end: end, runs: runs, caretX: carets, left: origin + hangLeft,
            width: justify ? min(setWidth + extraTotal, boxWidth) : setWidth,
            ascent: lineAscent, descent: lineDescent, distance: distance, size: size, hyphenated: hyphenated,
            endsParagraph: endsParagraph, cellBreak: cellBreak,
            emergency: !hyphenated && !endsParagraph && isLetter(scalars[end - 1]) && isLetter(scalars[end])
        )
    }

    /// The characters from the first to the last of `indices` (never empty).
    private func text(of indices: [Int]) -> String {
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars[indices.min()!...indices.max()!])
        return String(result)
    }

    /// The index after the last character that is not whitespace or a control.
    private func lastVisible(start: Int, end: Int) -> Int {
        var index = end
        while index > start {
            let scalar = scalars[index - 1]
            if scalar.properties.isWhitespace || scalar == "\u{00AD}" {
                index -= 1
            } else {
                break
            }
        }
        return index
    }

    /// Spreads `slack` over word spaces up to their maximum, then letter gaps up to theirs,
    /// then word spaces (or letter gaps) without limit; only text after the line's last tab is
    /// spread.  Fills `shifts` (the offset added to each glyph) and returns the total.
    private func justification(glyphs: [RawGlyph], spreadFrom: Int, visibleEnd: Int, slack: Double, shifts: inout [Double]) -> Double {
        guard slack > 0 else {
            return 0
        }
        let visible = glyphs.indices.filter { glyphs[$0].char >= spreadFrom && glyphs[$0].char < visibleEnd }
        guard let lastVisibleGlyph = visible.last else {
            return 0
        }
        var spaceCapacity = [Int: Double]()
        var letterCapacity = [Int: Double]()
        for index in visible {
            let glyph = glyphs[index]
            let size = attributes[glyph.span].size
            if scalars[glyph.char] == " " {
                spaceCapacity[index] = max(style.wordSpacing.max - style.wordSpacing.optimum, 0) / 100 * glyph.advance
            }
            if index != lastVisibleGlyph {
                letterCapacity[index] = max(style.letterSpacing.max - style.letterSpacing.optimum, 0) / 100 * size
            }
        }
        let words = spaceCapacity.values.reduce(0, +)
        let letters = letterCapacity.values.reduce(0, +)
        var extra = [Int: Double]()
        func spread(_ capacity: [Int: Double], total: Double, amount: Double) {
            guard total > 0 else {
                return
            }
            for (index, value) in capacity {
                extra[index, default: 0] += value / total * amount
            }
        }
        spread(spaceCapacity, total: words, amount: min(slack, words))
        spread(letterCapacity, total: letters, amount: min(max(slack - words, 0), letters))
        let rest = slack - min(slack, words) - min(max(slack - words, 0), letters)
        if rest > 0 {
            let targets = spaceCapacity.isEmpty ? letterCapacity : spaceCapacity
            let even = targets.mapValues { _ in 1.0 }
            spread(even, total: Double(even.count), amount: rest)
        }
        var running = 0.0
        for index in glyphs.indices {
            shifts[index] = running
            running += extra[index] ?? 0
        }
        shifts[glyphs.count] = running
        return running
    }

    private struct Leader {
        let span: Int
        let font: GlyphFont
        let glyphs: [CGGlyph]
        let xs: [Double]
        let advances: [Double]
        let char: Int
    }

    /// Leader glyphs for each tab in `start..<end` whose stop has a leader: the leader
    /// character repeated on a grid of its advance from the column edge, in the font of the
    /// character before the tab, filling the gap the tab opened.
    private func tabLeaderGlyphs(start: Int, end: Int, boxLeft: Double, line: CTLine) -> [Leader] {
        guard sortedTabs.contains(where: { !$0.leader.isEmpty }) else {
            return []
        }
        var leaders: [Leader] = []
        for index in start..<end where scalars[index] == "\t" {
            let tabX = boxLeft + Double(CTLineGetOffsetForStringIndex(line, utf16Offsets[index], nil))
            let nextX = boxLeft + Double(CTLineGetOffsetForStringIndex(line, utf16Offsets[index + 1], nil))
            guard let stop = sortedTabs.first(where: { $0.position > tabX + 0.001 }), stop.kind != .wrapping,
                  let character = stop.leader.first
            else {
                continue
            }
            let spanIndex = span(at: max(index - 1, 0))
            let font = fonts[spanIndex]
            guard let (glyph, advance) = TypesetParagraph.glyphAdvance(of: character, in: font), advance > 0 else {
                continue
            }
            var xs: [Double] = []
            var slot = (tabX / advance).rounded(.up)
            while (slot + 1) * advance <= nextX + 0.01 {
                xs.append(slot * advance)
                slot += 1
            }
            guard !xs.isEmpty else {
                continue
            }
            leaders.append(Leader(
                span: spanIndex, font: GlyphFont(font, horizontalScale: Double(CTFontGetMatrix(font).a)),
                glyphs: Array(repeating: glyph, count: xs.count), xs: xs,
                advances: Array(repeating: advance, count: xs.count), char: index
            ))
        }
        return leaders
    }
}
