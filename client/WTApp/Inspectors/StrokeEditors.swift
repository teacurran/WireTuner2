import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// What the stroke editors read and the commands they perform (ATTR-006 Basic, ATTR-015
/// Calligraphic, Custom and Pattern; the brush pop-up and its sheet are ATTR-009).  Every value is
/// nil when the selected objects' strokes differ; every edit is one change over all of them.
@MainActor
struct StrokeEditorModel {
    let context: AttributeEditorContext
    var presets: StrokePresetStore = .shared
    /// *Default line weights* (Settings › Object), in points.
    var widthPresets: [String] = PreferenceCatalog.Object.defaultLineWeights.defaultValue
    /// Where Paste In reads and Copy Out writes.
    var pasteboard: (any ObjectPasteboard)?

    static let maximumWidth = 16_164.0
    static let kinds: [(Wiretuner_Doc_V1_StrokeKind, String)] = [
        (.basic, "Basic"), (.brush, "Brush"), (.calligraphic, "Calligraphic"), (.custom, "Custom"), (.pattern, "Pattern"),
    ]
    static let caps: [(Wiretuner_Doc_V1_LineCap, String)] = [(.butt, "Butt"), (.round, "Round"), (.square, "Square")]
    static let joins: [(Wiretuner_Doc_V1_LineJoin, String)] = [(.miter, "Miter"), (.round, "Round"), (.bevel, "Bevel")]

    var pairs: [(node: OpID, row: AppearanceRow)] { context.pairs }

    private func settings<T: Equatable>(_ read: (Wiretuner_Doc_V1_StrokeSettings) -> T) -> T? {
        context.shared { read($0.stroke.settings) }
    }

    private func edit(_ label: String, _ fields: [[UInt32]], _ build: (inout Wiretuner_Doc_V1_StrokeSettings) -> Void) -> EditAttribute {
        EditAttribute.stroke(pairs, label, fields, build)
    }

    /// The live kind, nil when the strokes differ.
    var kind: Wiretuner_Doc_V1_StrokeKind? {
        context.shared { entry -> Wiretuner_Doc_V1_StrokeKind? in
            if case .stroke(let kind) = entry.kind { return kind }
            return nil
        } ?? nil
    }

    func setKind(_ kind: Wiretuner_Doc_V1_StrokeKind) -> any WTModel.Command {
        SetAttributeKind(pairs, stroke: kind)
    }

    // MARK: Widths

    /// The width pop-up's presets: Hairline (0) and the preference's values, in points.
    var widthChoices: [Double] {
        var result: [Double] = [0]
        for text in widthPresets {
            if let value = Double(text), value > 0, value <= Self.maximumWidth, !result.contains(value) { result.append(value) }
        }
        return result
    }

    /// A typed width: "Hairline", or a length in points (units and arithmetic as in every numeric
    /// field).  Above the maximum it clamps with a beep; negative or unreadable, it beeps and
    /// returns nil.
    func width(from text: String, current: Double?) -> Double? {
        if text.trimmingCharacters(in: .whitespaces).lowercased() == "hairline" { return 0 }
        guard let value = try? Measure.parse(text, unit: .points, current: current ?? 0), value >= 0 else {
            context.beep()
            return nil
        }
        return clampedWidth(value)
    }

    /// `value` within 0 ... 16,164 pt, beeping when it had to clamp.
    func clampedWidth(_ value: Double) -> Double {
        guard value <= Self.maximumWidth else {
            context.beep()
            return Self.maximumWidth
        }
        return max(value, 0)
    }

    // MARK: Basic

    var basicColor: Wiretuner_Doc_V1_ColorRef? { settings(\.basic.color) }
    var basicWidth: Double? { settings(\.basic.width) }
    var cap: Wiretuner_Doc_V1_LineCap? { settings { $0.basic.cap == .unspecified ? .butt : $0.basic.cap } }
    var join: Wiretuner_Doc_V1_LineJoin? { settings { $0.basic.join == .unspecified ? .miter : $0.basic.join } }
    /// Unset reads as 4.
    var miterLimit: Double? { settings { $0.basic.miterLimit == 0 ? 4 : $0.basic.miterLimit } }
    var dash: Wiretuner_Doc_V1_DashPattern? { settings(\.basic.dash) }
    var startArrowhead: Wiretuner_Doc_V1_Arrowhead? { settings(\.basic.startArrowhead) }
    var endArrowhead: Wiretuner_Doc_V1_Arrowhead? { settings(\.basic.endArrowhead) }
    var basicOverprint: Bool? { settings(\.basic.overprint) }

