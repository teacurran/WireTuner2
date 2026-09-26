import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The style row at the top of the Object panel's properties list (styles.adoc, "Object panel
/// integration"; LIB-021): the selected objects' graphic style -- or, with nothing selected, the
/// style the default attributes mirror -- with its preview, a plus sign when the objects override
/// it (or the defaults differ from it), btn:[Redefine] and a pop-up to change style.  It works
/// through a `StylesPanelModel` of the front window: a pop-up choice is the panel's click
/// (`ApplyGraphicStyle`, or `SelectGraphicStyleAsDefaults` with nothing selected), btn:[Redefine]
/// is the Redefine flow's command (`RedefineGraphicStyle` from the first selected object, else the
/// defaults) without its sheet, and the preview drags as a `StyleDrag` onto the Styles panel or an
/// object.  The overridden rows' dots and *Clear Override* are `StyleOverrideMarks`.
struct ObjectStyleRowState: Equatable {
    /// The style shown; nil when the selected objects use different styles (or none).
    let style: OpID?
    let name: String
    let isModified: Bool
    /// The pop-up's styles.
    let styles: [(id: OpID, name: String)]

    static func == (a: ObjectStyleRowState, b: ObjectStyleRowState) -> Bool {
        a.style == b.style && a.name == b.name && a.isModified == b.isModified && a.styles.map(\.id) == b.styles.map(\.id) && a.styles.map(\.name) == b.styles.map(\.name)
    }

    static let mixed = "Mixed"
    static let none = "No style"

    /// The row of `model`'s front window; nil without a document or graphic styles.
    @MainActor
    init?(_ model: StylesPanelModel) {
        let rows = model.rows
        guard model.document != nil, !rows.isEmpty else { return nil }
        let highlighted = rows.filter(\.isHighlighted)
        let shown = highlighted.count == 1 ? highlighted[0] : nil
        style = shown?.id
        name = shown?.name ?? (highlighted.isEmpty ? Self.none : Self.mixed)
        isModified = highlighted.contains { $0.isModified }
        styles = rows.map { ($0.id, $0.name) }
    }
}

@MainActor
enum ObjectStyleRowActions {
    /// btn:[Redefine]: the shown style takes the first selected object's look, or the defaults'.
    @discardableResult
    static func redefine(_ model: StylesPanelModel) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let state = model.document?.state, let row = ObjectStyleRowState(model), let style = row.style, row.isModified else { return nil }
        return model.perform(RedefineGraphicStyle(style, from: model.canvasObjects.first.map { .object($0) } ?? .defaults, in: state))
    }

    /// The pop-up: the chosen style applied (or made the defaults).
    static func choice(_ row: ObjectStyleRowState, _ model: StylesPanelModel) -> Binding<String> {
        Binding(get: { row.style?.description ?? row.name }, set: { choice in
            if let style = row.styles.first(where: { $0.id.description == choice })?.id { model.click(style) }
        })
    }

    /// The preview's drag: the style, for the Styles panel or an object.
    static func drag(_ row: ObjectStyleRowState, _ model: StylesPanelModel) -> NSItemProvider {
        row.style.flatMap(model.dragPayload)?.itemProvider ?? NSItemProvider()
    }
}

struct ObjectStyleRow: View {
    let model: StylesPanelModel

    /// The app's row model (the front window's styles); set when the features install.
    @MainActor static var shared: StylesPanelModel?

    var body: some View {
        if let row = ObjectStyleRowState(model) {
            HStack(spacing: 6) {
                Group {
                    if let style = row.style, let image = model.preview(style) {
                        Image(decorative: image, scale: 2)
                    } else {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary).frame(width: 30, height: 20)
                    }
                }
                .onDrag { ObjectStyleRowActions.drag(row, model) }
                .accessibilityIdentifier("objectStyle.preview")
                Picker("Style", selection: ObjectStyleRowActions.choice(row, model)) {
                    if row.style == nil { Text(row.name).tag(row.name) }
                    ForEach(row.styles, id: \.id) { Text($0.name).tag($0.id.description) }
                }
                .labelsHidden()
                .accessibilityIdentifier("objectStyle.popup")
                if row.isModified {
                    Text("+").bold().help("Differs from the style").accessibilityIdentifier("objectStyle.plus")
                }
                Spacer()
                Button("Redefine") { ObjectStyleRowActions.redefine(model) }
                    .disabled(!row.isModified || row.style == nil)
                    .accessibilityIdentifier("objectStyle.redefine")
            }
            .accessibilityIdentifier("objectStyle")
        }
    }
}

/// The overridden rows' dots and the row's *Clear Override* (LIB-021): an object with a style
/// overrides each category it sets that the style governs; with several objects, what the first
/// overrides.
@MainActor
enum StyleOverrideMarks {
    /// The lists whose rows show the dot for `list`'s targets.
    static func lists(_ list: AttributesListModel) -> Set<AppearanceList> {
        guard !list.isDefaults, let first = list.targets.first else { return [] }
        let categories = GraphicStyleDefaults.overrides(of: first, in: list.document.state)
        return Set(AppearanceList.allCases.filter { categories.contains(StyleCategory($0)) })
    }

    /// *Clear Override* on `item`'s row: one change over the targets.
    static func clear(_ item: AttributeRowItem, list: AttributesListModel) -> (any WTModel.Command)? {
        guard lists(list).contains(item.list) else { return nil }
        return ClearGraphicStyleOverride(list.targets, category: StyleCategory(item.list))
    }
}
