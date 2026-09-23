// The text an RTF or plain-text export reads (export-text.adoc; IO-030).  The display list holds
// text only as positioned glyphs, so `WTModel` passes each text block's story alongside it: the
// resolved runs of its `RichText` with their character attributes, its paragraphs with their
// paragraph attributes, tables and inline graphics, plus the block's page, stacking order and link
// to the next block of its chain.  `TextStories.ordered` applies the export's ordering rules.

import CoreGraphics
import Foundation
import WTRender

/// Character attributes as RTF carries them.
public struct ExportTextAttributes: Hashable, Sendable {
    public enum Script: Hashable, Sendable {
        case none
        case superscript
        case `subscript`
    }

    /// The family name ("Helvetica Neue").
    public var fontFamily: String
    /// Points.
    public var size: Double
    public var bold: Bool
    public var italic: Bool
    /// Converted to RGB (gradient and pattern fills pass their first colour).
    public var color: Color
    public var underline: Bool
    public var strikethrough: Bool
    public var script: Script
    /// Points, up positive.
    public var baselineShift: Double
    /// 1 = 100%.
    public var horizontalScale: Double
    /// Tracking and kerning in thousandths of an em.
    public var tracking: Double
    public var smallCaps: Bool
    public var allCaps: Bool
    /// BCP 47.
    public var language: String?
    /// The character style's name, if the run carries one.
    public var styleName: String?

    public init(fontFamily: String = "Helvetica", size: Double = 12, bold: Bool = false, italic: Bool = false, color: Color = .black, underline: Bool = false, strikethrough: Bool = false, script: Script = .none, baselineShift: Double = 0, horizontalScale: Double = 1, tracking: Double = 0, smallCaps: Bool = false, allCaps: Bool = false, language: String? = nil, styleName: String? = nil) {
        self.fontFamily = fontFamily
        self.size = size
        self.bold = bold
        self.italic = italic
        self.color = color
        self.underline = underline
        self.strikethrough = strikethrough
        self.script = script
        self.baselineShift = baselineShift
        self.horizontalScale = horizontalScale
        self.tracking = tracking
        self.smallCaps = smallCaps
        self.allCaps = allCaps
        self.language = language
        self.styleName = styleName
    }
}

/// A run of characters with one set of attributes, or one inline graphic.
public struct ExportTextRun: @unchecked Sendable {
    public var text: String
    public var attributes: ExportTextAttributes
    /// An inline graphic rendered at the document's raster resolution; its `text` is U+FFFC.
    public var graphic: CGImage?
    /// The graphic's size in points.
    public var graphicSize: CGSize

    public init(_ text: String, attributes: ExportTextAttributes = ExportTextAttributes()) {
        self.text = text
        self.attributes = attributes
        graphic = nil
        graphicSize = .zero
    }

    public init(graphic: CGImage, size: CGSize, attributes: ExportTextAttributes = ExportTextAttributes()) {
        text = "\u{FFFC}"
        self.attributes = attributes
        self.graphic = graphic
        graphicSize = size
    }
}

/// A tab stop.
public struct ExportTabStop: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable {
        case left
        case center
        case right
        case decimal
    }

    public enum Leader: Hashable, Sendable {
        case none
        case dots
        case hyphens
        case underline
    }

    /// Points from the left indent's origin.
    public var position: Double
    public var alignment: Alignment
    public var leader: Leader

    public init(position: Double, alignment: Alignment = .left, leader: Leader = .none) {
        self.position = position
        self.alignment = alignment
        self.leader = leader
    }
}

/// Paragraph attributes as RTF carries them.  Lengths in points.
public struct ExportParagraphStyle: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable {
        case left
        case center
        case right
        case justified
    }

    public enum LineSpacing: Hashable, Sendable {
        /// Single spacing (the font's).
        case auto
        /// A multiple of single spacing.
        case multiple(Double)
        /// A fixed leading in points.
        case exactly(Double)
    }

    public var alignment: Alignment
    public var leftIndent: Double
    public var rightIndent: Double
    public var firstLineIndent: Double
    public var spaceBefore: Double
    public var spaceAfter: Double
    public var lineSpacing: LineSpacing
    public var tabStops: [ExportTabStop]
    public var keepWithNext: Bool
    public var hyphenate: Bool
    /// The paragraph style's name.
    public var styleName: String?

    public init(alignment: Alignment = .left, leftIndent: Double = 0, rightIndent: Double = 0, firstLineIndent: Double = 0, spaceBefore: Double = 0, spaceAfter: Double = 0, lineSpacing: LineSpacing = .auto, tabStops: [ExportTabStop] = [], keepWithNext: Bool = false, hyphenate: Bool = true, styleName: String? = nil) {
        self.alignment = alignment
        self.leftIndent = leftIndent
        self.rightIndent = rightIndent
        self.firstLineIndent = firstLineIndent
        self.spaceBefore = spaceBefore
        self.spaceAfter = spaceAfter
        self.lineSpacing = lineSpacing
        self.tabStops = tabStops
        self.keepWithNext = keepWithNext
        self.hyphenate = hyphenate
        self.styleName = styleName
    }
}

