import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The Object panel's Spacing section (paragraphs.adoc, "Word and letter spacing" and "Keeping
/// lines and words together"; TYPE-027): *Horizontal scale* (a character mark), the *Word* and
/// *Letter* spacing triples (each one ATOMIC register, written whole), *Keep lines together*,
/// *Keep with next*, *Selected words* (the `no_break` mark) and *Inhibit hyphens* (the `no_hyphen`
/// mark).  Paragraph settings go to every paragraph the Text tool's selection touches, else every
/// paragraph of the selected blocks; character settings to the Text tool's selection (its pending
/// format at an insertion point), else every selected block whole.  A triple whose minimum is above
/// its optimum, or whose optimum is above its maximum, is refused.
extension ObjectPanelModel {
    /// Minimum, optimum and maximum, in percent.
    struct SpacingTriple: Hashable {
        var min: Double
        var opt: Double
        var max: Double

        /// Word spacing as layout reads an unset register: 80, 100, 150.
        static let words = SpacingTriple(min: 80, opt: 100, max: 150)
        /// Letter spacing as layout reads an unset register: 0, 0, 5.
        static let letters = SpacingTriple(min: 0, opt: 0, max: 5)

        init(min: Double, opt: Double, max: Double) {
            self.min = min
            self.opt = opt
            self.max = max
        }

        init(_ range: Wiretuner_Doc_V1_SpacingRange) {
            self.init(min: range.min, opt: range.opt, max: range.max)
        }

        /// Whether the triple is ordered (min ≤ opt ≤ max) and finite.
        var isValid: Bool { [min, opt, max].allSatisfy(\.isFinite) && min <= opt && opt <= max }

        var range: Wiretuner_Doc_V1_SpacingRange {
            .with {
                $0.min = min
                $0.opt = opt
                $0.max = max
            }
        }

        /// The triple with one part replaced.
        func replacing(_ part: SpacingPart, with value: Double) -> SpacingTriple {
            var copy = self
            switch part {
            case .min: copy.min = value
            case .opt: copy.opt = value
            case .max: copy.max = value
            }
            return copy
        }

        func value(_ part: SpacingPart) -> Double {
            switch part {
            case .min: min
            case .opt: opt
            case .max: max
            }
        }
    }

    enum SpacingPart: String, CaseIterable {
        case min, opt, max

        var title: String {
            switch self {
            case .min: "Min"
            case .opt: "Opt"
            case .max: "Max"
            }
        }
    }

    /// Word or letter spacing.
    enum SpacingKind: String {
        case word, letter

        var field: [UInt32] { self == .word ? [15] : [16] }
        var label: String { self == .word ? "Word Spacing" : "Letter Spacing" }
        var defaults: SpacingTriple { self == .word ? .words : .letters }
    }

    struct SpacingSection: Equatable {
        let nodes: [OpID]
        let editing: Bool
        /// The shared horizontal scale (unset reads as 100); nil when mixed.
        let horizontalScale: Double?
        /// The shared triples (unset reads as the defaults); nil when mixed.
        let word: SpacingTriple?
        let letter: SpacingTriple?
        /// *Keep lines together* (0 = off); nil when mixed.
        let keepLines: Double?
        let keepWithNext: MixedState
        /// *Selected words*: the `no_break` mark over the characters.
        let noBreak: MixedState
        /// *Inhibit hyphens*: the `no_hyphen` mark over the characters.
        let noHyphen: MixedState
    }

    /// The triple a paragraph shows for `kind`: its register, read the way layout reads it (an
    /// unset register is the default; an unordered one is the optimum three times).
    static func spacing(_ props: Wiretuner_Doc_V1_ParagraphProps, _ kind: SpacingKind) -> SpacingTriple {
        let has = kind == .word ? props.hasWordSpacing : props.hasLetterSpacing
        guard has else { return kind.defaults }
        let triple = SpacingTriple(kind == .word ? props.wordSpacing : props.letterSpacing)
        return triple.isValid ? triple : SpacingTriple(min: triple.opt, opt: triple.opt, max: triple.opt)
    }

    static func horizontalScale(_ values: [Wiretuner_Doc_V1_TextMarkValue]) -> Double {
        for value in values { if case .horizontalScale(let scale)? = value.value, scale > 0 { return scale } }
        return 100
    }

    static func flag(_ values: [Wiretuner_Doc_V1_TextMarkValue], _ read: (Wiretuner_Doc_V1_TextMarkValue) -> Bool?) -> Bool {
        values.lazy.compactMap(read).first ?? false
    }

    /// The runs the section's character settings read.
    private var spacingRuns: [[Wiretuner_Doc_V1_TextMarkValue]] {
        editingText?.formatRuns ?? targetRuns
    }

    var spacing: SpacingSection? {
        guard let section = text else { return nil }
        let props = paragraphProps
        let runs = spacingRuns
        func shared<Value: Hashable>(_ values: [Value]) -> Value? {
            let set = Set(values)
            return set.count == 1 ? set.first : nil
        }
        return SpacingSection(
            nodes: section.nodes, editing: section.editing,
            horizontalScale: shared(runs.map(Self.horizontalScale)),
            word: shared(props.map { Self.spacing($0, .word) }), letter: shared(props.map { Self.spacing($0, .letter) }),
            keepLines: shared(props.map { Double($0.keepLines) }), keepWithNext: MixedState(props.map(\.keepWithNext)),
            noBreak: MixedState(runs.map { run in Self.flag(run) { if case .noBreak(let on)? = $0.value { on } else { nil } } }),
            noHyphen: MixedState(runs.map { run in Self.flag(run) { if case .noHyphen(let on)? = $0.value { on } else { nil } } })
        )
    }

