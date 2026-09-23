// Where a flow is laid out: text blocks (text-blocks, columns-tables, text-effects' vertical
// writing) and paths (text-on-path).  A linked flow is a list of containers laid out in order,
// each continuing where the previous one stopped (text-blocks, "Layout across a chain").

import WTGeometry
import struct WTGeometry.AffineTransform
import WTRender
import struct WTRender.StrokeStyle

/// Space between a block's edge and its text, per side (tabs-indents, "Margins (insets)").
public struct Inset: Hashable, Sendable {
    public var left: Double
    public var right: Double
    public var top: Double
    public var bottom: Double

    public init(left: Double = 0, right: Double = 0, top: Double = 0, bottom: Double = 0) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }

    public static let zero = Inset()
}

/// How text fills a grid of cells (columns-tables).
public enum FlowOrder: Hashable, Sendable {
    /// The first column top to bottom, then the next.
    case down
    /// The first row left to right, then the next.
    case across
}

/// How far the lines between columns or rows reach (columns-tables, `RuleExtent`).
public enum RuleExtent: Hashable, Sendable {
    case none
    /// As tall (or wide) as the text area: the block minus its inset.
    case inset
    /// The block's full height (or width).
    case full
}

/// Columns and rows (columns-tables, `ColumnsRows`).
public struct ColumnsRows: Hashable, Sendable {
    public var columns: Int
    /// Height of each cell of a column; 0 divides the block's text height among the rows.
    public var columnHeight: Double
    /// Gutter between columns.
    public var columnSpacing: Double
    public var rows: Int
    /// Width of each cell of a row; 0 divides the block's text width among the columns.
    public var rowWidth: Double
    /// Gutter between rows.
    public var rowSpacing: Double
    public var flow: FlowOrder
    /// Lines between columns, drawn with the block's stroke.
    public var columnRules: RuleExtent
    /// Lines between rows, drawn with the block's stroke.
    public var rowRules: RuleExtent

    public init(columns: Int = 1, columnHeight: Double = 0, columnSpacing: Double = 0, rows: Int = 1, rowWidth: Double = 0, rowSpacing: Double = 0, flow: FlowOrder = .down, columnRules: RuleExtent = .none, rowRules: RuleExtent = .none) {
        self.columns = columns
        self.columnHeight = columnHeight
        self.columnSpacing = columnSpacing
        self.rows = rows
        self.rowWidth = rowWidth
        self.rowSpacing = rowSpacing
        self.flow = flow
        self.columnRules = columnRules
        self.rowRules = rowRules
    }
}

/// Fitting text to its container (columns-tables, `AdjustColumns`; first-line leading is
/// `TextBlock.firstLineLeading`).
public struct AdjustColumns: Hashable, Sendable {
    /// Spread the lines evenly among the cells.
    public var balance: Bool
    /// Add leading so the lines fill each cell that is at least `thresholdPercent` full.
    public var modifyLeading: Bool
    public var thresholdPercent: Double
    /// The range, in percent of the set size, copyfit may scale the size and leading within;
    /// 100 and 100 turn copyfit off.
    public var copyfitMinPercent: Double
    public var copyfitMaxPercent: Double

    public init(balance: Bool = false, modifyLeading: Bool = false, thresholdPercent: Double = 50, copyfitMinPercent: Double = 100, copyfitMaxPercent: Double = 100) {
        self.balance = balance
        self.modifyLeading = modifyLeading
        self.thresholdPercent = thresholdPercent
        self.copyfitMinPercent = copyfitMinPercent
        self.copyfitMaxPercent = copyfitMaxPercent
    }

    /// The copyfit range as scale factors, normalized: a minimum above the maximum reads as
    /// both at the minimum; nil when copyfit is off.
    var copyfitRange: ClosedRange<Double>? {
        let low = max(copyfitMinPercent, 1) / 100
        let high = max(copyfitMaxPercent, 1) / 100
        let range = low <= high ? low...high : low...low
        return range == 1...1 ? nil : range
    }
}

/// An object text flows around (text-effects, "Wrapping text around objects"): its outline
/// in its own space, placed into the block, kept `standoff` points clear of the text.
public struct TextExclusion: Hashable, Sendable {
    /// The object's outline (its painted shape), in its own space.
    public var contours: [Contour]
    /// The object's space to the block's local space.
    public var transform: AffineTransform
    /// Points; negative lets text run under the object's edge.
    public var standoff: Double