public struct ExportParagraph: Sendable {
    public var runs: [ExportTextRun]
    public var style: ExportParagraphStyle

    public init(_ runs: [ExportTextRun], style: ExportParagraphStyle = ExportParagraphStyle()) {
        self.runs = runs
        self.style = style
    }

    /// The paragraph's characters.
    public var text: String {
        runs.map(\.text).joined()
    }
}

/// A table: column widths and rows of cells, each cell a list of paragraphs.
public struct ExportTable: Sendable {
    /// Points.
    public var columnWidths: [Double]
    public var rows: [[[ExportParagraph]]]

    public init(columnWidths: [Double], rows: [[[ExportParagraph]]]) {
        self.columnWidths = columnWidths
        self.rows = rows
    }
}

/// One element of a story, in order.
public enum ExportStoryElement: Sendable {
    case paragraph(ExportParagraph)
    case table(ExportTable)
}

/// A story: the content of one text block, or of a linked chain.
public struct ExportStory: Sendable {
    public var elements: [ExportStoryElement]

    public init(_ elements: [ExportStoryElement]) {
        self.elements = elements
    }

    /// A story of plain paragraphs.
    public init(paragraphs: [ExportParagraph]) {
        elements = paragraphs.map { .paragraph($0) }
    }
}

/// A text block on a page, with its place in the export order.
public struct ExportTextBlock: Sendable {
    public var node: NodeID
    /// The index of the page (in `ExportScene.pages`) whose area holds the block's origin.
    public var page: Int
    /// Bottom to top on the page.
    public var stackingOrder: Int
    /// The next block of a linked chain.
    public var next: NodeID?
    /// The text this block shows.  In a chain, the head holds the story and the others nothing;
    /// stories held by several blocks of a chain are joined in link order.
    public var story: ExportStory?

    public init(node: NodeID, page: Int, stackingOrder: Int, next: NodeID? = nil, story: ExportStory?) {
        self.node = node
        self.page = page
        self.stackingOrder = stackingOrder
        self.next = next
        self.story = story
    }
}

enum TextStories {
    /// The stories in export order: each linked chain once, at its head block, and every block
    /// by page, then stacking order, bottom to top.  A chain that loops is cut before the block
    /// that would repeat; a loop with no head starts at its first block in that order.
    static func ordered(_ blocks: [ExportTextBlock]) -> [(page: Int, story: ExportStory)] {
        var byNode: [NodeID: ExportTextBlock] = [:]
        for block in blocks {
            byNode[block.node] = block
        }
        let linked = Set(blocks.compactMap(\.next))
        let sorted = blocks.sorted { ($0.page, $0.stackingOrder) < ($1.page, $1.stackingOrder) }
        var visited = Set<NodeID>()
        var result: [(page: Int, order: Int, story: ExportStory)] = []
        func chain(from head: ExportTextBlock) {
            var elements: [ExportStoryElement] = []
            var current: ExportTextBlock? = head
            while let block = current, visited.insert(block.node).inserted {
                elements += block.story?.elements ?? []
                current = block.next.flatMap { byNode[$0] }
            }
            if !elements.isEmpty {
                result.append((head.page, head.stackingOrder, ExportStory(elements)))
            }
        }
        for block in sorted where !linked.contains(block.node) {
            chain(from: block)
        }
        // Blocks left are in chains without a head: loops.
        for block in sorted where !visited.contains(block.node) {
            chain(from: block)
        }
        return result.sorted { ($0.page, $0.order) < ($1.page, $1.order) }.map { ($0.page, $0.story) }
    }
}
