import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The six text effects and *None* (text-effects.adoc, "Text effects"; TYPE-037): what the
/// *Effect* pop-up and menu:Text[Effect] offer, each effect's defaults, and which of the four
/// option sheets edits it.
enum TextEffectKind: String, CaseIterable, Identifiable, Sendable {
    case none, highlight, inline, shadow, strikethrough, underline, zoom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .highlight: "Highlight"
        case .inline: "Inline"
        case .shadow: "Shadow"
        case .strikethrough: "Strikethrough"
        case .underline: "Underline"
        case .zoom: "Zoom"
        }
    }

    /// The effects themselves, in the pop-up's order.
    static var effects: [TextEffectKind] { allCases.filter { $0 != .none } }

    /// The kind of a stored effect; an effect with no case set (the cleared value) is *None*.
    init(_ effect: Wiretuner_Doc_V1_TextEffect) {
        switch effect.effect {
        case .highlight?: self = .highlight
        case .underline?: self = .underline
        case .strikethrough?: self = .strikethrough
        case .inline?: self = .inline
        case .shadow?: self = .shadow
        case .zoom?: self = .zoom
        case nil: self = .none
        }
    }

    /// The effect of a run's winning marks.
    static func effect(of values: [Wiretuner_Doc_V1_TextMarkValue]) -> Wiretuner_Doc_V1_TextEffect {
        for value in values { if case .effect(let effect)? = value.value { return effect } }
        return Wiretuner_Doc_V1_TextEffect()
    }

    /// The effect with its default options (WTText's defaults: a 50% shadow a tenth of the size
    /// down and right, a zoom to half size, one ring, lines at the font's thickness); *None* is the
    /// cleared value, which reads as no effect.
    var defaultEffect: Wiretuner_Doc_V1_TextEffect {
        var effect = Wiretuner_Doc_V1_TextEffect()
        let black = Appearances.inline(red: 0, green: 0, blue: 0)
        let white = Appearances.inline(red: 1, green: 1, blue: 1)
        switch self {
        case .none: break
        case .highlight: effect.highlight = .with { $0.color = Appearances.inline(red: 1, green: 0.93, blue: 0.3) }
        case .underline: effect.underline = .with { $0.position = -2; $0.color = black }
        case .strikethrough: effect.strikethrough = .with { $0.position = 3; $0.color = black }
        case .inline:
            effect.inline = .with { $0.count = 1; $0.strokeWidth = 1; $0.strokeColor = black; $0.backgroundWidth = 1; $0.backgroundColor = white }
        case .shadow: effect.shadow = .with { $0.offsetX = 10; $0.offsetY = 10; $0.color = black; $0.tint = 50 }
        case .zoom: effect.zoom = .with { $0.zoomTo = 50; $0.offsetX = 20; $0.offsetY = -20; $0.from = black; $0.to = white }
        }
        return effect
    }

    /// The option sheet that edits the effect (highlight, underline and strikethrough share one).
    var sheet: TextEffectSheet? {
        switch self {
        case .none: nil
        case .highlight, .underline, .strikethrough: .line
        case .inline: .inline
        case .shadow: .shadow
        case .zoom: .zoom
        }
    }
}

/// The four option sheets.
enum TextEffectSheet: Sendable {
    case line, inline, shadow, zoom
}

extension ObjectPanelModel {
    /// The *Effect* pop-up at the bottom of the Character section: the effect the text shares.
    struct TextEffectSection: Equatable {
        let nodes: [OpID]
        /// The kind every run has; nil when they differ.
        let kind: TextEffectKind?
        /// The whole effect every run has (what a sheet starts from); nil when they differ.
        let effect: Wiretuner_Doc_V1_TextEffect?
    }

    /// The format runs the Character section reads: the Text tool's selection while it edits a
    /// selected block, else every run of every selected block.
    var characterRuns: [[Wiretuner_Doc_V1_TextMarkValue]] {
        if let session = editingText { return session.formatRuns }
        let state = document.state
        return selection.ids.compactMap { state.textNode($0.opID) }.flatMap { text in text.length == 0 ? [[]] : text.runs.map(\.values) }
    }