    public init(contours: [Contour], transform: AffineTransform = .identity, standoff: Double = 0) {
        self.contours = contours
        self.transform = transform
        self.standoff = standoff
    }
}

/// Horizontal (default) or vertical writing (text-effects).
public enum WritingDirection: Hashable, Sendable {
    /// Lines run left to right and stack downward.
    case horizontal
    /// Lines run top to bottom and stack right to left.
    case vertical
}

/// A text block's container settings (creating-text, `TextBlockProps`).
public struct TextBlock: Hashable, Sendable {
    /// Points; the value used while the width is fixed.
    public var width: Double
    public var height: Double
    /// Grows with the longest line (one column).
    public var autoWidth: Bool
    /// Grows with the line count (one row of cells).
    public var autoHeight: Bool
    public var inset: Inset
    public var columns: ColumnsRows
    public var direction: WritingDirection
    /// The space above each column's first line (columns-tables, *First line leading*); nil
    /// sets the first baseline at the line's ascent.
    public var firstLineLeading: Leading?
    /// Balance, modify leading and copyfit.
    public var adjust: AdjustColumns
    /// Block (local) space to pasteboard.
    public var transform: AffineTransform
    /// The block's fill and stroke (`block_appearance`, resolved).  Its strokes draw the
    /// column and row rules and the paragraph rules that have no stroke of their own; the
    /// fills and the border are drawn only with `displayBorder`.
    public var appearance: Appearance
    /// Draw the block's fill and outline.
    public var displayBorder: Bool
    /// Objects in front of the block that text wraps around (horizontal writing).
    public var exclusions: [TextExclusion]

    public init(
        width: Double = 200,
        height: Double = 100,
        autoWidth: Bool = false,
        autoHeight: Bool = false,
        inset: Inset = .zero,
        columns: ColumnsRows = ColumnsRows(),
        direction: WritingDirection = .horizontal,
        firstLineLeading: Leading? = nil,
        adjust: AdjustColumns = AdjustColumns(),
        transform: AffineTransform = .identity,
        appearance: Appearance = Appearance(),
        displayBorder: Bool = false,
        exclusions: [TextExclusion] = []
    ) {
        self.width = width
        self.height = height
        self.autoWidth = autoWidth
        self.autoHeight = autoHeight
        self.inset = inset
        self.columns = columns
        self.direction = direction
        self.firstLineLeading = firstLineLeading
        self.adjust = adjust
        self.transform = transform
        self.appearance = appearance
        self.displayBorder = displayBorder
        self.exclusions = exclusions
    }

    /// The block's strokes, bottom first, as a stack of their own (rules are drawn with them).
    var strokeAppearance: Appearance? {
        let strokes = appearance.strokes
        return strokes.isEmpty ? nil : Appearance(strokes.map { .stroke($0) })
    }
}

/// Text attached to or flowed inside a path (text-on-path, `TextOnPathProps`).
public struct PathText: Hashable, Sendable {
    public enum Mode: Hashable, Sendable {
        /// Along the path: one run on an open path, a top and a bottom run on a closed one.
        case along
        /// Inside a closed path, wrapping at its edges.
        case inside
    }

    public enum Orientation: Hashable, Sendable {
        /// Glyphs turn with the tangent.
        case rotate
        /// Glyphs stay upright; only their positions follow the path.
        case vertical
        /// Glyphs stay upright with horizontal baselines, their verticals leaning with the curve.
        case skewHorizontal
        /// Glyphs turn with the curve, their verticals staying vertical.
        case skewVertical
    }

    /// Which part of a run touches the path.
    public enum Alignment: Hashable, Sendable {
        /// Hidden.
        case none
        case baseline
        case ascent
        case descent
    }

    /// The path, in the container's local space.
    public var contour: Contour
    public var mode: Mode
    public var orientation: Orientation
    public var top: Alignment
    public var bottom: Alignment
    /// "Left": points from the path start.
    public var offsetStart: Double
    /// "Right": points from the path end.
    public var offsetEnd: Double
    /// Inside mode: kept clear of the path's edges.
    public var inset: Inset
    /// Inside mode: copyfit (columns-tables, "Balancing and fitting columns").
    public var adjust: AdjustColumns
    /// Local space to pasteboard.
    public var transform: AffineTransform

