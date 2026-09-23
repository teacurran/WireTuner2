// Text effects and glyph decorations as display items (TYPE-021, TYPE-036; text-effects,
// "Rendering"): WTText draws them in the glyph pass as ordinary attribute-stack paths, so both
// renderers draw them the same way and REND-007 holds them to parity like any path.
//
// * Highlight, underline and strikethrough: a stroke (with the effect's dash) along the line's
//   run of effected glyphs -- straight on a line, glyph by glyph on a path.
// * Inline: rings around the glyph outlines, widest first, alternating the outline colour and
//   the background band, under the glyphs -- filled `RoundOutline` regions rather than strokes,
//   because GEO-003's stroker drops the outline of some glyphs at some widths.
// * Shadow: a second fill of the outlines, offset, in the colour tinted over white.
// * Zoom: fills of the outlines stepping from the back copy (scaled, offset, in `to`) toward
//   the glyphs (in `from`), one step per point of offset.
// * Glyph strokes (`TextMarkValue.stroke`, stroked like any path) and a synthesized bold's
//   heavier weight (a `RoundOutline` region in the fill colour).
//
// Effects draw behind (highlight, inline, shadow, zoom) or over (underline, strikethrough) the
// glyphs, in groups Keyline never draws (text-effects: "Keyline view never shows them").

import WTGeometry
import struct WTGeometry.AffineTransform
import WTRender
import struct WTRender.StrokeStyle
import CoreText

/// The layers of a container's text drawing, collected line by line.
struct TextDrawing {
    /// Effects under the glyphs.
    var under: [DisplayItem] = []
    var glyphs: [DisplayItem] = []
    /// Glyph strokes and synthesized emboldening.
    var decorations: [DisplayItem] = []
    /// Effects over the glyphs.
    var over: [DisplayItem] = []

    /// Zoom never draws more steps than this.
    static let maximumZoomSteps = 200

    /// The layers in draw order.
    var items: [DisplayItem] {
        var result: [DisplayItem] = []
        if !under.isEmpty {
            result.append(.group(GroupItem(children: under, hiddenInKeyline: true)))
        }
        result.append(contentsOf: glyphs)
        if !decorations.isEmpty {
            result.append(.group(GroupItem(children: decorations, hiddenInKeyline: true)))
        }
        if !over.isEmpty {
            result.append(.group(GroupItem(children: over, hiddenInKeyline: true)))
        }
        return result
    }

    // MARK: Glyph decorations

    /// Whether `run` draws decorations or glyph effects, which need its outline.
    static func needsOutline(_ run: LineGlyphRun, showsEffects: Bool) -> Bool {
        if run.emboldening > 0 || run.attributes.stroke != nil {
            return true
        }
        guard showsEffects, let effect = run.attributes.effect else {
            return false
        }
        return lineOptions(effect) == nil
    }

    /// The run's glyph stroke and synthesized emboldening.
    mutating func addDecorations(run: LineGlyphRun, glyphRun: GlyphRun, outline: DisplayPath, transform: AffineTransform) {
        guard run.emboldening > 0 || run.attributes.stroke != nil, !outline.isEmpty else {
            return
        }
        if run.emboldening > 0 {
            let weight = FillPaint(paint: .solid(run.color), overprint: run.attributes.overprint)
            decorations.append(contentsOf: glyphRun.roundOutlineItems(width: run.emboldening, paint: weight, transform: transform))
        }
        if let stroke = run.attributes.stroke {
            decorations.append(.path(PathItem(path: outline, appearance: Appearance([.stroke(stroke)]), transform: transform)))
        }
    }

    // MARK: Glyph effects

    /// Inline, shadow and zoom for one run.
    mutating func addGlyphEffect(run: LineGlyphRun, glyphRun: GlyphRun, outline: DisplayPath, transform: AffineTransform) {
        let size = run.attributes.size
        guard !outline.isEmpty else {
            return
        }
        switch run.attributes.effect {
        case .inline(let inline)?:
            let band = max(inline.backgroundWidth, 0) + max(inline.strokeWidth, 0)
            for ring in stride(from: max(inline.count, 1), through: 1, by: -1) {
                let reach = Double(ring) * band
                if reach > 0 {
                    under.append(contentsOf: glyphRun.roundOutlineItems(width: 2 * reach, paint: FillPaint(paint: .solid(inline.strokeColor)), transform: transform))
                }
                let inner = reach - max(inline.strokeWidth, 0)
                if inner > 0 {
                    under.append(contentsOf: glyphRun.roundOutlineItems(width: 2 * inner, paint: FillPaint(paint: .solid(inline.backgroundColor)), transform: transform))
                }
            }
        case .shadow(let shadow)?:
            let offset = AffineTransform.translation(x: shadow.offsetX / 100 * size, y: shadow.offsetY / 100 * size)
            let color = TextDrawing.tint(shadow.color, percent: shadow.tint)
            under.append(.path(PathItem(path: outline, appearance: Appearance([.fill(FillPaint(paint: .solid(color)))]), transform: offset.concatenating(transform))))
        case .zoom(let zoom)?:
            guard let bounds = glyphRun.inkBounds else { return }
            let center = Point(x: bounds.midX, y: bounds.midY)
            let offset = Vector(dx: zoom.offsetX / 100 * size, dy: zoom.offsetY / 100 * size)
            let back = max(zoom.zoomTo, 0) / 100
            // One step per point the copies travel (offset, or growth at the glyphs' edge).
            let travel = max(offset.length, abs(1 - back) * max(bounds.width, bounds.height) / 2)
            let steps = min(max(Int(travel.rounded(.up)), 1), TextDrawing.maximumZoomSteps)
            for step in 0..<steps {
                let t = Double(step) / Double(steps)
                let scale = back + (1 - back) * t
                let shift = offset * (1 - t)
                let place = AffineTransform.translation(x: -center.x, y: -center.y)
                    .concatenating(.scale(scale))
                    .concatenating(.translation(x: center.x + shift.dx, y: center.y + shift.dy))
                let color = TextDrawing.mix(zoom.to, zoom.from, t)
                under.append(.path(PathItem(path: outline, appearance: Appearance([.fill(FillPaint(paint: .solid(color)))]), transform: place.concatenating(transform))))
            }
        default:
            break
        }
    }