    var textEffect: TextEffectSection? {
        guard let text else { return nil }
        let effects = characterRuns.map(TextEffectKind.effect(of:))
        return TextEffectSection(nodes: text.nodes, kind: shared(effects.map(TextEffectKind.init)), effect: shared(effects))
    }

    /// Applies `effect` whole (one `effect` mark: the kind and its options never mix between
    /// people, text-effects.adoc "Merge semantics").
    @discardableResult
    func setTextEffect(_ effect: Wiretuner_Doc_V1_TextEffect) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        formatText(.with { $0.effect = effect })
    }

    /// The *Effect* pop-up or menu:Text[Effect]: the effect with its defaults, or *None*.
    @discardableResult
    func setTextEffect(_ kind: TextEffectKind) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        setTextEffect(kind.defaultEffect)
    }
}

/// An inline colour reference as the sheets' colour wells show it (swatch and tint references
/// show their cached colour; anything else black).
enum EffectColor {
    static func color(_ ref: Wiretuner_Doc_V1_ColorRef) -> SwiftUI.Color {
        let stored: Wiretuner_Doc_V1_Color
        switch ref.ref {
        case .inline(let color)?: stored = color
        case .swatch(let swatch)?: stored = decode(swatch.cached)
        case .tint(let tint)?: stored = decode(tint.base.cached)
        default: return .black
        }
        let resolved = ColorValues.color(stored)
        return SwiftUI.Color(.sRGB, red: resolved.red, green: resolved.green, blue: resolved.blue, opacity: 1)
    }

    /// A reference's cached colour (its bytes); unreadable bytes read as the default colour.
    static func decode(_ bytes: Data) -> Wiretuner_Doc_V1_Color {
        (try? Wiretuner_Doc_V1_Color(serializedBytes: bytes)) ?? Wiretuner_Doc_V1_Color()
    }

    /// The inline sRGB reference of a colour the well picked.
    static func ref(_ color: SwiftUI.Color) -> Wiretuner_Doc_V1_ColorRef {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return Appearances.inline(red: Double(resolved.redComponent), green: Double(resolved.greenComponent), blue: Double(resolved.blueComponent))
    }

    static func binding(_ ref: Binding<Wiretuner_Doc_V1_ColorRef>) -> Binding<SwiftUI.Color> {
        Binding(get: { color(ref.wrappedValue) }, set: { ref.wrappedValue = self.ref($0) })
    }
}

/// One option sheet's state: the effect being edited, whole, and the kind it is (a line sheet
/// keeps whether it edits a highlight, an underline or a strikethrough).
struct TextEffectSheetModel: Equatable {
    var kind: TextEffectKind
    var effect: Wiretuner_Doc_V1_TextEffect

    /// Starts from the text's effect when it is of `kind`, else from the kind's defaults.
    init(kind: TextEffectKind, current: Wiretuner_Doc_V1_TextEffect?) {
        self.kind = kind
        effect = current.flatMap { TextEffectKind($0) == kind ? $0 : nil } ?? kind.defaultEffect
    }

    /// The line options of a highlight, underline or strikethrough.
    var line: Wiretuner_Doc_V1_TextLineEffect {
        get {
            switch effect.effect {
            case .highlight(let line)?, .underline(let line)?, .strikethrough(let line)?: line
            default: Wiretuner_Doc_V1_TextLineEffect()
            }
        }
        set {
            switch kind {
            case .highlight: effect.highlight = newValue
            case .strikethrough: effect.strikethrough = newValue
            default: effect.underline = newValue
            }
        }
    }

    var inline: Wiretuner_Doc_V1_TextInlineEffect {
        get { effect.inline }
        set { effect.inline = newValue }
    }

