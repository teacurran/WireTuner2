// A laid-out flow (TXT-001): placed lines in their containers, character offsets and ids to
// caret positions and back (creating-text, "Layout": every glyph run keeps the character ids
// it came from, so a caret is an anchor and hit testing returns an anchor), and the display
// list items the renderers draw.

import WTGeometry
import struct WTGeometry.AffineTransform
import WTRender
import struct WTRender.StrokeStyle
import CoreGraphics
import Foundation

/// A caret: a boundary between characters drawn as a segment in its container's local space.
public struct Caret: Hashable, Sendable {
    public let container: Int
    /// Global scalar offset of the boundary.
    public let offset: Int
    /// Where the caret meets the baseline.
    public let baseline: Point
    /// The caret's ends: the line's ascent above the baseline and its descent below.
    public let top: Point
    public let bottom: Point
}

/// One glyph as laid out, for tests and hit regions.
public struct LaidOutGlyph: Hashable, Sendable {
    public let container: Int
    public let glyph: CGGlyph
    /// Glyph space (points, y down, origin on the baseline) to the container's local space.
    public let transform: AffineTransform
    /// Global scalar offset of the character it came from.
    public let offset: Int
    /// The glyph's advance along its line (points).
    public let advance: Double

    /// The glyph origin in local space.
    public var origin: Point { transform.apply(.zero) }
}

/// Where a path line's glyphs and carets sit.
struct PathPlacement: Sendable {
    struct Glyph: Sendable {
        let run: Int
        let index: Int
        let transform: AffineTransform
    }

    struct CaretFrame: Sendable {
        let base: Point
        /// Unit vector from the baseline toward the glyph tops.
        let up: Vector
    }

    let glyphs: [Glyph]
    /// One per boundary `start...end` of the placed line.
    let carets: [CaretFrame]
}

/// One line in its container.
struct PlacedLine: Sendable {
    let container: Int
    let paragraph: Int
    /// Global scalar offsets of the line's characters.
    let start: Int
    let end: Int
    /// Global offset of the paragraph's first character.
    let paragraphStart: Int
    let line: TypesetLine
    /// Straight lines: the column's left edge and the baseline, logical space.
    let origin: Point
    /// The cell the line is in, logical space (rules measure against it).
    let cell: Rect
    /// Logical space to the container's local space (vertical writing rotates).
    let frame: AffineTransform
    let vertical: Bool
    /// Set for text on a path.
    let path: PathPlacement?

    /// Caret x (logical) at global boundary `offset`.
    func caretX(_ offset: Int) -> Double {
        origin.x + line.caret(at: offset - paragraphStart)
    }

    /// The baseline (logical y) of the sub-line holding global boundary `offset`.
    func caretBaseline(_ offset: Int) -> Double {
        origin.y + line.caretDepth(at: offset - paragraphStart)
    }

    /// The line moved to `origin` (modify leading).
    func with(origin: Point) -> PlacedLine {
        PlacedLine(container: container, paragraph: paragraph, start: start, end: end, paragraphStart: paragraphStart, line: line, origin: origin, cell: cell, frame: frame, vertical: vertical, path: path)
    }

    /// The line framed by `frame` (vertical writing).
    func with(frame: AffineTransform, vertical: Bool) -> PlacedLine {
        PlacedLine(container: container, paragraph: paragraph, start: start, end: end, paragraphStart: paragraphStart, line: line, origin: origin, cell: cell, frame: frame, vertical: vertical, path: path)
    }
}

/// A selection's shape on one line, in its container's local space: a rectangle from caret to
/// caret across the line's ascent and descent (turned for vertical text), or one glyph's box on
/// a path.
public struct SelectionQuad: Hashable, Sendable {
    public let container: Int
    /// Four corners in order.
    public let corners: [Point]
}

/// Where an inline graphic is drawn.
public struct InlineGraphicPlacement: Hashable, Sendable {
    public let container: Int
    /// Global scalar offset of its U+FFFC.
    public let offset: Int
    /// The graphic's own space to the container's local space.
    public let transform: AffineTransform
}

/// Offsets by character id, built on first use.
final class CharIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var index: [CharID: Int]?
    let ids: [CharID]

    init(ids: [CharID]) {
        self.ids = ids
    }

    func offset(of id: CharID) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if index == nil {
            var built: [CharID: Int] = [:]
            built.reserveCapacity(ids.count)
            for (offset, id) in ids.enumerated() where built[id] == nil {
                built[id] = offset
            }
            index = built
        }
        return index?[id]
    }
}

