import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The Style Behavior sheet of a text style (text-styles.adoc, "Style behavior"; TYPE-035): every
/// setting can be *No selection* -- an empty field, the *No selection* pop-up item, the blank
/// alignment, the mixed checkbox -- which leaves the text alone when the style is applied.
/// *Global settings* offers *No settings*, *Restore original values* and *Restore program
/// defaults* (Normal Text's settings); *Next style* is the style the paragraph after this one gets.
/// btn:[OK] writes the registers that changed, one change ("Edit style <name>").
@MainActor
@Observable
final class TextStyleBehaviorModel {
    /// A setting the sheet edits: its register path under `TextStyleAttrs` and how to compare it.
    struct Field {
        let path: [UInt32]
        let same: (Wiretuner_Doc_V1_TextStyleAttrs, Wiretuner_Doc_V1_TextStyleAttrs) -> Bool
    }

    static let noSelection = "No selection"

    static let fields: [Field] = [
        Field(path: [1]) { $0.hasNext == $1.hasNext && $0.next.id == $1.next.id },
        Field(path: [2, 1]) { $0.character.hasFontFamily == $1.character.hasFontFamily && $0.character.fontFamily == $1.character.fontFamily },
        Field(path: [2, 2]) { $0.character.hasFontStyle == $1.character.hasFontStyle && $0.character.fontStyle == $1.character.fontStyle },
        Field(path: [2, 3]) { $0.character.hasSize == $1.character.hasSize && $0.character.size == $1.character.size },
        Field(path: [2, 4]) { $0.character.hasLeading == $1.character.hasLeading && $0.character.leading == $1.character.leading },
        Field(path: [2, 5]) { $0.character.hasRangeKerning == $1.character.hasRangeKerning && $0.character.rangeKerning == $1.character.rangeKerning },
        Field(path: [2, 6]) { $0.character.hasBaselineShift == $1.character.hasBaselineShift && $0.character.baselineShift == $1.character.baselineShift },
        Field(path: [2, 7]) { $0.character.hasHorizontalScale == $1.character.hasHorizontalScale && $0.character.horizontalScale == $1.character.horizontalScale },
        Field(path: [2, 10]) { $0.character.hasEffect == $1.character.hasEffect && $0.character.effect == $1.character.effect },
        Field(path: [3, 1]) { $0.paragraph.hasAlignment == $1.paragraph.hasAlignment && $0.paragraph.alignment == $1.paragraph.alignment },
        Field(path: [3, 4]) { $0.paragraph.hasLeftIndent == $1.paragraph.hasLeftIndent && $0.paragraph.leftIndent == $1.paragraph.leftIndent },
        Field(path: [3, 5]) { $0.paragraph.hasRightIndent == $1.paragraph.hasRightIndent && $0.paragraph.rightIndent == $1.paragraph.rightIndent },
        Field(path: [3, 6]) { $0.paragraph.hasFirstLineIndent == $1.paragraph.hasFirstLineIndent && $0.paragraph.firstLineIndent == $1.paragraph.firstLineIndent },
        Field(path: [3, 7]) { $0.paragraph.hasSpaceAbove == $1.paragraph.hasSpaceAbove && $0.paragraph.spaceAbove == $1.paragraph.spaceAbove },
        Field(path: [3, 8]) { $0.paragraph.hasSpaceBelow == $1.paragraph.hasSpaceBelow && $0.paragraph.spaceBelow == $1.paragraph.spaceBelow },
        Field(path: [3, 13]) { $0.paragraph.hasHangPunctuation == $1.paragraph.hasHangPunctuation && $0.paragraph.hangPunctuation == $1.paragraph.hangPunctuation },
        Field(path: [3, 14]) { $0.paragraph.hasKeepLines == $1.paragraph.hasKeepLines && $0.paragraph.keepLines == $1.paragraph.keepLines },
        Field(path: [3, 15]) { $0.paragraph.hasKeepWithNext == $1.paragraph.hasKeepWithNext && $0.paragraph.keepWithNext == $1.paragraph.keepWithNext },
        Field(path: [4]) { $0.affectsColor == $1.affectsColor },
    ] + StyleVariationControls.fields

    let style: TextStyle
    /// The settings the sheet started from.
    let original: Wiretuner_Doc_V1_TextStyleAttrs
    /// Normal Text's settings (*Restore program defaults*).
    let defaults: Wiretuner_Doc_V1_TextStyleAttrs
    /// The styles *Next style* offers.
    let paragraphStyles: [TextStyle]
    var attrs: Wiretuner_Doc_V1_TextStyleAttrs