    var shadow: Wiretuner_Doc_V1_TextShadowEffect {
        get { effect.shadow }
        set { effect.shadow = newValue }
    }

    var zoom: Wiretuner_Doc_V1_TextZoomEffect {
        get { effect.zoom }
        set { effect.zoom = newValue }
    }

    /// The dash as the field shows it: lengths separated by spaces, empty for solid.
    static func dashText(_ dash: Wiretuner_Doc_V1_DashPattern) -> String {
        dash.lengths.map { $0.formatted(.number.precision(.fractionLength(0...3)).grouping(.never)) }.joined(separator: " ")
    }

    /// The dash a field's text stands for: up to eight non-negative lengths; nil refuses it.
    static func dash(_ text: String) -> Wiretuner_Doc_V1_DashPattern? {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        let lengths = parts.compactMap(Double.init)
        guard lengths.count == parts.count, lengths.count <= 8, lengths.allSatisfy({ $0 >= 0 && $0.isFinite }) else { return nil }
        return .with { $0.lengths = lengths }
    }
}

/// The *Effect* pop-up and its *Edit…* item.
struct TextEffectSectionView: View {
    let section: ObjectPanelModel.TextEffectSection
    let model: ObjectPanelModel
    @State private var editing: TextEffectSheetModel?

    static let mixed = "Mixed"
    static let edit = "Edit…"

    /// The pop-up's selection: choosing an effect applies it with its defaults; *Edit…* opens the
    /// sheet of the text's effect (through `open`).
    static func choice(_ section: ObjectPanelModel.TextEffectSection, _ model: ObjectPanelModel, editing: Binding<TextEffectSheetModel?>) -> Binding<String> {
        Binding(get: { section.kind?.title ?? mixed }, set: { chosen in
            if chosen == edit {
                if let sheet = editor(section) { editing.wrappedValue = sheet }
            } else if let kind = TextEffectKind.allCases.first(where: { $0.title == chosen }) {
                model.setTextEffect(kind)
            }
        })
    }

    /// The sheet for `sheet` (btn:[OK] writes it and closes, btn:[Cancel] closes).
    static func sheet(_ sheet: TextEffectSheetModel, model: ObjectPanelModel, editing: Binding<TextEffectSheetModel?>) -> TextEffectSheetView {
        TextEffectSheetView(model: sheet, commit: { commit($0, model); editing.wrappedValue = nil }, cancel: { editing.wrappedValue = nil })
    }

    /// The sheet *Edit…* opens: the shared effect's own; nil for *None* or mixed effects.
    static func editor(_ section: ObjectPanelModel.TextEffectSection) -> TextEffectSheetModel? {
        guard let kind = section.kind, kind != .none else { return nil }
        return TextEffectSheetModel(kind: kind, current: section.effect)
    }

    /// The open sheet.
    func sheet(_ sheet: TextEffectSheetModel) -> TextEffectSheetView {
        Self.sheet(sheet, model: model, editing: $editing)
    }

    /// btn:[OK]: the sheet's effect, whole.
    static func commit(_ sheet: TextEffectSheetModel, _ model: ObjectPanelModel) {
        model.setTextEffect(sheet.effect)
    }

    var body: some View {
        Form {
            Picker("Effect", selection: Self.choice(section, model, editing: $editing)) {
                if section.kind == nil { Text(Self.mixed).tag(Self.mixed) }
                ForEach(TextEffectKind.allCases) { Text($0.title).tag($0.title) }
                Divider()
                Text(Self.edit).tag(Self.edit)
            }
            .accessibilityIdentifier("object.text.effect")
        }
        .padding(.horizontal)
        .sheet(item: $editing, content: sheet)
    }
}

extension TextEffectSheetModel: Identifiable {
    var id: String { kind.rawValue }
}

/// One of the four option sheets: Highlight/Underline/Strikethrough, Inline, Shadow, Zoom.
struct TextEffectSheetView: View {
    @State var model: TextEffectSheetModel
    let commit: (TextEffectSheetModel) -> Void
    let cancel: () -> Void

