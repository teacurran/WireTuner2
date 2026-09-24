import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The Color Control sheet (editing-colors.adoc, "Controlling color values"; COLOR-017): a mode
/// -- CMYK, RGB or HLS -- and a slider with a field per component, −100% to +100% (hue −360° to
/// +360°).  With *Preview* on the canvas shows the adjustment through the document's preview, so
/// nothing reaches the outbox until btn:[Apply], which writes one change; btn:[Cancel] shows the
/// document as it is.  A remote change to a previewed object redraws with the preview still over
/// it (`DocumentHandle.preview`).
@MainActor
@Observable
final class ColorControlModel {
    static let sheet = "color-control-sheet"
    static let modes: [(ColorControlMode, String)] = [(.cmyk, "CMYK"), (.rgb, "RGB"), (.hls, "HLS")]

    let document: DocumentHandle
    let nodes: [OpID]
    /// Changing the mode starts again from no change.
    private(set) var mode = ColorControlMode.hls
    /// The fields: percentages, hue in degrees.
    private(set) var values = SIMD4<Double>(repeating: 0)
    private(set) var previewing = true

    init(document: DocumentHandle, nodes: [OpID]) {
        self.document = document
        self.nodes = nodes
    }

    /// The components of `mode` with their ranges.
    static func components(_ mode: ColorControlMode) -> [(title: String, range: ClosedRange<Double>)] {
        let percent = -100.0...100.0
        switch mode {
        case .cmyk: return [("Cyan", percent), ("Magenta", percent), ("Yellow", percent), ("Black", percent)]
        case .rgb: return [("Red", percent), ("Green", percent), ("Blue", percent)]
        case .hls: return [("Hue", -360...360), ("Lightness", percent), ("Saturation", percent)]
        }
    }

    /// The deltas the command applies: fractions, hue in degrees.
    var deltas: SIMD4<Double> {
        mode == .hls ? SIMD4(values.x, values.y / 100, values.z / 100, 0) : values / 100
    }

    var command: AdjustColors { AdjustColors(nodes, .control(mode, deltas)) }

    func setMode(_ mode: ColorControlMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        values = SIMD4(repeating: 0)
        refresh()
    }

    /// Field or slider `index`, clamped to its range.
    func setValue(_ index: Int, _ value: Double) {
        let range = Self.components(mode)[index].range
        values[index] = min(max(value, range.lowerBound), range.upperBound)
        refresh()
    }

    /// Field `index`'s commit.
    func setter(_ index: Int) -> (Double) -> Void {
        { self.setValue(index, $0) }
    }

    func setPreviewing(_ on: Bool) {
        previewing = on
        refresh()
    }

    /// Shows the adjustment on the canvas while *Preview* is on and something would change.
    func refresh() {
        document.preview(previewing && values != SIMD4(repeating: 0) ? command : nil)
    }

    /// btn:[Apply]: the preview ends and the adjustment is one change.
    @discardableResult
    func apply() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        document.preview(nil)
        return values == SIMD4(repeating: 0) ? nil : document.perform(command)
    }

    /// btn:[Cancel]: the document shows as it is.
    func cancel() {
        document.preview(nil)
    }
}

struct ColorControlSheet: View {
    let model: ColorControlModel
    /// Closes the sheet.
    let close: @MainActor () -> Void

    static func mode(_ model: ColorControlModel) -> Binding<ColorControlMode> {
        Binding(get: { model.mode }, set: { model.setMode($0) })
    }

    static func value(_ index: Int, _ model: ColorControlModel) -> Binding<Double> {
        Binding(get: { model.values[index] }, set: { model.setValue(index, $0) })
    }

    static func preview(_ model: ColorControlModel) -> Binding<Bool> {
        Binding(get: { model.previewing }, set: { model.setPreviewing($0) })
    }

    static func applying(_ model: ColorControlModel, close: @escaping @MainActor () -> Void) -> () -> Void {
        {
            model.apply()
            close()
        }
    }

    static func cancelling(_ model: ColorControlModel, close: @escaping @MainActor () -> Void) -> () -> Void {
        {
            model.cancel()
            close()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Color Control").font(.headline)
            Picker("Mode", selection: Self.mode(model)) {
                ForEach(ColorControlModel.modes, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("color-control.mode")
            ForEach(Array(ColorControlModel.components(model.mode).enumerated()), id: \.offset) { index, component in
                HStack {
                    Text(component.title).frame(width: 80, alignment: .leading)
                    Slider(value: Self.value(index, model), in: component.range)
                        .accessibilityIdentifier("color-control.slider.\(index)")
                    CommitField(title: component.title, value: model.values[index], identifier: "color-control.field.\(index)", commit: model.setter(index))
                        .frame(width: 60)
                }
            }
            Toggle("Preview", isOn: Self.preview(model)).accessibilityIdentifier("color-control.preview")
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancelling(model, close: close)).keyboardShortcut(.cancelAction)
                Button("Apply", action: Self.applying(model, close: close)).keyboardShortcut(.defaultAction).accessibilityIdentifier("color-control.apply")
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
