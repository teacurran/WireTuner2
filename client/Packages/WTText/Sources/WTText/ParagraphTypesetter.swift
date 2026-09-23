// One paragraph shaped by Core Text and broken into lines (TXT-001).  Core Text shapes and
// suggests breaks (UAX #14); WTText does the rest itself, as the type chapter's Client sections
// require: justification within the word and letter spacing ranges and the flush zone, the
// ragged width, hyphenation through `CFStringGetHyphenationLocationBeforeIndex` with the
// paragraph's locale (consecutive limit, capitalized words, inhibited spans, discretionary
// hyphens), "Selected words" that never break, tab leaders in the preceding character's font,
// hanging punctuation, baseline shift and per-line maximum leading; small capitals drawn as
// scaled capitals in any font; inline graphics as run delegates the graphic's size; wrapping
// tabs as rows of sub-columns (TabRow.swift).
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
    /// The span's attributes (effects, glyph stroke, overprint).
    let attributes: TextAttributes
    /// The stroke width synthesizing a bold face; 0 for none.
    let emboldening: Double
}

/// An inline graphic placed on a line (text-effects, "Inline graphics").
struct LineInline: Sendable {
    /// The paragraph scalar (U+FFFC) it stands for.
    let char: Int
    let graphic: InlineGraphic
    /// Where its advance starts, column coordinates.
    let x: Double
    /// The baseline shift (and a row's sub-line), y down.
    let yOffset: Double
    /// The type size (a missing graphic's box).
    let size: Double
    let fill: Color
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
    /// The index after the last character that is not whitespace or a control.
    let visibleEnd: Int
    /// Inline graphics on the line.
    let inlines: [LineInline]
    /// A wrapping-tab row's sub-lines: each boundary's y below the baseline (nil: all on it),
    /// and how far the last sub-line's baseline sits below the first.
    let caretY: [Double]?
    let extraDepth: Double

    init(start: Int, end: Int, runs: [LineGlyphRun], caretX: [Double], left: Double, width: Double, ascent: Double, descent: Double, distance: Double, size: Double, hyphenated: Bool, endsParagraph: Bool, cellBreak: Bool, emergency: Bool = false, visibleEnd: Int? = nil, inlines: [LineInline] = [], caretY: [Double]? = nil, extraDepth: Double = 0) {
        self.visibleEnd = visibleEnd ?? end
        self.inlines = inlines
        self.caretY = caretY
        self.extraDepth = extraDepth
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

    /// The caret's baseline below the line's at paragraph boundary `index` (a row's sub-line).
    func caretDepth(at index: Int) -> Double {
        caretY.map { $0[min(max(index - start, 0), $0.count - 1)] } ?? 0
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

/// A run delegate's metrics: an inline graphic's box, or nothing for a bare U+FFFC.
private final class InlineMetrics {
    let ascent: Double
    let descent: Double
    let width: Double

    init(ascent: Double, descent: Double, width: Double) {
        self.ascent = ascent
        self.descent = descent
        self.width = width
    }

    /// A Core Text run delegate reporting these metrics.
    func delegate() -> CTRunDelegate? {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { Unmanaged<InlineMetrics>.fromOpaque($0).release() },
            getAscent: { CGFloat(Unmanaged<InlineMetrics>.fromOpaque($0).takeUnretainedValue().ascent) },
            getDescent: { CGFloat(Unmanaged<InlineMetrics>.fromOpaque($0).takeUnretainedValue().descent) },
            getWidth: { CGFloat(Unmanaged<InlineMetrics>.fromOpaque($0).takeUnretainedValue().width) }
        )
        return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(self).toOpaque())
    }
}

/// Vertical forms by font and character.
final class VerticalForms: @unchecked Sendable {
    static let shared = VerticalForms()

    private struct Key: Hashable {
        let font: String
        let size: CGFloat
        let scalar: Unicode.Scalar
    }

    private let lock = NSLock()
    private var glyphs: [Key: CGGlyph] = [:]