    init(style: TextStyle, in state: EngineState) {
        self.style = style
        original = style.attrs
        attrs = style.attrs
        let styles = state.textStyles
        defaults = styles.normalText.flatMap { styles.style($0)?.attrs } ?? Wiretuner_Doc_V1_TextStyleAttrs()
        paragraphStyles = styles.styles(.paragraph)
    }

    var isCharacter: Bool { style.kind == .character }

    /// The paths of the settings that differ from where the sheet started.
    var changedFields: [[UInt32]] {
        Self.fields.filter { !$0.same(original, attrs) && !(isCharacter && $0.path.first == 3) && !(isCharacter && $0.path == [1]) }.map(\.path)
    }

    /// btn:[OK]'s command; nil when nothing changed.
    var command: EditTextStyle? {
        let fields = changedFields
        guard !fields.isEmpty else { return nil }
        return EditTextStyle(style.id, attrs: attrs, fields: fields, name: style.name)
    }

    // MARK: Global settings

    enum Global: String, CaseIterable {
        case noSettings = "No settings"
        case original = "Restore original values"
        case defaults = "Restore program defaults"
    }

    func apply(_ global: Global) {
        switch global {
        case .noSettings:
            let next = attrs.next
            attrs = Wiretuner_Doc_V1_TextStyleAttrs()
            if original.hasNext { attrs.next = next }
        case .original: attrs = original
        case .defaults:
            attrs = defaults
            attrs.clearNext()
            if original.hasNext { attrs.next = original.next }
        }
        if isCharacter { attrs.clearParagraph() }
    }

    // MARK: Optional values as text

    /// A number field: empty is *No selection*.
    static func number(_ get: @escaping () -> Double?, _ set: @escaping (Double?) -> Void) -> Binding<String> {
        Binding(get: { get().map { $0.formatted(.number) } ?? "" }, set: { text in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { set(nil) } else if let value = Double(trimmed) { set(value) }
        })
    }

    /// A tri-state setting: *No selection*, On, Off.
    static func tristate(_ get: @escaping () -> Bool?, _ set: @escaping (Bool?) -> Void) -> Binding<String> {
        Binding(get: { get().map { $0 ? "On" : "Off" } ?? noSelection }, set: { set($0 == "On" ? true : $0 == "Off" ? false : nil) })
    }

    /// A text pop-up: *No selection* or a value.
    static func choice(_ get: @escaping () -> String?, _ set: @escaping (String?) -> Void) -> Binding<String> {
        Binding(get: { get() ?? noSelection }, set: { set($0 == noSelection ? nil : $0) })
    }

    var family: Binding<String> {
        Self.choice({ self.attrs.character.hasFontFamily ? self.attrs.character.fontFamily : nil },
                    { if let v = $0 { self.attrs.character.fontFamily = v } else { self.attrs.character.clearFontFamily() } })
    }

    var face: Binding<String> {
        Self.choice({ self.attrs.character.hasFontStyle ? self.attrs.character.fontStyle : nil },
                    { if let v = $0 { self.attrs.character.fontStyle = v } else { self.attrs.character.clearFontStyle() } })
    }

    var size: Binding<String> {
        Self.number({ self.attrs.character.hasSize ? self.attrs.character.size : nil },
                    { if let v = $0, v > 0 { self.attrs.character.size = v } else { self.attrs.character.clearSize() } })
    }

    /// *Leading*: *No selection*, *Solid*, *Auto* (120%).
    var leading: Binding<String> {
        Binding(get: {
            guard self.attrs.character.hasLeading else { return Self.noSelection }
            return self.attrs.character.leading.mode == .percent ? "Auto" : "Solid"
        }, set: { choice in
            switch choice {
            case "Solid": self.attrs.character.leading = .with { $0.mode = .extra; $0.value = 0 }
            case "Auto": self.attrs.character.leading = .with { $0.mode = .percent; $0.value = 120 }
            default: self.attrs.character.clearLeading()
            }
        })
    }

    var rangeKerning: Binding<String> {
        Self.number({ self.attrs.character.hasRangeKerning ? self.attrs.character.rangeKerning : nil },
                    { if let v = $0 { self.attrs.character.rangeKerning = v } else { self.attrs.character.clearRangeKerning() } })
    }

    var baselineShift: Binding<String> {
        Self.number({ self.attrs.character.hasBaselineShift ? self.attrs.character.baselineShift : nil },
                    { if let v = $0 { self.attrs.character.baselineShift = v } else { self.attrs.character.clearBaselineShift() } })
    }

    var horizontalScale: Binding<String> {
        Self.number({ self.attrs.character.hasHorizontalScale ? self.attrs.character.horizontalScale : nil },
                    { if let v = $0, v > 0 { self.attrs.character.horizontalScale = v } else { self.attrs.character.clearHorizontalScale() } })
    }

