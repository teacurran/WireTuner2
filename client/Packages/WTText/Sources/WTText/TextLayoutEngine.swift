// The layout engine (TXT-001): a flow through its containers in order -- text blocks with
// insets, columns and rows filled in flow order with U+000C as a cell break, fixed or auto
// sizes, vertical writing; paths along or inside -- with paragraph spacing (the larger of
// below and above, none at a column top), keep-lines-together and keep-with-next in the
// column-filling pass, and first-line leading.
//
// Incremental: paragraphs are cached by their typesetting key and lines by request, so an
// edit re-typesets only the paragraphs it changed; the rest of a relayout is re-placing
// cached lines.

import WTGeometry
import struct WTGeometry.AffineTransform
import WTRender
import struct WTRender.StrokeStyle

public final class TextLayoutEngine {
    private var cache: [ParagraphKey: TypesetParagraph] = [:]
    /// Paragraphs typeset so far (cache misses).
    public private(set) var paragraphsTypeset = 0

    public init() {}

    /// Lines broken so far across the cached paragraphs (memo misses).
    public var linesBroken: Int {
        cache.values.reduce(0) { $0 + $1.linesBroken }
    }

    /// Lays `content` out through `containers`, reusing every paragraph and line it can from
    /// earlier layouts.
    public func layout(_ content: TextContent, in containers: [TextContainer]) -> TextLayout {
        let paragraphs = content.splitParagraphs()
        let count = paragraphs.last.map { $0.start + $0.length } ?? 0
        var ids = content.charIDs
        if ids.count != count {
            ids = Array(ids.prefix(count))
            ids.append(contentsOf: (ids.count..<count).map(syntheticCharID))
        }
        var pass = LayoutPass(paragraphs: paragraphs, engine: self)
        var sizes: [Size] = []
        for (index, container) in containers.enumerated() {
            switch container {
            case .block(let block):
                sizes.append(pass.placeBlock(block, container: index))
            case .path(let path):
                sizes.append(pass.placePath(path, container: index))
            }
        }
        // Keep what this layout used; anything else was edited away.
        cache = pass.used
        return TextLayout(
            containers: containers,
            sizes: sizes,
            characterCount: count,
            laidOutEnd: pass.laidOutEnd,
            lines: pass.lines,
            paragraphs: paragraphs,
            charIDs: ids
        )
    }

    fileprivate func typeset(_ key: ParagraphKey) -> TypesetParagraph {
        if let cached = cache[key] {
            return cached
        }
        paragraphsTypeset += 1
        let typeset = TypesetParagraph(key: key)
        cache[key] = typeset
        return typeset
    }
}

/// Where the flow has reached.
struct FlowPosition {
    var paragraph = 0
    /// Scalar offset within the paragraph.
    var offset = 0
    /// Consecutive hyphenated lines just placed.
    var hyphens = 0
    /// The previous paragraph's space below, until a paragraph starts after it.
    var spaceBelow: Double?
}

/// One layout: the flow position and the lines placed so far.
struct LayoutPass {
    let paragraphs: [ParagraphSource]
    let engine: TextLayoutEngine
    var position = FlowPosition()
    var lines: [PlacedLine] = []
    var used: [ParagraphKey: TypesetParagraph] = [:]

    init(paragraphs: [ParagraphSource], engine: TextLayoutEngine) {
        self.paragraphs = paragraphs
        self.engine = engine
    }

    var isDone: Bool { position.paragraph >= paragraphs.count }

    /// The global offset the flow has reached.
    var laidOutEnd: Int {
        guard !isDone else {
            return paragraphs.last.map { $0.start + $0.length } ?? 0
        }
        return paragraphs[position.paragraph].start + position.offset
    }

    mutating func typeset(_ index: Int, vertical: Bool) -> TypesetParagraph {
        let key = paragraphs[index].key.with(vertical: vertical)
        if let typeset = used[key] {
            return typeset
        }
        let typeset = engine.typeset(key)
        used[key] = typeset
        return typeset
    }

    /// Moves past a finished paragraph.
    mutating func finishParagraph(spaceBelow: Double) {
        position = FlowPosition(paragraph: position.paragraph + 1, offset: 0, hyphens: 0, spaceBelow: spaceBelow)
    }

    // MARK: Blocks

    /// Fills `block`'s cells; returns its size after auto sizing.
    mutating func placeBlock(_ block: TextBlock, container: Int) -> Size {
        let geometry = BlockGeometry(block)
        let vertical = block.direction == .vertical
        let measure = geometry.autoMeasure ? longestLine(vertical: vertical) : nil
        let cells = geometry.cells(measure: measure)
        let firstLine = lines.count
        var extent = geometry.inset.top
        for (index, cell) in cells.enumerated() where !isDone {
            let bottom = fillCell(cell, index: index, container: container, vertical: vertical, firstLineLeading: block.firstLineLeading)
            extent = max(extent, bottom)
        }
        let spec = block.columns
        let columns = Double(geometry.columns)
        let rows = Double(geometry.rows)
        let logicalWidth: Double
        if let measure {
            logicalWidth = geometry.inset.left + measure + geometry.inset.right
        } else if spec.rowWidth > 0 {
            logicalWidth = geometry.inset.left + columns * spec.rowWidth + (columns - 1) * spec.columnSpacing + geometry.inset.right
        } else {
            logicalWidth = geometry.logicalWidth
        }
        let logicalHeight: Double
        if geometry.autoLines {
            logicalHeight = extent + geometry.inset.bottom
        } else if spec.columnHeight > 0 {
            logicalHeight = geometry.inset.top + rows * spec.columnHeight + (rows - 1) * spec.rowSpacing + geometry.inset.bottom
        } else {
            logicalHeight = geometry.logicalHeight
        }
        guard vertical else {
            return Size(width: logicalWidth, height: logicalHeight)
        }
        // Vertical: lines stack right to left from the block's right edge, which is only known
        // now for an auto-sized block.
        let frame = AffineTransform(a: 0, b: 1, c: -1, d: 0, tx: logicalHeight, ty: 0)
        for index in firstLine..<lines.count {
            let placed = lines[index]
            lines[index] = PlacedLine(
                container: placed.container, paragraph: placed.paragraph, start: placed.start, end: placed.end,
                paragraphStart: placed.paragraphStart, line: placed.line, origin: placed.origin, cell: placed.cell,
                frame: frame, vertical: true, path: nil
            )
        }
        return Size(width: logicalHeight, height: logicalWidth)
    }

