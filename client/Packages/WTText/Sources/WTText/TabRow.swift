// Wrapping tabs (tabs-indents, "Setting tabs"; TYPE-025).  Core Text has no wrapping tab, so a
// line whose tabs reach a wrapping stop is laid out here as a *row*: the text between tabs is a
// cell; a cell after a wrapping stop wraps within the sub-column that runs to the next stop (or
// the line's right edge) and continues below, under the stop, while the cells after it stay on
// the row's first line ("two wrapping tabs with a plain tab between them make a gutter").  The
// other stops align as Core Text aligns them: left, right, centre, and decimal on the locale's
// separator (text without one right-aligns); leaders fill the gap before a non-wrapping stop in
// the preceding character's font.  A row is one `TypesetLine` whose glyphs and carets sit on
// sub-lines one leading apart; `extraDepth` is how far its last sub-line is below the first.

import WTGeometry
import WTRender
import CoreText
import Foundation

extension TypesetParagraph {
    /// The row starting at `start`, or nil when the line is not a row: no tab before the
    /// paragraph end (or a mandatory break), no tab reaching a wrapping stop, or a first cell
    /// wider than the line.
    func rowLine(start: Int, boxLeft: Double, boxWidth: Double, columnWidth: Double) -> TypesetLine? {
        var end = length
        for index in start..<length where isMandatoryBreak(scalars[index]) {
            end = index + 1
            break
        }
        let contentEnd = end > start && isMandatoryBreak(scalars[end - 1]) ? end - 1 : end
        let tabs = (start..<contentEnd).filter { scalars[$0] == "\t" }
        guard !tabs.isEmpty else {
            return nil
        }
        var cells: [Range<Int>] = []
        var cellStart = start
        for tab in tabs {
            cells.append(cellStart..<tab)
            cellStart = tab + 1
        }
        cells.append(cellStart..<contentEnd)

        let right = boxLeft + boxWidth
        let spacing = metrics(start: start, end: end, ascent: 0, descent: 0).distance
        let stops = sortedTabs.filter { $0.position <= columnWidth + 0.001 }
        var glyphs: [RawGlyph] = []
        var leaders: [Leader] = []
        var caretX = [Double](repeating: boxLeft, count: end - start + 1)
        var caretY = [Double](repeating: 0, count: end - start + 1)
        var widest = boxLeft
        var deepest = 0

        /// Places `range` from `x` on sub-line `depth`; returns its typographic width.
        func place(_ range: Range<Int>, at x: Double, depth: Int) -> Double {
            // An empty range is no line (Core Text reads length 0 as "to the end").
            guard !range.isEmpty else {
                caretX[range.lowerBound - start] = x
                caretY[range.lowerBound - start] = Double(depth) * spacing
                return 0
            }
            let ctRange = CFRange(location: utf16Offsets[range.lowerBound], length: utf16Offsets[range.upperBound] - utf16Offsets[range.lowerBound])
            let line = CTTypesetterCreateLineWithOffset(typesetter, ctRange, x)
            let y = Double(depth) * spacing
            glyphs.append(contentsOf: rawGlyphs(of: line, xOffset: x).map { raw in
                var raw = raw
                raw.depth = y
                return raw
            })
            for boundary in range.lowerBound...range.upperBound {
                caretX[boundary - start] = x + Double(CTLineGetOffsetForStringIndex(line, utf16Offsets[boundary], nil))
                caretY[boundary - start] = y
            }
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            widest = max(widest, x + width - CTLineGetTrailingWhitespaceWidth(line))
            deepest = max(deepest, depth)
            return width
        }

        func measure(_ range: Range<Int>) -> (width: Double, visible: Double, line: CTLine?) {
            guard !range.isEmpty else {
                return (0, 0, nil)
            }
            let ctRange = CFRange(location: utf16Offsets[range.lowerBound], length: utf16Offsets[range.upperBound] - utf16Offsets[range.lowerBound])
            let line = CTTypesetterCreateLineWithOffset(typesetter, ctRange, 0)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            return (width, width - CTLineGetTrailingWhitespaceWidth(line), line)
        }

        guard boxLeft + measure(cells[0]).visible <= right + 0.01 else {
            return nil
        }
        var pen = boxLeft + place(cells[0], at: boxLeft, depth: 0)
        var wrapped = false
        for (index, tab) in tabs.enumerated() {
            let cell = cells[index + 1]
            let stop = stops.first { $0.position > pen + 0.001 } ?? defaultStop(after: pen, stops: stops, right: right)
            if stop.kind == .wrapping {
                wrapped = true
                let limit = stops.first { $0.position > stop.position + 0.001 }?.position ?? right
                let width = max(limit - stop.position, 1)
                var first = place(cell.lowerBound..<cell.lowerBound, at: stop.position, depth: 0)
                var lineStart = cell.lowerBound
                var depth = 0
                while lineStart < cell.upperBound {
                    let suggested = CTTypesetterSuggestLineBreakWithOffset(typesetter, utf16Offsets[lineStart], width, stop.position)
                    let lineEnd = min(max(scalar(atUTF16: utf16Offsets[lineStart] + max(suggested, 1)), lineStart + 1), cell.upperBound)
                    let placed = place(lineStart..<lineEnd, at: stop.position, depth: depth)
                    if depth == 0 {
                        first = placed
                    }
                    lineStart = lineEnd
                    depth += 1
                }
                pen = stop.position + first
            } else {
                let measured = measure(cell)
                var x: Double
                switch stop.kind {
                case .right: x = stop.position - measured.visible
                case .center: x = stop.position - measured.visible / 2
                case .decimal:
                    if let line = measured.line, let separator = cell.first(where: { String(scalars[$0]) == decimalSeparator }) {
                        x = stop.position - Double(CTLineGetOffsetForStringIndex(line, utf16Offsets[separator], nil))
                    } else {
                        x = stop.position - measured.visible
                    }
                case .left, .wrapping: x = stop.position
                }
                x = max(x, pen)
                if let leader = leader(stop.leader, tab: tab, from: pen, to: x) {
                    leaders.append(leader)
                }
                pen = x + place(cell, at: x, depth: 0)
            }
        }
        guard wrapped else {
            return nil
        }
        if end > contentEnd {
            caretX[end - start] = caretX[contentEnd - start]
            caretY[end - start] = caretY[contentEnd - start]
        }
        glyphs.removeAll { isInvisible(scalars[$0.char]) }
        var runs = makeRuns(glyphs, xs: glyphs.map(\.x))
        runs.append(contentsOf: leaders.map { leader in
            LineGlyphRun(span: leader.span, font: leader.font, color: attributes[leader.span].fill, glyphs: leader.glyphs,
                         xs: leader.xs, advances: leader.advances,
                         charIndices: Array(repeating: leader.char, count: leader.glyphs.count), yOffset: 0, upright: false,
                         ascent: 0, descent: 0, text: "", attributes: attributes[leader.span], emboldening: 0)
        })
        let metrics = metrics(start: start, end: end, ascent: 0, descent: 0)
        return TypesetLine(
            start: start, end: end, runs: runs, caretX: caretX, left: boxLeft, width: widest - boxLeft,
            ascent: metrics.ascent, descent: metrics.descent, distance: metrics.distance, size: metrics.size,
            hyphenated: false, endsParagraph: end >= length, cellBreak: end > start && scalars[end - 1] == "\u{000C}",
            visibleEnd: lastVisible(start: start, end: end),
            inlines: inlines(start: start, end: end, carets: caretX, depths: caretY),
            caretY: caretY, extraDepth: Double(deepest) * spacing
        )
    }

    /// The default stop after `x`: every half inch from the column edge, beyond the last set
    /// stop (placing a stop removes the default stops to its left); at `x` itself when none is
    /// left before the line's right edge.
    func defaultStop(after x: Double, stops: [TabStop], right: Double) -> TabStop {
        let from = max(x, stops.last?.position ?? 0)
        let position = (from / defaultTabInterval).rounded(.down) * defaultTabInterval + defaultTabInterval
        return TabStop(.left, at: position <= right ? position : x)
    }
}