    public init(
        contour: Contour,
        mode: Mode = .along,
        orientation: Orientation = .rotate,
        top: Alignment = .baseline,
        bottom: Alignment = .baseline,
        offsetStart: Double = 0,
        offsetEnd: Double = 0,
        inset: Inset = .zero,
        adjust: AdjustColumns = AdjustColumns(),
        transform: AffineTransform = .identity
    ) {
        self.adjust = adjust
        self.contour = contour
        self.mode = mode
        self.orientation = orientation
        self.top = top
        self.bottom = bottom
        self.offsetStart = offsetStart
        self.offsetEnd = offsetEnd
        self.inset = inset
        self.transform = transform
    }
}

/// One container of a flow.
public enum TextContainer: Hashable, Sendable {
    case block(TextBlock)
    case path(PathText)

    /// Local space to pasteboard.
    public var transform: AffineTransform {
        switch self {
        case .block(let block): return block.transform
        case .path(let path): return path.transform
        }
    }

    /// Balance, modify leading and copyfit.
    var adjust: AdjustColumns {
        switch self {
        case .block(let block): return block.adjust
        case .path(let path): return path.adjust
        }
    }
}

/// A block's cells in its *logical* space: horizontal writing is the block itself; vertical
/// writing swaps the axes, so lines always run along logical x and stack along logical y (the
/// engine maps back: x' = width - y, y' = x).
struct BlockGeometry {
    let block: TextBlock
    /// Logical extent before auto sizing.
    let logicalWidth: Double
    let logicalHeight: Double
    let inset: Inset
    let columns: Int
    let rows: Int

    init(_ block: TextBlock) {
        var block = block
        if block.direction == .vertical {
            // Columns and rows are horizontal-only (text-effects, "Vertical text").
            block.columns = ColumnsRows()
        }
        self.block = block
        if block.direction == .vertical {
            logicalWidth = block.height
            logicalHeight = block.width
            inset = Inset(left: block.inset.top, right: block.inset.bottom, top: block.inset.right, bottom: block.inset.left)
        } else {
            logicalWidth = block.width
            logicalHeight = block.height
            inset = block.inset
        }
        let autoLines = block.direction == .vertical ? block.autoWidth : block.autoHeight
        let autoMeasure = block.direction == .vertical ? block.autoHeight : block.autoWidth
        columns = autoMeasure ? 1 : max(block.columns.columns, 1)
        rows = autoLines ? 1 : max(block.columns.rows, 1)
    }

    /// Whether lines have no length limit (auto width in horizontal writing).
    var autoMeasure: Bool { block.direction == .vertical ? block.autoHeight : block.autoWidth }
    /// Whether the line stack has no limit (auto height in horizontal writing).
    var autoLines: Bool { block.direction == .vertical ? block.autoWidth : block.autoHeight }

    /// A cell's width and height (logical space); `measure` replaces the width when the block
    /// is auto-measured.
    func cellSize(measure: Double? = nil) -> Size {
        let spec = block.columns
        let contentWidth = logicalWidth - inset.left - inset.right
        let contentHeight = logicalHeight - inset.top - inset.bottom
        let cellWidth = measure ?? (spec.rowWidth > 0 ? spec.rowWidth : max((contentWidth - Double(columns - 1) * spec.columnSpacing) / Double(columns), 1))
        let cellHeight = autoLines ? Double.greatestFiniteMagnitude / 4 : (spec.columnHeight > 0 ? spec.columnHeight : max((contentHeight - Double(rows - 1) * spec.rowSpacing) / Double(rows), 0))
        return Size(width: cellWidth, height: cellHeight)
    }

    /// The cells in flow order, logical space; `measure` replaces the cell width when the
    /// block is auto-measured.
    func cells(measure: Double? = nil) -> [Rect] {
        let spec = block.columns
        let size = cellSize(measure: measure)
        let cellWidth = size.width
        let cellHeight = size.height
        var result: [Rect] = []
        func cell(column: Int, row: Int) -> Rect {
            Rect(
                x: inset.left + Double(column) * (cellWidth + spec.columnSpacing),
                y: inset.top + Double(row) * (cellHeight + spec.rowSpacing),
                width: cellWidth, height: cellHeight
            )
        }
        switch spec.flow {
        case .down:
            for column in 0..<columns {
                for row in 0..<rows {
                    result.append(cell(column: column, row: row))
                }
            }
        case .across:
            for row in 0..<rows {
                for column in 0..<columns {
                    result.append(cell(column: column, row: row))
                }
            }
        }
        return result
    }
}
