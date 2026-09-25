import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The Object panel's Paragraph section (paragraphs.adoc; TYPE-026): *Space above* and *below*,
/// the *Left*, *Right* and *First line* indents, *Hyphenate* with its sheet, *Hang punctuation*,
/// the *Rules* pop-up with the Paragraph Rule Width sheet, and the Edit Alignment sheet.  Each
/// control writes only its register(s), on every paragraph the Text tool's selection touches, else
/// on every paragraph of the selected blocks, one change; a value the paragraphs do not share
/// shows as mixed.
extension ObjectPanelModel {
    struct ParagraphSection: Equatable {
        let nodes: [OpID]
        let editing: Bool
        let spaceAbove: Double?
        let spaceBelow: Double?
        let leftIndent: Double?
        let rightIndent: Double?
        let firstLineIndent: Double?
        let hyphenate: MixedState
        let hangPunctuation: MixedState
        /// The shared rule mode (unset reads as none); nil when mixed.
        let ruleMode: Wiretuner_Doc_V1_RuleMode?
        /// The first paragraph's settings, what the sheets start from.
        let first: Wiretuner_Doc_V1_ParagraphProps
    }

    /// The paragraph field numbers (`ParagraphProps`).
    enum ParagraphField {
        static let alignment: [UInt32] = [1], raggedWidth: [UInt32] = [2], flushZone: [UInt32] = [3]
        static let leftIndent: [UInt32] = [4], rightIndent: [UInt32] = [5], firstLineIndent: [UInt32] = [6]
        static let spaceAbove: [UInt32] = [7], spaceBelow: [UInt32] = [8], hangPunctuation: [UInt32] = [12]
        static func hyphenation(_ field: UInt32) -> [UInt32] { [10, field] }
        static func rule(_ field: UInt32) -> [UInt32] { [11, field] }
    }

    /// The paragraphs the section reads.
    var paragraphProps: [Wiretuner_Doc_V1_ParagraphProps] {
        guard let section = text else { return [] }
        if let session = editingText { return session.paragraphProps }
        let state = document.state
        return section.nodes.compactMap { state.textNode($0) }.flatMap { $0.paragraphs.map(\.props) }
    }

    var paragraph: ParagraphSection? {
        guard let section = text else { return nil }
        let props = paragraphProps
        // A text always has a paragraph.
        let first = props[0]
        func shared<Value: Hashable>(_ read: (Wiretuner_Doc_V1_ParagraphProps) -> Value) -> Value? {
            let values = Set(props.map(read))
            return values.count == 1 ? values.first : nil
        }
        return ParagraphSection(
            nodes: section.nodes, editing: section.editing, spaceAbove: shared(\.spaceAbove), spaceBelow: shared(\.spaceBelow),
            leftIndent: shared(\.leftIndent), rightIndent: shared(\.rightIndent), firstLineIndent: shared(\.firstLineIndent),
            hyphenate: MixedState(props.map(\.hyphenation.enabled)), hangPunctuation: MixedState(props.map(\.hangPunctuation)),
            ruleMode: shared { $0.rule.mode == .unspecified ? .none : $0.rule.mode }, first: first
        )
    }

    /// Writes the registers `fields` from `props` on the section's paragraphs, one change.
    @discardableResult
    func setParagraph(_ props: Wiretuner_Doc_V1_ParagraphProps, fields: [[UInt32]], label: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let section = text, !fields.isEmpty else { return nil }
        if let session = editingText, let node = session.node, let text = session.text {
            let range = session.selectedRange
            return perform(SetParagraph(node: node, from: text.anchor(at: range.lowerBound), to: text.anchor(at: range.upperBound),
                                        props: props, fields: fields, label: label))
        }
        return perform(CommandBatch(label, section.nodes.map { SetParagraph(node: $0, from: .start, to: .end, props: props, fields: fields, label: label) }))
    }

    /// One numeric register.
    @discardableResult
    func setParagraphValue(_ field: [UInt32], _ value: Double, label: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard value.isFinite else { return nil }
        var props = Wiretuner_Doc_V1_ParagraphProps()
        switch field {
        case ParagraphField.spaceAbove: props.spaceAbove = value
        case ParagraphField.spaceBelow: props.spaceBelow = value
        case ParagraphField.leftIndent: props.leftIndent = value
        case ParagraphField.rightIndent: props.rightIndent = value
        case ParagraphField.firstLineIndent: props.firstLineIndent = value
        case ParagraphField.raggedWidth: props.raggedWidth = min(max(value, 0), 100)
        case ParagraphField.flushZone: props.flushZone = min(max(value, 0), 100)
        default: return nil
        }
        return setParagraph(props, fields: [field], label: label)
    }

