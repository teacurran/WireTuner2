import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The Object panel's Text section (type-specifications.adoc, "The Character section"; the basic
/// part of TYPE-020): font family, face and size, and paragraph alignment.  While the Text tool
/// edits one of the selected blocks the section formats its selection -- one mark over a range,
/// or at an insertion point the pending format for the next typed characters, which writes
/// nothing -- and otherwise the whole of every selected block, one change for all of them.  A
/// value the text does not share shows as mixed.
extension ObjectPanelModel {
    struct TextSection: Equatable {
        /// The blocks the section formats.
        let nodes: [OpID]
        /// Whether it formats the Text tool's selection rather than whole blocks.
        let editing: Bool
        /// The shared value of each attribute; nil when the text differs.
        let family: String?
        let style: String?
        let size: Double?
        let alignment: Wiretuner_Doc_V1_Alignment?
    }

    /// What text without a family, face or size mark is set in (WTText's defaults).
    static let defaultFamily = "Helvetica"
    static let defaultStyle = "Regular"
    static let defaultSize = 12.0

    /// The Text tool's session when it edits one of the selected blocks, or a text block inside the
    /// selected instance (its text override, LIB-027).
    var editingText: TextEditingSession? {
        guard let session = textSession, let node = session.node ?? session.override?.instance, selection.ids.contains(SelectionID(node)),
              session.isLive else { return nil }
        return session
    }

    /// The selected text blocks.
    private var textNodes: [OpID] {
        selection.ids.compactMap { id in document.object(for: id)?.kind == .text ? id.opID : nil }
    }

    /// The section, when every selected object is a text block, or while the Text tool edits a
    /// text block inside the selected instance (its `nodes` then the instance).
    var text: TextSection? {
        let override = editingText?.override
        let nodes = override.map { [$0.instance] } ?? textNodes
        guard !nodes.isEmpty, nodes.count == selection.ids.count else { return nil }
        let runs: [[Wiretuner_Doc_V1_TextMarkValue]]
        let paragraphs: [Wiretuner_Doc_V1_ParagraphProps]
        if let session = editingText {
            runs = session.formatRuns
            paragraphs = session.paragraphProps
        } else {
            let state = document.state
            let texts = nodes.compactMap { state.textNode($0) }
            runs = texts.flatMap { text in text.length == 0 ? [[]] : text.runs.map(\.values) }
            paragraphs = texts.flatMap { $0.paragraphs.map(\.props) }
        }
        func shared<Value: Hashable>(_ read: ([Wiretuner_Doc_V1_TextMarkValue]) -> Value) -> Value? {
            let values = Set(runs.map(read))
            return values.count == 1 ? values.first : nil
        }
        let alignments = Set(paragraphs.map { $0.alignment == .unspecified ? .left : $0.alignment })
        return TextSection(
            nodes: nodes, editing: editingText != nil,
            family: shared { Self.family($0) }, style: shared { Self.style($0) }, size: shared { Self.size($0) },
            alignment: alignments.count == 1 ? alignments.first : nil
        )
    }

    static func family(_ values: [Wiretuner_Doc_V1_TextMarkValue]) -> String {
        for value in values { if case .fontFamily(let family)? = value.value, !family.isEmpty { return family } }
        return defaultFamily
    }

    static func style(_ values: [Wiretuner_Doc_V1_TextMarkValue]) -> String {
        for value in values { if case .fontStyle(let style)? = value.value, !style.isEmpty { return style } }
        return defaultStyle
    }

    static func size(_ values: [Wiretuner_Doc_V1_TextMarkValue]) -> Double {
        for value in values { if case .size(let size)? = value.value, size > 0 { return size } }
        return defaultSize
    }

    // MARK: Commands