    /// Writes a whole triple (one ATOMIC register per paragraph); nil when it is refused.
    @discardableResult
    func setSpacing(_ kind: SpacingKind, _ triple: SpacingTriple) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard triple.isValid else { return nil }
        var props = Wiretuner_Doc_V1_ParagraphProps()
        if kind == .word { props.wordSpacing = triple.range } else { props.letterSpacing = triple.range }
        return setParagraph(props, fields: [kind.field], label: kind.label)
    }

    /// One field of a triple typed: the rest from the section's shared triple (the default when
    /// the paragraphs differ).  Nil when the result is refused.
    @discardableResult
    func setSpacingPart(_ kind: SpacingKind, _ part: SpacingPart, _ value: Double) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let section = spacing else { return nil }
        let current = (kind == .word ? section.word : section.letter) ?? kind.defaults
        return setSpacing(kind, current.replacing(part, with: value))
    }

    /// *Horizontal scale*, percent, above 0 and at most 10,000.
    @discardableResult
    func setHorizontalScale(_ scale: Double) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard scale.isFinite, scale > 0, scale <= 10_000 else { return nil }
        return formatText(.with { $0.horizontalScale = scale })
    }

    /// *Keep lines together*: 0 (off) to 1,000 lines.
    @discardableResult
    func setKeepLines(_ lines: Double) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard lines.isFinite, lines >= 0, lines <= 1000 else { return nil }
        return setParagraph(.with { $0.keepLines = UInt32(lines.rounded()) }, fields: [[13]], label: "Keep Lines Together")
    }

    @discardableResult
    func setKeepWithNext(_ on: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        setParagraph(.with { $0.keepWithNext = on }, fields: [[14]], label: "Keep With Next")
    }

    /// *Selected words*: the characters never break across lines.
    @discardableResult
    func setNoBreak(_ on: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        formatText(.with { $0.noBreak = on })
    }
}

/// The section's view.
struct SpacingSectionView: View {
    let section: ObjectPanelModel.SpacingSection
    let model: ObjectPanelModel
    @State private var refusal: String?

    static let refused = "The minimum must not be above the optimum, nor the optimum above the maximum."

    static func triple(_ section: ObjectPanelModel.SpacingSection, _ kind: ObjectPanelModel.SpacingKind) -> ObjectPanelModel.SpacingTriple? {
        kind == .word ? section.word : section.letter
    }

    /// A triple field's commit: the refusal message when the triple would be unordered.
    static func commit(_ kind: ObjectPanelModel.SpacingKind, _ part: ObjectPanelModel.SpacingPart, _ model: ObjectPanelModel,
                       refusal: Binding<String?>) -> (Double) -> Void {
        { value in
            let written = model.setSpacingPart(kind, part, value)
            refusal.wrappedValue = written == nil ? refused : nil
        }
    }

    static func scale(_ model: ObjectPanelModel) -> (Double) -> Void { { model.setHorizontalScale($0) } }
    static func keepLines(_ model: ObjectPanelModel) -> (Double) -> Void { { model.setKeepLines($0) } }
    static func keepWithNext(_ section: ObjectPanelModel.SpacingSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        toggle(section.keepWithNext) { model.setKeepWithNext($0) }
    }
    static func noBreak(_ section: ObjectPanelModel.SpacingSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        toggle(section.noBreak) { model.setNoBreak($0) }
    }
    static func noHyphen(_ section: ObjectPanelModel.SpacingSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        toggle(section.noHyphen) { model.inhibitHyphens($0) }
    }

    static func toggle(_ state: MixedState, _ set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { state.isOn }, set: { set($0) })
    }

    var body: some View {
        Form {
            CommitField(title: "Horizontal scale", value: section.horizontalScale, identifier: "object.spacing.scale",
                        commit: Self.scale(model))
            ForEach([ObjectPanelModel.SpacingKind.word, .letter], id: \.rawValue) { kind in
                LabeledContent(kind == .word ? "Word" : "Letter") {
                    HStack {
                        ForEach(ObjectPanelModel.SpacingPart.allCases, id: \.rawValue) { part in
                            CommitField(title: part.title, value: Self.triple(section, kind)?.value(part),
                                        identifier: "object.spacing.\(kind.rawValue).\(part.rawValue)",
                                        commit: Self.commit(kind, part, model, refusal: $refusal))
                        }
                    }
                }
            }
            if let refusal {
                Text(refusal).font(.caption).foregroundStyle(.red).accessibilityIdentifier("object.spacing.refused")
            }
            CommitField(title: "Keep lines together", value: section.keepLines, identifier: "object.spacing.keepLines",
                        commit: Self.keepLines(model))
            Toggle("Keep with next", isOn: Self.keepWithNext(section, model))
                .accessibilityIdentifier("object.spacing.keepWithNext")
            Toggle("Selected words", isOn: Self.noBreak(section, model))
                .accessibilityIdentifier("object.spacing.noBreak")
            Toggle("Inhibit hyphens", isOn: Self.noHyphen(section, model))
                .accessibilityIdentifier("object.spacing.noHyphen")
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal)
    }
}
