// The layout engine (TXT-001, TYPE-028, TYPE-032, TYPE-033, TYPE-039): a flow through its
// containers in order -- text blocks with insets, columns and rows filled in flow order with
// U+000C as a cell break, fixed or auto sizes, vertical writing; paths along or inside -- with
// paragraph spacing (the larger of below and above, none at a column top), keep-lines-together
// and keep-with-next in the column-filling pass, first-line leading, balance (a second pass
// over line counts), modify leading (spreading the slack of cells at least the threshold full),
// copyfit (a bounded bisection over the size scale, at most `copyfitIterationLimit` layouts,
// the same operations in the same order on every Mac) and text wrap around exclusions.
//
// Incremental: paragraphs are cached by their typesetting key and lines by request, so an
// edit re-typesets only the paragraphs it changed; the rest of a relayout is re-placing
// cached lines.

import WTGeometry
import struct WTGeometry.AffineTransform
import WTRender
import struct WTRender.StrokeStyle

/// Copyfit lays the flow out at most this many times (columns-tables, "Client").
public let copyfitIterationLimit = 8

public final class TextLayoutEngine {
    private var cache: [ParagraphKey: TypesetParagraph] = [:]
    private var exclusionCache: [TextExclusion: ExclusionRegion] = [:]
    fileprivate var exclusionsUsed: [TextExclusion: ExclusionRegion] = [:]
    /// Paragraphs typeset so far (cache misses).
    public private(set) var paragraphsTypeset = 0
    /// Run fonts looked up by the paragraphs typeset so far, and how many the font cache held.
    public private(set) var fontLookups = 0
    public private(set) var fontHits = 0

    /// The fonts layout resolves against (TXT-002).
    public let fonts: FontManager
    /// The font epoch the cached paragraphs were typeset under.
    private var fontEpoch: FontManager.Epoch

    public init(fonts: FontManager = .shared) {
        self.fonts = fonts
        fontEpoch = fonts.epoch
    }

    /// Lines broken so far across the cached paragraphs (memo misses).
    public var linesBroken: Int {
        cache.values.reduce(0) { $0 + $1.linesBroken }
    }

    /// Lays `content` out through `containers`, reusing every paragraph and line it can from
    /// earlier layouts.  When the first container asks for copyfit, the size and leading are
    /// scaled within its range to the largest scale at which nothing overflows.
    public func layout(_ content: TextContent, in containers: [TextContainer]) -> TextLayout {
        // After fonts were activated or a substitution changed, the paragraphs whose faces now
        // resolve differently, or whose laid-out family was activated or deactivated, are
        // typeset again; the rest stay cached.
        let epoch = fonts.epoch
        if epoch != fontEpoch {
            cache = cache.filter { fonts.stillHolds($0.value.fontReport, since: fontEpoch) }
            fontEpoch = epoch
        }
        var used: [ParagraphKey: TypesetParagraph] = [:]
        exclusionsUsed = [:]
        defer {
            cache = used
            exclusionCache = exclusionsUsed
        }
        guard let range = containers.first?.adjust.copyfitRange else {
            return run(content, in: containers, used: &used)
        }
        var iterations = 0
        func attempt(_ scale: Double) -> TextLayout {
            iterations += 1
            return run(content.scaled(by: scale), in: containers, used: &used, scale: scale)
        }
        var result = attempt(range.upperBound)
        if result.overflows && range.lowerBound < range.upperBound {
            let smallest = attempt(range.lowerBound)
            result = smallest
            if !smallest.overflows {
                var low = range.lowerBound
                var high = range.upperBound
                while iterations < copyfitIterationLimit {
                    let middle = (low + high) / 2
                    let trial = attempt(middle)
                    if trial.overflows {
                        high = middle
                    } else {
                        low = middle
                        result = trial
                    }
                }
            }
        }
        result.copyfitIterations = iterations
        return result
    }

