import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// One option of a Custom fill's form (fill-attributes.adoc, "Custom fills": each pattern shows
/// only the options it uses).
enum CustomFillOption: Hashable {
    case color, mortar, background, width, height, radius, sideLength, spacing, angle, angle1, angle2, whiteness, gray, count, teethCount

    var title: String {
        switch self {
        case .color: "Color"
        case .mortar: "Mortar"
        case .background: "Background"
        case .width: "Width"
        case .height: "Height"
        case .radius: "Radius"
        case .sideLength: "Side length"
        case .spacing: "Spacing"
        case .angle: "Angle"
        case .angle1: "Angle 1"
        case .angle2: "Angle 2"
        case .whiteness: "Whiteness"
        case .gray: "Gray"
        case .count, .teethCount: "Count"
        }
    }

    var isColor: Bool { [.color, .mortar, .background].contains(self) }

    /// The option's register in the fill's settings.
    var path: [UInt32] {
        switch self {
        case .color: AttributeFields.CustomFill.color
        case .mortar, .background: AttributeFields.CustomFill.color2
        case .width: AttributeFields.CustomFill.width
        case .height: AttributeFields.CustomFill.height
        case .radius: AttributeFields.CustomFill.radius
        case .sideLength: AttributeFields.CustomFill.side
        case .spacing: AttributeFields.CustomFill.spacing
        case .angle, .angle1: AttributeFields.CustomFill.angle
        case .angle2: AttributeFields.CustomFill.angle2
        case .whiteness, .gray: AttributeFields.CustomFill.whiteness
        case .count, .teethCount: AttributeFields.CustomFill.count
        }
    }

    /// The accepted values of a number option.
    var range: ClosedRange<Double> {
        switch self {
        case .whiteness, .gray: 0...100
        case .count: 1...32_000
        case .teethCount: 1...700
        case .angle, .angle1, .angle2: -360...360
        default: 0...16_164
        }
    }

    /// The options each pattern shows, in the table's order.
    static func options(_ pattern: Wiretuner_Doc_V1_CustomFillPattern) -> [CustomFillOption] {
        switch pattern {
        case .bricks: [.color, .mortar, .width, .height, .angle]
        case .circles: [.color, .radius, .spacing, .angle]
        case .hatch: [.color, .angle1, .angle2, .spacing, .width]
        case .noise: [.whiteness]
        case .randomGrass, .randomLeaves: [.count]
        case .squares: [.color, .sideLength, .spacing, .angle, .width]
        case .tigerTeeth: [.color, .background, .teethCount, .angle]
        case .topNoise: [.gray]
        default: []
        }
    }
}

/// What the fill editors read and the commands they perform (ATTR-017).  Values are nil when the
/// selected objects' fills differ; every edit is one change over all of them.
@MainActor
struct FillEditorModel {
    let context: AttributeEditorContext
    /// Where Paste In reads and Copy Out writes.
    var pasteboard: (any ObjectPasteboard)?

    /// The *Fill type* pop-up.
    static let kinds: [(Wiretuner_Doc_V1_FillKind, String)] = [
        (.basic, "Basic"), (.gradient, "Gradient"), (.lens, "Lens"), (.custom, "Custom"), (.pattern, "Pattern"), (.textured, "Textured"),
        (.tiled, "Tiled"),
    ]

    var pairs: [(node: OpID, row: AppearanceRow)] { context.pairs }

    private func settings<T: Equatable>(_ read: (Wiretuner_Doc_V1_FillSettings) -> T) -> T? {
        context.shared { read($0.fill.settings) }
    }

    private func edit(_ label: String, _ fields: [[UInt32]], _ build: (inout Wiretuner_Doc_V1_FillSettings) -> Void) -> EditAttribute {
        EditAttribute.fill(pairs, label, fields, build)
    }

    var kind: Wiretuner_Doc_V1_FillKind? {
        context.shared { entry -> Wiretuner_Doc_V1_FillKind? in
            if case .fill(let kind) = entry.kind { return kind }
            return nil
        } ?? nil
    }