    // MARK: Line effects

    /// One stretch of glyphs under one line effect.
    private struct Stretch {
        let effect: TextEffect
        let line: TextLineEffect
        let depth: Double
        let size: Double
        let font: GlyphFont
        var points: [Point]
        var lastX: Double
    }

    /// Highlight, underline and strikethrough along `placed`'s effected glyphs: straight lines
    /// merge adjacent runs with the same effect; on a path each glyph adds its piece.
    mutating func addLineEffects(placed: PlacedLine, positioned: [[PositionedGlyph]], indices: [[Int]], transform: AffineTransform) {
        let line = placed.line
        var stretches: [Stretch] = []
        for (runIndex, run) in line.runs.enumerated() where !run.text.isEmpty {
            guard let effect = run.attributes.effect, let options = TextDrawing.lineOptions(effect) else {
                continue
            }
            let depth = run.yOffset + run.attributes.baselineShift
            let y = TextDrawing.centre(of: effect, options: options, line: line, font: run.font)
            for (piece, glyph) in positioned[runIndex].enumerated() {
                let index = indices[runIndex][piece]
                guard run.charIndices[index] < line.visibleEnd else {
                    continue
                }
                let advance = run.advances[index]
                let start: Point
                let end: Point
                if placed.path != nil {
                    // Glyph space: y from the (lifted) baseline.
                    let place = glyph.placement
                    start = place.apply(Point(x: 0, y: y - run.yOffset))
                    end = place.apply(Point(x: advance, y: y - run.yOffset))
                } else {
                    let x = placed.origin.x + run.xs[index]
                    start = placed.frame.apply(Point(x: x, y: placed.origin.y + depth + y))
                    end = placed.frame.apply(Point(x: x + advance, y: placed.origin.y + depth + y))
                }
                if var last = stretches.last, last.effect == effect, last.depth == depth, placed.path != nil || abs(run.xs[index] - last.lastX) < 0.5 {
                    last.points.append(contentsOf: placed.path != nil ? [start, end] : [end])
                    last.lastX = run.xs[index] + advance
                    stretches[stretches.count - 1] = last
                } else {
                    stretches.append(Stretch(effect: effect, line: options, depth: depth, size: run.attributes.size, font: run.font, points: [start, end], lastX: run.xs[index] + advance))
                }
            }
        }
        for stretch in stretches {
            var path = DisplayPath()
            path.move(to: stretch.points[0])
            for point in stretch.points.dropFirst() {
                path.addLine(to: point)
            }
            let width = TextDrawing.thickness(of: stretch.effect, options: stretch.line, line: line, font: stretch.font)
            let stroke = StrokePaint(paint: .solid(stretch.line.color), style: StrokeStyle(width: width, cap: .butt, join: .round, dash: stretch.line.dash), overprint: stretch.line.overprint)
            let item = DisplayItem.path(PathItem(path: path, appearance: Appearance([.stroke(stroke)]), transform: transform))
            if case .highlight = stretch.effect {
                under.append(item)
            } else {
                over.append(item)
            }
        }
    }

    /// A line effect's options; nil for the glyph effects.
    static func lineOptions(_ effect: TextEffect) -> TextLineEffect? {
        switch effect {
        case .highlight(let options), .underline(let options), .strikethrough(let options): return options
        case .inline, .shadow, .zoom: return nil
        }
    }

    /// The line's centre below the baseline (y down).
    static func centre(of effect: TextEffect, options: TextLineEffect, line: TypesetLine, font: GlyphFont) -> Double {
        if case .highlight = effect {
            return options.width > 0 ? -(options.position + options.width / 2) : (line.descent - line.ascent) / 2
        }
        return -options.position
    }

    /// The line's thickness: a highlight's band (the line's height when unset), the font's
    /// underline thickness for an unset line width.
    static func thickness(of effect: TextEffect, options: TextLineEffect, line: TypesetLine, font: GlyphFont) -> Double {
        guard options.width <= 0 else {
            return options.width
        }
        if case .highlight = effect {
            return line.ascent + line.descent
        }
        return max(Double(CTFontGetUnderlineThickness(font.ctFont)), 0.5)
    }

    // MARK: Colour

    /// `color` at `percent` over white (a tint), alpha kept.
    static func tint(_ color: Color, percent: Double) -> Color {
        let t = min(max(percent, 0), 100) / 100
        return Color(red: 1 - t * (1 - color.red), green: 1 - t * (1 - color.green), blue: 1 - t * (1 - color.blue), alpha: color.alpha)
    }

    /// The colour `t` of the way from `a` to `b`.
    static func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
        Color(red: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t, blue: a.blue + (b.blue - a.blue) * t, alpha: a.alpha + (b.alpha - a.alpha) * t)
    }
}
