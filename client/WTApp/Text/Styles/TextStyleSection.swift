import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The Object panel's text style pop-ups (text-styles.adoc; the WTApp half of TYPE-034 and the
/// Character-section part of TYPE-035): *Style* lists Normal Text and the paragraph styles,
/// *Character style* *None* and the character styles, each showing what the selected paragraphs
/// or runs share (blank when they differ) and a *+* when the text overrides its style; choosing one
/// applies it as one change.  The *Styles* menu beside them makes a style from the selection
/// (the attributes it shares), redefines the current style from the selection, renames and
/// removes it.
extension ObjectPanelModel {
    struct TextStyleSection: Equatable {
        let paragraphStyles: [TextStyle]
        let characterStyles: [TextStyle]
        /// The paragraph style every targeted paragraph has (Normal Text's id when it is Normal);
        /// nil when they differ or there is no Normal Text.
        let paragraphStyle: OpID?
        /// The character style every targeted run has; `.some(nil)` for *None*, nil when they differ.
        let characterStyle: OpID??
        /// Whether a targeted paragraph differs from its style (the *+*).
        let overridden: Bool
    }

    static let noneStyle = "None"

    var textStyle: TextStyleSection? {
        guard text != nil else { return nil }
        let styles = document.state.textStyles
        let paragraphs = targetParagraphs
        let paragraphIDs = Set(paragraphs.map { styles.paragraphStyle($0.text.paragraphs[$0.index].props).style })
        let characterIDs = Set(targetRuns.map { values -> OpID? in
            for value in values { if case .style(let ref)? = value.value { return styles.reference(ref, kind: .character)?.style } }
            return nil
        })
        let overridden = paragraphs.contains { paragraph in
            let found = styles.overrides(in: paragraph.text, paragraph: paragraph.index)
            return !found.paragraph.isEmpty || !found.character.isEmpty
        }
        return TextStyleSection(paragraphStyles: styles.styles(.paragraph), characterStyles: styles.styles(.character),
                                paragraphStyle: paragraphIDs.count == 1 ? paragraphIDs.first! : nil,
                                characterStyle: characterIDs.count == 1 ? .some(characterIDs.first!) : nil, overridden: overridden)
    }

    /// *Style*: `style` on every targeted paragraph, one change.
    @discardableResult
    func applyParagraphStyle(_ style: OpID) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let targets = textTargets
        guard !targets.isEmpty else { return nil }
        return perform(CommandBatch("Apply style", targets.map { ApplyParagraphStyle(node: $0.node, from: $0.from, to: $0.to, style: style) }))
    }

    /// *Character style*: `style` over the targets, or *None* (the cleared `style` mark).
    @discardableResult
    func applyCharacterStyle(_ style: OpID?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let targets = textTargets.filter { !$0.range.isEmpty || editingText == nil }
        guard !targets.isEmpty else { return nil }
        let commands: [any WTModel.Command] = targets.map { target in
            guard let style else { return ApplyMark(node: target.node, from: target.from, to: target.to, value: .with { $0.style = Wiretuner_Doc_V1_NodeRef() }) }
            return ApplyCharacterStyle(node: target.node, from: target.from, to: target.to, style: style)
        }
        return perform(CommandBatch("Apply style", commands))
    }

    /// The attributes the targeted text shares.
    var sharedTextAttributes: Wiretuner_Doc_V1_TextStyleAttrs {
        SharedTextAttributes.attrs(runs: targetRuns, paragraphs: targetParagraphs.map { $0.text.paragraphs[$0.index].props })
    }

    /// *New Paragraph Style* / *New Character Style*: a style from what the selection shares (a
    /// character style takes no paragraph settings), based on the current paragraph style.
    @discardableResult
    func newTextStyle(_ kind: TextStyleKind) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let section = textStyle else { return nil }
        var attrs = sharedTextAttributes
        if kind == .character { attrs.clearParagraph() }
        let parent = kind == .paragraph ? section.paragraphStyle : nil
        return perform(CreateTextStyle(kind, attrs: attrs, basedOn: parent))
    }

    /// *Redefine…*: the current paragraph style takes what the selection shares.
    @discardableResult
    func redefineParagraphStyle() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        // A shared paragraph style is a live style.
        guard let style = textStyle?.paragraphStyle else { return nil }
        let attrs = sharedTextAttributes
        return perform(EditTextStyle(style, attrs: attrs, fields: SharedTextAttributes.fields(attrs), name: document.state.textStyles.style(style)!.name))
    }

    @discardableResult
    func renameTextStyle(_ style: OpID, to name: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return perform(RenameTextStyle(style, to: trimmed))
    }

    @discardableResult
    func removeTextStyle(_ style: OpID) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        perform(RemoveTextStyle(style))
    }
}

