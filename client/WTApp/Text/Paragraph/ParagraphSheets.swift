import SwiftUI
import WTModel
import WTProto

/// The Hyphenation sheet (paragraphs.adoc, "Hyphenation"): *Language* (empty: the document's),
/// *Consecutive hyphens* (0: unlimited), *Skip capitalized words*, and -- with a Text tool
/// selection -- *Inhibit hyphens in selection*, which marks the characters at once.
struct HyphenationSheet: View {
    @State var hyphenation: Wiretuner_Doc_V1_Hyphenation
    let editing: Bool
    let commit: (Wiretuner_Doc_V1_Hyphenation) -> Void
    let inhibit: (Bool) -> Void
    let cancel: () -> Void

    init(hyphenation: Wiretuner_Doc_V1_Hyphenation, editing: Bool, commit: @escaping (Wiretuner_Doc_V1_Hyphenation) -> Void,
         inhibit: @escaping (Bool) -> Void, cancel: @escaping () -> Void) {
        _hyphenation = State(initialValue: hyphenation)
        self.editing = editing
        self.commit = commit
        self.inhibit = inhibit
        self.cancel = cancel
    }

    static let documentLanguage = ""
    /// The languages offered: the document's, then those macOS knows.
    static var languages: [(code: String, title: String)] {
        [(documentLanguage, "Document language")] + ["en", "en-GB", "de", "fr", "es", "it", "nl", "pt", "sv", "da", "nb", "fi", "pl", "cs", "hu"].map { code in
                (code, Locale.current.localizedString(forIdentifier: code) ?? code)
            }
    }

    static func consecutive(_ value: Binding<Wiretuner_Doc_V1_Hyphenation>) -> Binding<Int> {
        Binding(get: { Int(value.wrappedValue.consecutive) }, set: { value.wrappedValue.consecutive = UInt32(clamping: max($0, 0)) })
    }

    static func committing(_ value: Wiretuner_Doc_V1_Hyphenation, _ commit: @escaping (Wiretuner_Doc_V1_Hyphenation) -> Void) -> () -> Void {
        { commit(value) }
    }

    static func inhibiting(_ inhibit: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { false }, set: { inhibit($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hyphenation").font(.headline)
            Picker("Language", selection: $hyphenation.language) {
                ForEach(Self.languages, id: \.code) { Text($0.title).tag($0.code) }
            }
            .accessibilityIdentifier("hyphenation.language")
            Stepper("Consecutive hyphens: \(hyphenation.consecutive == 0 ? "Unlimited" : String(hyphenation.consecutive))",
                    value: Self.consecutive($hyphenation), in: 0...10)
                .accessibilityIdentifier("hyphenation.consecutive")
            Toggle("Skip capitalized words", isOn: $hyphenation.skipCapitalized).accessibilityIdentifier("hyphenation.skipCapitalized")
            if editing {
                Toggle("Inhibit hyphens in selection", isOn: Self.inhibiting(inhibit)).accessibilityIdentifier("hyphenation.inhibit")
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.committing(hyphenation, commit)).keyboardShortcut(.defaultAction).accessibilityIdentifier("hyphenation.ok")
            }
        }
        .toggleStyle(.checkbox)
        .padding(20)
        .frame(width: 380)
    }
}

/// The Paragraph Rule Width sheet (paragraphs.adoc, "Paragraph rules"): the width as a percentage
/// of the last line or the column, the *Position* below the baseline, *Above*, and the stroke
/// override's width and colour.
struct ParagraphRuleSheet: View {
    @State var rule: Wiretuner_Doc_V1_ParagraphRule
    @State var overridesStroke: Bool
    let commit: (Wiretuner_Doc_V1_ParagraphRule, Bool) -> Void
    let cancel: () -> Void

    init(rule: Wiretuner_Doc_V1_ParagraphRule, commit: @escaping (Wiretuner_Doc_V1_ParagraphRule, Bool) -> Void, cancel: @escaping () -> Void) {
        var start = rule
        if start.widthPercent == 0 { start.widthPercent = 100 }
        if start.basis == .unspecified { start.basis = .lastLine }
        _rule = State(initialValue: start)
        _overridesStroke = State(initialValue: rule.hasStroke)
        self.commit = commit
        self.cancel = cancel
    }

    static func committing(_ rule: Wiretuner_Doc_V1_ParagraphRule, _ overrides: Bool, _ commit: @escaping (Wiretuner_Doc_V1_ParagraphRule, Bool) -> Void) -> () -> Void {
        { commit(rule, overrides) }
    }

    /// The override's colour as a percentage of black (a CMYK black ink).
    static func strokeTint(_ rule: Binding<Wiretuner_Doc_V1_ParagraphRule>) -> Binding<Double> {
        Binding(get: {
            if case .inline(let color)? = rule.wrappedValue.stroke.color.ref, case .cmyk(let cmyk)? = color.components { return cmyk.k * 100 }
            return 100
        }, set: { value in
            rule.wrappedValue.stroke.color = .with { $0.inline = .with { $0.cmyk = .with { $0.k = min(max(value, 0), 100) / 100 } } }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paragraph Rule Width").font(.headline)
            HStack {
                TextField("Width", value: $rule.widthPercent, format: .number).frame(width: 60).accessibilityIdentifier("rule.width")
                Text("% of")
                Picker("Basis", selection: $rule.basis) {
                    Text("Last line").tag(Wiretuner_Doc_V1_RuleBasis.lastLine)
                    Text("Column").tag(Wiretuner_Doc_V1_RuleBasis.column)
                }
                .labelsHidden()
                .accessibilityIdentifier("rule.basis")
            }
            TextField("Position", value: $rule.position, format: .number).accessibilityIdentifier("rule.position")
            Toggle("Above", isOn: $rule.above).accessibilityIdentifier("rule.above")
            Toggle("Override stroke", isOn: $overridesStroke).accessibilityIdentifier("rule.override")
            if overridesStroke {
                TextField("Stroke width", value: $rule.stroke.width, format: .number).accessibilityIdentifier("rule.strokeWidth")
                Slider(value: Self.strokeTint($rule), in: 0...100) { Text("Black %") }.accessibilityIdentifier("rule.strokeTint")
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.committing(rule, overridesStroke, commit)).keyboardShortcut(.defaultAction).accessibilityIdentifier("rule.ok")
            }
        }
        .toggleStyle(.checkbox)
        .padding(20)
        .frame(width: 380)
    }
}

/// The Edit Alignment sheet (paragraphs.adoc, "Alignment"): *Ragged width* and *Flush zone*.
struct AlignmentSheet: View {
    @State var raggedWidth: Double
    @State var flushZone: Double
    let commit: (Double, Double) -> Void
    let cancel: () -> Void

    static func committing(_ ragged: Double, _ flush: Double, _ commit: @escaping (Double, Double) -> Void) -> () -> Void {
        { commit(ragged, flush) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Alignment").font(.headline)
            HStack {
                Text("Ragged width")
                TextField("Ragged width", value: $raggedWidth, format: .number).frame(width: 60).accessibilityIdentifier("alignment.ragged")
                Text("%")
            }
            HStack {
                Text("Flush zone")
                TextField("Flush zone", value: $flushZone, format: .number).frame(width: 60).accessibilityIdentifier("alignment.flush")
                Text("%")
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.committing(raggedWidth, flushZone, commit)).keyboardShortcut(.defaultAction).accessibilityIdentifier("alignment.ok")
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
