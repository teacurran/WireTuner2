// Text on a path (text-on-path, "Layout"): each glyph's origin at its advance distance from
// the start offset by GEO-001 arc length, the orientation as a per-glyph transform, the top
// run (to the first paragraph end, or tab on an open path) and on a closed path the bottom
// run (to the second paragraph end) along the reversed path; left-aligned text on a tight
// curve respaced to the next position where its glyph does not collide.  Text inside a closed
// path fills the lines the path leaves at each height.

import WTGeometry
import struct WTGeometry.AffineTransform
import WTRender
import struct WTRender.StrokeStyle

/// Arc-length lookups over a contour.
struct ArcLength {
    private let segments: [CubicBezier]
    /// Length at the start of each segment, then the total.
    private let cumulative: [Double]

    init(_ contour: Contour) {
        var segments = contour.segments
        if contour.isClosed, let closing = contour.closingSegment {
            segments.append(closing)
        }
        self.segments = segments
        var cumulative = [0.0]
        for segment in segments {
            cumulative.append(cumulative.last! + segment.length(tolerance: 1e-4))
        }
        self.cumulative = cumulative
    }

    var total: Double { cumulative.last! }

    /// The point and unit tangent at arc length `distance` (clamped to the contour).
    func frame(at distance: Double) -> (point: Point, tangent: Vector) {
        let clamped = min(max(distance, 0), total)
        var low = 0
        var high = segments.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if cumulative[mid] <= clamped {
                low = mid
            } else {
                high = mid - 1
            }
        }
        let segment = segments[low]
        let length = cumulative[low + 1] - cumulative[low]
        let t = length > 0 ? segment.parameter(atLength: clamped - cumulative[low], tolerance: 1e-4) : 0
        var tangent = segment.tangent(t)
        if !(tangent.length > 0) {
            tangent = (segment.p3 - segment.p0).normalized
        }
        if !(tangent.length > 0) {
            tangent = Vector(dx: 1, dy: 0)
        }
        return (segment.evaluate(t), tangent)
    }
}

extension LayoutPass {
    /// Lays text along or inside `path`; returns the path's size.
    mutating func placePath(_ path: PathText, container: Int) -> Size {
        let bounds = path.contour.isEmpty ? Rect.zero : path.contour.bounds
        switch path.mode {
        case .along:
            placeAlong(path, container: container)
        case .inside:
            placeInside(path, bounds: bounds, container: container)
        }
        return Size(width: bounds.width, height: bounds.height)
    }

    // MARK: Along

    private mutating func placeAlong(_ path: PathText, container: Int) {
        guard !path.contour.isEmpty else {
            return
        }
        let forward = ArcLength(path.contour)
        if path.contour.isClosed {
            // Both runs hidden: nothing is drawn and the text overflows (text-on-path).
            guard path.top != .none || path.bottom != .none else {
                return
            }
            let reversed = ArcLength(path.contour.reversed())
            let upper = forward.total / 2 - path.offsetEnd
            guard placeRun(on: forward, range: path.offsetStart...max(upper, path.offsetStart), alignment: path.top, path: path, container: container, stopsAtTab: false) else {
                return
            }
            _ = placeRun(on: reversed, range: path.offsetStart...max(upper, path.offsetStart), alignment: path.bottom, path: path, container: container, stopsAtTab: false)
        } else {
            guard path.top != .none else {
                return
            }
            let upper = forward.total - path.offsetEnd
            _ = placeRun(on: forward, range: path.offsetStart...max(upper, path.offsetStart), alignment: path.top, path: path, container: container, stopsAtTab: true)
        }
    }

