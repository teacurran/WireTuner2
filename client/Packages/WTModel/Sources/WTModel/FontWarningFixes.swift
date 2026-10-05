import WTCRDT
import WTGeometry
import WTRender

// FONT-026 (rest): btn:[Fix All Warnings] of the Generate Fonts sheet (font-export.adoc,
// "Validation"): Correct Directions, Remove Overlaps, Add Extrema and Round to Units applied to the
// artwork of every glyph whose warnings generation would otherwise correct on the way out (points
// off the unit grid, missing extrema) -- a permanent edit of the document, one change and so one
// undo step.  Each glyph's filled artwork (strokes expanded, transforms applied; components and open
// unstroked paths left alone) is replaced by one path of the result, as the Glyph menu's rewrites do.

/// Fixes the warnings generation corrects anyway, in the document itself.
public struct FixGlyphWarnings: Command {
    /// The warnings this fixes.
    public static let kinds: Set<FontProblem.Kind> = [.offGrid, .missingExtrema]

    public var glyphs: [OpID]
    public var label: String { "Fix All Warnings" }

    public init(_ glyphs: [OpID]) {
        self.glyphs = glyphs
    }

    /// The glyphs of `problems` with a warning this fixes, in list order, each once.
    public static func glyphs(in problems: [FontProblem]) -> [OpID] {
        var seen: Set<OpID> = []
        return problems.compactMap { problem in
            guard problem.level == .warning, kinds.contains(problem.kind), let glyph = problem.glyph, seen.insert(glyph).inserted else { return nil }
            return glyph
        }
    }

    /// The fixed contours of `glyph` (glyph space): merged, outer contours counter-clockwise as
    /// the union leaves them, extrema added, whole units.
    static func fixed(_ contours: [Contour]) -> [Contour] {
        GlyphContours.rounded(GlyphContours.addingExtrema(GlyphContours.correctingDirections(contours, outer: .counterClockwise)))
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        let layers = LayerOrder(state)
        for id in glyphs {
            let glyph = try GlyphEditing.glyph(id, in: index)
            guard let rewrite = RewriteGlyphOutlines.rewrite(glyph, .removeOverlaps, in: state, layers: layers) else { continue }
            let last = state.store.children(rewrite.layer).last.flatMap { state.store.placement($0)?.position }
            for node in rewrite.replaced { builder.append(Ops.setDeleted(node)) }
            let contours = Self.fixed(rewrite.contours)
            guard !contours.isEmpty else { continue }
            let key = try PathEditing.keys(between: last, and: nil, count: 1)[0]
            try GlyphPaths.create(contours, parent: rewrite.layer, position: key, canvas: id, builder: &builder)
        }
    }
}
