// The layout engine's input (TXT-001): attributed runs, one paragraph style per paragraph and
// one character id per Unicode scalar.  It mirrors what WTCRDT reads out of a `RichText` field
// (docs/spec/crdt-model.adoc, "Text": the plain string, character id <-> offset, runs with
// their attributes, and the paragraph registers on each newline) without depending on the
// engine, so WTModel adapts one to the other.  Meanings follow the type chapter
// (creating-text, type-specifications, paragraphs, tabs-indents).

import WTGeometry
import struct WTGeometry.AffineTransform
import WTRender
import struct WTRender.StrokeStyle

/// A character's id: the `OpID` of the insert that created it (counter, then replica).
public struct CharID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var counter: UInt64
    public var replica: UInt64

    public init(counter: UInt64, replica: UInt64) {
        self.counter = counter
        self.replica = replica
    }

    public static func < (lhs: CharID, rhs: CharID) -> Bool {
        (lhs.counter, lhs.replica) < (rhs.counter, rhs.replica)
    }

    public var description: String { "\(counter):\(replica)" }
}

/// A caret or selection end: just before or just after a character (creating-text, "Layout":
/// a caret is a `(node, Anchor)`, never an integer offset).
public struct CharAnchor: Hashable, Sendable {
    public var char: CharID
    public var before: Bool

    public init(char: CharID, before: Bool) {
        self.char = char
        self.before = before
    }

    public static func before(_ char: CharID) -> CharAnchor { CharAnchor(char: char, before: true) }
    public static func after(_ char: CharID) -> CharAnchor { CharAnchor(char: char, before: false) }
}

/// Leading: the baseline-to-baseline distance (type-specifications, "Leading").
public struct Leading: Hashable, Sendable {
    public enum Mode: Hashable, Sendable {
        /// Size plus `value` points; +0 is solid.
        case extra
        /// Exactly `value` points.
        case fixed
        /// Size × `value` / 100; 120 is auto.
        case percent
    }

    public var mode: Mode
    public var value: Double

    public init(mode: Mode, value: Double) {
        self.mode = mode
        self.value = value
    }

    /// Auto leading: 120% of the size.
    public static let auto = Leading(mode: .percent, value: 120)
    /// Solid: as tall as the type.
    public static let solid = Leading(mode: .extra, value: 0)

    /// The baseline distance this leading gives type of `size` points.
    public func distance(forSize size: Double) -> Double {
        switch mode {
        case .extra: return size + value
        case .fixed: return value
        case .percent: return size * value / 100
        }
    }
}

/// An OpenType feature's tri-state (type-specifications, "Features").
public enum FeatureState: Hashable, Sendable {
    case `default`
    case on
    case off
}

/// Character formatting: the resolved winning marks of one run.
public struct TextAttributes: Hashable, Sendable {
    /// Family name ("Helvetica"); nil for the default family.
    public var fontFamily: String?
    /// Face within the family ("Bold Italic").
    public var fontStyle: String?
    /// Points.
    public var size: Double
    /// Nil reads as auto leading.
    public var leading: Leading?
    /// Pair kerning after each character, % of an em.
    public var kerning: Double
    /// Tracking across the span, % of an em.
    public var rangeKerning: Double
    /// Points, positive raises.
    public var baselineShift: Double
    /// Percent, 100 = normal.
    public var horizontalScale: Double
    public var fill: Color
    /// BCP 47; hyphenation and shaping.
    public var language: String?
    /// "Selected words": never break a line inside the span.
    public var noBreak: Bool
    /// "Inhibit hyphens in selection".
    public var noHyphen: Bool
    public var smallCaps: Bool
    /// OpenType features by tag.
    public var features: [String: FeatureState]
    /// Variation axis values by tag.
    public var axes: [String: Double]

    public init(
        fontFamily: String? = nil,
        fontStyle: String? = nil,
        size: Double = 12,
        leading: Leading? = nil,
        kerning: Double = 0,
        rangeKerning: Double = 0,
        baselineShift: Double = 0,
        horizontalScale: Double = 100,
        fill: Color = .black,
        language: String? = nil,
        noBreak: Bool = false,
        noHyphen: Bool = false,
        smallCaps: Bool = false,
        features: [String: FeatureState] = [:],
        axes: [String: Double] = [:]
    ) {
        self.fontFamily = fontFamily
        self.fontStyle = fontStyle
        self.size = size
        self.leading = leading
        self.kerning = kerning
        self.rangeKerning = rangeKerning
        self.baselineShift = baselineShift
        self.horizontalScale = horizontalScale
        self.fill = fill
        self.language = language
        self.noBreak = noBreak
        self.noHyphen = noHyphen
        self.smallCaps = smallCaps
        self.features = features
        self.axes = axes
    }