    /// Places the rest of the current paragraph along `arc` within `range`; returns whether all
    /// of it was placed (or hidden), so the next run may start.
    private mutating func placeRun(on arc: ArcLength, range: ClosedRange<Double>, alignment: PathText.Alignment, path: PathText, container: Int, stopsAtTab: Bool) -> Bool {
        guard !isDone else {
            return false
        }
        let paragraphIndex = position.paragraph
        let source = paragraphs[paragraphIndex]
        let typeset = typeset(paragraphIndex, vertical: false)
        let line = typeset.line(start: position.offset, columnWidth: unboundedWidth)
        // An open path shows text up to the first tab; the rest flows on.
        let tab = stopsAtTab ? (line.start..<line.end).first { typeset.scalars[$0] == "\t" } : nil
        let shownEnd = tab ?? line.end

        func advance(to end: Int) {
            if let tab, end >= tab {
                position.offset = tab + 1
                if position.offset >= source.length && source.length > 0 && line.endsParagraph {
                    finishParagraph(spaceBelow: typeset.style.spaceBelow)
                }
            } else if end >= line.end && line.endsParagraph {
                finishParagraph(spaceBelow: typeset.style.spaceBelow)
            } else {
                position.offset = end
            }
        }

        guard alignment != .none else {
            advance(to: shownEnd)
            return true
        }
        // The glyphs shown, in order, with their distance along the text.
        struct Item {
            let run: Int
            let index: Int
            let x: Double
            let advance: Double
            let char: Int
        }
        var items: [Item] = []
        for (runIndex, run) in line.runs.enumerated() {
            for index in run.glyphs.indices where run.charIndices[index] < shownEnd {
                items.append(Item(run: runIndex, index: index, x: run.xs[index], advance: run.advances[index], char: run.charIndices[index]))
            }
        }
        items.sort { $0.x < $1.x }
        let base = items.first?.x ?? 0
        let width = items.last.map { $0.x + $0.advance - base } ?? 0
        let length = range.upperBound - range.lowerBound
        var start: Double
        switch typeset.style.alignment {
        case _ where width > length: start = range.lowerBound
        case .center: start = range.lowerBound + (length - width) / 2
        case .right: start = range.upperBound - width
        case .left, .justified: start = range.lowerBound
        }
        let respaces = typeset.style.alignment == .left || typeset.style.alignment == .justified
        let lift: Double
        switch alignment {
        case .ascent: lift = line.ascent
        case .descent: lift = -line.descent
        case .baseline, .none: lift = 0
        }

        var glyphs: [PathPlacement.Glyph] = []
        var starts: [Int: Double] = [:]
        var placedEnd = line.start
        var respacing = 0.0
        var previousBox: [Point]?
        var endDistance = start
        for item in items {
            let run = line.runs[item.run]
            var along = start + item.x - base + respacing
            var transform = glyphTransform(arc: arc, at: along, advance: item.advance, lift: lift + run.yOffset, orientation: path.orientation)
            if respaces, let previous = previousBox {
                var steps = 0
                while steps < 200 && boxesOverlap(previous, box(transform, advance: item.advance, line: line)) {
                    along += 0.5
                    respacing += 0.5
                    transform = glyphTransform(arc: arc, at: along, advance: item.advance, lift: lift + run.yOffset, orientation: path.orientation)
                    steps += 1
                }
            }
            if along + item.advance > range.upperBound + 0.01 {
                break
            }
            glyphs.append(PathPlacement.Glyph(run: item.run, index: item.index, transform: transform))
            previousBox = box(transform, advance: item.advance, line: line)
            if starts[item.char] == nil {
                starts[item.char] = along
            }
            placedEnd = max(placedEnd, item.char + 1)
            endDistance = along + item.advance
        }
        if glyphs.count == items.count {
            placedEnd = shownEnd
        }
        // Carets at each boundary: a glyph's start, or the end of the last glyph.
        var carets: [PathPlacement.CaretFrame] = []
        var lastDistance = start
        for boundary in line.start...placedEnd {
            let distance = boundary == placedEnd ? endDistance : (starts[boundary] ?? lastDistance)
            lastDistance = distance
            let frame = arc.frame(at: distance)
            let normal = Vector(dx: -frame.tangent.dy, dy: frame.tangent.dx)
            let up = path.orientation == .rotate || path.orientation == .skewHorizontal ? -normal : Vector(dx: 0, dy: -1)
            carets.append(PathPlacement.CaretFrame(base: frame.point + normal * lift, up: up))
        }
        lines.append(PlacedLine(
            container: container, paragraph: paragraphIndex,
            start: source.start + line.start, end: source.start + placedEnd, paragraphStart: source.start,
            line: line, origin: .zero, cell: .zero, frame: .identity, vertical: false,
            path: PathPlacement(glyphs: glyphs, carets: carets)
        ))
        advance(to: placedEnd)
        return placedEnd >= shownEnd
    }

    /// Glyph space to local space for a glyph whose advance starts at `distance`.
    private func glyphTransform(arc: ArcLength, at distance: Double, advance: Double, lift: Double, orientation: PathText.Orientation) -> AffineTransform {
        let (point, tangent) = arc.frame(at: distance + advance / 2)
        let normal = Vector(dx: -tangent.dy, dy: tangent.dx)
        let centre = point + normal * lift
        switch orientation {
        case .rotate:
            let origin = centre - tangent * (advance / 2)
            return AffineTransform(a: tangent.dx, b: tangent.dy, c: normal.dx, d: normal.dy, tx: origin.x, ty: origin.y)
        case .vertical:
            return .translation(x: centre.x - advance / 2, y: centre.y)
        case .skewHorizontal:
            return AffineTransform(a: 1, b: 0, c: normal.dx, d: normal.dy, tx: centre.x - advance / 2, ty: centre.y)
        case .skewVertical:
            let origin = centre - tangent * (advance / 2)
            return AffineTransform(a: tangent.dx, b: tangent.dy, c: 0, d: 1, tx: origin.x, ty: origin.y)
        }
    }

    /// A glyph's advance box (ascent to descent) in local space.
    private func box(_ transform: AffineTransform, advance: Double, line: TypesetLine) -> [Point] {
        [
            Point(x: 0, y: -line.ascent), Point(x: advance, y: -line.ascent),
            Point(x: advance, y: line.descent), Point(x: 0, y: line.descent),
        ].map(transform.apply)
    }

    // MARK: Inside