/// The section's view.
struct TextStyleSectionView: View {
    let section: ObjectPanelModel.TextStyleSection
    let model: ObjectPanelModel
    @State private var renaming = false
    @State private var newName = ""

    /// The pop-up's title for a style: its name, with *+* when the text overrides it.
    static func title(_ style: TextStyle, overridden: Bool, current: Bool) -> String {
        style.name + (overridden && current ? " +" : "")
    }

    static func paragraphBinding(_ section: ObjectPanelModel.TextStyleSection, _ model: ObjectPanelModel) -> Binding<String> {
        Binding(get: { section.paragraphStyle.map(\.description) ?? "" },
                set: { id in if let style = section.paragraphStyles.first(where: { $0.id.description == id }) { model.applyParagraphStyle(style.id) } })
    }

    static func characterBinding(_ section: ObjectPanelModel.TextStyleSection, _ model: ObjectPanelModel) -> Binding<String> {
        Binding(get: {
            guard let current = section.characterStyle else { return "" }
            return current.map(\.description) ?? ObjectPanelModel.noneStyle
        }, set: { id in
            model.applyCharacterStyle(section.characterStyles.first { $0.id.description == id }?.id)
        })
    }

    static func renamingAction(_ section: ObjectPanelModel.TextStyleSection, _ model: ObjectPanelModel, name: String) -> () -> Void {
        { if let style = section.paragraphStyle { model.renameTextStyle(style, to: name) } }
    }

    static func newStyle(_ kind: TextStyleKind, _ model: ObjectPanelModel) -> () -> Void {
        { model.newTextStyle(kind) }
    }

    static func redefining(_ model: ObjectPanelModel) -> () -> Void {
        { model.redefineParagraphStyle() }
    }

    static func removing(_ section: ObjectPanelModel.TextStyleSection, _ model: ObjectPanelModel) -> () -> Void {
        { if let style = section.paragraphStyle { model.removeTextStyle(style) } }
    }

    static func showing(_ flag: Binding<Bool>) -> () -> Void {
        { flag.wrappedValue = true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Style", selection: Self.paragraphBinding(section, model)) {
                    if section.paragraphStyle == nil { Text("").tag("") }
                    ForEach(section.paragraphStyles, id: \.id) { style in
                        Text(Self.title(style, overridden: section.overridden, current: style.id == section.paragraphStyle)).tag(style.id.description)
                    }
                }
                .accessibilityIdentifier("object.text.paragraphStyle")
                Menu("Styles") {
                    Button("New Paragraph Style", action: Self.newStyle(.paragraph, model))
                    Button("New Character Style", action: Self.newStyle(.character, model))
                    Button("Redefine…", action: Self.redefining(model)).disabled(section.paragraphStyle == nil)
                    Button("Rename…", action: Self.showing($renaming)).disabled(section.paragraphStyle == nil)
                    Button("Remove", action: Self.removing(section, model)).disabled(section.paragraphStyle == nil)
                }
                .fixedSize()
                .accessibilityIdentifier("object.text.styles")
            }
            Picker("Character style", selection: Self.characterBinding(section, model)) {
                if section.characterStyle == nil { Text("").tag("") }
                Text(ObjectPanelModel.noneStyle).tag(ObjectPanelModel.noneStyle)
                ForEach(section.characterStyles, id: \.id) { style in Text(style.name).tag(style.id.description) }
            }
            .accessibilityIdentifier("object.text.characterStyle")
            if renaming {
                HStack {
                    TextField("Name", text: $newName).accessibilityIdentifier("object.text.styleName")
                    Button("Rename", action: Self.renamingAction(section, model, name: newName))
                }
            }
        }
    }
}