    /// *Hyphenate* on or off.
    @discardableResult
    func setHyphenate(_ on: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        setParagraph(.with { $0.hyphenation.enabled = on }, fields: [ParagraphField.hyphenation(1)], label: "Hyphenation")
    }

    /// The Hyphenation sheet's btn:[OK]: language, consecutive hyphens and skip capitalized.
    @discardableResult
    func setHyphenation(_ hyphenation: Wiretuner_Doc_V1_Hyphenation) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        setParagraph(.with { $0.hyphenation = hyphenation }, fields: [2, 3, 4].map { ParagraphField.hyphenation($0) }, label: "Hyphenation")
    }

    /// *Inhibit hyphens in selection*: a `no_hyphen` mark over the characters.
    @discardableResult
    func inhibitHyphens(_ on: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        formatText(.with { $0.noHyphen = on })
    }

    @discardableResult
    func setHangPunctuation(_ on: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        setParagraph(.with { $0.hangPunctuation = on }, fields: [ParagraphField.hangPunctuation], label: "Hang Punctuation")
    }

    /// The *Rules* pop-up: none, centred or paragraph.
    @discardableResult
    func setRuleMode(_ mode: Wiretuner_Doc_V1_RuleMode) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        setParagraph(.with { $0.rule.mode = mode }, fields: [ParagraphField.rule(1)], label: "Paragraph Rule")
    }

    /// The Paragraph Rule Width sheet's btn:[OK]: width, basis, position, above and, with
    /// `overridesStroke`, the stroke override's colour and width.
    @discardableResult
    func setRule(_ rule: Wiretuner_Doc_V1_ParagraphRule, overridesStroke: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        var fields = [2, 3, 4, 5].map { ParagraphField.rule($0) }
        if overridesStroke { fields += [[11, 6, 1], [11, 6, 2]] }
        return setParagraph(.with { $0.rule = rule }, fields: fields, label: "Paragraph Rule")
    }

    /// The Edit Alignment sheet's btn:[OK].
    @discardableResult
    func setAlignmentSettings(raggedWidth: Double, flushZone: Double) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        setParagraph(.with {
            $0.raggedWidth = min(max(raggedWidth, 0), 100)
            $0.flushZone = min(max(flushZone, 0), 100)
        }, fields: [ParagraphField.raggedWidth, ParagraphField.flushZone], label: "Alignment")
    }
}

/// The section's view.
struct ParagraphSectionView: View {
    let section: ObjectPanelModel.ParagraphSection
    let model: ObjectPanelModel
    @State private var sheet: Sheet?

    enum Sheet: String, Identifiable {
        case hyphenation, rule, alignment
        var id: String { rawValue }
    }

    static let rules: [(mode: Wiretuner_Doc_V1_RuleMode, title: String)] = [(.none, "None"), (.centered, "Centered"), (.paragraph, "Paragraph")]
    static let mixed = "Mixed"

    static func commit(_ field: [UInt32], _ label: String, _ model: ObjectPanelModel) -> (Double) -> Void {
        { model.setParagraphValue(field, $0, label: label) }
    }

