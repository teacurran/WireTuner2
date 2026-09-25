import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The registers of the raster and transparency effects' settings messages (effects.proto).
enum RasterField {
    static func bevel(_ field: UInt32) -> [UInt32] { EffectFields.field(.bevelEmboss, field) }
    static func blur(_ field: UInt32) -> [UInt32] { EffectFields.field(.blur, field) }
    static func shadow(_ field: UInt32) -> [UInt32] { EffectFields.field(.shadow, field) }
    static func sharpen(_ field: UInt32) -> [UInt32] { EffectFields.field(.sharpen, field) }
    static func transparency(_ field: UInt32) -> [UInt32] { EffectFields.field(.transparency, field) }
}

/// The raster effect forms (raster-effects.adoc; FX-008) and the transparency forms
/// (transparency.adoc; FX-014): every option of each effect, one change per edit over every
/// selected effect, values `Mixed` (nil) where they differ.
extension EffectEditorModel {
    static let bevelStyles: [(Wiretuner_Doc_V1_BevelStyle, String)] = [
        (.outerBevel, "Outer bevel"), (.innerBevel, "Inner bevel"), (.raisedEmboss, "Raised emboss"), (.insetEmboss, "Inset emboss"),
    ]
    static let edgeShapes: [(Wiretuner_Doc_V1_BevelEdgeShape, String)] = [
        (.flat, "Flat"), (.smooth, "Smooth"), (.sloped, "Sloped"), (.frame1, "Frame 1"), (.frame2, "Frame 2"), (.ring, "Ring"), (.ruffle, "Ruffle"),
    ]
    static let buttonPresets: [(Wiretuner_Doc_V1_BevelButtonPreset, String)] = [(.raised, "Raised"), (.highlighted, "Highlighted"), (.inset, "Inset"), (.inverted, "Inverted")]
    static let blurStyles: [(Wiretuner_Doc_V1_BlurStyle, String)] = [(.basic, "Basic"), (.gaussian, "Gaussian")]
    static let shadowStyles: [(Wiretuner_Doc_V1_ShadowStyle, String)] = [(.dropShadow, "Drop shadow"), (.innerShadow, "Inner shadow"), (.glow, "Glow"), (.innerGlow, "Inner glow")]
    static let sharpenStyles: [(Wiretuner_Doc_V1_SharpenStyle, String)] = [(.basic, "Basic"), (.unsharpMask, "Unsharp mask")]
    static let transparencyStyles: [(Wiretuner_Doc_V1_TransparencyStyle, String)] = [(.basic, "Basic"), (.feather, "Feather"), (.gradientMask, "Gradient mask")]
    static let maskTypes: [(Wiretuner_Doc_V1_GradientType, String)] = [(.linear, "Linear"), (.logarithmic, "Logarithmic"), (.radial, "Radial"), (.rectangle, "Rectangle"), (.contour, "Contour"), (.cone, "Cone")]

    // MARK: Bevel and Emboss

    var bevelStyle: Wiretuner_Doc_V1_BevelStyle? { settings { $0.bevelEmboss.style == .unspecified ? .innerBevel : $0.bevelEmboss.style } }
    var bevelColor: Wiretuner_Doc_V1_ColorRef? { settings(\.bevelEmboss.color) }
    var bevelWidth: Double? { settings(\.bevelEmboss.width) }
    var bevelContrast: Double? { settings { Double($0.bevelEmboss.contrast) } }
    var bevelSoftness: Double? { settings { Double($0.bevelEmboss.softness) } }
    var bevelAngle: Double? { settings(\.bevelEmboss.angle) }
    var edgeShape: Wiretuner_Doc_V1_BevelEdgeShape? { settings { $0.bevelEmboss.edgeShape == .unspecified ? .flat : $0.bevelEmboss.edgeShape } }
    var buttonPreset: Wiretuner_Doc_V1_BevelButtonPreset? { settings { $0.bevelEmboss.buttonPreset == .unspecified ? .raised : $0.bevelEmboss.buttonPreset } }
    /// Whether the bevel is an outer one (only it has *Bevel color*) and not an emboss (no edge
    /// shape or preset).
    var isOuterBevel: Bool { bevelStyle == .outerBevel }
    var isEmboss: Bool { bevelStyle == .raisedEmboss || bevelStyle == .insetEmboss }

