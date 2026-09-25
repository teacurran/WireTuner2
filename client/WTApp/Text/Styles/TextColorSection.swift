import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTRender

/// The Object panel's text colour rows (text-color.adoc; the WTApp rows of TYPE-029): the glyphs'
/// *Fill* (a colour well; *None* draws the text clear) and *Stroke* (on or off, 1 pt black when
/// added), and the block's own *Background* fill and *Border* stroke (adding the first turns
/// *Display border* on).  Each is one change over the targeted text or the selected blocks.
extension ObjectPanelModel {
    struct TextColorSection: Equatable {
        let nodes: [OpID]
        /// The glyph fill every targeted run has (black when none is set); nil when they differ.
        let fill: RenderColor?
        let fillNone: Bool
        /// Whether every targeted run has a glyph stroke; nil when they differ.
        let stroke: Bool?
        /// The first block's own fill and stroke rows.
        let blockFill: AppearanceRow?
        let blockStroke: AppearanceRow?
    }

    var textColor: TextColorSection? {
        guard let text else { return nil }
        let state = document.state
        let resolver = SwatchList(state).resolver
        let runs = targetRuns
        let fills = runs.map { values -> Wiretuner_Doc_V1_ColorRef? in
            for value in values { if case .fill(let ref)? = value.value { return ref } }
            return nil
        }
        let colors = Set(fills.map { ref -> RenderColor? in ref.map { resolver.color($0) } ?? .black })
        let strokes = Set(runs.map { values in values.contains { if case .stroke? = $0.value { true } else { false } } })
        // The section needs a block, so `nodes` is never empty.
        let rows = TextBlockAppearance.rows(text.nodes[0], in: state)
        return TextColorSection(nodes: text.nodes, fill: colors.count == 1 ? colors.first! : nil, fillNone: !fills.isEmpty && fills.allSatisfy { $0?.none == true },
                                stroke: strokes.count == 1 ? strokes.first : nil, blockFill: rows.first { $0.list == .fills },
                                blockStroke: rows.first { $0.list == .strokes })
    }

    /// The glyph fill: `color`, or *None*.
    @discardableResult
    func setTextFill(_ color: RenderColor?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let commands = textTargets.map { target in
            color.map { TextColor.fill(node: target.node, from: target.from, to: target.to, ColorResolver.inline($0)) }
                ?? TextColor.removeFill(node: target.node, from: target.from, to: target.to)
        }
        return commands.isEmpty ? nil : perform(CommandBatch(color == nil ? "Remove Fill" : "Fill", commands))
    }

    /// The glyph stroke on (1 pt black) or off.
    @discardableResult
    func setTextStroke(_ on: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let commands = textTargets.map { target in
            on ? TextColor.stroke(node: target.node, from: target.from, to: target.to) : TextColor.removeStroke(node: target.node, from: target.from, to: target.to)
        }
        return commands.isEmpty ? nil : perform(CommandBatch(on ? "Stroke" : "Remove Stroke", commands))
    }

    /// The block's *Background* or *Border* row added to each selected block that lacks it, or
    /// removed from each that has it.
    @discardableResult
    func setBlockRow(_ list: AppearanceList, on: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let section = textColor else { return nil }
        let state = document.state
        let commands: [any WTModel.Command] = section.nodes.compactMap { node in
            let row = TextBlockAppearance.rows(node, in: state).first { $0.list == list }
            if on { return row == nil ? (list == .strokes ? AddTextBlockAppearance.stroke(node) : AddTextBlockAppearance.fill(node, Appearances.basicFill(red: 1, green: 1, blue: 1))) : nil }
            return row.map { RemoveTextBlockAppearance(node: node, row: $0) }
        }
        return commands.isEmpty ? nil : perform(CommandBatch(list == .strokes ? "Border" : "Background", commands))
    }
}

/// The rows' view.
struct TextColorSectionView: View {
    let section: ObjectPanelModel.TextColorSection
    let model: ObjectPanelModel

    static func fillBinding(_ section: ObjectPanelModel.TextColorSection, _ model: ObjectPanelModel) -> Binding<CGColor> {
        Binding(get: { (section.fill ?? .black).cgColor }, set: { color in
            let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) ?? .black
            model.setTextFill(RenderColor(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent)))
        })
    }

    static func clearing(_ model: ObjectPanelModel) -> () -> Void {
        { model.setTextFill(nil) }
    }

    static func strokeBinding(_ section: ObjectPanelModel.TextColorSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        Binding(get: { section.stroke ?? false }, set: { model.setTextStroke($0) })
    }

    static func blockBinding(_ list: AppearanceList, _ row: AppearanceRow?, _ model: ObjectPanelModel) -> Binding<Bool> {
        Binding(get: { row != nil }, set: { model.setBlockRow(list, on: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ColorPicker("Text fill", selection: Self.fillBinding(section, model), supportsOpacity: false).accessibilityIdentifier("object.text.fill")
                Button("None", action: Self.clearing(model)).disabled(section.fillNone).accessibilityIdentifier("object.text.fillNone")
            }
            Toggle("Text stroke", isOn: Self.strokeBinding(section, model)).accessibilityIdentifier("object.text.stroke")
            Toggle("Block background", isOn: Self.blockBinding(.fills, section.blockFill, model)).accessibilityIdentifier("object.text.blockFill")
            Toggle("Block border", isOn: Self.blockBinding(.strokes, section.blockStroke, model)).accessibilityIdentifier("object.text.blockStroke")
        }
    }
}