    /// Choosing a kind: Gradient starts a two-stop ramp when the fill has none (`ChooseGradient`);
    /// a Gradient fill switched to Basic takes the ramp's left colour (`ConvertGradientToBasic`).
    func setKind(_ kind: Wiretuner_Doc_V1_FillKind) -> any WTModel.Command {
        if kind == .gradient { return ChooseGradient(pairs) }
        if kind == .basic, self.kind == .gradient { return ConvertGradientToBasic(pairs) }
        return SetAttributeKind(pairs, fill: kind)
    }

    /// The preview of the first fill.
    var preview: CGImage? { context.entries.first.flatMap { AttributePreview.image($0) } }

    // MARK: Basic

    var basicColor: Wiretuner_Doc_V1_ColorRef? { settings(\.basic.color) }
    var basicOverprint: Bool? { settings(\.basic.overprint) }

    func setBasicColor(_ color: Wiretuner_Doc_V1_ColorRef) -> any WTModel.Command {
        edit("Change fill color", [AttributeFields.Basic.color]) { $0.basic.color = color }
    }

    func setBasicOverprint(_ overprint: Bool) -> any WTModel.Command {
        edit("Overprint", [AttributeFields.Basic.fillOverprint]) { $0.basic.overprint = overprint }
    }

    // MARK: Custom

    var customPattern: Wiretuner_Doc_V1_CustomFillPattern? { settings(\.custom.pattern) }
    var customOverprint: Bool? { settings(\.custom.overprint) }

    func setCustomPattern(_ pattern: Wiretuner_Doc_V1_CustomFillPattern) -> any WTModel.Command {
        edit("Change pattern", [AttributeFields.CustomFill.pattern]) { $0.custom.pattern = pattern }
    }

    func customColor(_ option: CustomFillOption) -> Wiretuner_Doc_V1_ColorRef? {
        settings { option == .color ? $0.custom.color : $0.custom.color2 }
    }

    func setCustomColor(_ option: CustomFillOption, _ color: Wiretuner_Doc_V1_ColorRef) -> any WTModel.Command {
        edit(option == .color ? "Change fill color" : "Change \(option.title.lowercased()) color", [option.path]) { settings in
            if option == .color { settings.custom.color = color } else { settings.custom.color2 = color }
        }
    }

    /// The commands of one option's control.
    func colorSetter(_ option: CustomFillOption) -> (Wiretuner_Doc_V1_ColorRef) -> any WTModel.Command {
        { setCustomColor(option, $0) }
    }

    func numberSetter(_ option: CustomFillOption) -> (Double) -> any WTModel.Command {
        { setCustomNumber(option, $0) }
    }

    func customNumber(_ option: CustomFillOption) -> Double? {
        settings { settings -> Double in
            let custom = settings.custom
            switch option {
            case .width: return custom.width
            case .height: return custom.height
            case .radius: return custom.radius
            case .sideLength: return custom.side
            case .spacing: return custom.spacing
            case .angle, .angle1: return custom.angle
            case .angle2: return custom.angle2
            case .whiteness, .gray: return custom.whiteness
            case .count, .teethCount: return Double(custom.count)
            case .color, .mortar, .background: return 0
            }
        }
    }

    /// A number option, clamped to its range.
    func setCustomNumber(_ option: CustomFillOption, _ value: Double) -> any WTModel.Command {
        let value = min(max(value, option.range.lowerBound), option.range.upperBound)
        return edit("Change \(option.title.lowercased())", [option.path]) { settings in
            switch option {
            case .width: settings.custom.width = value
            case .height: settings.custom.height = value
            case .radius: settings.custom.radius = value
            case .sideLength: settings.custom.side = value
            case .spacing: settings.custom.spacing = value
            case .angle, .angle1: settings.custom.angle = value
            case .angle2: settings.custom.angle2 = value
            case .whiteness, .gray: settings.custom.whiteness = value
            case .count, .teethCount: settings.custom.count = UInt32(value.rounded())
            case .color, .mortar, .background: break
            }
        }
    }