    private func run(_ content: TextContent, in containers: [TextContainer], used: inout [ParagraphKey: TypesetParagraph], scale: Double = 1) -> TextLayout {
        let paragraphs = content.splitParagraphs()
        let count = paragraphs.last.map { $0.start + $0.length } ?? 0
        var ids = content.charIDs
        if ids.count != count {
            ids = Array(ids.prefix(count))
            ids.append(contentsOf: (ids.count..<count).map(syntheticCharID))
        }
        // U+000C in a lone block of one cell behaves as U+2028 (columns-tables).
        let singleCell: Bool
        switch containers.first {
        case .block(let block) where containers.count == 1:
            let geometry = BlockGeometry(block)
            singleCell = geometry.columns * geometry.rows == 1
        case .path where containers.count == 1:
            singleCell = true
        default:
            singleCell = false
        }
        var pass = LayoutPass(paragraphs: paragraphs, engine: self, singleCell: singleCell)
        var sizes: [Size] = []
        for (index, container) in containers.enumerated() {
            switch container {
            case .block(let block):
                sizes.append(pass.placeBlock(block, container: index))
            case .path(let path):
                sizes.append(pass.placePath(path, container: index))
            }
        }
        used.merge(pass.used) { lhs, _ in lhs }
        var report = FontReport()
        for typeset in pass.used.values {
            report.merge(typeset.fontReport)
        }
        return TextLayout(
            containers: containers,
            sizes: sizes,
            characterCount: count,
            laidOutEnd: pass.laidOutEnd,
            lines: pass.lines,
            paragraphs: paragraphs,
            charIDs: ids,
            grids: pass.grids,
            fontReport: report,
            copyfitScale: scale
        )
    }

    fileprivate func typeset(_ key: ParagraphKey) -> TypesetParagraph {
        if let cached = cache[key] {
            return cached
        }
        paragraphsTypeset += 1
        let typeset = TypesetParagraph(key: key, resolver: fonts.resolver)
        fontLookups += typeset.fontLookups
        fontHits += typeset.fontHits
        cache[key] = typeset
        return typeset
    }