    static func toggle(_ state: MixedState, _ set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { state.isOn }, set: { set($0) })
    }

    static func rule(_ section: ObjectPanelModel.ParagraphSection, _ model: ObjectPanelModel) -> Binding<String> {
        Binding(get: { section.ruleMode.flatMap { mode in rules.first { $0.mode == mode }?.title } ?? mixed },
                set: { chosen in if let mode = rules.first(where: { $0.title == chosen })?.mode { model.setRuleMode(mode) } })
    }

    static func opening(_ value: Sheet, _ binding: Binding<Sheet?>) -> () -> Void {
        { binding.wrappedValue = value }
    }

    /// The sheet `value` shows, closing through `binding`.
    @ViewBuilder
    static func sheetView(_ value: Sheet, section: ObjectPanelModel.ParagraphSection, model: ObjectPanelModel, close: @escaping () -> Void) -> some View {
        switch value {
        case .hyphenation:
            HyphenationSheet(hyphenation: section.first.hyphenation, editing: section.editing,
                             commit: hyphenationCommit(model, close), inhibit: inhibiting(model), cancel: close)
        case .rule:
            ParagraphRuleSheet(rule: section.first.rule, commit: ruleCommit(model, close), cancel: close)
        case .alignment:
            AlignmentSheet(raggedWidth: raggedWidth(section.first), flushZone: section.first.flushZone, commit: alignmentCommit(model, close), cancel: close)
        }
    }

    static func hyphenationCommit(_ model: ObjectPanelModel, _ close: @escaping () -> Void) -> (Wiretuner_Doc_V1_Hyphenation) -> Void {
        { model.setHyphenation($0); close() }
    }

    static func inhibiting(_ model: ObjectPanelModel) -> (Bool) -> Void {
        { model.inhibitHyphens($0) }
    }

    static func ruleCommit(_ model: ObjectPanelModel, _ close: @escaping () -> Void) -> (Wiretuner_Doc_V1_ParagraphRule, Bool) -> Void {
        { model.setRule($0, overridesStroke: $1); close() }
    }

    static func alignmentCommit(_ model: ObjectPanelModel, _ close: @escaping () -> Void) -> (Double, Double) -> Void {
        { model.setAlignmentSettings(raggedWidth: $0, flushZone: $1); close() }
    }

    /// The ragged width the sheet starts from (unset reads as 100).
    static func raggedWidth(_ props: Wiretuner_Doc_V1_ParagraphProps) -> Double {
        props.raggedWidth == 0 ? 100 : props.raggedWidth
    }

    static func hyphenate(_ section: ObjectPanelModel.ParagraphSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        toggle(section.hyphenate) { model.setHyphenate($0) }
    }

    static func hangPunctuation(_ section: ObjectPanelModel.ParagraphSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        toggle(section.hangPunctuation) { model.setHangPunctuation($0) }
    }

    var body: some View {
        Form {
            CommitField(title: "Space above", value: section.spaceAbove, identifier: "object.paragraph.spaceAbove",
                        commit: Self.commit(ObjectPanelModel.ParagraphField.spaceAbove, "Space Above", model))
            CommitField(title: "Space below", value: section.spaceBelow, identifier: "object.paragraph.spaceBelow",
                        commit: Self.commit(ObjectPanelModel.ParagraphField.spaceBelow, "Space Below", model))
            CommitField(title: "Left", value: section.leftIndent, identifier: "object.paragraph.left",
                        commit: Self.commit(ObjectPanelModel.ParagraphField.leftIndent, "Left Indent", model))
            CommitField(title: "Right", value: section.rightIndent, identifier: "object.paragraph.right",
                        commit: Self.commit(ObjectPanelModel.ParagraphField.rightIndent, "Right Indent", model))
            CommitField(title: "First line", value: section.firstLineIndent, identifier: "object.paragraph.firstLine",
                        commit: Self.commit(ObjectPanelModel.ParagraphField.firstLineIndent, "First Line Indent", model))
            HStack {
                Toggle("Hyphenate", isOn: Self.hyphenate(section, model)).accessibilityIdentifier("object.paragraph.hyphenate")
                Button("Edit…", action: Self.opening(.hyphenation, $sheet)).accessibilityIdentifier("object.paragraph.hyphenation")
            }
            Toggle("Hang punctuation", isOn: Self.hangPunctuation(section, model))
                .accessibilityIdentifier("object.paragraph.hang")
            HStack {
                Picker("Rules", selection: Self.rule(section, model)) {
                    if section.ruleMode == nil { Text(Self.mixed).tag(Self.mixed) }
                    ForEach(Self.rules, id: \.title) { Text($0.title).tag($0.title) }
                }
                .accessibilityIdentifier("object.paragraph.rules")
                Button("Edit…", action: Self.opening(.rule, $sheet)).accessibilityIdentifier("object.paragraph.ruleWidth")
            }
            Button("Edit Alignment…", action: Self.opening(.alignment, $sheet)).accessibilityIdentifier("object.paragraph.alignment")
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal)
        .sheet(item: $sheet) { value in Self.sheetView(value, section: section, model: model) { sheet = nil } }
    }
}
