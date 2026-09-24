import CoreText
import WTGeometry
import WTRender

// Convert to Paths (TYPE-044; type/text-to-paths.adoc, "Client"): the outline of every positioned
// glyph of a laid-out container, composed with everything that placed it (baseline shift,
// horizontal scale, the path glyph transform, the container's transform), and the effect shapes
// TYPE-036's generators draw -- underline, strikethrough, highlight, inline and shadow; zoom is
// dropped.  Everything comes back in pasteboard space (the container's transform, then the one
// given).

/// One filled or stroked shape of converted text.
public struct TextShape: Hashable, Sendable {
    /// Pasteboard space.
    public var path: DisplayPath
    public var fill: FillPaint?
    public var stroke: StrokePaint?

    public init(path: DisplayPath, fill: FillPaint? = nil, stroke: StrokePaint? = nil) {
        self.path = path
        self.fill = fill
        self.stroke = stroke
    }
}

/// A converted glyph: its outline (every contour of the character, holes included, filled
/// non-zero as the font draws it) and the character's fill and stroke.
public struct TextGlyphOutline: Hashable, Sendable {
    /// Pasteboard space.
    public var path: DisplayPath
    /// Global scalar offset of the character the glyph came from.
    public var offset: Int
    public var fill: Color
    public var stroke: StrokePaint?
    public var overprint: Bool
    /// The glyph's font (for the missing-font warning).
    public var fontName: String
}

/// The shapes of one converted container, in draw order: the effects under the glyphs, the glyphs,
/// the effects over them.
public struct TextOutlines: Hashable, Sendable {
    public var under: [TextShape]
    public var glyphs: [TextGlyphOutline]
    public var over: [TextShape]
    /// Where each inline graphic is drawn: its own space to pasteboard space.
    public var inlines: [InlineGraphicPlacement]
}

extension TextLayout {
    /// The outlines of `container` (text-to-paths): glyphs with outlines only (spaces and
    /// bitmap-only glyphs have none), effects without zoom.  `transform` follows the container's.
    public func outlines(forContainer container: Int, transform: AffineTransform = .identity) -> TextOutlines {
        guard containers.indices.contains(container) else {
            return TextOutlines(under: [], glyphs: [], over: [], inlines: [])
        }
        let toPasteboard = containers[container].transform.concatenating(transform)
        var glyphs: [TextGlyphOutline] = []
        var drawing = TextDrawing()
        var inlines: [InlineGraphicPlacement] = []
        for placed in lines where placed.container == container {
            var positioned = [[PositionedGlyph]](repeating: [], count: placed.line.runs.count)
            var indices = [[Int]](repeating: [], count: placed.line.runs.count)
            forEachGlyph(of: placed) { runIndex, index, glyphTransform in
                let run = placed.line.runs[runIndex]
                let glyph = PositionedGlyph(glyph: run.glyphs[index], position: glyphTransform.apply(.zero), transform: glyphTransform)
                positioned[runIndex].append(glyph)
                indices[runIndex].append(index)
                let outline = GlyphRun(font: run.font, glyphs: [glyph]).outline
                guard !outline.isEmpty else {
                    return
                }
                glyphs.append(TextGlyphOutline(path: outline.applying(toPasteboard), offset: placed.paragraphStart + run.charIndices[index],
                                               fill: run.color, stroke: run.attributes.stroke, overprint: run.attributes.overprint,
                                               fontName: CTFontCopyPostScriptName(run.font.ctFont) as String))
            }
            for (index, run) in placed.line.runs.enumerated() where !positioned[index].isEmpty {
                if case .zoom? = run.attributes.effect {
                    continue
                }
                let glyphRun = GlyphRun(font: run.font, glyphs: positioned[index])
                drawing.addGlyphEffect(run: run, glyphRun: glyphRun, outline: glyphRun.outline, transform: toPasteboard)
            }
            drawing.addLineEffects(placed: placed, positioned: positioned, indices: indices, transform: toPasteboard)
            if placed.path == nil {
                for inline in placed.line.inlines {
                    inlines.append(InlineGraphicPlacement(container: container, offset: placed.paragraphStart + inline.char,
                                                          transform: inlineTransform(inline, on: placed).concatenating(toPasteboard)))
                }
            }
        }
        return TextOutlines(under: Self.shapes(drawing.under), glyphs: glyphs, over: Self.shapes(drawing.over), inlines: inlines)
    }

    /// Path items as shapes in pasteboard space.
    static func shapes(_ items: [DisplayItem]) -> [TextShape] {
        items.compactMap { item in
            guard case .path(let path) = item else {
                return nil
            }
            return TextShape(path: path.path.applying(path.transform), fill: path.appearance.fills.first, stroke: path.appearance.strokes.first)
        }
    }
}