    func setBasicColor(_ color: Wiretuner_Doc_V1_ColorRef) -> any WTModel.Command {
        edit("Change stroke color", [AttributeFields.Basic.color]) { $0.basic.color = color }
    }

    func setBasicWidth(_ width: Double) -> any WTModel.Command {
        let value = clampedWidth(width)
        return edit("Change stroke width", [AttributeFields.Basic.width]) { $0.basic.width = Measure.rounded(value) }
    }

    func setCap(_ cap: Wiretuner_Doc_V1_LineCap) -> any WTModel.Command {
        edit("Change cap", [AttributeFields.Basic.cap]) { $0.basic.cap = cap }
    }

    func setJoin(_ join: Wiretuner_Doc_V1_LineJoin) -> any WTModel.Command {
        edit("Change join", [AttributeFields.Basic.join]) { $0.basic.join = join }
    }

    /// 1 ... 57.
    func setMiterLimit(_ limit: Double) -> any WTModel.Command {
        edit("Change miter limit", [AttributeFields.Basic.miterLimit]) { $0.basic.miterLimit = min(max(limit, 1), 57) }
    }

    func setBasicOverprint(_ overprint: Bool) -> any WTModel.Command {
        edit("Overprint", [AttributeFields.Basic.overprint]) { $0.basic.overprint = overprint }
    }

    // MARK: Dashes

    /// The *Dash* pop-up: the built-in dashes, those saved on this Mac, then any other dash a
    /// stroke in the document uses.
    var dashChoices: [DashChoice] {
        var result = DashPreset.builtIns.map { DashChoice(name: $0.name, lengths: $0.lengths) }
        for dash in presets.dashes + Self.documentDashes(context.document.state) where !result.contains(where: { $0.lengths == dash.lengths }) {
            result.append(dash)
        }
        return result
    }

    /// The custom dashes strokes in the document use.
    static func documentDashes(_ state: EngineState) -> [DashChoice] {
        DocumentStrokes.basics(in: state).compactMap { basic in
            basic.dash.lengths.contains { $0 > 0 } ? DashChoice(name: basic.dash.name.isEmpty ? DashChoice.name(for: basic.dash.lengths) : basic.dash.name,
                                                               lengths: basic.dash.lengths) : nil
        }
    }

    /// The dash the strokes share, as a choice; nil for *No dash* or mixed.
    var dashChoice: DashChoice? {
        guard let dash, dash.lengths.contains(where: { $0 > 0 }) else { return nil }
        return DashChoice(name: dash.name, lengths: dash.lengths)
    }

    /// Choosing a dash (nil: *No dash*): the chosen lengths are copied into every stroke.
    func setDash(_ choice: DashChoice?) -> any WTModel.Command {
        edit("Change dash", [AttributeFields.Basic.dash]) { settings in
            if let choice { settings.basic.dash = choice.pattern }
        }
    }

    /// The Dash Editor's btn:[OK]: saved on this Mac and applied.
    func applyEditedDash(_ choice: DashChoice) -> any WTModel.Command {
        presets.add(choice)
        return setDash(choice)
    }

    // MARK: Arrowheads

    /// The arrowhead pop-ups: the built-in heads, those saved on this Mac, then any other head a
    /// stroke in the document uses.
    var arrowheadChoices: [Wiretuner_Doc_V1_Arrowhead] {
        var result = Arrowhead.builtIns.map(InlineShapes.arrowhead)
        for head in presets.arrowheads + Self.documentArrowheads(context.document.state) where !result.contains(where: { $0.contours == head.contours }) {
            result.append(head)
        }
        return result
    }