    /// *Effect*: *No selection*, *No effect* (a real value that removes effects), or a kind.
    var effect: Binding<String> {
        Binding(get: {
            guard self.attrs.character.hasEffect else { return Self.noSelection }
            let kind = TextEffectKind(self.attrs.character.effect)
            return kind == .none ? "No effect" : kind.title
        }, set: { choice in
            if choice == Self.noSelection { return self.attrs.character.clearEffect() }
            let kind = TextEffectKind.allCases.first { $0.title == choice } ?? .none
            self.attrs.character.effect = kind.defaultEffect
        })
    }

    /// *Alignment*: the blank button is *No selection*.
    var alignment: Binding<Wiretuner_Doc_V1_Alignment> {
        Binding(get: { self.attrs.paragraph.hasAlignment ? self.attrs.paragraph.alignment : .unspecified },
                set: { if $0 == .unspecified { self.attrs.paragraph.clearAlignment() } else { self.attrs.paragraph.alignment = $0 } })
    }

    func paragraphNumber(_ keyPath: WritableKeyPath<Wiretuner_Doc_V1_ParagraphSettings, Double>, has: KeyPath<Wiretuner_Doc_V1_ParagraphSettings, Bool>,
                         clear: @escaping (inout Wiretuner_Doc_V1_ParagraphSettings) -> Void) -> Binding<String> {
        Self.number({ self.attrs.paragraph[keyPath: has] ? self.attrs.paragraph[keyPath: keyPath] : nil },
                    { if let v = $0 { self.attrs.paragraph[keyPath: keyPath] = v } else { clear(&self.attrs.paragraph) } })
    }

    var spaceAbove: Binding<String> { paragraphNumber(\.spaceAbove, has: \.hasSpaceAbove, clear: Self.clearSpaceAbove) }
    var spaceBelow: Binding<String> { paragraphNumber(\.spaceBelow, has: \.hasSpaceBelow, clear: Self.clearSpaceBelow) }
    var leftIndent: Binding<String> { paragraphNumber(\.leftIndent, has: \.hasLeftIndent, clear: Self.clearLeftIndent) }
    var rightIndent: Binding<String> { paragraphNumber(\.rightIndent, has: \.hasRightIndent, clear: Self.clearRightIndent) }
    var firstLineIndent: Binding<String> { paragraphNumber(\.firstLineIndent, has: \.hasFirstLineIndent, clear: Self.clearFirstLineIndent) }

    static func clearSpaceAbove(_ settings: inout Wiretuner_Doc_V1_ParagraphSettings) { settings.clearSpaceAbove() }
    static func clearSpaceBelow(_ settings: inout Wiretuner_Doc_V1_ParagraphSettings) { settings.clearSpaceBelow() }
    static func clearLeftIndent(_ settings: inout Wiretuner_Doc_V1_ParagraphSettings) { settings.clearLeftIndent() }
    static func clearRightIndent(_ settings: inout Wiretuner_Doc_V1_ParagraphSettings) { settings.clearRightIndent() }
    static func clearFirstLineIndent(_ settings: inout Wiretuner_Doc_V1_ParagraphSettings) { settings.clearFirstLineIndent() }

    /// The faces the Style pop-up lists: the chosen family's, and the chosen face.
    var faces: [String] {
        TextSectionView.styles(of: attrs.character.hasFontFamily ? attrs.character.fontFamily : nil,
                               including: attrs.character.hasFontStyle ? attrs.character.fontStyle : nil)
    }

    var keepLines: Binding<String> {
        Self.number({ self.attrs.paragraph.hasKeepLines ? Double(self.attrs.paragraph.keepLines) : nil },
                    { if let v = $0, v >= 0 { self.attrs.paragraph.keepLines = UInt32(v) } else { self.attrs.paragraph.clearKeepLines() } })
    }

    var hangPunctuation: Binding<String> {
        Self.tristate({ self.attrs.paragraph.hasHangPunctuation ? self.attrs.paragraph.hangPunctuation : nil },
                      { if let v = $0 { self.attrs.paragraph.hangPunctuation = v } else { self.attrs.paragraph.clearHangPunctuation() } })
    }

    var keepWithNext: Binding<String> {
        Self.tristate({ self.attrs.paragraph.hasKeepWithNext ? self.attrs.paragraph.keepWithNext : nil },
                      { if let v = $0 { self.attrs.paragraph.keepWithNext = v } else { self.attrs.paragraph.clearKeepWithNext() } })
    }

    var affectsColor: Binding<Bool> {
        Binding(get: { self.attrs.affectsColor }, set: { self.attrs.affectsColor = $0 })
    }