    func setBevelStyle(_ style: Wiretuner_Doc_V1_BevelStyle) -> any WTModel.Command {
        edit("Change bevel style", [RasterField.bevel(1)]) { $0.bevelEmboss.style = style }
    }
    func setBevelColor(_ color: Wiretuner_Doc_V1_ColorRef) -> any WTModel.Command {
        edit("Change bevel color", [RasterField.bevel(2)]) { $0.bevelEmboss.color = color }
    }
    func setBevelWidth(_ width: Double) -> any WTModel.Command {
        edit("Change bevel width", [RasterField.bevel(3)]) { $0.bevelEmboss.width = max(width, 0) }
    }
    func setBevelContrast(_ contrast: Double) -> any WTModel.Command {
        edit("Change bevel contrast", [RasterField.bevel(4)]) { $0.bevelEmboss.contrast = UInt32(min(max(contrast, 0), 100).rounded()) }
    }
    func setBevelSoftness(_ softness: Double) -> any WTModel.Command {
        edit("Change bevel softness", [RasterField.bevel(5)]) { $0.bevelEmboss.softness = UInt32(min(max(softness, 0), 10).rounded()) }
    }
    func setBevelAngle(_ angle: Double) -> any WTModel.Command {
        edit("Change light angle", [RasterField.bevel(6)]) { $0.bevelEmboss.angle = Self.normalized(angle) }
    }
    func setEdgeShape(_ shape: Wiretuner_Doc_V1_BevelEdgeShape) -> any WTModel.Command {
        edit("Change edge shape", [RasterField.bevel(7)]) { $0.bevelEmboss.edgeShape = shape }
    }
    func setButtonPreset(_ preset: Wiretuner_Doc_V1_BevelButtonPreset) -> any WTModel.Command {
        edit("Change button preset", [RasterField.bevel(8)]) { $0.bevelEmboss.buttonPreset = preset }
    }

    // MARK: Blur

    var blurStyle: Wiretuner_Doc_V1_BlurStyle? { settings { $0.blur.style == .unspecified ? .gaussian : $0.blur.style } }
    var blurRadius: Double? { settings(\.blur.radius) }

    func setBlurStyle(_ style: Wiretuner_Doc_V1_BlurStyle) -> any WTModel.Command {
        edit("Change blur", [RasterField.blur(1)]) { $0.blur.style = style }
    }
    func setBlurRadius(_ radius: Double) -> any WTModel.Command {
        edit("Change blur radius", [RasterField.blur(2)]) { $0.blur.radius = min(max(radius, 0), 250) }
    }

    // MARK: Shadow and Glow

    var shadowStyle: Wiretuner_Doc_V1_ShadowStyle? { settings { $0.shadow.style == .unspecified ? .dropShadow : $0.shadow.style } }
    var shadowColor: Wiretuner_Doc_V1_ColorRef? { settings(\.shadow.color) }
    var shadowOffset: Double? { settings(\.shadow.offset) }
    var shadowOpacity: Double? { settings { Double($0.shadow.opacity) } }
    var shadowSoftness: Double? { settings { Double($0.shadow.softness) } }
    var shadowAngle: Double? { settings(\.shadow.angle) }
    /// Glows have no angle.
    var isGlow: Bool { shadowStyle == .glow || shadowStyle == .innerGlow }

    func setShadowStyle(_ style: Wiretuner_Doc_V1_ShadowStyle) -> any WTModel.Command {
        edit("Change shadow", [RasterField.shadow(1)]) { $0.shadow.style = style }
    }
    func setShadowColor(_ color: Wiretuner_Doc_V1_ColorRef) -> any WTModel.Command {
        edit("Change shadow color", [RasterField.shadow(2)]) { $0.shadow.color = color }
    }
    func setShadowOffset(_ offset: Double) -> any WTModel.Command {
        edit("Change shadow offset", [RasterField.shadow(3)]) { $0.shadow.offset = max(offset, 0) }
    }
    func setShadowOpacity(_ opacity: Double) -> any WTModel.Command {
        edit("Change shadow opacity", [RasterField.shadow(4)]) { $0.shadow.opacity = UInt32(min(max(opacity, 0), 100).rounded()) }
    }
    func setShadowSoftness(_ softness: Double) -> any WTModel.Command {
        edit("Change shadow softness", [RasterField.shadow(5)]) { $0.shadow.softness = UInt32(min(max(softness, 0), 30).rounded()) }
    }
    func setShadowAngle(_ angle: Double) -> any WTModel.Command {
        edit("Change shadow angle", [RasterField.shadow(6)]) { $0.shadow.angle = Self.normalized(angle) }
    }

    // MARK: Sharpen

    var sharpenStyle: Wiretuner_Doc_V1_SharpenStyle? { settings { $0.sharpen.style == .unspecified ? .basic : $0.sharpen.style } }
    var sharpenAmount: Double? { settings(\.sharpen.amount) }
    var sharpenRadius: Double? { settings(\.sharpen.pixelRadius) }
    var sharpenThreshold: Double? { settings { Double($0.sharpen.threshold) } }