    static func documentArrowheads(_ state: EngineState) -> [Wiretuner_Doc_V1_Arrowhead] {
        DocumentStrokes.basics(in: state).flatMap { [$0.startArrowhead, $0.endArrowhead] }.filter { !$0.contours.isEmpty }
    }

    /// Choosing an arrowhead for the start (`end` false) or end of the path; nil removes it.
    func setArrowhead(_ head: Wiretuner_Doc_V1_Arrowhead?, end: Bool) -> any WTModel.Command {
        edit("Change arrowhead", [end ? AttributeFields.Basic.endArrowhead : AttributeFields.Basic.startArrowhead]) { settings in
            guard let head else { return }
            if end { settings.basic.endArrowhead = head } else { settings.basic.startArrowhead = head }
        }
    }

    /// A pop-up title for `head`.
    static func title(_ head: Wiretuner_Doc_V1_Arrowhead?) -> String {
        guard let head, !head.contours.isEmpty else { return "None" }
        return head.name.isEmpty ? "Custom" : head.name
    }

    // MARK: Calligraphic

    var calligraphicColor: Wiretuner_Doc_V1_ColorRef? { settings(\.calligraphic.color) }
    var nibWidth: Double? { settings(\.calligraphic.width) }
    var nibHeight: Double? { settings(\.calligraphic.height) }
    var nibAngle: Double? { settings(\.calligraphic.angle) }
    var nib: [Wiretuner_Doc_V1_Contour] { context.entries[0].stroke.settings.calligraphic.nib }

    func setCalligraphicColor(_ color: Wiretuner_Doc_V1_ColorRef) -> any WTModel.Command {
        edit("Change stroke color", [AttributeFields.Calligraphic.color]) { $0.calligraphic.color = color }
    }

    func setNib(width: Double? = nil, height: Double? = nil, angle: Double? = nil) -> any WTModel.Command {
        var fields: [[UInt32]] = []
        if width != nil { fields.append(AttributeFields.Calligraphic.width) }
        if height != nil { fields.append(AttributeFields.Calligraphic.height) }
        if angle != nil { fields.append(AttributeFields.Calligraphic.angle) }
        return edit(angle != nil ? "Change nib angle" : "Change nib size", fields) { settings in
            if let width { settings.calligraphic.width = clampedWidth(width) }
            if let height { settings.calligraphic.height = clampedWidth(height) }
            if let angle { settings.calligraphic.angle = angle }
        }
    }

    func setNibWidth(_ value: Double) -> any WTModel.Command { setNib(width: value) }
    func setNibHeight(_ value: Double) -> any WTModel.Command { setNib(height: value) }
    func setNibAngle(_ value: Double) -> any WTModel.Command { setNib(angle: value) }

    /// btn:[Paste In]: the pasteboard's single closed path becomes the nib, or the reason it
    /// cannot.
    func pasteNib() -> Result<any WTModel.Command, PasteInError> {
        guard let bytes = pasteboard?.read(), let payload = ClipboardPayload(decoding: bytes) else { return .failure(.empty) }
        do {
            let nib = try Subtrees.nib(from: payload)
            return .success(edit("Paste In", [AttributeFields.Calligraphic.nib]) { $0.calligraphic.nib = nib })
        } catch {
            return .failure(error)
        }
    }

    /// btn:[Copy Out]: the nib as a closed path on the pasteboard (no change).
    func copyNib() {
        let payload = nibOutline
        pasteboard?.write(payload.encoded())
    }

    /// The first stroke's nib as a closed path at its size and angle.
    var nibOutline: ClipboardPayload {
        let calligraphic = context.entries[0].stroke.settings.calligraphic
        return Subtrees.nibPayload(calligraphic.nib, width: calligraphic.width, height: calligraphic.height, angle: calligraphic.angle)
    }