    func glyph(for scalar: Unicode.Scalar, glyph: CGGlyph, in font: CTFont) -> CGGlyph {
        let key = Key(font: CTFontCopyPostScriptName(font) as String, size: CTFontGetSize(font), scalar: scalar)
        lock.lock()
        if let known = glyphs[key] {
            lock.unlock()
            return known == 0 ? glyph : known
        }
        lock.unlock()
        let attributed = NSAttributedString(string: String(scalar), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String): true,
        ])
        var found: CGGlyph = 0
        let runs = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(attributed)) as! [CTRun]
        if runs.count == 1, CTRunGetGlyphCount(runs[0]) == 1 {
            CTRunGetGlyphs(runs[0], CFRange(location: 0, length: 1), &found)
        }
        lock.lock()
        glyphs[key] = found
        lock.unlock()
        return found == 0 ? glyph : found
    }
}

/// The object replacement character: an inline graphic's place in the text.
let objectReplacement: Unicode.Scalar = "\u{FFFC}"

final class TypesetParagraph {
    let key: ParagraphKey
    let length: Int
    let scalars: [Unicode.Scalar]
    /// UTF-16 offset of each scalar boundary (count `length + 1`).
    let utf16Offsets: [Int]
    private let scalarAtUTF16: [Int32]
    /// Attributes per span; `spanStarts[i]` is span i's first scalar.
    let attributes: [TextAttributes]
    let spanStarts: [Int]
    let fonts: [CTFont]
    /// Per span: the stroke width synthesizing a bold face.
    let emboldening: [Double]
    /// What the fonts could not honour.
    let fontReport: FontReport
    /// Run fonts looked up while typesetting, and how many came from the cache.
    let fontLookups: Int
    let fontHits: Int
    /// The paragraph's text, for hyphenation (Core Text shapes small capitals uppercased).
    private let string: CFString
    let typesetter: CTTypesetter
    private let locale: CFLocale
    /// The locale's decimal separator (decimal tabs align on it).
    let decimalSeparator: String
    let sortedTabs: [TabStop]
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
        var report = FontReport()
        var lookups = 0
        var hits = 0
        func resolve(_ attributes: TextAttributes, upright: Bool = false) -> ResolvedFont {
            let (font, hit) = resolver.resolve(attributes, upright: upright)
            lookups += 1
            hits += hit ? 1 : 0
            report.merge(font.report)
            return font
        }
        let resolved = attributes.map { resolve($0) }
        fonts = resolved.map(\.font)
        emboldening = resolved.map(\.emboldening)
        // Tab stops are horizontal-only (text-effects, "Vertical text").
        sortedTabs = key.vertical ? [] : key.style.sortedTabs
        let language = key.style.hyphenation.language ?? attributes.first?.language ?? "en_US"
        let paragraphLocale = Locale(identifier: language)
        locale = paragraphLocale as CFLocale
        decimalSeparator = paragraphLocale.decimalSeparator ?? "."