    func setSharpenStyle(_ style: Wiretuner_Doc_V1_SharpenStyle) -> any WTModel.Command {
        edit("Change sharpen", [RasterField.sharpen(1)]) { $0.sharpen.style = style }
    }
    func setSharpenAmount(_ amount: Double) -> any WTModel.Command {
        edit("Change sharpen amount", [RasterField.sharpen(2)]) { $0.sharpen.amount = min(max(amount, 0), 500) }
    }
    func setSharpenRadius(_ radius: Double) -> any WTModel.Command {
        edit("Change sharpen radius", [RasterField.sharpen(3)]) { $0.sharpen.pixelRadius = min(max(radius, 0.1), 250) }
    }
    func setSharpenThreshold(_ threshold: Double) -> any WTModel.Command {
        edit("Change sharpen threshold", [RasterField.sharpen(4)]) { $0.sharpen.threshold = UInt32(min(max(threshold, 0), 255).rounded()) }
    }

    // MARK: Transparency

    var transparencyStyle: Wiretuner_Doc_V1_TransparencyStyle? { settings { $0.transparency.style == .unspecified ? .basic : $0.transparency.style } }
    var transparencyAmount: Double? { settings { Double($0.transparency.amount) } }
    var featherRadius: Double? { settings(\.transparency.radius) }
    var featherSoftness: Double? { settings { Double($0.transparency.softness) } }
    var maskType: Wiretuner_Doc_V1_GradientType? { settings { $0.transparency.mask.type == .unspecified ? .linear : $0.transparency.mask.type } }

    /// Choosing a style; *Gradient mask* seeds a ramp where there is none (`ChooseGradientMask`).
    func setTransparencyStyle(_ style: Wiretuner_Doc_V1_TransparencyStyle) -> any WTModel.Command {
        guard style == .gradientMask else { return edit("Change transparency", [RasterField.transparency(1)]) { $0.transparency.style = style } }
        return ChooseGradientMask(pairs)
    }
    func setTransparencyAmount(_ amount: Double) -> any WTModel.Command {
        edit("Change transparency", [RasterField.transparency(2)]) { $0.transparency.amount = UInt32(min(max(amount, 0), 100).rounded()) }
    }
    func setFeatherRadius(_ radius: Double) -> any WTModel.Command {
        edit("Change feather radius", [RasterField.transparency(3)]) { $0.transparency.radius = max(radius, 0) }
    }
    func setFeatherSoftness(_ softness: Double) -> any WTModel.Command {
        edit("Change feather softness", [RasterField.transparency(4)]) { $0.transparency.softness = UInt32(min(max(softness, 0), 100).rounded()) }
    }
    func setMaskType(_ type: Wiretuner_Doc_V1_GradientType) -> any WTModel.Command {
        SetMaskGradientType(pairs, type: type)
    }

    /// The first selected effect's mask ramp, gray per stop (the ramp edits one effect at a time;
    /// empty when several are selected).
    var maskStops: [(id: OpID, offset: Double, gray: Double)] {
        guard pairs.count == 1, let entry = context.entries.first else { return [] }
        let state = context.document.state
        return MaskReading.ramp(entry.effect).map { ($0.id, $0.offset, MaskReading.gray($0.color, in: state)) }
    }

    func addMaskStop() -> (any WTModel.Command)? {
        let stops = maskStops
        guard let (node, row) = pairs.first, stops.count >= 2 else { return nil }
        let widest = zip(stops, stops.dropFirst()).max { ($0.1.offset - $0.0.offset) < ($1.1.offset - $1.0.offset) }!
        return AddMaskStop(node: node, row: row, offset: (widest.0.offset + widest.1.offset) / 2, gray: (widest.0.gray + widest.1.gray) / 2)
    }
    func moveMaskStop(_ stop: OpID, _ offset: Double) -> (any WTModel.Command)? {
        pairs.first.map { EditMaskStop(node: $0.node, row: $0.row, stop: stop, offset: offset / 100) }
    }
    func grayMaskStop(_ stop: OpID, _ gray: Double) -> (any WTModel.Command)? {
        pairs.first.map { EditMaskStop(node: $0.node, row: $0.row, stop: stop, gray: gray / 100) }
    }
    func removeMaskStop(_ stop: OpID) -> (any WTModel.Command)? {
        guard maskStops.count > 2 else { return nil }
        return pairs.first.map { RemoveMaskStop(node: $0.node, row: $0.row, stop: stop) }
    }