    /// The nib preview: the nib's outline at its size and angle.
    var nibPreview: CGImage {
        let outline = Appearances.display(nibOutline.nodes[0].props.path.contours)
        let bounds = outline.controlBounds!
        let size = Size(width: 48, height: 48)
        let scale = min(40 / bounds.width, 40 / bounds.height, 4)
        let transform = AffineTransform.translation(x: -bounds.midX, y: -bounds.midY)
            .concatenating(.scale(x: scale, y: scale)).concatenating(.translation(x: size.width / 2, y: size.height / 2))
        let item = PathItem(path: outline, appearance: Appearance([.fill(FillPaint(paint: .solid(.black)))]), transform: transform)
        return AttributePreview.render(.path(item), size: size)!
    }

    // MARK: Custom

    var customPattern: Wiretuner_Doc_V1_CustomStrokePattern? { settings(\.custom.pattern) }
    var customColor: Wiretuner_Doc_V1_ColorRef? { settings(\.custom.color) }
    var customWidth: Double? { settings(\.custom.width) }
    var customLength: Double? { settings(\.custom.length) }
    var customSpacing: Double? { settings(\.custom.spacing) }

    func setCustomPattern(_ pattern: Wiretuner_Doc_V1_CustomStrokePattern) -> any WTModel.Command {
        edit("Change pattern", [AttributeFields.CustomStroke.pattern]) { $0.custom.pattern = pattern }
    }

    func setCustomColor(_ color: Wiretuner_Doc_V1_ColorRef) -> any WTModel.Command {
        edit("Change stroke color", [AttributeFields.CustomStroke.color]) { $0.custom.color = color }
    }

    func setCustom(width: Double? = nil, length: Double? = nil, spacing: Double? = nil) -> any WTModel.Command {
        var fields: [[UInt32]] = []
        if width != nil { fields.append(AttributeFields.CustomStroke.width) }
        if length != nil { fields.append(AttributeFields.CustomStroke.length) }
        if spacing != nil { fields.append(AttributeFields.CustomStroke.spacing) }
        return edit(width != nil ? "Change stroke width" : length != nil ? "Change length" : "Change spacing", fields) { settings in
            if let width { settings.custom.width = clampedWidth(width) }
            if let length { settings.custom.length = max(length, 0) }
            if let spacing { settings.custom.spacing = max(spacing, 0) }
        }
    }

    func setCustomWidth(_ value: Double) -> any WTModel.Command { setCustom(width: value) }
    func setCustomLength(_ value: Double) -> any WTModel.Command { setCustom(length: value) }
    func setCustomSpacing(_ value: Double) -> any WTModel.Command { setCustom(spacing: value) }

    // MARK: Pattern

    var patternColor: Wiretuner_Doc_V1_ColorRef? { settings(\.pattern.color) }
    var patternWidth: Double? { settings(\.pattern.width) }
    var bitmap: [UInt8] { Array(context.entries[0].stroke.settings.pattern.bitmap.rows) }

    func setPatternColor(_ color: Wiretuner_Doc_V1_ColorRef) -> any WTModel.Command {
        edit("Change stroke color", [AttributeFields.PatternStroke.color]) { $0.pattern.color = color }
    }

    func setPatternWidth(_ width: Double) -> any WTModel.Command {
        edit("Change stroke width", [AttributeFields.PatternStroke.width]) { $0.pattern.width = clampedWidth(width) }
    }

    func setBitmap(_ rows: [UInt8]) -> any WTModel.Command {
        edit("Edit pattern", [AttributeFields.PatternStroke.bitmap]) { $0.pattern.bitmap.rows = Data(PatternEditorState.normalized(rows)) }
    }

    // MARK: Brush

    var brushColor: Wiretuner_Doc_V1_ColorRef? { settings(\.brush.color) }
    var brushWidth: Double? { settings(\.brush.widthPercent) }

    func setBrushColor(_ color: Wiretuner_Doc_V1_ColorRef) -> any WTModel.Command {
        edit("Change stroke color", [AttributeFields.Brush.color]) { $0.brush.color = color }
    }

    /// 1% ... 400%.
    func setBrushWidth(_ percent: Double) -> any WTModel.Command {
        edit("Change brush width", [AttributeFields.Brush.widthPercent]) { $0.brush.widthPercent = min(max(percent, 1), 400) }
    }

