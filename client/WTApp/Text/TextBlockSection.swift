import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTText

/// The Object panel's *Text Block* section (text-blocks.adoc, "The Text Block section of the
/// Object panel"; TYPE-006, with TYPE-040's *Direction* pop-up): width and height, the *Auto width*
/// and *Auto height* buttons, the four insets and *Display border*, over every selected text block.
/// A value the blocks do not share shows as mixed, and an edit writes only the register it names --
/// one `SetTextBlock` per block, one change for all of them.
extension ObjectPanelModel {
    struct TextBlockSection: Equatable {
        struct Block: Equatable {
            var node: OpID
            var props: Wiretuner_Doc_V1_TextBlockProps
            /// The size the block is laid out at (an auto dimension's current value).
            var laidOut: Size
        }

        let blocks: [Block]

        var nodes: [OpID] { blocks.map(\.node) }
        var autoWidth: MixedState { MixedState(blocks.map(\.props.autoWidth)) }
        var autoHeight: MixedState { MixedState(blocks.map(\.props.autoHeight)) }
        var displayBorder: MixedState { MixedState(blocks.map(\.props.displayBorder)) }

        /// The width each block shows: its fixed width, or for an auto width the laid-out one; a
        /// width at or below 0 shows as the 1 pt it is laid out at (text-blocks.adoc, read-time
        /// normalizations).
        var width: Double? { shared(blocks.map { Self.shown($0.props.autoWidth ? $0.laidOut.width : $0.props.width) }) }
        var height: Double? { shared(blocks.map { Self.shown($0.props.autoHeight ? $0.laidOut.height : $0.props.height) }) }
        var insetLeft: Double? { shared(blocks.map(\.props.inset.left)) }
        var insetRight: Double? { shared(blocks.map(\.props.inset.right)) }
        var insetTop: Double? { shared(blocks.map(\.props.inset.top)) }
        var insetBottom: Double? { shared(blocks.map(\.props.inset.bottom)) }
        /// Horizontal or vertical; nil when the blocks differ.
        var direction: Wiretuner_Doc_V1_WritingDirection? {
            shared(blocks.map { $0.props.direction == .vertical ? Wiretuner_Doc_V1_WritingDirection.vertical : .horizontal })
        }

        static func shown(_ value: Double) -> Double { value > 0 ? value : 1 }
    }

    /// The inset sides with their register below `TextBlockProps.inset` (field 5).
    enum InsetSide: UInt32, CaseIterable, Sendable {
        case left = 1, right = 2, top = 3, bottom = 4

        var title: String {
            switch self {
            case .left: "Left"
            case .right: "Right"
            case .top: "Top"
            case .bottom: "Bottom"
            }
        }
    }

    /// The section, when every selected object is a text block.
    var textBlock: TextBlockSection? {
        let state = document.state
        let ids = selection.ids.map(\.opID)
        guard !ids.isEmpty, ids.allSatisfy({ state.nodeKind($0) == .text }) else { return nil }
        return TextBlockSection(blocks: ids.map { node in
            let props = state.props(node).text.block
            let laidOut = document.textLayout(for: node)?.sizes.first ?? Size(width: props.width, height: props.height)
            return TextBlockSection.Block(node: node, props: props, laidOut: laidOut)
        })
    }

    /// One change writing `fields` of `block` to every selected block (`build` fills each block's
    /// values from its current ones).
    private func writeBlocks(_ label: String, fields: [[UInt32]], _ build: (TextBlockSection.Block) -> Wiretuner_Doc_V1_TextBlockProps) -> (any WTModel.Command)? {
        guard let section = textBlock else { return nil }
        return CommandBatch(label, section.blocks.map { SetTextBlock(node: $0.node, block: build($0), fields: fields, label: label) })
    }

    /// *Width* (fixed width, points; at least 1 pt).
    func setBlockWidth(_ width: Double) -> (any WTModel.Command)? {
        guard width.isFinite, width > 0 else { return nil }
        return writeBlocks("Text Block Width", fields: [[3]]) { _ in .with { $0.width = Measure.rounded(width) } }
    }

    func setBlockHeight(_ height: Double) -> (any WTModel.Command)? {
        guard height.isFinite, height > 0 else { return nil }
        return writeBlocks("Text Block Height", fields: [[4]]) { _ in .with { $0.height = Measure.rounded(height) } }
    }

    /// btn:[Auto width]: every block auto-expanding, or -- when every one already is -- every one
    /// fixed at the width it has now (text-blocks.adoc, "Fixed-size or auto-expanding").
    func toggleAutoWidth() -> (any WTModel.Command)? {
        guard let section = textBlock else { return nil }
        let fix = section.autoWidth == .on
        return writeBlocks(fix ? "Fixed Width" : "Auto Width", fields: fix ? [[1], [3]] : [[1]]) { block in
            .with {
                $0.autoWidth = !fix
                if fix { $0.width = Measure.rounded(TextBlockSection.shown(block.laidOut.width)) }
            }
        }
    }

    func toggleAutoHeight() -> (any WTModel.Command)? {
        guard let section = textBlock else { return nil }
        let fix = section.autoHeight == .on
        return writeBlocks(fix ? "Fixed Height" : "Auto Height", fields: fix ? [[2], [4]] : [[2]]) { block in
            .with {
                $0.autoHeight = !fix
                if fix { $0.height = Measure.rounded(TextBlockSection.shown(block.laidOut.height)) }
            }
        }
    }