        string = key.text as CFString
        // Small capitals are the capitals of lowercase letters, set smaller; only letters whose
        // capital is one scalar of the same UTF-16 length change, so offsets stay put.
        var shaped = String.UnicodeScalarView()
        var smallCap = [Bool](repeating: false, count: scalars.count)
        for (index, scalar) in scalars.enumerated() {
            let spanIndex = TypesetParagraph.span(at: index, starts: starts)
            if attributes[spanIndex].smallCaps, scalar.properties.isLowercase,
               let upper = TypesetParagraph.singleUppercase(scalar), upper.utf16.count == scalar.utf16.count {
                shaped.append(upper)
                smallCap[index] = true
            } else {
                shaped.append(scalar)
            }
        }
        let attributed = CFAttributedStringCreateMutable(nil, 0)!
        CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), String(shaped) as CFString)
        CFAttributedStringBeginEditing(attributed)
        let paragraphStyle = TypesetParagraph.paragraphStyle(tabs: sortedTabs, decimalSeparator: decimalSeparator)
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
            var smallCapFont: CTFont?
            for scalarIndex in first..<last {
                let scalar = scalars[scalarIndex]
                let single = CFRange(location: offsets[scalarIndex], length: offsets[scalarIndex + 1] - offsets[scalarIndex])
                if scalar == " " && wordExtra != 0 {
                    CFAttributedStringSetAttribute(attributed, single, kCTKernAttributeName, NSNumber(value: kern + wordExtra))
                }
                if scalar == objectReplacement {
                    // An inline graphic advances by its width and rises by its height; a bare
                    // U+FFFC takes no room at all.
                    let metrics: InlineMetrics
                    if let graphic = span.inlineGraphic {
                        let box = graphic.items == nil ? Rect(x: 0, y: 0, width: size, height: size) : graphic.bounds
                        metrics = InlineMetrics(ascent: box.height, descent: 0, width: box.width)
                    } else {
                        metrics = InlineMetrics(ascent: 0, descent: 0, width: 0)
                    }
                    if let delegate = metrics.delegate() {
                        CFAttributedStringSetAttribute(attributed, single, kCTRunDelegateAttributeName, delegate)
                    }
                } else if key.vertical && isUpright(scalar) {
                    CFAttributedStringSetAttribute(attributed, single, kCTFontAttributeName, resolve(span, upright: true).font)
                    CFAttributedStringSetAttribute(attributed, single, uprightAttributeKey, kCFBooleanTrue)
                } else if smallCap[scalarIndex] {
                    if smallCapFont == nil {
                        smallCapFont = resolve(span.scaled(by: TextAttributes.smallCapsScale)).font
                    }
                    CFAttributedStringSetAttribute(attributed, single, kCTFontAttributeName, smallCapFont)
                }
            }
        }
        CFAttributedStringEndEditing(attributed)
        typesetter = CTTypesetterCreateWithAttributedString(attributed)
        fontReport = report
        fontLookups = lookups
        fontHits = hits
    }

    /// The capital of a lowercase letter when it is a single scalar.
    static func singleUppercase(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
        let upper = scalar.properties.uppercaseMapping.unicodeScalars
        return upper.count == 1 ? upper.first : nil
    }

    /// The span holding scalar `index` among spans starting at `starts`.
    static func span(at index: Int, starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= index {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    private static func paragraphStyle(tabs: [TabStop], decimalSeparator: String) -> CTParagraphStyle {
        let terminators = CFCharacterSetCreateWithCharactersInString(nil, decimalSeparator as CFString)!
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
                // A right tab whose column ends at the locale's decimal separator (NSTextTab's
                // decimal); text without one right-aligns.
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
        TypesetParagraph.span(at: index, starts: spanStarts)
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

    /// Whether a stop is a wrapping tab: lines with tabs are then laid out as rows.
    var hasWrappingTabs: Bool { sortedTabs.contains { $0.kind == .wrapping } }

    private func breakLine(_ request: LineRequest) -> TypesetLine {
        let start = request.start
        let (boxLeft, boxWidth) = box(start: start, columnWidth: request.columnWidth)
        guard start < length else {
            return emptyLine(at: start, boxLeft: boxLeft, boxWidth: boxWidth)
        }
        if hasWrappingTabs, let row = rowLine(start: start, boxLeft: boxLeft, boxWidth: boxWidth, columnWidth: request.columnWidth) {
            return row
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

    func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic
    }

    func isMandatoryBreak(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{000C}" || scalar == "\u{2028}" || scalar == "\u{2029}" || scalar == "\u{000B}"
    }

    /// The visible width of `start..<end` set from `boxLeft`.
    private func measure(start: Int, end: Int, boxLeft: Double) -> Double {
        let range = CFRange(location: utf16Offsets[start], length: utf16Offsets[end] - utf16Offsets[start])
        let line = CTTypesetterCreateLineWithOffset(typesetter, range, boxLeft)
        return CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
    }

    func hyphenGlyph(at index: Int) -> (glyph: CGGlyph, advance: Double, span: Int)? {
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

    struct RawGlyph {
        var glyph: CGGlyph
        var x: Double
        var advance: Double
        var char: Int
        var span: Int
        var font: CTFont
        var upright: Bool
        /// A row's sub-line: the baseline below the line's, y down.
        var depth: Double = 0
    }

    /// `ctLine`'s glyphs in line order, x from the line origin plus `xOffset`.
    func rawGlyphs(of ctLine: CTLine, xOffset: Double = 0) -> [RawGlyph] {
        var glyphs: [RawGlyph] = []
        for run in CTLineGetGlyphRuns(ctLine) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(), &ids)
            CTRunGetPositions(run, CFRange(), &positions)
            // A run in a font with a matrix (horizontal scale, synthesized slant) reports
            // positions in the matrix's space.
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
                let char = scalar(atUTF16: indices[index])
                glyphs.append(RawGlyph(
                    glyph: upright ? TypesetParagraph.verticalForm(of: scalars[char], glyph: ids[index], in: font) : ids[index],
                    x: xOffset + Double(positions[index].x), advance: Double(advances[index].width),
                    char: char, span: spanIndex, font: font, upright: upright
                ))
            }
        }
        return glyphs
    }

    /// The vertical form of an upright character's glyph (vertical punctuation, brackets,
    /// the long vowel mark): Core Text substitutes vertical forms only under
    /// `kCTVerticalFormsAttributeName`, whose runs report positions in a rotated space, so the
    /// glyph is looked up on its own and swapped in; its advance is the em box either way.
    static func verticalForm(of scalar: Unicode.Scalar, glyph: CGGlyph, in font: CTFont) -> CGGlyph {
        VerticalForms.shared.glyph(for: scalar, glyph: glyph, in: font)
    }

    /// Whether a glyph of `scalar` is never drawn: controls, tabs, soft hyphens and the object
    /// replacement character (an inline graphic is drawn by itself).
    func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{000C}" || scalar == "\u{00AD}" || scalar == "\t" || scalar == "\u{2028}" || scalar == objectReplacement
    }

    /// Glyph runs of one font, span, orientation and sub-line from `glyphs` placed at `xs`.
    func makeRuns(_ glyphs: [RawGlyph], xs: [Double]) -> [LineGlyphRun] {
        var runs: [LineGlyphRun] = []
        var current: [Int] = []
        func flush() {
            guard let firstIndex = current.first else {
                return  // a line of controls only
            }
            let first = glyphs[firstIndex]
            let attributes = self.attributes[first.span]
            let matrix = CTFontGetMatrix(first.font)
            runs.append(LineGlyphRun(
                span: first.span,
                font: GlyphFont(first.font, horizontalScale: Double(matrix.a), obliqueness: Double(matrix.c)),
                color: attributes.fill,
                glyphs: current.map { glyphs[$0].glyph },
                xs: current.map { xs[$0] },
                advances: current.map { glyphs[$0].advance },
                charIndices: current.map { glyphs[$0].char },
                yOffset: first.depth - attributes.baselineShift,
                upright: first.upright,
                ascent: Double(CTFontGetAscent(first.font)),
                descent: Double(CTFontGetDescent(first.font)),
                text: text(of: current.map { glyphs[$0].char }),
                attributes: attributes,
                emboldening: emboldening[first.span]
            ))
            current = []
        }
        for (index, glyph) in glyphs.enumerated() {
            if let last = current.last, glyphs[last].span != glyph.span || glyphs[last].upright != glyph.upright
                || glyphs[last].font != glyph.font || glyphs[last].depth != glyph.depth {
                flush()
            }
            current.append(index)
        }
        flush()
        return runs
    }

    /// The inline graphics among `start..<end` at the caret positions `carets` (boundaries
    /// `start...end`), each `depth` below the baseline.
    func inlines(start: Int, end: Int, carets: [Double], depths: [Double]? = nil) -> [LineInline] {
        var result: [LineInline] = []
        for index in start..<end where scalars[index] == objectReplacement {
            let attributes = self.attributes[span(at: index)]
            guard let graphic = attributes.inlineGraphic else {
                continue
            }
            let depth = depths.map { $0[index - start] } ?? 0
            result.append(LineInline(char: index, graphic: graphic, x: carets[index - start], yOffset: depth - attributes.baselineShift, size: attributes.size, fill: attributes.fill))
        }
        return result
    }

    /// The line's metrics over spans `start..<end`: the tallest font, raised or lowered by its
    /// shift, and the largest leading and size.
    func metrics(start: Int, end: Int, ascent: Double, descent: Double) -> (ascent: Double, descent: Double, distance: Double, size: Double) {
        var lineAscent = ascent
        var lineDescent = descent
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
        return (lineAscent, lineDescent, distance, size)
    }

    private func makeLine(start: Int, end: Int, boxLeft: Double, boxWidth: Double, hyphenated: Bool) -> TypesetLine {
        let range = CFRange(location: utf16Offsets[start], length: utf16Offsets[end] - utf16Offsets[start])
        let ctLine = CTTypesetterCreateLineWithOffset(typesetter, range, boxLeft)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let typographicWidth = CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil)
        var naturalWidth = typographicWidth - CTLineGetTrailingWhitespaceWidth(ctLine)

        // Glyphs in line order, positions from the line origin (at boxLeft).
        var glyphs = rawGlyphs(of: ctLine)
        glyphs.removeAll { isInvisible(scalars[$0.char]) }
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

        var runs = makeRuns(glyphs, xs: glyphs.indices.map { origin + glyphs[$0].x + shifts[$0] })
        runs.append(contentsOf: tabStarts.map { leader in
            LineGlyphRun(span: leader.span, font: leader.font, color: attributes[leader.span].fill, glyphs: leader.glyphs,
                         xs: leader.xs.map { $0 + alignShift - hangLeft }, advances: leader.advances,
                         charIndices: Array(repeating: leader.char, count: leader.glyphs.count), yOffset: 0, upright: false,
                         ascent: 0, descent: 0, text: "", attributes: attributes[leader.span], emboldening: 0)
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

        let metrics = metrics(start: start, end: end, ascent: Double(ascent), descent: Double(descent))
        return TypesetLine(
            start: start, end: end, runs: runs, caretX: carets, left: origin + hangLeft,
            width: justify ? min(setWidth + extraTotal, boxWidth) : setWidth,
            ascent: metrics.ascent, descent: metrics.descent, distance: metrics.distance, size: metrics.size, hyphenated: hyphenated,
            endsParagraph: endsParagraph, cellBreak: cellBreak,
            emergency: !hyphenated && !endsParagraph && isLetter(scalars[end - 1]) && isLetter(scalars[end]),
            visibleEnd: visibleEnd,
            inlines: inlines(start: start, end: end, carets: carets)
        )
    }

    /// The characters from the first to the last of `indices` (never empty).
    func text(of indices: [Int]) -> String {
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars[indices.min()!...indices.max()!])
        return String(result)
    }

    /// The index after the last character that is not whitespace or a control.
    func lastVisible(start: Int, end: Int) -> Int {
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

    struct Leader {
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
                  let leader = leader(stop.leader, tab: index, from: tabX, to: nextX)
            else {
                continue
            }
            leaders.append(leader)
        }
        return leaders
    }

    /// `character` (a leader's first) repeated on a grid of its advance from the column edge
    /// between `tabX` and `nextX`, in the font of the character before tab `index`; nil when
    /// nothing fits or the font lacks the character.
    func leader(_ leader: String, tab index: Int, from tabX: Double, to nextX: Double) -> Leader? {
        guard let character = leader.first else {
            return nil
        }
        let spanIndex = span(at: max(index - 1, 0))
        let font = fonts[spanIndex]
        guard let (glyph, advance) = TypesetParagraph.glyphAdvance(of: character, in: font), advance > 0 else {
            return nil
        }
        var xs: [Double] = []
        var slot = (tabX / advance).rounded(.up)
        while (slot + 1) * advance <= nextX + 0.01 {
            xs.append(slot * advance)
            slot += 1
        }
        guard !xs.isEmpty else {
            return nil
        }
        let matrix = CTFontGetMatrix(font)
        return Leader(
            span: spanIndex, font: GlyphFont(font, horizontalScale: Double(matrix.a), obliqueness: Double(matrix.c)),
            glyphs: Array(repeating: glyph, count: xs.count), xs: xs,
            advances: Array(repeating: advance, count: xs.count), char: index
        )
    }
}