    private mutating func placeInside(_ path: PathText, bounds: Rect, container: Int) {
        // An open path is closed for layout (text-on-path, read-time normalizations).
        guard !path.contour.isEmpty else {
            return
        }
        let polygon = flattenContour(path.contour)
        let top = bounds.minY + path.inset.top
        let bottom = bounds.maxY - path.inset.bottom
        let region = Rect(minX: bounds.minX, minY: top, maxX: bounds.maxX, maxY: bottom)
        var lastBaseline: Double?
        while !isDone {
            let paragraphIndex = position.paragraph
            let source = paragraphs[paragraphIndex]
            let typeset = typeset(paragraphIndex, vertical: false)
            let style = typeset.style
            // Estimate the line from the widest possible one, then settle its span.
            let probe = typeset.line(start: position.offset, columnWidth: bounds.width, hyphensBefore: position.hyphens)
            var baseline: Double
            if let previous = lastBaseline {
                baseline = previous + probe.distance + (position.offset == 0 ? max(position.spaceBelow ?? 0, style.spaceAbove) : 0)
            } else {
                baseline = top + probe.ascent
            }
            // The first band down that holds a line; one that holds only part of a word is
            // passed over while a lower band might hold the word (kept as the fallback).
            var placed: (line: TypesetLine, span: ClosedRange<Double>, baseline: Double)?
            var fallback: (line: TypesetLine, span: ClosedRange<Double>, baseline: Double)?
            while baseline + probe.descent <= bottom + 0.001 {
                if let span = span(of: polygon, top: baseline - probe.ascent, bottom: baseline + probe.descent, inset: path.inset, minimum: probe.size * 2) {
                    let line = typeset.line(start: position.offset, columnWidth: span.upperBound - span.lowerBound, hyphensBefore: position.hyphens)
                    if !line.emergency {
                        placed = (line, span, baseline)
                        break
                    }
                    fallback = fallback ?? (line, span, baseline)
                }
                baseline += 1
            }
            guard let (line, span, lineBaseline) = placed ?? fallback, lineBaseline + line.extraDepth + line.descent <= bottom + 0.001 else {
                return
            }
            baseline = lineBaseline
            let cell = Rect(minX: span.lowerBound, minY: region.minY, maxX: span.upperBound, maxY: region.maxY)
            lines.append(PlacedLine(
                container: container, paragraph: paragraphIndex,
                start: source.start + line.start, end: source.start + line.end, paragraphStart: source.start,
                line: line, origin: Point(x: span.lowerBound, y: baseline), cell: cell,
                frame: .identity, vertical: false, path: nil
            ))
            lastBaseline = baseline + line.extraDepth
            position.hyphens = line.hyphenated ? position.hyphens + 1 : 0
            if line.endsParagraph {
                finishParagraph(spaceBelow: style.spaceBelow)
            } else {
                position.offset = line.end
            }
            if line.cellBreak && !singleCell {
                return
            }
        }
    }

    /// The widest horizontal span inside `polygon` (even-odd) across the band `top...bottom`,
    /// shrunk by the inset; nil when none is at least `minimum` wide.
    private func span(of polygon: [Point], top: Double, bottom: Double, inset: Inset, minimum: Double) -> ClosedRange<Double>? {
        var spans = intervals(of: polygon, at: top)
        for y in [(top + bottom) / 2, bottom] {
            spans = intersect(spans, intervals(of: polygon, at: y))
        }
        let shrunk = spans.compactMap { span -> ClosedRange<Double>? in
            let low = span.lowerBound + inset.left
            let high = span.upperBound - inset.right
            return high - low >= max(minimum, 1) ? low...high : nil
        }
        return shrunk.max { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }
    }

    private func intervals(of polygon: [Point], at y: Double) -> [ClosedRange<Double>] {
        var crossings: [Double] = []
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            if (a.y <= y) != (b.y <= y) {
                crossings.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
            }
        }
        crossings.sort()
        return stride(from: 0, to: crossings.count - 1, by: 2).map { crossings[$0]...crossings[$0 + 1] }
    }

    private func intersect(_ lhs: [ClosedRange<Double>], _ rhs: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for a in lhs {
            for b in rhs {
                let low = max(a.lowerBound, b.lowerBound)
                let high = min(a.upperBound, b.upperBound)
                if low < high {
                    result.append(low...high)
                }
            }
        }
        return result
    }
}

/// Whether two convex quadrilaterals overlap by more than a hair (separating axis test):
/// glyphs that merely touch, as on a straight path, do not collide.
func boxesOverlap(_ lhs: [Point], _ rhs: [Point]) -> Bool {
    for polygon in [lhs, rhs] {
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let axis = Vector(dx: b.y - a.y, dy: a.x - b.x)
            let projectL = lhs.map { axis.dot($0 - .zero) }
            let projectR = rhs.map { axis.dot($0 - .zero) }
            let overlap = min(projectL.max()!, projectR.max()!) - max(projectL.min()!, projectR.min()!)
            if overlap <= 0.01 * max(axis.length, 1e-9) {
                return false
            }
        }
    }
    return true
}