public struct TextLayout: Sendable {
    /// The containers laid out, in flow order.
    public let containers: [TextContainer]
    /// Each container's local size after auto sizing (a path's: its bounds).
    public let sizes: [Size]
    /// Scalars in the flow.
    public let characterCount: Int
    /// Global offset where layout stopped: everything before it is placed (or hidden on a path).
    public let laidOutEnd: Int
    /// What the fonts could not honour (the Missing Fonts sheet).
    public let fontReport: FontReport
    /// The size scale copyfit settled on (1 without copyfit), and how many layouts it took.
    public let copyfitScale: Double
    public internal(set) var copyfitIterations = 0
    let lines: [PlacedLine]
    let paragraphs: [ParagraphSource]
    let grids: [Int: CellGrid]
    private let charIndex: CharIndex

    init(containers: [TextContainer], sizes: [Size], characterCount: Int, laidOutEnd: Int, lines: [PlacedLine], paragraphs: [ParagraphSource], charIDs: [CharID], grids: [Int: CellGrid] = [:], fontReport: FontReport = FontReport(), copyfitScale: Double = 1) {
        self.containers = containers
        self.sizes = sizes
        self.characterCount = characterCount
        self.laidOutEnd = laidOutEnd
        self.lines = lines
        self.paragraphs = paragraphs
        self.grids = grids
        self.fontReport = fontReport
        self.copyfitScale = copyfitScale
        charIndex = CharIndex(ids: charIDs)
    }

    /// Whether characters remain after the last container (the overflow dot).
    public var overflows: Bool { laidOutEnd < characterCount }

    /// Lines placed, in flow order.
    public var lineCount: Int { lines.count }

    /// How many lines each container holds.
    public func lineCount(inContainer container: Int) -> Int {
        lines.reduce(0) { $0 + ($1.container == container ? 1 : 0) }
    }

    /// The global offset range of each placed line (for tests and selection painting).
    public var lineRanges: [Range<Int>] { lines.map { $0.start..<$0.end } }

    /// Each placed line's baseline origin in its container's local space.
    public var lineOrigins: [Point] {
        lines.map { line in
            line.path.map { $0.carets.first?.base ?? .zero } ?? line.frame.apply(Point(x: line.origin.x + line.line.left, y: line.origin.y))
        }
    }

    // MARK: Ids

    /// The id of the character at `offset`.
    public func charID(at offset: Int) -> CharID? {
        charIndex.ids.indices.contains(offset) ? charIndex.ids[offset] : nil
    }

    /// The offset of the character `id`, if the flow holds it.
    public func offset(of id: CharID) -> Int? {
        charIndex.offset(of: id)
    }

    // MARK: Carets

    /// The caret at `anchor`: before a character on its line, after one at its trailing edge
    /// (the end of a wrapped line rather than the start of the next); after a newline, the
    /// start of the next paragraph.  Nil for a character the flow does not hold or that was
    /// not laid out.
    public func caret(for anchor: CharAnchor) -> Caret? {
        guard let offset = offset(of: anchor.char) else {
            return nil
        }
        if anchor.before {
            return caret(atOffset: offset)
        }
        let newline = paragraphs.contains { $0.terminated && $0.start + $0.length == offset }
        return caret(atOffset: offset + 1, upstream: !newline)
    }

    /// The caret at boundary `offset`.  At a soft line break the boundary ends one line and
    /// starts the next: `upstream` picks the end of the earlier one.
    public func caret(atOffset offset: Int, upstream: Bool = false) -> Caret? {
        guard let line = line(containing: offset, upstream: upstream) else {
            return nil
        }
        return caret(on: line, at: offset)
    }