    func setCustomOverprint(_ overprint: Bool) -> any WTModel.Command {
        edit("Overprint", [AttributeFields.CustomFill.overprint]) { $0.custom.overprint = overprint }
    }

    // MARK: Lens

    var lensType: Wiretuner_Doc_V1_LensType? { settings { $0.lens.type == .unspecified ? .transparency : $0.lens.type } }
    var lensColor: Wiretuner_Doc_V1_ColorRef? { settings(\.lens.color) }
    var lensAmount: Double? { settings(\.lens.amount) }
    var magnification: Double? { settings { max($0.lens.magnification, 1) } }
    var centerpointShown: Bool? { settings(\.lens.centerpointShown) }
    var objectsOnly: Bool? { settings(\.lens.objectsOnly) }
    var snapshot: Bool? { settings(\.lens.snapshot) }

    /// Which lens options the chosen lens shows.
    static func showsColor(_ type: Wiretuner_Doc_V1_LensType?) -> Bool { type == .transparency || type == .monochrome }
    static func showsAmount(_ type: Wiretuner_Doc_V1_LensType?) -> Bool { [.transparency, .lighten, .darken].contains(type) }
    static func showsMagnification(_ type: Wiretuner_Doc_V1_LensType?) -> Bool { type == .magnify }

    func setLensType(_ type: Wiretuner_Doc_V1_LensType) -> any WTModel.Command {
        EditAttribute.lensType(pairs, type)
    }

    func setLensColor(_ color: Wiretuner_Doc_V1_ColorRef) -> any WTModel.Command {
        edit("Change lens color", [AttributeFields.Lens.color]) { $0.lens.color = color }
    }

    /// 0 ... 100.
    func setLensAmount(_ amount: Double) -> any WTModel.Command {
        edit("Change amount", [AttributeFields.Lens.amount]) { $0.lens.amount = min(max(amount, 0), 100) }
    }

    /// 1 ... 20.
    func setMagnification(_ value: Double) -> any WTModel.Command {
        edit("Change magnification", [AttributeFields.Lens.magnification]) { $0.lens.magnification = min(max(value, 1), 20) }
    }

    func setCenterpointShown(_ shown: Bool) -> any WTModel.Command {
        edit("Centerpoint", [AttributeFields.Lens.centerpointShown]) { $0.lens.centerpointShown = shown }
    }

    func setObjectsOnly(_ on: Bool) -> any WTModel.Command {
        edit("Objects only", [AttributeFields.Lens.objectsOnly]) { $0.lens.objectsOnly = on }
    }

    /// *Snapshot*: on freezes the lens -- what it shows now captured with the flag in one change
    /// (`SnapshotLens`, ATTR-020) -- off returns it to live and drops the captured contents.
    func setSnapshot(_ on: Bool) -> any WTModel.Command {
        guard !on else { return SnapshotLens(pairs) }
        return edit("Snapshot", [AttributeFields.Lens.snapshot, AttributeFields.Lens.snapshotContents]) { $0.lens.snapshot = false }
    }

    // MARK: Pattern

    var patternColor: Wiretuner_Doc_V1_ColorRef? { settings(\.pattern.color) }
    var patternOverprint: Bool? { settings(\.pattern.overprint) }
    var bitmap: [UInt8] { Array(context.entries[0].fill.settings.pattern.bitmap.rows) }

    func setPatternColor(_ color: Wiretuner_Doc_V1_ColorRef) -> any WTModel.Command {
        edit("Change fill color", [AttributeFields.PatternFill.color]) { $0.pattern.color = color }
    }

    func setBitmap(_ rows: [UInt8]) -> any WTModel.Command {
        edit("Edit pattern", [AttributeFields.PatternFill.bitmap]) { $0.pattern.bitmap.rows = Data(PatternEditorState.normalized(rows)) }
    }

    func setPatternOverprint(_ overprint: Bool) -> any WTModel.Command {
        edit("Overprint", [AttributeFields.PatternFill.overprint]) { $0.pattern.overprint = overprint }
    }

