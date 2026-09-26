import AppKit
import WTCRDT
import WTModel
import WTProto

/// The *Swatches apply color to* preference (text-color.adoc, "Dropping color on text"; the rest of
/// TYPE-030): what the Swatches panel's Fill and Stroke selectors act on -- and what its wells show
/// -- when text blocks are selected with the Pointer: *Text*, the characters (a `fill` or `stroke`
/// mark over all of each block's text), or *Text block*, the block's own top fill or stroke row
/// (added when the block has none).  Other selected objects take the colour as before, in the same
/// change.
@MainActor
enum TextSwatchTarget {
    enum AppliesTo: String {
        case text, block
    }

    static func appliesTo(_ preferences: PreferenceStore?) -> AppliesTo {
        AppliesTo(rawValue: preferences?[PreferenceCatalog.Colors.swatchTarget] ?? "text") ?? .text
    }

    /// The stroke a character stroke coloured from the Swatches gets: its own stroke with the
    /// colour, else 1 pt.
    static func stroke(of text: TextNode, _ color: Wiretuner_Doc_V1_ColorRef) -> Wiretuner_Doc_V1_BasicStroke {
        var stroke = text.length == 0 ? TextColor.defaultStroke : (text.values(at: 0).lazy.compactMap { value -> Wiretuner_Doc_V1_BasicStroke? in
            if case .stroke(let stroke)? = value.value, stroke != Wiretuner_Doc_V1_BasicStroke() { stroke } else { nil }
        }.first ?? TextColor.defaultStroke)
        stroke.color = color
        return stroke
    }

    /// The change a swatch click makes on `nodes`; nil when none of them is text (the panel's own
    /// `ApplyColor` then runs).
    static func command(_ nodes: [OpID], target: ColorTarget, color: Wiretuner_Doc_V1_ColorRef, name: String, state: EngineState,
                        appliesTo: AppliesTo) -> (any WTModel.Command)? {
        guard nodes.contains(where: { state.textNode($0) != nil }) else { return nil }
        var commands: [any WTModel.Command] = []
        for node in nodes {
            guard let text = state.textNode(node) else { continue }
            for list in target.lists {
                switch appliesTo {
                case .text:
                    commands.append(list == .fills ? TextColor.fill(node: node, from: .start, to: .end, color)
                                                   : TextColor.stroke(node: node, from: .start, to: .end, stroke(of: text, color)))
                case .block:
                    if let command = TextColorDrop.command(list == .fills ? .interior(node) : .border(node), color: color, in: state) { commands.append(command) }
                }
            }
        }
        let others = nodes.filter { state.textNode($0) == nil }
        if !others.isEmpty { commands.append(ApplyColor(others, target: target, color: color, name: name)) }
        return CommandBatch(ApplyColor(nodes, target: target, color: color, name: name).label, commands)
    }

    /// The colour a text block shows for `list` under the preference.
    static func ref(_ node: OpID, list: AppearanceList, state: EngineState, appliesTo: AppliesTo) -> Wiretuner_Doc_V1_ColorRef {
        guard let text = state.textNode(node) else { return ColorResolver.none }
        switch appliesTo {
        case .text:
            let values = text.length == 0 ? [] : text.values(at: 0)
            for value in values {
                if list == .fills, case .fill(let ref)? = value.value { return ref }
                if list == .strokes, case .stroke(let stroke)? = value.value, stroke != Wiretuner_Doc_V1_BasicStroke() { return stroke.color }
            }
            return list == .fills ? Appearances.inline(red: 0, green: 0, blue: 0) : ColorResolver.none
        case .block:
            let appearance = text.props.blockAppearance
            guard let row = TextBlockAppearance.rows(node, in: state).last(where: { $0.list == list }) else { return ColorResolver.none }
            if list == .fills { return appearance.fills.first { OpID(element: $0.id) == row.element }?.settings.basic.color ?? ColorResolver.none }
            return appearance.strokes.first { OpID(element: $0.id) == row.element }?.settings.basic.color ?? ColorResolver.none
        }
    }

    /// The Fill or Stroke well for a selection of text blocks only; nil otherwise.
    static func well(_ nodes: [OpID], target: ColorTarget, document: DocumentHandle, appliesTo: AppliesTo) -> ColorWellModel? {
        let state = document.state
        guard !nodes.isEmpty, nodes.allSatisfy({ state.textNode($0) != nil }) else { return nil }
        let refs = nodes.flatMap { node in target.lists.map { ref(node, list: $0, state: state, appliesTo: appliesTo) } }
        return ColorWellModel(ref: refs.allSatisfy { $0 == refs[0] } ? refs[0] : nil, state: state, documentID: document.id)
    }
}