    func line(containing offset: Int, upstream: Bool) -> PlacedLine? {
        // The last line starting at or before the offset.
        var low = 0
        var high = lines.count - 1
        var found = -1
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= offset {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard found >= 0 else {
            return nil
        }
        if upstream, found > 0, lines[found].start == offset, lines[found - 1].end == offset,
           lines[found - 1].paragraph == lines[found].paragraph {
            return lines[found - 1]
        }
        let line = lines[found]
        return offset <= line.end ? line : nil
    }

    private func caret(on placed: PlacedLine, at offset: Int) -> Caret {
        if let path = placed.path {
            let frame = path.carets[min(max(offset - placed.start, 0), path.carets.count - 1)]
            let top = frame.base + frame.up * placed.line.ascent
            let bottom = frame.base - frame.up * placed.line.descent
            return Caret(container: placed.container, offset: offset, baseline: frame.base, top: top, bottom: bottom)
        }
        let x = placed.caretX(offset)
        let y = placed.caretBaseline(offset)
        return Caret(
            container: placed.container,
            offset: offset,
            baseline: placed.frame.apply(Point(x: x, y: y)),
            top: placed.frame.apply(Point(x: x, y: y - placed.line.ascent)),
            bottom: placed.frame.apply(Point(x: x, y: y + placed.line.descent))
        )
    }

    // MARK: Hit testing

    /// The boundary nearest `point` (container local space): on the nearest line of the
    /// container, the nearest caret position.
    public func offset(at point: Point, inContainer container: Int) -> Int? {
        var best: (line: PlacedLine, distance: Double, along: Double)?
        for placed in lines where placed.container == container {
            let (distance, along) = distance(from: point, to: placed)
            if best == nil || distance < best!.distance || (distance == best!.distance && along < best!.along) {
                best = (placed, distance, along)
            }
        }
        guard let placed = best?.line else {
            return nil
        }
        if let path = placed.path {
            let nearest = path.carets.indices.min { path.carets[$0].base.distance(to: point) < path.carets[$1].base.distance(to: point) }!
            return placed.start + nearest
        }
        let logical = placed.frame.invertedOrIdentity.apply(point)
        var nearest = placed.start
        var nearestDistance = (across: Double.infinity, along: Double.infinity)
        for offset in placed.start...placed.end {
            // A row's sub-lines: the nearest sub-line first, then the nearest caret on it.
            let baseline = placed.caretBaseline(offset)
            let top = baseline - placed.line.ascent
            let bottom = baseline + placed.line.descent
            let across = logical.y < top ? top - logical.y : (logical.y > bottom ? logical.y - bottom : 0)
            let distance = (across: across, along: abs(placed.caretX(offset) - logical.x))
            if distance.across < nearestDistance.across || (distance.across == nearestDistance.across && distance.along < nearestDistance.along) {
                nearest = offset
                nearestDistance = distance
            }
        }
        // A wrapped line's trailing space: the caret goes before it, not onto the next line.
        if nearest == placed.end, !placed.line.endsParagraph, placed.end > placed.start {
            nearest = placed.end - 1
        }
        return nearest
    }

    /// The anchor nearest `point`: before the character at the boundary, or after the last
    /// character at the end of the flow.  Nil for an empty flow or container.
    public func anchor(at point: Point, inContainer container: Int) -> CharAnchor? {
        guard let offset = offset(at: point, inContainer: container) else {
            return nil
        }
        if let id = charID(at: offset) {
            return .before(id)
        }
        return charID(at: offset - 1).map { .after($0) }
    }

    /// Distance across and along a line from `point`.
    private func distance(from point: Point, to placed: PlacedLine) -> (Double, Double) {
        if let path = placed.path {
            let nearest = path.carets.map { $0.base.distance(to: point) }.min() ?? .infinity
            return (nearest, 0)
        }
        let logical = placed.frame.invertedOrIdentity.apply(point)
        let top = placed.origin.y - placed.line.ascent
        let bottom = placed.origin.y + placed.line.extraDepth + placed.line.descent
        let across = logical.y < top ? top - logical.y : (logical.y > bottom ? logical.y - bottom : 0)
        let left = placed.origin.x + placed.line.left
        let right = left + placed.line.width
        let along = logical.x < left ? left - logical.x : (logical.x > right ? logical.x - right : 0)
        return (across, along)
    }

    // MARK: Glyphs

    /// Every glyph laid out in `container` (all containers when nil), in flow order.
    public func glyphs(inContainer container: Int? = nil) -> [LaidOutGlyph] {
        var result: [LaidOutGlyph] = []
        for placed in lines where container == nil || placed.container == container {
            forEachGlyph(of: placed) { run, index, transform in
                let glyphRun = placed.line.runs[run]
                result.append(LaidOutGlyph(container: placed.container, glyph: glyphRun.glyphs[index], transform: transform, offset: placed.paragraphStart + glyphRun.charIndices[index], advance: glyphRun.advances[index]))
            }
        }
        return result
    }

    /// Calls `body` with each glyph's run, index and glyph-to-local transform.
    func forEachGlyph(of placed: PlacedLine, _ body: (Int, Int, AffineTransform) -> Void) {
        if let path = placed.path {
            for glyph in path.glyphs {
                body(glyph.run, glyph.index, glyph.transform)
            }
            return
        }
        for (runIndex, run) in placed.line.runs.enumerated() {
            for index in run.glyphs.indices {
                body(runIndex, index, glyphTransform(placed, run: run, index: index))
            }
        }
    }

    private func glyphTransform(_ placed: PlacedLine, run: LineGlyphRun, index: Int) -> AffineTransform {
        let x = placed.origin.x + run.xs[index]
        let y = placed.origin.y + run.yOffset
        guard placed.vertical else {
            return .translation(x: x, y: y)
        }
        guard run.upright else {
            return AffineTransform.translation(x: x, y: y).concatenating(placed.frame)
        }
        // Upright in a vertical line: centred on the line's axis, the em box filling the
        // advance along it.
        let advance = run.advances[index]
        let center = placed.origin.y + (placed.line.descent - placed.line.ascent) / 2
        let axis = placed.frame.apply(Point(x: x + advance / 2, y: center))
        let width = run.advances[index]
        return .translation(x: axis.x - width / 2, y: axis.y + (run.ascent - run.descent) / 2 + run.yOffset)
    }

    // MARK: Selection

    /// The selection between global boundaries `start` and `end` (either order), one quad per
    /// line it touches (per sub-line of a row, per glyph on a path).
    public func selection(from start: Int, to end: Int) -> [SelectionQuad] {
        let low = min(start, end)
        let high = max(start, end)
        var result: [SelectionQuad] = []
        for placed in lines where placed.end > low && placed.start < high {
            let a = max(low, placed.start)
            let b = min(high, placed.end)
            if let path = placed.path {
                for glyph in path.glyphs {
                    let run = placed.line.runs[glyph.run]
                    let char = placed.paragraphStart + run.charIndices[glyph.index]
                    if char >= a && char < b {
                        result.append(SelectionQuad(container: placed.container, corners: glyphBox(glyph.transform, advance: run.advances[glyph.index], line: placed.line)))
                    }
                }
                continue
            }
            // Boundaries grouped by sub-line (one group for an ordinary line).
            var levels: [Double: (low: Double, high: Double)] = [:]
            for offset in a...b {
                let y = placed.caretBaseline(offset)
                let x = placed.caretX(offset)
                let level = levels[y] ?? (x, x)
                levels[y] = (min(level.low, x), max(level.high, x))
            }
            for (baseline, span) in levels.sorted(by: { $0.key < $1.key }) where span.high > span.low {
                let top = baseline - placed.line.ascent
                let bottom = baseline + placed.line.descent
                let corners = [Point(x: span.low, y: top), Point(x: span.high, y: top), Point(x: span.high, y: bottom), Point(x: span.low, y: bottom)]
                result.append(SelectionQuad(container: placed.container, corners: corners.map(placed.frame.apply)))
            }
        }
        return result
    }

    /// The selection between two anchors (remote selections), nil when either is not laid out.
    public func selection(from start: CharAnchor, to end: CharAnchor) -> [SelectionQuad]? {
        func boundary(_ anchor: CharAnchor) -> Int? {
            offset(of: anchor.char).map { anchor.before ? $0 : $0 + 1 }
        }
        guard let a = boundary(start), let b = boundary(end) else {
            return nil
        }
        return selection(from: a, to: b)
    }

    /// A glyph's advance box (ascent to descent) in local space.
    func glyphBox(_ transform: AffineTransform, advance: Double, line: TypesetLine) -> [Point] {
        [
            Point(x: 0, y: -line.ascent), Point(x: advance, y: -line.ascent),
            Point(x: advance, y: line.descent), Point(x: 0, y: line.descent),
        ].map(transform.apply)
    }

    // MARK: Inline graphics

    /// Every inline graphic laid out in `container` (all containers when nil), in flow order.
    public func inlineGraphics(inContainer container: Int? = nil) -> [InlineGraphicPlacement] {
        var result: [InlineGraphicPlacement] = []
        for placed in lines where placed.path == nil && (container == nil || placed.container == container) {
            for inline in placed.line.inlines {
                result.append(InlineGraphicPlacement(container: placed.container, offset: placed.paragraphStart + inline.char, transform: inlineTransform(inline, on: placed)))
            }
        }
        return result
    }

    /// An inline graphic's own space to local space: its bounds' bottom-left corner on the
    /// (shifted) baseline at its advance's start.
    func inlineTransform(_ inline: LineInline, on placed: PlacedLine) -> AffineTransform {
        let bounds = inline.graphic.items == nil ? Rect(x: 0, y: 0, width: inline.size, height: inline.size) : inline.graphic.bounds
        let x = placed.origin.x + inline.x - bounds.minX
        let y = placed.origin.y + inline.yOffset - bounds.maxY
        return AffineTransform.translation(x: x, y: y).concatenating(placed.frame)
    }

    // MARK: Display list

    /// The display items drawing `container`, each with the container's transform (local →
    /// pasteboard) followed by `transform`, back to front: the block's fill (with *Display
    /// border*), the text effects drawn behind the glyphs, the glyph runs and inline graphics,
    /// the glyph strokes and synthesized emboldening, the effects drawn over the glyphs, the
    /// paragraph rules, the column and row rules and the block's border.  Effects and glyph
    /// decorations sit in groups Keyline never draws; `showsEffects` false leaves the effects
    /// out altogether (the *Display text effects* preference).
    public func displayItems(forContainer container: Int, transform: AffineTransform = .identity, showsEffects: Bool = true) -> [DisplayItem] {
        guard containers.indices.contains(container) else {
            return []
        }
        let toPasteboard = containers[container].transform.concatenating(transform)
        var layers = TextDrawing()
        for placed in lines where placed.container == container {
            var positioned = [[PositionedGlyph]](repeating: [], count: placed.line.runs.count)
            var indices = [[Int]](repeating: [], count: placed.line.runs.count)
            forEachGlyph(of: placed) { run, index, glyphTransform in
                let glyph = placed.line.runs[run].glyphs[index]
                indices[run].append(index)
                if glyphTransform.a == 1 && glyphTransform.b == 0 && glyphTransform.c == 0 && glyphTransform.d == 1 {
                    positioned[run].append(PositionedGlyph(glyph: glyph, position: Point(x: glyphTransform.tx, y: glyphTransform.ty)))
                } else {
                    positioned[run].append(PositionedGlyph(glyph: glyph, position: glyphTransform.apply(.zero), transform: glyphTransform))
                }
            }
            let origin = lineOrigin(placed)
            for (index, run) in placed.line.runs.enumerated() where !positioned[index].isEmpty {
                let glyphRun = GlyphRun(font: run.font, glyphs: positioned[index])
                layers.glyphs.append(.text(TextRunItem(text: run.text, glyphRun: glyphRun, origin: origin, color: run.color, transform: toPasteboard, overprint: run.attributes.overprint)))
                if TextDrawing.needsOutline(run, showsEffects: showsEffects) {
                    let outline = glyphRun.outline
                    layers.addDecorations(run: run, glyphRun: glyphRun, outline: outline, transform: toPasteboard)
                    if showsEffects {
                        layers.addGlyphEffect(run: run, glyphRun: glyphRun, outline: outline, transform: toPasteboard)
                    }
                }
            }
            if showsEffects {
                layers.addLineEffects(placed: placed, positioned: positioned, indices: indices, transform: toPasteboard)
            }
            if placed.path == nil {
                for inline in placed.line.inlines {
                    layers.glyphs.append(contentsOf: inlineItems(inline, on: placed, transform: toPasteboard))
                }
            }
        }
        var items: [DisplayItem] = []
        let block: TextBlock?
        if case .block(let value) = containers[container] {
            block = value
        } else {
            block = nil
        }
        let frame = Rect(x: 0, y: 0, width: sizes[container].width, height: sizes[container].height)
        if let block, block.displayBorder, !block.appearance.fills.isEmpty {
            items.append(.path(PathItem(path: DisplayPath(rect: frame), appearance: Appearance(block.appearance.fills.map { .fill($0) }), transform: toPasteboard)))
        }
        items.append(contentsOf: layers.items)
        items.append(contentsOf: ruleItems(container: container, transform: toPasteboard))
        if let block, let strokes = block.strokeAppearance {
            if let rules = gridRules(container: container) {
                items.append(.path(PathItem(path: rules, appearance: strokes, transform: toPasteboard)))
            }
            if block.displayBorder {
                items.append(.path(PathItem(path: DisplayPath(rect: frame), appearance: strokes, transform: toPasteboard)))
            }
        }
        return items
    }

    /// An inline graphic's items placed at its glyph position, or the empty box of a missing one.
    private func inlineItems(_ inline: LineInline, on placed: PlacedLine, transform: AffineTransform) -> [DisplayItem] {
        let placement = inlineTransform(inline, on: placed).concatenating(transform)
        guard let items = inline.graphic.items else {
            let box = DisplayPath(rect: Rect(x: 0, y: 0, width: inline.size, height: inline.size))
            return [.path(PathItem(path: box, appearance: Appearance([.stroke(StrokePaint(paint: .solid(inline.fill), style: StrokeStyle(width: 0)))]), transform: placement))]
        }
        return items.map { $0.transformed(by: placement) }
    }

    private func lineOrigin(_ placed: PlacedLine) -> Point {
        placed.path.map { $0.carets.first?.base ?? .zero } ?? placed.frame.apply(placed.origin)
    }

    /// The lines between columns and between rows (columns-tables), in local space: Inset
    /// rules span the text area, Full rules the block.
    private func gridRules(container: Int) -> DisplayPath? {
        guard case .block(let block) = containers[container], let grid = grids[container] else {
            return nil
        }
        var path = DisplayPath()
        if block.columns.columnRules != .none && grid.columns > 1 {
            let full = block.columns.columnRules == .full
            let top = full ? 0 : grid.inset.top
            let bottom = full ? grid.size.height : grid.size.height - grid.inset.bottom
            for column in 1..<grid.columns {
                let x = grid.inset.left + Double(column) * (grid.cell.width + grid.columnSpacing) - grid.columnSpacing / 2
                path.move(to: Point(x: x, y: top))
                path.addLine(to: Point(x: x, y: bottom))
            }
        }
        if block.columns.rowRules != .none && grid.rows > 1 {
            let full = block.columns.rowRules == .full
            let left = full ? 0 : grid.inset.left
            let right = full ? grid.size.width : grid.size.width - grid.inset.right
            for row in 1..<grid.rows {
                let y = grid.inset.top + Double(row) * (grid.cell.height + grid.rowSpacing) - grid.rowSpacing / 2
                path.move(to: Point(x: left, y: y))
                path.addLine(to: Point(x: right, y: y))
            }
        }
        return path.isEmpty ? nil : path
    }

    /// Paragraph rules (paragraphs, "Paragraph rules") drawn with the rule's stroke or the
    /// block's; none without either.
    private func ruleItems(container: Int, transform: AffineTransform) -> [DisplayItem] {
        guard case .block(let block) = containers[container] else {
            return []
        }
        var items: [DisplayItem] = []
        var byParagraph: [Int: [PlacedLine]] = [:]
        var order: [Int] = []
        for placed in lines where placed.container == container && placed.path == nil {
            if byParagraph[placed.paragraph] == nil {
                order.append(placed.paragraph)
            }
            byParagraph[placed.paragraph, default: []].append(placed)
        }
        for paragraph in order {
            let style = paragraphs[paragraph].key.style
            let rule = style.rule
            guard rule.mode != .none, let stroke = rule.stroke.map({ Appearance([.stroke($0)]) }) ?? block.strokeAppearance, let placedLines = byParagraph[paragraph] else {
                continue
            }
            let anchor = rule.above ? placedLines.first! : placedLines.last!
            // Only where the paragraph starts (above) or ends (below).
            if rule.above ? anchor.start != anchor.paragraphStart : !anchor.line.endsParagraph {
                continue
            }
            let cell = anchor.cell
            let line = anchor.line
            let basisWidth = rule.basis == .column ? cell.width : line.width
            let width = basisWidth * rule.widthPercent / 100
            let y = rule.above ? anchor.origin.y - line.ascent - rule.position : anchor.origin.y + line.extraDepth + rule.position
            let x: Double
            switch (rule.mode, style.alignment) {
            case (.centered, _):
                x = cell.minX + (cell.width - width) / 2
            case (_, .right):
                x = rule.basis == .column ? cell.maxX - style.rightIndent - width : anchor.origin.x + line.left + line.width - width
            case (_, .center):
                x = rule.basis == .column ? cell.minX + (cell.width - width) / 2 : anchor.origin.x + line.left + (line.width - width) / 2
            default:
                x = rule.basis == .column ? cell.minX + style.leftIndent : anchor.origin.x + line.left
            }
            var path = DisplayPath()
            path.move(to: anchor.frame.apply(Point(x: x, y: y)))
            path.addLine(to: anchor.frame.apply(Point(x: x + width, y: y)))
            items.append(.path(PathItem(path: path, appearance: stroke, transform: transform)))
        }
        return items
    }
}

extension AffineTransform {
    /// The inverse, or identity for a singular transform.
    var invertedOrIdentity: AffineTransform {
        inverted() ?? .identity
    }
}