    /// The region `exclusion` keeps text out of, in block space.
    fileprivate func region(for exclusion: TextExclusion) -> ExclusionRegion {
        if let region = exclusionsUsed[exclusion] ?? exclusionCache[exclusion] {
            exclusionsUsed[exclusion] = region
            return region
        }
        let region = ExclusionRegion(exclusion)
        exclusionsUsed[exclusion] = region
        return region
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

/// A block's cell grid as laid out (horizontal writing), for its rules.
struct CellGrid: Sendable {
    let columns: Int
    let rows: Int
    let cell: Size
    let columnSpacing: Double
    let rowSpacing: Double
    let inset: Inset
    /// The block's size after auto sizing.
    let size: Size
}

/// One layout: the flow position and the lines placed so far.
struct LayoutPass {
    let paragraphs: [ParagraphSource]
    let engine: TextLayoutEngine
    /// U+000C does not end the (only) cell.
    let singleCell: Bool
    var position = FlowPosition()
    var lines: [PlacedLine] = []
    var used: [ParagraphKey: TypesetParagraph] = [:]
    var grids: [Int: CellGrid] = [:]

    init(paragraphs: [ParagraphSource], engine: TextLayoutEngine, singleCell: Bool = false) {
        self.paragraphs = paragraphs
        self.engine = engine
        self.singleCell = singleCell
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
        let exclusions = vertical ? [] : block.exclusions.map { engine.region(for: $0) }.filter { !$0.isEmpty }
        let start = position
        var extent = fillCells(cells, limits: nil, container: container, vertical: vertical, firstLineLeading: block.firstLineLeading, exclusions: exclusions, inset: geometry.inset.top)
        // Balance: the same lines spread evenly over the cells, the first cells taking one
        // more where they do not divide.
        if block.adjust.balance, cells.count > 1, !geometry.autoLines, exclusions.isEmpty, isDone {
            let total = lines.count - firstLine
            var bonus = 0
            while total > 0 && bonus <= total {
                position = start
                lines.removeSubrange(firstLine...)
                let limits = cells.indices.map { total / cells.count + ($0 < total % cells.count ? 1 : 0) + bonus }
                extent = fillCells(cells, limits: limits, container: container, vertical: vertical, firstLineLeading: block.firstLineLeading, exclusions: [], inset: geometry.inset.top)
                if isDone {
                    break
                }
                bonus += 1
            }
        }
        if block.adjust.modifyLeading, !geometry.autoLines {
            modifyLeading(from: firstLine, threshold: block.adjust.thresholdPercent)
        }
        let spec = geometry.block.columns
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
            let size = Size(width: logicalWidth, height: logicalHeight)
            var cell = geometry.cellSize(measure: measure)
            if geometry.autoLines {
                cell.height = logicalHeight - geometry.inset.top - geometry.inset.bottom
            }
            grids[container] = CellGrid(columns: geometry.columns, rows: geometry.rows, cell: cell, columnSpacing: spec.columnSpacing, rowSpacing: spec.rowSpacing, inset: geometry.inset, size: size)
            return size
        }
        // Vertical: lines stack right to left from the block's right edge, which is only known
        // now for an auto-sized block.
        let frame = AffineTransform(a: 0, b: 1, c: -1, d: 0, tx: logicalHeight, ty: 0)
        for index in firstLine..<lines.count {
            lines[index] = lines[index].with(frame: frame, vertical: true)
        }
        return Size(width: logicalHeight, height: logicalWidth)
    }

    /// Fills `cells` in order, at most `limits[i]` lines in cell i; returns the lowest line
    /// bottom placed (the top inset when nothing fits).
    mutating func fillCells(_ cells: [Rect], limits: [Int]?, container: Int, vertical: Bool, firstLineLeading: Leading?, exclusions: [ExclusionRegion], inset: Double) -> Double {
        var extent = inset
        for (index, cell) in cells.enumerated() where !isDone {
            let bottom: Double
            if exclusions.contains(where: { $0.bounds.intersects(cell) }) {
                bottom = fillWrapped(cell, container: container, firstLineLeading: firstLineLeading, exclusions: exclusions)
            } else {
                bottom = fillCell(cell, container: container, vertical: vertical, firstLineLeading: firstLineLeading, maxLines: limits?[index])
            }
            extent = max(extent, bottom)
        }
        return extent
    }

    /// Modify leading: in every cell at least `threshold` percent full, the slack below the
    /// last line is spread evenly between the lines.
    mutating func modifyLeading(from firstLine: Int, threshold: Double) {
        var index = firstLine
        while index < lines.count {
            let cell = lines[index].cell
            var end = index
            while end < lines.count && lines[end].cell == cell {
                end += 1
            }
            let last = lines[end - 1]
            let used = last.origin.y + last.line.extraDepth + last.line.descent - cell.minY
            let count = end - index
            if count > 1, cell.height > 0, used < cell.height, used >= cell.height * threshold / 100 {
                let extra = (cell.height - used) / Double(count - 1)
                for (step, line) in (index..<end).enumerated() {
                    let placed = lines[line]
                    lines[line] = placed.with(origin: Point(x: placed.origin.x, y: placed.origin.y + Double(step) * extra))
                }
            }
            index = end
        }
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

    /// Places lines into `cell` (logical space) from the flow position, at most `maxLines`;
    /// returns the lowest line bottom placed (the cell top when nothing fits).
    mutating func fillCell(_ cell: Rect, container: Int, vertical: Bool, firstLineLeading: Leading?, maxLines: Int? = nil) -> Double {
        var lastBaseline: Double?
        var bottom = cell.minY
        var remaining = maxLines ?? Int.max
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
                if line.endsParagraph || (line.cellBreak && !singleCell) {
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
                if baseline + line.extraDepth + line.descent > cell.maxY + 0.001 {
                    break
                }
                baselines.append(baseline)
                cursor = baseline + line.extraDepth
            }
            var count = baselines.count
            if lastBaseline != nil {
                count = keeping(count, of: candidates, baselines: baselines, style: style, startsParagraph: startsParagraph, cell: cell, vertical: vertical)
            }
            count = min(count, remaining)
            remaining -= count

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
                let last = candidates[count - 1]
                lastBaseline = baselines[count - 1] + last.extraDepth
                bottom = max(bottom, baselines[count - 1] + last.extraDepth + last.descent)
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
            if last.cellBreak && !singleCell {
                return bottom
            }
        }
        return bottom
    }

    /// Applies keep-lines-together and keep-with-next to `count` fitting lines of a paragraph
    /// that does not start the cell (paragraphs, "Keeping lines and words together"): with
    /// keep with next, the next paragraph's first lines -- as many as its own keep asks for --
    /// must fit after this one's last.
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
            var cursor = baselines[total - 1] + candidates[total - 1].extraDepth
            var start = 0
            for index in 0..<max(next.style.keepLines, 1) {
                let line = next.line(start: start, columnWidth: cell.width)
                let baseline = cursor + line.distance + (index == 0 ? max(style.spaceBelow, next.style.spaceAbove) : 0)
                if baseline + line.extraDepth + line.descent > cell.maxY + 0.001 {
                    result = total - 1
                    applyKeepLines()
                    break
                }
                cursor = baseline + line.extraDepth
                if line.endsParagraph || line.cellBreak {
                    break
                }
                start = line.end
            }
        }
        return result
    }

    // MARK: Text wrap

    /// Places lines into `cell` around `exclusions` (text-effects, "Wrapping text around
    /// objects"): each band a line's ascent and descent tall is split into the spans the
    /// exclusions leave free, filled left to right; a band with no span wide enough for the
    /// next word is passed over a point at a time.  Keeps and balance do not apply here.
    mutating func fillWrapped(_ cell: Rect, container: Int, firstLineLeading: Leading?, exclusions: [ExclusionRegion]) -> Double {
        var lastBaseline: Double?
        var bottom = cell.minY
        while !isDone {
            let paragraphIndex = position.paragraph
            let source = paragraphs[paragraphIndex]
            let typeset = typeset(paragraphIndex, vertical: false)
            let style = typeset.style
            let probe = typeset.line(start: position.offset, columnWidth: cell.width, hyphensBefore: position.hyphens)
            var baseline: Double
            if let previous = lastBaseline {
                baseline = previous + probe.distance + (position.offset == 0 ? max(position.spaceBelow ?? 0, style.spaceAbove) : 0)
            } else {
                baseline = cell.minY + (firstLineLeading?.distance(forSize: probe.size) ?? probe.ascent)
            }
            // The first band down whose spans take at least one line.
            var placedAny = false
            while !placedAny {
                guard baseline + probe.descent <= cell.maxY + 0.001 else {
                    return bottom
                }
                let spans = ExclusionRegion.freeSpans(in: cell.minX...cell.maxX, top: baseline - probe.ascent, bottom: baseline + probe.descent, exclusions: exclusions, minimum: max(probe.size * 2, 1))
                var depth = 0.0
                for span in spans where !isDone && position.paragraph == paragraphIndex {
                    let width = span.upperBound - span.lowerBound
                    let line = typeset.line(start: position.offset, columnWidth: width, hyphensBefore: position.hyphens)
                    if line.emergency && width < cell.width - 0.001 {
                        continue  // not even a word fits this span
                    }
                    guard baseline + line.extraDepth + line.descent <= cell.maxY + 0.001 else {
                        break
                    }
                    lines.append(PlacedLine(
                        container: container, paragraph: paragraphIndex,
                        start: source.start + line.start, end: source.start + line.end, paragraphStart: source.start,
                        line: line, origin: Point(x: span.lowerBound, y: baseline),
                        cell: Rect(x: span.lowerBound, y: cell.minY, width: width, height: cell.height),
                        frame: .identity, vertical: false, path: nil
                    ))
                    placedAny = true
                    depth = max(depth, line.extraDepth)
                    bottom = max(bottom, baseline + line.extraDepth + line.descent)
                    position.hyphens = line.hyphenated ? position.hyphens + 1 : 0
                    if line.endsParagraph {
                        finishParagraph(spaceBelow: style.spaceBelow)
                    } else {
                        position.offset = line.end
                    }
                    if line.cellBreak && !singleCell {
                        return bottom
                    }
                }
                if placedAny {
                    lastBaseline = baseline + depth
                } else {
                    baseline += 1
                }
            }
        }
        return bottom
    }
}