    /// The baseline distance of a line holding this run (the line takes the maximum).
    public var lineDistance: Double {
        (leading ?? .auto).distance(forSize: size)
    }
}

/// A run of text with one set of attributes.
public struct TextRun: Hashable, Sendable {
    public var text: String
    public var attributes: TextAttributes

    public init(_ text: String, attributes: TextAttributes = TextAttributes()) {
        self.text = text
        self.attributes = attributes
    }
}

/// Paragraph alignment (paragraphs, "Alignment").
public enum Alignment: Hashable, Sendable {
    case left
    case center
    case right
    /// Both edges flush; the last line left unless it reaches the flush zone.
    case justified
}

/// A tab stop (tabs-indents).
public struct TabStop: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case left
        case right
        case center
        /// The decimal separator on the stop; text without one right-aligns.
        case decimal
        /// Text between this stop and the next wraps as a column.
        case wrapping
    }

    public var kind: Kind
    /// Points from the column's left edge after inset.
    public var position: Double
    /// One grapheme repeated before the stop; empty for none.
    public var leader: String

    public init(_ kind: Kind = .left, at position: Double, leader: String = "") {
        self.kind = kind
        self.position = position
        self.leader = leader
    }
}

/// Hyphenation settings (paragraphs, "Hyphenation").
public struct Hyphenation: Hashable, Sendable {
    public var enabled: Bool
    /// BCP 47; nil for the document language.
    public var language: String?
    /// The most consecutive hyphenated lines; 0 = unlimited.
    public var consecutive: Int
    public var skipCapitalized: Bool

    public init(enabled: Bool = false, language: String? = nil, consecutive: Int = 0, skipCapitalized: Bool = false) {
        self.enabled = enabled
        self.language = language
        self.consecutive = consecutive
        self.skipCapitalized = skipCapitalized
    }
}

/// The stroke a rule is drawn with.
public struct RuleStroke: Hashable, Sendable {
    public var style: StrokeStyle
    public var color: Color

    public init(style: StrokeStyle = StrokeStyle(width: 1), color: Color = .black) {
        self.style = style
        self.color = color
    }
}

/// A paragraph rule (paragraphs, "Paragraph rules").
public struct ParagraphRule: Hashable, Sendable {
    public enum Mode: Hashable, Sendable {
        case none
        /// Centered in the column.
        case centered
        /// Aligned as the paragraph is aligned.
        case paragraph
    }

    public enum Basis: Hashable, Sendable {
        case lastLine
        case column
    }

    public var mode: Mode
    public var widthPercent: Double
    public var basis: Basis
    /// Points below the last baseline, or above the first line's top when `above`.
    public var position: Double
    public var above: Bool
    /// Overrides the block's stroke.
    public var stroke: RuleStroke?

    public init(mode: Mode = .none, widthPercent: Double = 100, basis: Basis = .lastLine, position: Double = 0, above: Bool = false, stroke: RuleStroke? = nil) {
        self.mode = mode
        self.widthPercent = widthPercent
        self.basis = basis
        self.position = position
        self.above = above
        self.stroke = stroke
    }
}

/// A min/optimum/max spacing triple (paragraphs, "Word and letter spacing").
public struct SpacingRange: Hashable, Sendable {
    public var min: Double
    public var optimum: Double
    public var max: Double

    public init(min: Double, optimum: Double, max: Double) {
        self.min = min
        self.optimum = optimum
        self.max = max
    }

    /// Word spacing, percent of the font's space: normal with room to stretch.
    public static let words = SpacingRange(min: 80, optimum: 100, max: 150)
    /// Letter spacing, percent of an em: none, with a little room to stretch.
    public static let letters = SpacingRange(min: 0, optimum: 0, max: 5)
}