    /// One inset side (any finite value: negative lets the text hang outside).
    func setInset(_ side: InsetSide, _ value: Double) -> (any WTModel.Command)? {
        guard value.isFinite else { return nil }
        return writeBlocks("Inset", fields: [[5, side.rawValue]]) { _ in
            .with {
                switch side {
                case .left: $0.inset.left = value
                case .right: $0.inset.right = value
                case .top: $0.inset.top = value
                case .bottom: $0.inset.bottom = value
                }
            }
        }
    }

    func setDisplayBorder(_ on: Bool) -> (any WTModel.Command)? {
        writeBlocks("Display Border", fields: [[6]]) { _ in .with { $0.displayBorder = on } }
    }

    /// *Direction* (text-effects.adoc, "Vertical text").
    func setDirection(_ direction: Wiretuner_Doc_V1_WritingDirection) -> (any WTModel.Command)? {
        writeBlocks("Direction", fields: [[9]]) { _ in .with { $0.direction = direction } }
    }
}

/// The Text Block section: Width, Height, Auto width, Auto height, the insets, Display border and
/// Direction.
struct TextBlockSectionView: View {
    let section: ObjectPanelModel.TextBlockSection
    let model: ObjectPanelModel

    static let mixed = "Mixed"
    static let directions: [(direction: Wiretuner_Doc_V1_WritingDirection, title: String)] = [(.horizontal, "Horizontal"), (.vertical, "Vertical")]
    /// What a vertical block ignores (text-effects.adoc, "Vertical text").
    static let verticalNote = "Tabs, columns, rows and text on a path are ignored in a vertical block."

    static func width(_ model: ObjectPanelModel) -> (Double) -> Void { { model.perform(model.setBlockWidth($0)) } }
    static func height(_ model: ObjectPanelModel) -> (Double) -> Void { { model.perform(model.setBlockHeight($0)) } }
    static func autoWidth(_ model: ObjectPanelModel) -> () -> Void { { model.perform(model.toggleAutoWidth()) } }
    static func autoHeight(_ model: ObjectPanelModel) -> () -> Void { { model.perform(model.toggleAutoHeight()) } }

    static func inset(_ model: ObjectPanelModel, _ side: ObjectPanelModel.InsetSide) -> (Double) -> Void {
        { model.perform(model.setInset(side, $0)) }
    }

    static func displayBorder(_ section: ObjectPanelModel.TextBlockSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        Binding(get: { section.displayBorder.isOn }, set: { model.perform(model.setDisplayBorder($0)) })
    }

    static func direction(_ section: ObjectPanelModel.TextBlockSection, _ model: ObjectPanelModel) -> Binding<String> {
        Binding(get: { section.direction.flatMap { value in directions.first { $0.direction == value }?.title } ?? mixed },
                set: { chosen in if let value = directions.first(where: { $0.title == chosen })?.direction { model.perform(model.setDirection(value)) } })
    }

    static func inset(_ section: ObjectPanelModel.TextBlockSection, _ side: ObjectPanelModel.InsetSide) -> Double? {
        switch side {
        case .left: section.insetLeft
        case .right: section.insetRight
        case .top: section.insetTop
        case .bottom: section.insetBottom
        }
    }

    var body: some View {
        Form {
            MeasureField(title: "Width", value: section.width, unit: model.unit, identifier: "object.textBlock.width", commit: Self.width(model))
                .disabled(section.autoWidth == .on)
            MeasureField(title: "Height", value: section.height, unit: model.unit, identifier: "object.textBlock.height", commit: Self.height(model))
                .disabled(section.autoHeight == .on)
            HStack {
                Button(action: Self.autoWidth(model)) { Label("Auto width", systemImage: section.autoWidth.isOn ? "arrow.left.and.right.square.fill" : "arrow.left.and.right.square") }
                    .accessibilityIdentifier("object.textBlock.autoWidth")
                    .accessibilityValue(PathSectionView.accessibilityValue(section.autoWidth))
                Button(action: Self.autoHeight(model)) { Label("Auto height", systemImage: section.autoHeight.isOn ? "arrow.up.and.down.square.fill" : "arrow.up.and.down.square") }
                    .accessibilityIdentifier("object.textBlock.autoHeight")
                    .accessibilityValue(PathSectionView.accessibilityValue(section.autoHeight))
            }
            ForEach(ObjectPanelModel.InsetSide.allCases, id: \.self) { side in
                MeasureField(title: "Inset \(side.title.lowercased())", value: Self.inset(section, side), unit: model.unit,
                             identifier: "object.textBlock.inset.\(side.title.lowercased())", commit: Self.inset(model, side))
            }
            Toggle("Display border", isOn: Self.displayBorder(section, model))
                .accessibilityIdentifier("object.textBlock.displayBorder")
                .accessibilityValue(PathSectionView.accessibilityValue(section.displayBorder))
            Picker("Direction", selection: Self.direction(section, model)) {
                if section.direction == nil { Text(Self.mixed).tag(Self.mixed) }
                ForEach(Self.directions, id: \.title) { Text($0.title).tag($0.title) }
            }
            .accessibilityIdentifier("object.textBlock.direction")
            if section.direction == .vertical {
                Text(Self.verticalNote).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("object.textBlock.verticalNote")
            }
        }
        .padding(.horizontal)
    }
}
