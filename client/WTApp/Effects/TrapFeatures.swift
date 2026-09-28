import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// menu:Extensions[Create > Trap…] and the Extension Operations toolbar's *Trap* (PRINT-060,
/// printing.adoc "Trapping"): a sheet with *Trap width*, *Use maximum value* / *Use tint
/// reduction* with its percentage, and *Reverse traps*; btn:[OK] writes `TrapCommand` over the two
/// selected filled closed paths (one change "Trap") and remembers the settings on this Mac.
extension PathAlterFeatures {
    static let trapSheet = "trap-sheet"
    static let noTrapPair = "Select two overlapping filled closed paths"

    static let trapWidth = PreferenceKey<Double>("tools.trap.width", "Trap width", category: .object, scope: .local, default: TrapCommand.defaultWidth,
                                                 control: .stepper(range: TrapCommand.widths, step: 0.05, unit: "pt"), help: "printing")
    static let trapMaximum = PreferenceKey<Bool>("tools.trap.maximum", "Use maximum value", category: .object, scope: .local, default: false,
                                                 control: .toggle, help: "printing")
    static let trapTint = PreferenceKey<Double>("tools.trap.tint", "Tint reduction", category: .object, scope: .local, default: TrapCommand.defaultTint,
                                                control: .stepper(range: 0...100, step: 1, unit: "%"), help: "printing")
    static let trapReverse = PreferenceKey<Bool>("tools.trap.reverse", "Reverse traps", category: .object, scope: .local, default: false,
                                                 control: .toggle, help: "printing")

    static func trapPairSelected(_ target: @escaping Target) -> @MainActor @Sendable () -> CommandValidation {
        BlendMenu.validation(target) { TrapCommand.canPerform($0.selectedNodes, in: $0.document.state) ? nil : noTrapPair }
    }

    /// The settings a run passes back (Repeat): width, method and reverse as strings.
    static func parameters(_ model: TrapModel) -> ExtensionParameters {
        ["width": String(model.width), "maximum": String(model.maximum), "tint": String(model.tint), "reverse": String(model.reverse)]
    }

    /// The command for `parameters` (Repeat, kbd:[Cmd]-click); nil when they do not parse.
    static func trapCommand(_ nodes: [OpID], _ parameters: ExtensionParameters) -> TrapCommand? {
        guard let width = parameters["width"].flatMap(Double.init), let tint = parameters["tint"].flatMap(Double.init) else { return nil }
        let maximum = parameters["maximum"] == "true"
        return TrapCommand(nodes, width: width, method: maximum ? .maximum : .tintReduction(tint), reverse: parameters["reverse"] == "true")
    }

    /// Opens the Trap sheet over the selection; nil when it is not a trap pair.
    @discardableResult
    func showTrap(_ editing: ObjectEditing) -> TrapModel? {
        let nodes = editing.selectedNodes
        guard TrapCommand.canPerform(nodes, in: editing.document.state) else { return nil }
        let model = TrapModel(document: editing.document, nodes: nodes, width: store[Self.trapWidth], maximum: store[Self.trapMaximum],
                              tint: store[Self.trapTint], reverse: store[Self.trapReverse]) { [weak self] model in
            if let model, let self {
                self.store.set(model.width, for: Self.trapWidth)
                self.store.set(model.maximum, for: Self.trapMaximum)
                self.store.set(model.tint, for: Self.trapTint)
                self.store.set(model.reverse, for: Self.trapReverse)
            }
            self?.trap = nil
            self?.sheets.dismiss(Self.trapSheet)
        }
        trap = model
        sheets.present(TrapSheet(model: model), title: "Trap", identifier: Self.trapSheet)
        return model
    }

    /// The Extension Operations toolbar's and the Extensions menu's *Trap…*.
    func trapDescriptor(existing: ExtensionRegistry) -> ExtensionDescriptor? {
        guard var trap = existing.descriptor(for: "trap") else { return nil }
        let target = target
        trap.validate = Self.trapPairSelected(target)
        trap.run = { [weak self] parameters in
            guard let editing = target() else { return nil }
            if let parameters, let command = Self.trapCommand(editing.selectedNodes, parameters) {
                editing.perform(command)
                return parameters
            }
            self?.showTrap(editing)
            return nil
        }
        return trap
    }
}

/// The Trap sheet's settings while it is open.
@MainActor
@Observable
final class TrapModel {
    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored let nodes: [OpID]
    var width: Double
    var maximum: Bool
    var tint: Double
    var reverse: Bool
    @ObservationIgnored let finish: @MainActor (TrapModel?) -> Void

    init(document: DocumentHandle, nodes: [OpID], width: Double, maximum: Bool, tint: Double, reverse: Bool,
         finish: @escaping @MainActor (TrapModel?) -> Void) {
        self.document = document
        self.nodes = nodes
        self.width = min(max(width, TrapCommand.widths.lowerBound), TrapCommand.widths.upperBound)
        self.maximum = maximum
        self.tint = min(max(tint, 0), 100)
        self.reverse = reverse
        self.finish = finish
    }

    var command: TrapCommand {
        TrapCommand(nodes, width: width, method: maximum ? .maximum : .tintReduction(tint), reverse: reverse)
    }

    /// btn:[OK].
    @discardableResult
    func confirm() -> Task<Wiretuner_Doc_V1_Change?, Never> {
        let task = document.perform(command)
        finish(self)
        return task
    }

    /// btn:[Cancel].
    func cancel() {
        finish(nil)
    }
}

struct TrapSheet: View {
    @Bindable var model: TrapModel

    static func cancelling(_ model: TrapModel) -> () -> Void { { model.cancel() } }
    static func confirming(_ model: TrapModel) -> () -> Void { { model.confirm() } }

    static func method(_ model: TrapModel) -> Binding<Int> {
        Binding(get: { model.maximum ? 0 : 1 }, set: { model.maximum = $0 == 0 })
    }

    static func number(_ get: @escaping () -> Double, _ set: @escaping (Double) -> Void, range: ClosedRange<Double>) -> Binding<String> {
        Binding(get: { String(format: "%g", get()) }, set: { if let value = Double($0) { set(min(max(value, range.lowerBound), range.upperBound)) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trap").font(.headline)
            HStack {
                Text("Trap width")
                TextField("", text: Self.number({ model.width }, { model.width = $0 }, range: TrapCommand.widths)).frame(width: 60)
                    .accessibilityIdentifier("trap.width")
                Text("pt")
            }
            Picker("Trap color", selection: Self.method(model)) {
                Text("Use maximum value").tag(0)
                Text("Use tint reduction").tag(1)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("trap.method")
            HStack {
                Text("Tint reduction")
                TextField("", text: Self.number({ model.tint }, { model.tint = $0 }, range: 0...100)).frame(width: 60)
                    .accessibilityIdentifier("trap.tint")
                Text("%")
            }
            .disabled(model.maximum)
            Toggle("Reverse traps", isOn: $model.reverse).accessibilityIdentifier("trap.reverse")
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancelling(model)).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.confirming(model)).keyboardShortcut(.defaultAction).accessibilityIdentifier("trap.ok")
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