/// The region an exclusion keeps text out of: the object's outline grown by the standoff
/// (GEO-003's `Offset.inset` with a negative distance, round joins), flattened to polygons in
/// block space.  A similarity transform offsets in the object's own space, so moving the object
/// re-uses the offset outline.  The offset is `Offset.checkedInset`: where GEO-003 cannot compute
/// it, the region is the object's outline without the standoff, so text still keeps out of the
/// object rather than running over it.
struct ExclusionRegion: @unchecked Sendable {
    /// The outset `(outline, distance, join)`; replaced in tests.
    typealias Inset = (FilledPath, Double, WTGeometry.LineJoin) throws -> FilledPath

    let polygons: [[Point]]
    let bounds: Rect

    var isEmpty: Bool { polygons.isEmpty }

    init(_ exclusion: TextExclusion, inset: Inset = { try Offset.checkedInset($0, by: $1, join: $2) }) {
        let transform = exclusion.transform
        let path = FilledPath(contours: exclusion.contours, fillRule: .nonZero)
        let similarity = abs(transform.a - transform.d) < 1e-9 && abs(transform.b + transform.c) < 1e-9
            || abs(transform.a + transform.d) < 1e-9 && abs(transform.b - transform.c) < 1e-9
        let scale = abs(transform.determinant).squareRoot()
        let local = similarity && scale > 0
        let outline = local ? path : path.applying(transform)
        var region: FilledPath
        do {
            region = try inset(outline, -exclusion.standoff / (local ? scale : 1), .round)
        } catch {
            region = outline
        }
        if local {
            region = region.applying(transform)
        }
        polygons = region.contours.map(flattenContour).filter { $0.count >= 3 }
        var bounds = Rect.null
        for point in polygons.joined() {
            bounds = bounds.union(Rect(x: point.x, y: point.y, width: 0, height: 0))
        }
        self.bounds = bounds
    }