    // MARK: Textured

    var texture: Wiretuner_Doc_V1_Texture? { settings(\.textured.texture) }
    var texturedColor: Wiretuner_Doc_V1_ColorRef? { settings(\.textured.color) }
    var texturedOverprint: Bool? { settings(\.textured.overprint) }

    func setTexture(_ texture: Wiretuner_Doc_V1_Texture) -> any WTModel.Command {
        edit("Change texture", [AttributeFields.Textured.texture]) { $0.textured.texture = texture }
    }

    func setTexturedColor(_ color: Wiretuner_Doc_V1_ColorRef) -> any WTModel.Command {
        edit("Change fill color", [AttributeFields.Textured.color]) { $0.textured.color = color }
    }

    func setTexturedOverprint(_ overprint: Bool) -> any WTModel.Command {
        edit("Overprint", [AttributeFields.Textured.overprint]) { $0.textured.overprint = overprint }
    }

    // MARK: Tiled

    var tileAngle: Double? { settings(\.tiled.angle) }
    /// Percent; 0 reads 100.
    var scaleX: Double? { settings { $0.tiled.scaleX == 0 ? 100 : $0.tiled.scaleX } }
    var scaleY: Double? { settings { $0.tiled.scaleY == 0 ? 100 : $0.tiled.scaleY } }
    var offsetX: Double? { settings(\.tiled.offset.x) }
    var offsetY: Double? { settings(\.tiled.offset.y) }
    var tiledOverprint: Bool? { settings(\.tiled.overprint) }
    var hasTile: Bool { !context.entries[0].fill.settings.tiled.tile.nodes.isEmpty }

    func setTileAngle(_ angle: Double) -> any WTModel.Command {
        edit("Change tile angle", [AttributeFields.Tiled.angle]) { $0.tiled.angle = angle }
    }

    /// Percentages; 0 or less is refused as 1%.
    func setTileScale(x: Double? = nil, y: Double? = nil) -> any WTModel.Command {
        var fields: [[UInt32]] = []
        if x != nil { fields.append(AttributeFields.Tiled.scaleX) }
        if y != nil { fields.append(AttributeFields.Tiled.scaleY) }
        return edit("Change tile scale", fields) { settings in
            if let x { settings.tiled.scaleX = max(x, 1) }
            if let y { settings.tiled.scaleY = max(y, 1) }
        }
    }

    /// The offset is one value (ATOMIC): both coordinates are written, the other kept.
    func setTileOffset(x: Double? = nil, y: Double? = nil) -> any WTModel.Command {
        let current = context.entries[0].fill.settings.tiled.offset
        return edit("Change tile offset", [AttributeFields.Tiled.offset]) { settings in
            settings.tiled.offset.x = x ?? current.x
            settings.tiled.offset.y = y ?? current.y
        }
    }

    func setTileScaleX(_ value: Double) -> any WTModel.Command { setTileScale(x: value) }
    func setTileScaleY(_ value: Double) -> any WTModel.Command { setTileScale(y: value) }
    func setTileOffsetX(_ value: Double) -> any WTModel.Command { setTileOffset(x: value) }
    func setTileOffsetY(_ value: Double) -> any WTModel.Command { setTileOffset(y: value) }

    func setTiledOverprint(_ overprint: Bool) -> any WTModel.Command {
        edit("Overprint", [AttributeFields.Tiled.overprint]) { $0.tiled.overprint = overprint }
    }

    /// btn:[Paste In]: the pasteboard's artwork becomes the tile, or the reason it cannot.
    func pasteTile() -> Result<any WTModel.Command, PasteInError> {
        guard let bytes = pasteboard?.read(), let payload = ClipboardPayload(decoding: bytes) else { return .failure(.empty) }
        do {
            let tile = try Subtrees.tile(from: payload)
            return .success(edit("Paste In", [AttributeFields.Tiled.tile]) { $0.tiled.tile = tile })
        } catch {
            return .failure(error)
        }
    }