    static func normalized(_ angle: Double) -> Double {
        let value = angle.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }
}

/// The form of a raster or transparency effect.
struct RasterEffectForm: View {
    let model: EffectEditorModel
    let kind: Wiretuner_Doc_V1_EffectKind

    var body: some View {
        switch kind {
        case .bevelEmboss: bevel
        case .blur: blur
        case .shadow: shadow
        case .sharpen: sharpen
        default: transparency
        }
    }

    private var commit: AttributeEditorContext { model.context }

    private func slider(_ title: String, _ value: Double?, _ range: ClosedRange<Double>, _ id: String, _ command: @escaping (Double) -> any WTModel.Command) -> some View {
        AttributeSlider(title: title, value: value, range: range, identifier: "effect.\(id)", context: commit, commit: commit.committing(command))
    }

    private func field(_ title: String, _ value: Double?, _ id: String, _ command: @escaping (Double) -> any WTModel.Command) -> some View {
        CommitField(title: title, value: value, identifier: "effect.\(id)", commit: commit.committing(command))
    }

    /// An angle: the dial and its field, in step.
    private func angle(_ title: String, _ value: Double?, _ id: String, _ command: @escaping (Double) -> any WTModel.Command) -> some View {
        HStack {
            PointerDial(angle: value, identifier: "effect.\(id).dial", commit: commit.committing(command)).frame(width: 36, height: 36)
            field(title, value, id, command)
        }
    }

    private func color(_ title: String, _ value: Wiretuner_Doc_V1_ColorRef?, _ id: String, _ command: @escaping (Wiretuner_Doc_V1_ColorRef) -> any WTModel.Command) -> some View {
        AttributeColorControl(title: title, color: value, identifier: "effect.\(id)", document: commit.document, commit: commit.committing(command))
    }

    @ViewBuilder private var bevel: some View {
        AttributePicker(title: "Style", value: model.bevelStyle, choices: EffectEditorModel.bevelStyles, identifier: "effect.bevel.style", commit: commit.committing(model.setBevelStyle))
        if model.isOuterBevel { color("Bevel color", model.bevelColor, "bevel.color", model.setBevelColor) }
        field("Width", model.bevelWidth, "bevel.width", model.setBevelWidth)
        slider("Contrast", model.bevelContrast, 0...100, "bevel.contrast", model.setBevelContrast)
        slider("Softness", model.bevelSoftness, 0...10, "bevel.softness", model.setBevelSoftness)
        angle("Angle", model.bevelAngle, "bevel.angle", model.setBevelAngle)
        if !model.isEmboss {
            AttributePicker(title: "Edge shape", value: model.edgeShape, choices: EffectEditorModel.edgeShapes, identifier: "effect.bevel.edge", commit: commit.committing(model.setEdgeShape))
            AttributePicker(title: "Button preset", value: model.buttonPreset, choices: EffectEditorModel.buttonPresets, identifier: "effect.bevel.preset",
                            commit: commit.committing(model.setButtonPreset))
        }
    }

    @ViewBuilder private var blur: some View {
        AttributePicker(title: "Style", value: model.blurStyle, choices: EffectEditorModel.blurStyles, identifier: "effect.blur.style", commit: commit.committing(model.setBlurStyle))
        slider("Radius", model.blurRadius, 0...250, "blur.radius", model.setBlurRadius)
    }

    @ViewBuilder private var shadow: some View {
        AttributePicker(title: "Style", value: model.shadowStyle, choices: EffectEditorModel.shadowStyles, identifier: "effect.shadow.style", commit: commit.committing(model.setShadowStyle))
        color("Color", model.shadowColor, "shadow.color", model.setShadowColor)
        field(model.isGlow ? "Width" : "Offset", model.shadowOffset, "shadow.offset", model.setShadowOffset)
        slider("Opacity", model.shadowOpacity, 0...100, "shadow.opacity", model.setShadowOpacity)
        slider("Softness", model.shadowSoftness, 0...30, "shadow.softness", model.setShadowSoftness)
        if !model.isGlow { angle("Angle", model.shadowAngle, "shadow.angle", model.setShadowAngle) }
    }

    @ViewBuilder private var sharpen: some View {
        AttributePicker(title: "Style", value: model.sharpenStyle, choices: EffectEditorModel.sharpenStyles, identifier: "effect.sharpen.style", commit: commit.committing(model.setSharpenStyle))
        slider("Amount", model.sharpenAmount, 0...500, "sharpen.amount", model.setSharpenAmount)
        if model.sharpenStyle == .unsharpMask {
            field("Pixel radius", model.sharpenRadius, "sharpen.radius", model.setSharpenRadius)
            slider("Threshold", model.sharpenThreshold, 0...255, "sharpen.threshold", model.setSharpenThreshold)
        }
    }