    static func number(_ title: String, _ value: Binding<Double>, identifier: String) -> CommitField {
        CommitField(title: title, value: value.wrappedValue, identifier: identifier) { value.wrappedValue = $0 }
    }

    /// btn:[OK].
    func ok() {
        commit(model)
    }

    /// The dash field's commit: a valid list replaces the dash, anything else is refused.
    static func dash(_ line: Binding<Wiretuner_Doc_V1_TextLineEffect>) -> (String) -> Void {
        { text in if let dash = TextEffectSheetModel.dash(text) { line.wrappedValue.dash = dash } }
    }

    static func count(_ inline: Binding<Wiretuner_Doc_V1_TextInlineEffect>) -> Binding<Double> {
        Binding(get: { Double(inline.wrappedValue.count) }, set: { inline.wrappedValue.count = UInt32(min(max($0.rounded(), 1), 100)) })
    }

    static func tint(_ shadow: Binding<Wiretuner_Doc_V1_TextShadowEffect>) -> Binding<Double> {
        Binding(get: { shadow.wrappedValue.tint }, set: { shadow.wrappedValue.tint = min(max($0, 0), 100) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(model.kind.title) Effect").font(.headline)
            Form {
                switch model.kind.sheet {
                case .line?:
                    Self.number("Position", $model.line.position, identifier: "textEffect.position")
                    CommitTextField(title: "Dash", value: TextEffectSheetModel.dashText(model.line.dash), identifier: "textEffect.dash", commit: Self.dash($model.line))
                    Self.number("Stroke width", $model.line.width, identifier: "textEffect.width")
                    ColorPicker("Color", selection: EffectColor.binding($model.line.color)).accessibilityIdentifier("textEffect.color")
                    Toggle("Overprint", isOn: $model.line.overprint).accessibilityIdentifier("textEffect.overprint")
                case .inline?:
                    Self.number("Count", Self.count($model.inline), identifier: "textEffect.count")
                    Self.number("Stroke width", $model.inline.strokeWidth, identifier: "textEffect.strokeWidth")
                    ColorPicker("Stroke color", selection: EffectColor.binding($model.inline.strokeColor)).accessibilityIdentifier("textEffect.strokeColor")
                    Self.number("Background width", $model.inline.backgroundWidth, identifier: "textEffect.backgroundWidth")
                    ColorPicker("Background color", selection: EffectColor.binding($model.inline.backgroundColor)).accessibilityIdentifier("textEffect.backgroundColor")
                case .shadow?:
                    Self.number("Offset X", $model.shadow.offsetX, identifier: "textEffect.offsetX")
                    Self.number("Offset Y", $model.shadow.offsetY, identifier: "textEffect.offsetY")
                    ColorPicker("Color", selection: EffectColor.binding($model.shadow.color)).accessibilityIdentifier("textEffect.color")
                    Slider(value: Self.tint($model.shadow), in: 0...100) { Text("Tint") }.accessibilityIdentifier("textEffect.tint")
                    Self.number("Tint %", Self.tint($model.shadow), identifier: "textEffect.tintField")
                case .zoom?:
                    Self.number("Zoom to %", $model.zoom.zoomTo, identifier: "textEffect.zoomTo")
                    Self.number("Offset X", $model.zoom.offsetX, identifier: "textEffect.offsetX")
                    Self.number("Offset Y", $model.zoom.offsetY, identifier: "textEffect.offsetY")
                    ColorPicker("From", selection: EffectColor.binding($model.zoom.from)).accessibilityIdentifier("textEffect.from")
                    ColorPicker("To", selection: EffectColor.binding($model.zoom.to)).accessibilityIdentifier("textEffect.to")
                case nil:
                    EmptyView()
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("textEffect.cancel")
                Button("OK", action: ok).keyboardShortcut(.defaultAction).accessibilityIdentifier("textEffect.ok")
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