    /// The x intervals the region covers across the band `top...bottom`: its inside (non-zero)
    /// at the band's top, middle and bottom, and every edge's reach within the band.
    func blocked(top: Double, bottom: Double) -> [ClosedRange<Double>] {
        guard bounds.maxY >= top && bounds.minY <= bottom else {
            return []
        }
        var result: [ClosedRange<Double>] = []
        for y in [top, (top + bottom) / 2, bottom] {
            result.append(contentsOf: insideIntervals(at: y))
        }
        for polygon in polygons {
            for index in polygon.indices {
                let a = polygon[index]
                let b = polygon[(index + 1) % polygon.count]
                let low = max(min(a.y, b.y), top)
                let high = min(max(a.y, b.y), bottom)
                guard low <= high else {
                    continue
                }
                let dy = b.y - a.y
                let x0 = dy == 0 ? a.x : a.x + (low - a.y) / dy * (b.x - a.x)
                let x1 = dy == 0 ? b.x : a.x + (high - a.y) / dy * (b.x - a.x)
                result.append(min(x0, x1)...max(x0, x1))
            }
        }
        return result
    }

    /// The non-zero inside of the region along the line `y`.
    private func insideIntervals(at y: Double) -> [ClosedRange<Double>] {
        var crossings: [(x: Double, winding: Int)] = []
        for polygon in polygons {
            for index in polygon.indices {
                let a = polygon[index]
                let b = polygon[(index + 1) % polygon.count]
                if (a.y <= y) != (b.y <= y) {
                    crossings.append((a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x), a.y <= y ? 1 : -1))
                }
            }
        }
        crossings.sort { $0.x < $1.x }
        var result: [ClosedRange<Double>] = []
        var winding = 0
        var start = 0.0
        for crossing in crossings {
            let before = winding
            winding += crossing.winding
            if before == 0 && winding != 0 {
                start = crossing.x
            } else if before != 0 && winding == 0 {
                result.append(start...crossing.x)
            }
        }
        return result
    }

    /// The spans of `range` the exclusions leave free across the band, left to right, each at
    /// least `minimum` wide.
    static func freeSpans(in range: ClosedRange<Double>, top: Double, bottom: Double, exclusions: [ExclusionRegion], minimum: Double) -> [ClosedRange<Double>] {
        let blocked = exclusions.flatMap { $0.blocked(top: top, bottom: bottom) }.sorted { $0.lowerBound < $1.lowerBound }
        var spans: [ClosedRange<Double>] = []
        var cursor = range.lowerBound
        for interval in blocked {
            if interval.lowerBound > cursor {
                spans.append(cursor...min(interval.lowerBound, range.upperBound))
            }
            cursor = max(cursor, interval.upperBound)
            if cursor >= range.upperBound {
                break
            }
        }
        if cursor < range.upperBound {
            spans.append(cursor...range.upperBound)
        }
        return spans.filter { $0.upperBound - $0.lowerBound >= minimum }
    }
}

/// A contour as a closed polygon (curves at 24 steps).
func flattenContour(_ contour: Contour) -> [Point] {
    var points: [Point] = []
    var segments = contour.segments
    if let closing = contour.closingSegment {
        segments.append(closing)
    }
    for segment in segments {
        let steps = segment.isLinear() ? 1 : 24
        for step in 0..<steps {
            points.append(segment.evaluate(Double(step) / Double(steps)))
        }
    }
    return points
}
