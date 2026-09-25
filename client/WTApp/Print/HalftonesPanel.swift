import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The Halftones panel (halftones.adoc; PRINT-010): the selection's object screen -- *Screen*,
/// *Angle*, *Frequency* -- read from the document on every render, `Mixed` where the selected
/// objects differ, and btn:[Use document settings].  Choosing a value writes each selected
/// object's whole screen with that one part changed (the register is ATOMIC), in one change.
@MainActor
struct HalftonesPanelModel {
    let document: DocumentHandle
    let nodes: [OpID]
    let perform: @MainActor (any WTModel.Command) -> Void

    static let shapes: [(Wiretuner_Doc_V1_HalftoneShape, String)] = [(.unspecified, "Default")] + PrintPaneModel.shapes

    /// The selected objects that take a screen (they have common props; layers do not).
    var targets: [OpID] {
        nodes.filter { node in NodeKind(rawValue: document.state.store.kind(node)).map { $0 != .layer } ?? false }
    }

    /// Each target's own screen (unset: *Default* with no angle or frequency).
    var screens: [Wiretuner_Doc_V1_Halftone] {
        targets.map { ObjectHalftones.own($0, in: document.state) ?? Wiretuner_Doc_V1_Halftone() }
    }

    var shape: Wiretuner_Doc_V1_HalftoneShape? { shared(screens.map(\.shape)) }
    var angle: Double? { shared(screens.map(\.angle)) }
    var frequency: Double? { shared(screens.map(\.frequency)) }

    /// The one change that sets the part `change` edits on every target.
    func command(_ change: (inout Wiretuner_Doc_V1_Halftone) -> Void) -> (any WTModel.Command)? {
        let state = document.state
        let commands: [any WTModel.Command] = targets.map { node in
            var screen = ObjectHalftones.own(node, in: state) ?? Wiretuner_Doc_V1_Halftone()
            change(&screen)
            return SetObjectHalftone([node], halftone: screen)
        }
        guard !commands.isEmpty else { return nil }
        return CompositeCommand(SetObjectHalftone(targets, halftone: nil).label, commands)
    }

    func setShape(_ shape: Wiretuner_Doc_V1_HalftoneShape) {
        if let command = command({ $0.shape = shape }) { perform(command) }
    }

    func setAngle(_ degrees: Double) {
        let reduced = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        if let command = command({ $0.angle = reduced }) { perform(command) }
    }

    func setFrequency(_ lpi: Double) {
        let clamped = min(max(lpi, 1), 600)
        if let command = command({ $0.frequency = clamped }) { perform(command) }
    }

    /// btn:[Use document settings]: every target's screen unset.
    func useDocumentSettings() {
        guard !targets.isEmpty else { return }
        perform(SetObjectHalftone(targets, halftone: nil))
    }

    /// The frequency slider is logarithmic from 1 to 600 lpi: position 0...1.
    static func sliderPosition(_ lpi: Double) -> Double { log(min(max(lpi, 1), 600)) / log(600) }
    static func frequency(atSlider position: Double) -> Double { (pow(600, min(max(position, 0), 1)) * 10).rounded() / 10 }
}

struct HalftonesPanelBody: View {
    let selection: ActiveSelection?

    /// The front window's selection as the panel's model; nil with nothing that takes a screen.
    static func model(_ selection: ActiveSelection?) -> HalftonesPanelModel? {
        guard let document = selection?.document, let current = selection?.model else { return nil }
        _ = document.model?.revision
        let editing = selection?.editing
        let model = HalftonesPanelModel(document: document, nodes: current.selection.ids.map(\.opID)) { command in
            if let editing { editing.perform(command) } else { document.perform(command) }
        }
        return model.targets.isEmpty ? nil : model
    }

    static func shape(_ model: HalftonesPanelModel) -> Binding<Int> {
        Binding(get: { model.shape?.rawValue ?? -1 }, set: { model.setShape(Wiretuner_Doc_V1_HalftoneShape(rawValue: $0)!) })
    }

    static func slider(_ model: HalftonesPanelModel) -> Binding<Double> {
        Binding(get: { HalftonesPanelModel.sliderPosition(model.frequency ?? 60) },
                set: { model.setFrequency(HalftonesPanelModel.frequency(atSlider: $0)) })
    }

    static func dial(_ model: HalftonesPanelModel) -> Binding<Double> {
        Binding(get: { model.angle ?? 0 }, set: { model.setAngle(($0 / 15).rounded() * 15) })
    }

    var body: some View {
        if let model = Self.model(selection) {
            Form {
                Picker("Screen", selection: Self.shape(model)) {
                    if model.shape == nil { Text("Mixed").tag(-1) }
                    ForEach(HalftonesPanelModel.shapes, id: \.0.rawValue) { Text($0.1).tag($0.0.rawValue) }
                }
                .accessibilityIdentifier("halftones.screen")
                CommitField(title: "Angle", value: model.angle, identifier: "halftones.angle", commit: model.setAngle)
                Slider(value: Self.dial(model), in: 0...360, step: 15).accessibilityIdentifier("halftones.dial")
                CommitField(title: "Frequency (lpi)", value: model.frequency, identifier: "halftones.frequency", commit: model.setFrequency)
                Slider(value: Self.slider(model), in: 0...1).accessibilityIdentifier("halftones.slider")
                Button("Use Document Settings", action: model.useDocumentSettings).accessibilityIdentifier("halftones.useDocument")
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("Select objects to give them a halftone screen.")
                .font(.callout).foregroundStyle(.secondary).padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("halftones.empty")
        }
    }
}

enum HalftonesPanel {
    /// Replaces the catalog's *Halftones* placeholder.
    static func descriptor(selection: ActiveSelection?) -> PanelDescriptor {
        PanelDescriptor(id: "halftones", title: "Halftones", icon: "circle.grid.3x3", defaultGroup: PanelCatalog.Group.halftones,
                        menuOrder: 60, helpSlug: "halftones") {
            HalftonesPanelBody(selection: selection)
        }
    }
}