    /// Formats with one character attribute: the Text tool's selection (or its pending format),
    /// else every selected block whole, as one change.
    @discardableResult
    func formatText(_ value: Wiretuner_Doc_V1_TextMarkValue) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        if let session = editingText { return session.format(value) }
        guard let section = text else { return nil }
        return perform(CommandBatch(TextMarks.label(value), section.nodes.map { ApplyMark(node: $0, from: .start, to: .end, value: value) }))
    }

    /// A family (one `font_family` mark).
    @discardableResult
    func setFontFamily(_ family: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard !family.isEmpty else { return nil }
        return formatText(.with { $0.fontFamily = family })
    }

    @discardableResult
    func setFontStyle(_ style: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard !style.isEmpty else { return nil }
        return formatText(.with { $0.fontStyle = style })
    }

    /// Sizes from 0.1 to 10,000 points (creating-text, read-time normalizations).
    @discardableResult
    func setFontSize(_ size: Double) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard size.isFinite, size >= 0.1, size <= 10_000 else { return nil }
        return formatText(.with { $0.size = size })
    }

    /// Aligns the Text tool's paragraphs, else every paragraph of the selected blocks.
    @discardableResult
    func setAlignment(_ alignment: Wiretuner_Doc_V1_Alignment) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        if let session = editingText { return session.align(alignment) }
        guard let section = text else { return nil }
        return perform(CommandBatch("Alignment", section.nodes.map {
            SetParagraph(node: $0, from: .start, to: .end, props: .with { $0.alignment = alignment }, fields: [[1]], label: "Alignment")
        }))
    }
}

/// The Text section: Font and Style pop-ups, Size, Alignment.
struct TextSectionView: View {
    let section: ObjectPanelModel.TextSection
    let model: ObjectPanelModel

    static let mixed = "Mixed"
    static let alignments: [(alignment: Wiretuner_Doc_V1_Alignment, title: String)] = [
        (.left, "Left"), (.center, "Center"), (.right, "Right"), (.justified, "Justified"),
    ]

    /// The families the Font pop-up offers: the installed ones, and the section's own when it is
    /// not installed (a missing font still shows its name).
    static func families(including current: String?) -> [String] {
        var families = NSFontManager.shared.availableFontFamilies
        if let current, !families.contains(current) { families.insert(current, at: 0) }
        return families
    }

    /// The faces of `family` the Style pop-up offers, and the current one when the family lacks it.
    static func styles(of family: String?, including current: String?) -> [String] {
        // Each member is [PostScript name, face name, weight, traits].
        var styles = (family.flatMap { NSFontManager.shared.availableMembers(ofFontFamily: $0) } ?? []).compactMap { $0.dropFirst().first as? String }
        if styles.isEmpty { styles = [ObjectPanelModel.defaultStyle] }
        if let current, !styles.contains(current) { styles.insert(current, at: 0) }
        return styles
    }

    static func family(_ section: ObjectPanelModel.TextSection, _ model: ObjectPanelModel) -> Binding<String> {
        Binding(get: { section.family ?? mixed }, set: { if $0 != mixed { model.setFontFamily($0) } })
    }

    static func style(_ section: ObjectPanelModel.TextSection, _ model: ObjectPanelModel) -> Binding<String> {
        Binding(get: { section.style ?? mixed }, set: { if $0 != mixed { model.setFontStyle($0) } })
    }

    /// The Size field's commit.
    static func size(_ model: ObjectPanelModel) -> (Double) -> Void {
        { model.setFontSize($0) }
    }

    static func alignment(_ section: ObjectPanelModel.TextSection, _ model: ObjectPanelModel) -> Binding<String> {
        Binding(get: { section.alignment.flatMap { value in alignments.first { $0.alignment == value }?.title } ?? mixed },
                set: { chosen in if let value = alignments.first(where: { $0.title == chosen })?.alignment { model.setAlignment(value) } })
    }

    var body: some View {
        Form {
            Picker("Font", selection: Self.family(section, model)) {
                if section.family == nil { Text(Self.mixed).tag(Self.mixed) }
                ForEach(Self.families(including: section.family), id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("object.text.family")
            FontSubstitutionBadge(family: section.family, substitute: model.substitute(for: section))
            Picker("Style", selection: Self.style(section, model)) {
                if section.style == nil { Text(Self.mixed).tag(Self.mixed) }
                ForEach(Self.styles(of: section.family, including: section.style), id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("object.text.style")
            CommitField(title: "Size", value: section.size, identifier: "object.text.size", commit: Self.size(model))
            Picker("Alignment", selection: Self.alignment(section, model)) {
                if section.alignment == nil { Text(Self.mixed).tag(Self.mixed) }
                ForEach(Self.alignments, id: \.title) { Text($0.title).tag($0.title) }
            }
            .accessibilityIdentifier("object.text.alignment")
        }
        .padding(.horizontal)
    }
}