    /// The editor's preview of the first stroke.
    var preview: CGImage? { context.entries.first.flatMap { AttributePreview.image($0) } }

    /// The display-list colour of a stored one, for the pattern preview.
    static func renderColor(_ ref: Wiretuner_Doc_V1_ColorRef?) -> RenderColor {
        ref.flatMap(Appearances.color) ?? .black
    }
}

/// Every basic stroke of every live object, for the pop-ups' "used in the document" entries.
enum DocumentStrokes {
    static func basics(in state: EngineState) -> [Wiretuner_Doc_V1_BasicStroke] {
        var result: [Wiretuner_Doc_V1_BasicStroke] = []
        var pending = state.liveChildren(WellKnown.layers)
        while let node = pending.popLast() {
            pending += state.liveChildren(node)
            for entry in AppearanceEditing.entries(node, in: state) where entry.row.list == .strokes {
                result.append(entry.stroke.settings.basic)
            }
        }
        return result
    }
}

/// The stroke editor: the *Stroke type* pop-up and the live kind's form.
struct StrokeEditorView: View {
    let model: StrokeEditorModel
    @State private var patternState = PatternEditorState()
    @State private var dashEditor: DashEditorModel?
    @State private var managingDashes = false
    @State private var managingArrowheads = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AttributePicker(title: "Stroke type", value: model.kind, choices: StrokeEditorModel.kinds, identifier: "stroke.kind",
                            commit: model.context.committing(model.setKind))
            switch model.kind {
            case .calligraphic?: calligraphic
            case .custom?: custom
            case .pattern?: pattern
            case .brush?: brush
            case .basic?: basic
            default: EmptyView()
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.red).accessibilityIdentifier("stroke.message")
            }
        }
        .sheet(item: Self.dashBinding($dashEditor)) { editor in
            Self.dashSheet(editor.model, model: model) { dashEditor = nil }
        }
        .sheet(isPresented: $managingDashes) { Self.presetsSheet(arrowheads: false, model: model) { managingDashes = false } }
        .sheet(isPresented: $managingArrowheads) { Self.presetsSheet(arrowheads: true, model: model) { managingArrowheads = false } }
    }

    /// The Dash Editor sheet: btn:[OK] saves and applies the dash; both buttons close it.
    static func dashSheet(_ editor: DashEditorModel, model: StrokeEditorModel, close: @escaping () -> Void) -> DashEditorSheet {
        DashEditorSheet(model: editor, apply: { choice in
            model.context.perform(model.applyEditedDash(choice))
            close()
        }, cancel: close)
    }

    /// *Manage Dashes…* or *Manage Arrowheads…*.
    static func presetsSheet(arrowheads: Bool, model: StrokeEditorModel, done: @escaping () -> Void) -> ManagePresetsSheet {
        let presets = model.presets
        if arrowheads {
            return ManagePresetsSheet(title: "Manage Arrowheads", names: presets.arrowheads.map(StrokeEditorModel.title),
                                      remove: { presets.removeArrowhead(at: $0) }, done: done)
        }
        return ManagePresetsSheet(title: "Manage Dashes", names: presets.dashes.map(\.name), remove: { presets.removeDash(at: $0) }, done: done)
    }

    /// A sheet binding over the optional editor model.
    struct DashSheet: Identifiable {
        var model: DashEditorModel
        var id: Int { 0 }
    }

    static func dashBinding(_ binding: Binding<DashEditorModel?>) -> Binding<DashSheet?> {
        Binding(get: { binding.wrappedValue.map { DashSheet(model: $0) } }, set: { binding.wrappedValue = $0?.model })
    }

    /// The *Dash* pop-up's action for `choice`: kbd:[Option] opens the Dash Editor on it.
    static func chooseDash(_ choice: DashChoice?, option: Bool, model: StrokeEditorModel, edit: (DashEditorModel) -> Void) {
        if option {
            edit(DashEditorModel(lengths: choice?.lengths ?? []))
        } else {
            model.context.perform(model.setDash(choice))
        }
    }

    static var optionHeld: Bool { NSEvent.modifierFlags.contains(.option) }

    /// A *Dash* pop-up item's action.
    static func dashAction(_ choice: DashChoice?, model: StrokeEditorModel, option: @escaping @MainActor () -> Bool = { optionHeld },
                           edit: @escaping (DashEditorModel) -> Void) -> () -> Void {
        { chooseDash(choice, option: option(), model: model, edit: edit) }
    }

    /// An arrowhead pop-up item's action.
    static func arrowheadAction(_ head: Wiretuner_Doc_V1_Arrowhead?, end: Bool, model: StrokeEditorModel) -> () -> Void {
        { model.context.perform(model.setArrowhead(head, end: end)) }
    }

    /// *New…* until the Arrowhead Editor (ATTR-030) exists.
    static func unavailable() {}

    private func editDash(_ editor: DashEditorModel) { dashEditor = editor }
    private func paste() { message = Self.paste(model) }

    @ViewBuilder private var basic: some View {
        AttributeColorControl(title: "Color", color: model.basicColor, identifier: "stroke.basic.color", document: model.context.document, commit: model.context.committing(model.setBasicColor))
        WidthField(model: model, value: model.basicWidth, identifier: "stroke.basic.width", command: model.setBasicWidth)
        AttributePicker(title: "Cap", value: model.cap, choices: StrokeEditorModel.caps, identifier: "stroke.basic.cap", commit: model.context.committing(model.setCap))
            .pickerStyle(.segmented)
        AttributePicker(title: "Join", value: model.join, choices: StrokeEditorModel.joins, identifier: "stroke.basic.join", commit: model.context.committing(model.setJoin))
            .pickerStyle(.segmented)
        CommitField(title: "Miter limit", value: model.miterLimit, identifier: "stroke.basic.miter", commit: model.context.committing(model.setMiterLimit))
        Menu(model.dashChoice?.name ?? (model.dash == nil ? "Mixed" : "No dash")) {
            Button("No dash", action: Self.dashAction(nil, model: model, edit: editDash))
            ForEach(model.dashChoices, id: \.self) { choice in
                Button(choice.name, action: Self.dashAction(choice, model: model, edit: editDash))
            }
            Divider()
            Button("Edit Dash…") { dashEditor = DashEditorModel(lengths: model.dashChoice?.lengths ?? []) }
            Button("Manage Dashes…") { managingDashes = true }
        }
        .accessibilityIdentifier("stroke.basic.dash")
        HStack {
            arrowheadMenu(end: false)
            arrowheadMenu(end: true)
        }
        AttributeToggle(title: "Overprint", value: model.basicOverprint, identifier: "stroke.basic.overprint", commit: model.context.committing(model.setBasicOverprint))
    }

    private func arrowheadMenu(end: Bool) -> some View {
        Menu(StrokeEditorModel.title(end ? model.endArrowhead : model.startArrowhead)) {
            Button("None", action: Self.arrowheadAction(nil, end: end, model: model))
            ForEach(Array(model.arrowheadChoices.enumerated()), id: \.offset) { _, head in
                Button(StrokeEditorModel.title(head), action: Self.arrowheadAction(head, end: end, model: model))
            }
            Divider()
            Button("New…", action: Self.unavailable).disabled(true)
            Button("Manage Arrowheads…") { managingArrowheads = true }
        }
        .accessibilityIdentifier(end ? "stroke.basic.end-arrowhead" : "stroke.basic.start-arrowhead")
    }

    @ViewBuilder private var calligraphic: some View {
        AttributeColorControl(title: "Color", color: model.calligraphicColor, identifier: "stroke.calligraphic.color", document: model.context.document,
                              commit: model.context.committing(model.setCalligraphicColor))
        CommitField(title: "Width", value: model.nibWidth, identifier: "stroke.calligraphic.width", commit: model.context.committing(model.setNibWidth))
        CommitField(title: "Height", value: model.nibHeight, identifier: "stroke.calligraphic.height", commit: model.context.committing(model.setNibHeight))
        CommitField(title: "Angle", value: model.nibAngle, identifier: "stroke.calligraphic.angle", commit: model.context.committing(model.setNibAngle))
        HStack {
            AttributePreviewImage(image: model.nibPreview, size: Size(width: 48, height: 48), identifier: "stroke.calligraphic.nib")
            Button("Paste In", action: paste).accessibilityIdentifier("stroke.calligraphic.paste")
            Button("Copy Out", action: model.copyNib).accessibilityIdentifier("stroke.calligraphic.copy")
        }
    }

    /// btn:[Paste In]: performs the paste, or returns the refusal to show.
    static func paste(_ model: StrokeEditorModel) -> String? {
        switch model.pasteNib() {
        case .success(let command):
            model.context.perform(command)
            return nil
        case .failure(let error):
            return error.message
        }
    }

    @ViewBuilder private var custom: some View {
        AttributePicker(title: "Pattern", value: model.customPattern, choices: AttributeNames.customStrokePatterns, identifier: "stroke.custom.pattern",
                        commit: model.context.committing(model.setCustomPattern))
        AttributePreviewImage(image: model.preview, identifier: "stroke.custom.preview")
        AttributeColorControl(title: "Color", color: model.customColor, identifier: "stroke.custom.color", document: model.context.document, commit: model.context.committing(model.setCustomColor))
        WidthField(model: model, value: model.customWidth, identifier: "stroke.custom.width", command: model.setCustomWidth)
        CommitField(title: "Length", value: model.customLength, identifier: "stroke.custom.length", commit: model.context.committing(model.setCustomLength))
        CommitField(title: "Spacing", value: model.customSpacing, identifier: "stroke.custom.spacing", commit: model.context.committing(model.setCustomSpacing))
    }

    @ViewBuilder private var pattern: some View {
        AttributeColorControl(title: "Color", color: model.patternColor, identifier: "stroke.pattern.color", document: model.context.document, commit: model.context.committing(model.setPatternColor))
        WidthField(model: model, value: model.patternWidth, identifier: "stroke.pattern.width", command: model.setPatternWidth)
        PatternEditorView(bitmap: model.bitmap, color: StrokeEditorModel.renderColor(model.patternColor), state: patternState,
                          commit: model.context.committing(model.setBitmap))
    }

    @ViewBuilder private var brush: some View {
        AttributeColorControl(title: "Color", color: model.brushColor, identifier: "stroke.brush.color", document: model.context.document, commit: model.context.committing(model.setBrushColor))
        CommitField(title: "Width %", value: model.brushWidth, identifier: "stroke.brush.width", commit: model.context.committing(model.setBrushWidth))
        Text("Brushes are chosen and edited with the brush pop-up once the brush editor is available.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// The width combo box: a field (units, arithmetic, "Hairline") and a pop-up of the presets.
struct WidthField: View {
    let model: StrokeEditorModel
    let value: Double?
    let identifier: String
    let command: (Double) -> any WTModel.Command

    var body: some View {
        HStack {
            CommitTextField(title: "Width", value: value.map(AttributeNames.points), identifier: identifier, commit: Self.committing(model: model, value: value, command: command))
            Menu("Presets") {
                ForEach(model.widthChoices, id: \.self) { width in
                    Button(AttributeNames.points(width), action: Self.preset(width, model: model, command: command))
                }
            }
            .frame(width: 80)
            .accessibilityIdentifier("\(identifier).presets")
        }
    }

    /// A preset's action.
    static func preset(_ width: Double, model: StrokeEditorModel, command: @escaping (Double) -> any WTModel.Command) -> () -> Void {
        { model.context.perform(command(width)) }
    }

    static func committing(model: StrokeEditorModel, value: Double?, command: @escaping (Double) -> any WTModel.Command) -> (String) -> Void {
        { commit($0, model: model, value: value, command: command) }
    }

    /// A typed width, written when it reads as one.
    static func commit(_ text: String, model: StrokeEditorModel, value: Double?, command: (Double) -> any WTModel.Command) {
        guard let width = model.width(from: text, current: value) else { return }
        model.context.perform(command(width))
    }
}
