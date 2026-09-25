import WTCRDT
import WTProto

/// Style-driven appearance in the scene (LIB-019; styles.adoc, "Resolution (read-time)"): the
/// scene builder hands each object's properties and stack order here before drawing, and an
/// object that uses a graphic style is drawn with its effective look -- its own set categories,
/// then its style's chain, then the document defaults -- through `GraphicStyleResolver`.  An
/// object with no style (or whose reference reads as unset) is drawn from its own registers,
/// untouched.
public enum StyleAppearance {
    /// Rewrites `props` and `order` of `node` to its effective look when it uses a graphic style,
    /// and returns the nodes it is then drawn from -- its style's chain, and the settings node when
    /// a category falls back to the defaults -- for the scene's dependency index, so a redefinition,
    /// a parent change or a defaults edit redraws it.  The composed stack's elements are numbered
    /// by place (`StyleStacks.compose`) and `order` names them so.
    public static func apply(_ styles: GraphicStyleResolver, to props: inout Wiretuner_Doc_V1_NodeProps, order: inout [AppearanceRow],
                             node: OpID, state: EngineState) -> [OpID] {
        guard let style = styles.style(of: node, in: state), let kind = state.nodeKind(node), NodeValues.appearanceField(kind) != nil else { return [] }
        let chain = styles.chain(of: style)
        let (look, usesDefaults, own) = StyleStacks.look(of: node, chain: chain, props: props, styles: styles, state: state)
        let sources = chain + (usesDefaults ? [WellKnown.settings] : [])
        guard !own.isSuperset(of: [.fills, .strokes, .effects]) else { return sources }
        var appearance = NodeValues.appearance(props)!
        appearance.fills = []
        appearance.strokes = []
        appearance.effects = []
        order = []
        for element in look.stack {
            order.append(AppearanceRow(element.list, OpID(counter: element.place, replica: 0)))
            switch element {
            case .fill(let fill): appearance.fills.append(fill)
            case .stroke(let stroke): appearance.strokes.append(stroke)
            case .effect(let effect): appearance.effects.append(effect)
            }
        }
        props = NodeValues.replacing(appearance, of: kind, in: props)
        return sources
    }
}