    /// *Next style*: *No selection* or a paragraph style's id.
    var next: Binding<String> {
        Binding(get: { self.attrs.hasNext ? OpID(self.attrs.next.id).description : Self.noSelection }, set: { choice in
            if let style = self.paragraphStyles.first(where: { $0.id.description == choice }) {
                self.attrs.next = .with { $0.id = style.id.proto }
            } else {
                self.attrs.clearNext()
            }
        })
    }
}

/// The sheet.
struct TextStyleBehaviorSheet: View {
    @Bindable var model: TextStyleBehaviorModel
    let commit: (EditTextStyle?) -> Void
    let cancel: () -> Void

    static let tristates = [TextStyleBehaviorModel.noSelection, "On", "Off"]
    static let alignments: [(Wiretuner_Doc_V1_Alignment, String)] = [(.unspecified, " "), (.left, "Left"), (.center, "Center"), (.right, "Right"), (.justified, "Justified")]

    static func committing(_ model: TextStyleBehaviorModel, _ commit: @escaping (EditTextStyle?) -> Void) -> () -> Void {
        { commit(model.command) }
    }

    static func global(_ model: TextStyleBehaviorModel) -> Binding<String> {
        Binding(get: { "Global settings" }, set: { if let global = TextStyleBehaviorModel.Global(rawValue: $0) { model.apply(global) } })
    }

    var body: some View {
        Form {
            Text("Style Behavior — \(model.style.name)").font(.headline)
            Picker("Font", selection: model.family) {
                Text(TextStyleBehaviorModel.noSelection).tag(TextStyleBehaviorModel.noSelection)
                ForEach(TextSectionView.families(including: nil), id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("behavior.font")
            Picker("Style", selection: model.face) {
                Text(TextStyleBehaviorModel.noSelection).tag(TextStyleBehaviorModel.noSelection)
                ForEach(model.faces, id: \.self) { Text($0).tag($0) }
            }
            TextField("Size", text: model.size).accessibilityIdentifier("behavior.size")
            Picker("Leading", selection: model.leading) {
                ForEach([TextStyleBehaviorModel.noSelection, "Solid", "Auto"], id: \.self) { Text($0).tag($0) }
            }
            TextField("Range kerning", text: model.rangeKerning)
            TextField("Baseline shift", text: model.baselineShift)
            TextField("Horizontal scale", text: model.horizontalScale)
            Picker("Effect", selection: model.effect) {
                Text(TextStyleBehaviorModel.noSelection).tag(TextStyleBehaviorModel.noSelection)
                Text("No effect").tag("No effect")
                ForEach(TextEffectKind.effects) { Text($0.title).tag($0.title) }
            }
            StyleVariationControls(model: model)
            Toggle("Style affects text color", isOn: model.affectsColor).toggleStyle(.checkbox).accessibilityIdentifier("behavior.color")
            if !model.isCharacter {
                Picker("Alignment", selection: model.alignment) {
                    ForEach(Self.alignments, id: \.1) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                TextField("Space above", text: model.spaceAbove)
                TextField("Space below", text: model.spaceBelow)
                TextField("Left indent", text: model.leftIndent)
                TextField("Right indent", text: model.rightIndent)
                TextField("First line", text: model.firstLineIndent)
                Picker("Hang punctuation", selection: model.hangPunctuation) { ForEach(Self.tristates, id: \.self) { Text($0).tag($0) } }
                TextField("Keep lines together", text: model.keepLines)
                Picker("Keep with next", selection: model.keepWithNext) { ForEach(Self.tristates, id: \.self) { Text($0).tag($0) } }
                Picker("Next style", selection: model.next) {
                    Text(TextStyleBehaviorModel.noSelection).tag(TextStyleBehaviorModel.noSelection)
                    ForEach(model.paragraphStyles, id: \.id) { Text($0.name).tag($0.id.description) }
                }
                .accessibilityIdentifier("behavior.next")
            }
            Picker("Global settings", selection: Self.global(model)) {
                Text("Global settings").tag("Global settings")
                ForEach(TextStyleBehaviorModel.Global.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
            }
            .accessibilityIdentifier("behavior.global")
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.committing(model, commit)).keyboardShortcut(.defaultAction).accessibilityIdentifier("behavior.ok")
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// menu:Options[Redefine…]'s sheet: the style to redefine from the selection.
struct RedefineTextStyleSheet: View {
    let styles: [TextStyle]
    @State var selected: OpID?
    let commit: (OpID) -> Void
    let cancel: () -> Void

    static func committing(_ selected: OpID?, _ commit: @escaping (OpID) -> Void) -> () -> Void {
        { if let selected { commit(selected) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Redefine Style").font(.headline)
            Picker("Style", selection: $selected) {
                ForEach(styles, id: \.id) { Text($0.name).tag(OpID?.some($0.id)) }
            }
            .accessibilityIdentifier("redefine.style")
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.committing(selected, commit)).keyboardShortcut(.defaultAction).disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
