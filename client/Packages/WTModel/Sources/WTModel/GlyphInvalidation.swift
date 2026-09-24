import WTCRDT
import WTProto
import WTRender

// FONT-009 (model half): which glyph thumbnails a change invalidates (glyph-grid.adoc, "Glyph
// thumbnails"): the glyphs it wrote, the glyphs whose canvas holds an object it touched (before or
// after the change, so moving artwork between glyphs reaches both), and every glyph using one of
// those as a component, transitively.  Only those re-render (`WTRender.GlyphThumbnailCache`).

/// Glyph outline invalidation.
public enum GlyphInvalidation {
    /// The glyphs whose flattened outline `change` may have changed.
    public static func glyphs(touchedBy change: Wiretuner_Doc_V1_Change, before: EngineState, after: EngineState) -> Set<OpID> {
        var nodes = Set(change.ops.flatMap { DocumentDisplayListBuilder.targets($0).map(\.0) })
        nodes.formUnion(change.createdNodes)
        var direct: Set<OpID> = []
        for node in nodes {
            for state in [before, after] {
                if let glyph = glyph(drawing: node, in: state) { direct.insert(glyph) }
            }
        }
        // Users of changed glyphs, transitively.
        let index = GlyphIndex(after)
        var result = direct
        var pending = Array(direct)
        while let glyph = pending.popLast() {
            for user in index.users(of: glyph) where result.insert(user.id).inserted {
                pending.append(user.id)
            }
        }
        return result
    }

    /// The glyph `node` is, or whose canvas holds the top-level object `node` is in.
    static func glyph(drawing node: OpID, in state: EngineState) -> OpID? {
        if state.store.kind(node) == GlyphFields.kind { return node }
        var current = node
        var steps = 0
        while let parent = state.store.placement(current)?.parent, steps < 10_000 {
            if state.nodeKind(parent) == .layer {
                guard let common = NodeValues.common(state.props(current)), common.hasCanvas else { return nil }
                let canvas = OpID(common.canvas.id)
                return state.store.kind(canvas) == GlyphFields.kind ? canvas : nil
            }
            current = parent
            steps += 1
        }
        return nil
    }
}