    /// The widest line of the remaining text set without a width limit (auto width).
    mutating func longestLine(vertical: Bool) -> Double {
        var widest = 1.0
        var paragraph = position.paragraph
        var offset = position.offset
        while paragraph < paragraphs.count {
            let typeset = typeset(paragraph, vertical: vertical)
            var line = typeset.line(start: offset, columnWidth: unboundedWidth)
            widest = max(widest, line.left + line.width + typeset.style.rightIndent)
            while !line.endsParagraph {
                line = typeset.line(start: line.end, columnWidth: unboundedWidth)
                widest = max(widest, line.left + line.width + typeset.style.rightIndent)
            }
            paragraph += 1
            offset = 0
        }
        return widest
    }

    /// Places lines into `cell` (logical space) from the flow position; returns the lowest
    /// descent placed (the cell top when nothing fits).
    mutating func fillCell(_ cell: Rect, index cellIndex: Int, container: Int, vertical: Bool, firstLineLeading: Leading?) -> Double {
        var lastBaseline: Double?
        var bottom = cell.minY
        while !isDone {
            let paragraphIndex = position.paragraph
            let source = paragraphs[paragraphIndex]
            let typeset = typeset(paragraphIndex, vertical: vertical)
            let style = typeset.style
            let startsParagraph = position.offset == 0

            // The paragraph's remaining lines at this width, up to its end or a cell break.
            var candidates: [TypesetLine] = []
            var hyphensAfter: [Int] = []
            var start = position.offset
            var hyphens = position.hyphens
            while true {
                let line = typeset.line(start: start, columnWidth: cell.width, hyphensBefore: hyphens)
                hyphens = line.hyphenated ? hyphens + 1 : 0
                candidates.append(line)
                hyphensAfter.append(hyphens)
                if line.endsParagraph || line.cellBreak {
                    break
                }
                start = line.end
            }

            // Baselines while they fit.
            var baselines: [Double] = []
            var cursor = lastBaseline
            for (index, line) in candidates.enumerated() {
                let baseline: Double
                if let previous = cursor {
                    let gap = index == 0 && startsParagraph ? max(position.spaceBelow ?? 0, style.spaceAbove) : 0
                    baseline = previous + line.distance + gap
                } else {
                    // Space above is ignored at the top of a column.
                    baseline = cell.minY + (firstLineLeading?.distance(forSize: line.size) ?? line.ascent)
                }
                if baseline + line.descent > cell.maxY + 0.001 {
                    break
                }
                baselines.append(baseline)
                cursor = baseline
            }
            var count = baselines.count
            if lastBaseline != nil {
                count = keeping(count, of: candidates, baselines: baselines, style: style, startsParagraph: startsParagraph, cell: cell, vertical: vertical)
            }

            for index in 0..<count {
                let line = candidates[index]
                lines.append(PlacedLine(
                    container: container, paragraph: paragraphIndex,
                    start: source.start + line.start, end: source.start + line.end, paragraphStart: source.start,
                    line: line, origin: Point(x: cell.minX, y: baselines[index]), cell: cell,
                    frame: .identity, vertical: vertical, path: nil
                ))
            }
            if count > 0 {
                lastBaseline = baselines[count - 1]
                bottom = max(bottom, baselines[count - 1] + candidates[count - 1].descent)
                position.hyphens = hyphensAfter[count - 1]
            }
            if count < candidates.count {
                position.offset = candidates[count].start
                return bottom
            }
            let last = candidates[count - 1]
            if last.endsParagraph {
                finishParagraph(spaceBelow: style.spaceBelow)
            } else {
                position.offset = last.end
            }
            if last.cellBreak {
                return bottom
            }
        }
        return bottom
    }

    /// Applies keep-lines-together and keep-with-next to `count` fitting lines of a paragraph
    /// that does not start the cell (paragraphs, "Keeping lines and words together").
    mutating func keeping(_ count: Int, of candidates: [TypesetLine], baselines: [Double], style: ParagraphStyle, startsParagraph: Bool, cell: Rect, vertical: Bool) -> Int {
        let total = candidates.count
        let keep = style.keepLines
        var result = count
        func applyKeepLines() {
            guard keep > 0, result < total else {
                return
            }
            if total - result < keep {
                result = max(total - keep, 0)
            }
            if startsParagraph && result < keep {
                result = 0
            }
        }
        applyKeepLines()
        if result == total, style.keepWithNext, candidates[total - 1].endsParagraph, position.paragraph + 1 < paragraphs.count {
            let next = typeset(position.paragraph + 1, vertical: vertical)
            let first = next.line(start: 0, columnWidth: cell.width)
            let baseline = baselines[total - 1] + first.distance + max(style.spaceBelow, next.style.spaceAbove)
            if baseline + first.descent > cell.maxY + 0.001 {
                result = total - 1
                applyKeepLines()
            }
        }
        return result
    }
}