    /// btn:[Copy Out]'s action.
    func copyOut() { copyTile() }

    /// btn:[Copy Out]: the tile's artwork on the pasteboard (no change); false when there is no
    /// tile.
    @discardableResult
    func copyTile() -> Bool {
        guard let payload = Subtrees.payload(from: context.entries[0].fill.settings.tiled.tile) else { return false }
        pasteboard?.write(payload.encoded())
        return true
    }
}

/// The fill editor: the *Fill type* pop-up and the live kind's form.
struct FillEditorView: View {
    let model: FillEditorModel
    @State private var patternState = PatternEditorState()
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AttributePicker(title: "Fill type", value: model.kind, choices: FillEditorModel.kinds, identifier: "fill.kind",
                            commit: model.context.committing(model.setKind))
            switch model.kind {
            case .gradient?: GradientEditorView(model: GradientEditorModel(context: model.context))
            case .lens?: lens
            case .custom?: custom
            case .pattern?: pattern
            case .textured?: textured
            case .tiled?: tiled
            case .basic?: basic
            default: EmptyView()
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.red).accessibilityIdentifier("fill.message")
            }
        }
    }

    private func paste() { message = Self.paste(model) }

    /// btn:[Paste In]: performs the paste, or returns the refusal to show.
    static func paste(_ model: FillEditorModel) -> String? {
        switch model.pasteTile() {
        case .success(let command):
            model.context.perform(command)
            return nil
        case .failure(let error):
            return error.message
        }
    }

    @ViewBuilder private var basic: some View {
        AttributeColorControl(title: "Color", color: model.basicColor, identifier: "fill.basic.color", document: model.context.document, commit: model.context.committing(model.setBasicColor))
        AttributeToggle(title: "Overprint", value: model.basicOverprint, identifier: "fill.basic.overprint", commit: model.context.committing(model.setBasicOverprint))
    }

    @ViewBuilder private var custom: some View {
        AttributePicker(title: "Pattern", value: model.customPattern, choices: AttributeNames.customFillPatterns, identifier: "fill.custom.pattern", commit: model.context.committing(model.setCustomPattern))
        AttributePreviewImage(image: model.preview, identifier: "fill.custom.preview")
        ForEach(CustomFillOption.options(model.customPattern ?? .unspecified), id: \.self) { option in
            if option.isColor {
                AttributeColorControl(title: option.title, color: model.customColor(option), identifier: "fill.custom.\(option)", document: model.context.document, commit: model.context.committing(model.colorSetter(option)))
            } else {
                CommitField(title: option.title, value: model.customNumber(option), identifier: "fill.custom.\(option)", commit: model.context.committing(model.numberSetter(option)))
            }
        }
        AttributeToggle(title: "Overprint", value: model.customOverprint, identifier: "fill.custom.overprint", commit: model.context.committing(model.setCustomOverprint))
    }

    @ViewBuilder private var lens: some View {
        let type = model.lensType
        AttributePicker(title: "Lens", value: type, choices: AttributeNames.lensTypes, identifier: "fill.lens.type", commit: model.context.committing(model.setLensType))
        if FillEditorModel.showsColor(type) {
            AttributeColorControl(title: "Color", color: model.lensColor, identifier: "fill.lens.color", document: model.context.document, commit: model.context.committing(model.setLensColor))
        }
        if FillEditorModel.showsAmount(type) {
            AttributeSlider(title: "Amount", value: model.lensAmount, range: 0...100, identifier: "fill.lens.amount", context: model.context, commit: model.context.committing(model.setLensAmount))
        }
        if FillEditorModel.showsMagnification(type) {
            AttributeSlider(title: "Magnification", value: model.magnification, range: 1...20, identifier: "fill.lens.magnification", context: model.context, commit: model.context.committing(model.setMagnification))
        }
        AttributeToggle(title: "Centerpoint", value: model.centerpointShown, identifier: "fill.lens.centerpoint", commit: model.context.committing(model.setCenterpointShown))
        AttributeToggle(title: "Objects only", value: model.objectsOnly, identifier: "fill.lens.objects-only", commit: model.context.committing(model.setObjectsOnly))
        AttributeToggle(title: "Snapshot", value: model.snapshot, identifier: "fill.lens.snapshot", commit: model.context.committing(model.setSnapshot))
    }

    @ViewBuilder private var pattern: some View {
        AttributeColorControl(title: "Color", color: model.patternColor, identifier: "fill.pattern.color", document: model.context.document, commit: model.context.committing(model.setPatternColor))
        PatternEditorView(bitmap: model.bitmap, color: StrokeEditorModel.renderColor(model.patternColor), state: patternState, commit: model.context.committing(model.setBitmap))
        AttributeToggle(title: "Overprint", value: model.patternOverprint, identifier: "fill.pattern.overprint", commit: model.context.committing(model.setPatternOverprint))
    }

    @ViewBuilder private var textured: some View {
        AttributePicker(title: "Texture", value: model.texture, choices: AttributeNames.textures, identifier: "fill.textured.texture", commit: model.context.committing(model.setTexture))
        AttributePreviewImage(image: model.preview, identifier: "fill.textured.preview")
        AttributeColorControl(title: "Color", color: model.texturedColor, identifier: "fill.textured.color", document: model.context.document, commit: model.context.committing(model.setTexturedColor))
        AttributeToggle(title: "Overprint", value: model.texturedOverprint, identifier: "fill.textured.overprint", commit: model.context.committing(model.setTexturedOverprint))
    }

    @ViewBuilder private var tiled: some View {
        HStack {
            AttributePreviewImage(image: model.preview, identifier: "fill.tiled.preview")
            VStack(alignment: .leading) {
                Button("Paste In", action: paste).accessibilityIdentifier("fill.tiled.paste")
                Button("Copy Out", action: model.copyOut).disabled(!model.hasTile).accessibilityIdentifier("fill.tiled.copy")
            }
        }
        HStack {
            AngleDial(value: model.tileAngle ?? 0, commit: model.context.committing(model.setTileAngle))
                .frame(width: 32, height: 32)
            CommitField(title: "Angle", value: model.tileAngle, identifier: "fill.tiled.angle", commit: model.context.committing(model.setTileAngle))
        }
        CommitField(title: "Scale x %", value: model.scaleX, identifier: "fill.tiled.scale-x", commit: model.context.committing(model.setTileScaleX))
        CommitField(title: "Scale y %", value: model.scaleY, identifier: "fill.tiled.scale-y", commit: model.context.committing(model.setTileScaleY))
        CommitField(title: "Offset x", value: model.offsetX, identifier: "fill.tiled.offset-x", commit: model.context.committing(model.setTileOffsetX))
        CommitField(title: "Offset y", value: model.offsetY, identifier: "fill.tiled.offset-y", commit: model.context.committing(model.setTileOffsetY))
        AttributeToggle(title: "Overprint", value: model.tiledOverprint, identifier: "fill.tiled.overprint", commit: model.context.committing(model.setTiledOverprint))
    }
}

/// The tile's angle dial: a circular `NSSlider`, 0° to 360°, writing on mouse-up.
struct AngleDial: NSViewRepresentable {
    let value: Double
    let commit: (Double) -> Void

    @MainActor
    final class Coordinator: NSObject {
        var commit: (Double) -> Void

        init(commit: @escaping (Double) -> Void) {
            self.commit = commit
        }

        @objc func changed(_ sender: NSSlider) {
            commit(sender.doubleValue)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(commit: commit) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: Self.normalized(value), minValue: 0, maxValue: 360, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.sliderType = .circular
        slider.isContinuous = false
        slider.setAccessibilityIdentifier("fill.tiled.dial")
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.commit = commit
        slider.doubleValue = Self.normalized(value)
    }

    /// An angle in 0 ..< 360.
    static func normalized(_ angle: Double) -> Double {
        let value = angle.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }
}