/// Paragraph properties: one `ParagraphProps` register set, resolved.
public struct ParagraphStyle: Hashable, Sendable {
    public var alignment: Alignment
    /// Non-justified lines break at this percentage of the column width (100 = full width).
    public var raggedWidth: Double
    /// Justified: the last line is justified when it reaches this percentage of the width;
    /// 0 never justifies it.
    public var flushZone: Double
    public var leftIndent: Double
    public var rightIndent: Double
    /// Relative to the left indent.
    public var firstLineIndent: Double
    public var spaceAbove: Double
    public var spaceBelow: Double
    public var tabs: [TabStop]
    public var hyphenation: Hyphenation
    public var rule: ParagraphRule
    public var hangPunctuation: Bool
    /// 0 = off; N keeps at least N lines together at a column break.
    public var keepLines: Int
    public var keepWithNext: Bool
    public var wordSpacing: SpacingRange
    public var letterSpacing: SpacingRange

    public init(
        alignment: Alignment = .left,
        raggedWidth: Double = 100,
        flushZone: Double = 100,
        leftIndent: Double = 0,
        rightIndent: Double = 0,
        firstLineIndent: Double = 0,
        spaceAbove: Double = 0,
        spaceBelow: Double = 0,
        tabs: [TabStop] = [],
        hyphenation: Hyphenation = Hyphenation(),
        rule: ParagraphRule = ParagraphRule(),
        hangPunctuation: Bool = false,
        keepLines: Int = 0,
        keepWithNext: Bool = false,
        wordSpacing: SpacingRange = .words,
        letterSpacing: SpacingRange = .letters
    ) {
        self.alignment = alignment
        self.raggedWidth = raggedWidth
        self.flushZone = flushZone
        self.leftIndent = leftIndent
        self.rightIndent = rightIndent
        self.firstLineIndent = firstLineIndent
        self.spaceAbove = spaceAbove
        self.spaceBelow = spaceBelow
        self.tabs = tabs
        self.hyphenation = hyphenation
        self.rule = rule
        self.hangPunctuation = hangPunctuation
        self.keepLines = keepLines
        self.keepWithNext = keepWithNext
        self.wordSpacing = wordSpacing
        self.letterSpacing = letterSpacing
    }

    /// Tab stops ordered by position (tabs-indents: order is by position at read time).
    var sortedTabs: [TabStop] {
        tabs.enumerated().sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }.map(\.element)
    }
}

/// What the layout engine lays out: the text of one flow.
public struct TextContent: Hashable, Sendable {
    /// The characters, in document order, with their attributes.  U+000A ends a paragraph and
    /// U+000C ends a column or cell.
    public var runs: [TextRun]
    /// One style per paragraph: the paragraph registers of each terminating newline, then the
    /// tail paragraph's.
    public var paragraphs: [ParagraphStyle]
    /// One id per Unicode scalar of the runs' text.
    public var charIDs: [CharID]

    public init(runs: [TextRun], paragraphs: [ParagraphStyle] = [], charIDs: [CharID] = []) {
        self.runs = runs
        self.paragraphs = paragraphs
        self.charIDs = charIDs
    }

    /// Plain text with sequential ids from `firstID`, all in `attributes`, every paragraph in
    /// `style`: convenient for tests and previews.
    public init(_ text: String, attributes: TextAttributes = TextAttributes(), style: ParagraphStyle = ParagraphStyle(), replica: UInt64 = 1, firstCounter: UInt64 = 1) {
        let count = text.unicodeScalars.count
        let paragraphs = text.unicodeScalars.filter { $0 == "\n" }.count + 1
        self.init(
            runs: [TextRun(text, attributes: attributes)],
            paragraphs: Array(repeating: style, count: paragraphs),
            charIDs: (0..<count).map { CharID(counter: firstCounter + UInt64($0), replica: replica) }
        )
    }

    /// The concatenated text.
    public var string: String {
        runs.map(\.text).joined()
    }

    /// Unicode scalars in the flow.
    public var scalarCount: Int {
        runs.reduce(0) { $0 + $1.text.unicodeScalars.count }
    }
}

/// Synthetic ids for scalars a content's id list does not cover (normalize on read: a short
/// list never misaddresses characters).  Replica `UInt64.max` is never a real replica.
func syntheticCharID(_ offset: Int) -> CharID {
    CharID(counter: UInt64(offset), replica: .max)
}