    @ViewBuilder private var transparency: some View {
        AttributePicker(title: "Style", value: model.transparencyStyle, choices: EffectEditorModel.transparencyStyles, identifier: "effect.transparency.style",
                        commit: commit.committing(model.setTransparencyStyle))
        switch model.transparencyStyle {
        case .feather?:
            field("Radius", model.featherRadius, "transparency.radius", model.setFeatherRadius)
            slider("Softness", model.featherSoftness, 0...100, "transparency.softness", model.setFeatherSoftness)
        case .gradientMask?:
            AttributePicker(title: "Type", value: model.maskType, choices: EffectEditorModel.maskTypes, identifier: "effect.mask.type", commit: commit.committing(model.setMaskType))
            MaskRampView(model: model)
        default:
            slider("Transparency", model.transparencyAmount, 0...100, "transparency.amount", model.setTransparencyAmount)
        }
    }
}

/// The Gradient Mask's ramp, drawn in gray, and its stops: offset and gray (0 black, opaque; 100
/// white, transparent) per stop, btn:[Add Stop] halfway along the widest gap, remove.
struct MaskRampView: View {
    let model: EffectEditorModel

    static func gradient(_ stops: [(id: OpID, offset: Double, gray: Double)]) -> Gradient {
        Gradient(stops: stops.map { Gradient.Stop(color: SwiftUI.Color(white: $0.gray), location: $0.offset) })
    }

    static func adding(_ model: EffectEditorModel) -> () -> Void { { model.context.perform(model.addMaskStop()) } }
    static func removing(_ model: EffectEditorModel, _ stop: OpID) -> () -> Void { { model.context.perform(model.removeMaskStop(stop)) } }
    static func moving(_ model: EffectEditorModel, _ stop: OpID) -> (Double) -> Void { { model.context.perform(model.moveMaskStop(stop, $0)) } }
    static func graying(_ model: EffectEditorModel, _ stop: OpID) -> (Double) -> Void { { model.context.perform(model.grayMaskStop(stop, $0)) } }

    var body: some View {
        let stops = model.maskStops
        VStack(alignment: .leading, spacing: 4) {
            if stops.count >= 2 {
                LinearGradient(gradient: Self.gradient(stops), startPoint: .leading, endPoint: .trailing)
                    .frame(height: 16).border(SwiftUI.Color.secondary).accessibilityIdentifier("effect.mask.ramp")
            }
            ForEach(stops, id: \.id) { stop in
                HStack {
                    CommitField(title: "At %", value: stop.offset * 100, identifier: "effect.mask.offset", commit: Self.moving(model, stop.id))
                    CommitField(title: "Gray %", value: stop.gray * 100, identifier: "effect.mask.gray", commit: Self.graying(model, stop.id))
                    Button(action: Self.removing(model, stop.id)) { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).disabled(stops.count <= 2).accessibilityIdentifier("effect.mask.remove")
                }
            }
            Button("Add Stop", action: Self.adding(model)).disabled(stops.count < 2).accessibilityIdentifier("effect.mask.add")
        }
    }
}

/// The btn:[Add Effect] submenus of the raster and transparency effects (raster-effects.adoc and
/// transparency.adoc, "To add…"): each item adds its effect in its style.
enum EffectPresetMenu {
    static let groups: [(title: String, presets: [EffectPreset])] = [
        ("Bevel and Emboss", [.bevel(.outerBevel), .bevel(.innerBevel), .bevel(.raisedEmboss), .bevel(.insetEmboss)]),
        ("Blur", [.blur(.basic), .blur(.gaussian)]),
        ("Shadow and Glow", [.shadow(.dropShadow), .shadow(.innerShadow), .shadow(.glow), .shadow(.innerGlow)]),
        ("Sharpen", [.sharpen(.basic), .sharpen(.unsharpMask)]),
        ("Transparency", [.transparency(.basic), .transparency(.feather), .transparency(.gradientMask)]),
    ]
}

extension AttributesListModel {
    /// A submenu item: the effect in `preset`'s style, placed as btn:[Add Effect] places one.
    func addEffectPreset(_ preset: EffectPreset, above selected: AttributeRowItem?) -> AddEffectPreset? {
        guard !targets.isEmpty else { return nil }
        guard let selected, selected.list != .effects else { return AddEffectPreset(targets, preset: preset, above: Self.aboveRows(selected)) }
        return AddEffectPreset(targets, preset: preset, attachTo: Self.aboveRows(selected))
    }
}
