import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The path clean-ups of editing-paths.adoc ("Simplifying paths", "Path direction"; DRAW-030's
/// app half) and path-effects.adoc ("Fractalize"; FX-031's): menu:Modify[Alter Path > Simplify…]
/// and the Extension Operations toolbar's *Simplify…* -- a sheet whose *Amount* previews on the
/// canvas with btn:[Apply] and is written by btn:[OK] -- menu:Modify[Alter Path > Correct
/// Direction] and its toolbar entry, *Remove Overlap* (DRAW-060) in the Alter Path menu, the path
/// context menu and the Extension Operations toolbar, and *Fractalize* on WTModel's command.  Each
/// writes one change over the selected paths.
@MainActor
final class PathAlterFeatures {
    typealias Target = ObjectMenuCommands.Target

    enum ID {
        static let correctDirection: CommandID = "modify.alterPath.correctDirection"
    }

    static let sheet = "simplify-sheet"
    static let amount = PreferenceKey<Double>("tools.simplify.amount", "Amount", category: .object, scope: .local, default: 50,
                                              control: .stepper(range: 0...100, step: 1, unit: ""), help: "editing-paths")

    let target: Target
    let store: PreferenceStore
    let sheets: SheetPresenter
    /// The Simplify sheet's model while it is open.
    private(set) var simplify: SimplifyModel?
    /// The Trap sheet's model while it is open (PRINT-060, `TrapFeatures.swift`).
    var trap: TrapModel?

    init(target: @escaping Target, store: PreferenceStore, sheets: SheetPresenter = SheetPresenter()) {
        self.target = target
        self.store = store
        self.sheets = sheets
    }

    /// The selected paths (Simplify, Correct Direction, Fractalize).
    static func paths(_ editing: ObjectEditing) -> [OpID] {
        DistortFeatures.paths(editing)
    }

    static func pathSelected(_ target: @escaping Target) -> @MainActor @Sendable () -> CommandValidation {
        BlendMenu.validation(target) { paths($0).isEmpty ? DistortFeatures.noPath : nil }
    }

    static let noClosedPath = "Select a closed path"

    /// The selected closed paths Remove Overlap rewrites (DRAW-060), and the closed live shapes it
    /// converts when their outline overlaps (D-078).
    static func closedPaths(_ editing: ObjectEditing) -> [OpID] {
        RemoveOverlap.targets(paths(editing), in: editing.document.state)
    }

    static func closedPathSelected(_ target: @escaping Target) -> @MainActor @Sendable () -> CommandValidation {
        BlendMenu.validation(target) { closedPaths($0).isEmpty ? noClosedPath : nil }
    }

    /// Remove Overlap over the selected closed paths (one change; nothing when none overlaps).
    static func removeOverlap(_ editing: ObjectEditing) {
        let nodes = closedPaths(editing)
        if !nodes.isEmpty { editing.perform(RemoveOverlap(nodes)) }
    }

    // MARK: Simplify

    /// Opens the Simplify sheet over the selected paths.
    @discardableResult
    func showSimplify(_ editing: ObjectEditing) -> SimplifyModel? {
        let nodes = Self.paths(editing)
        guard !nodes.isEmpty else { return nil }
        let model = SimplifyModel(document: editing.document, nodes: nodes, amount: store[Self.amount]) { [weak self] amount in
            if let amount { self?.store.set(amount, for: Self.amount) }
            self?.simplify = nil
            self?.sheets.dismiss(Self.sheet)
        }
        simplify = model
        sheets.present(SimplifySheet(model: model), title: "Simplify", identifier: Self.sheet)
        return model
    }

    /// Simplify with the amount a sheet captured (Repeat, kbd:[Cmd]-click on the toolbar button).
    static func simplify(_ editing: ObjectEditing, amount: Double) {
        let nodes = paths(editing)
        if !nodes.isEmpty { editing.perform(SimplifyPaths(nodes, amount: amount)) }
    }

    // MARK: Commands

    func commands() -> [Command] {
        let target = target
        let modify = ContextMenuCatalog.Menu.modify
        let valid = Self.pathSelected(target)
        return [
            Command(id: ContextMenuCatalog.ID.simplify, title: "Simplify", menu: MenuPath(modify, "Alter Path", section: 3),
                    keywords: ["simplify", "points", "smooth"], validation: valid,
                    action: .perform { [weak self] in if let editing = target() { self?.showSimplify(editing) } }),
            Command(id: ContextMenuCatalog.ID.removeOverlap, title: "Remove Overlap", menu: MenuPath(modify, "Alter Path", section: 3),
                    contexts: [.path], keywords: ["overlap", "union", "self-intersection", "cleanup"], validation: Self.closedPathSelected(target),
                    action: .perform { if let editing = target() { Self.removeOverlap(editing) } }),
            Command(id: ID.correctDirection, title: "Correct Direction", menu: MenuPath(modify, "Alter Path", section: 3), keywords: ["direction", "holes", "winding"],
                    validation: valid,
                    action: .perform {
                        guard let editing = target() else { return }
                        let nodes = Self.paths(editing)
                        if !nodes.isEmpty { editing.perform(CorrectDirection(nodes)) }
                    }),
        ]
    }

    /// The Extension Operations toolbar's *Simplify…*, *Correct Direction* and *Fractalize*.
    func extensionDescriptors(existing: ExtensionRegistry) -> [ExtensionDescriptor] {
        let target = target
        let valid = Self.pathSelected(target)
        var result: [ExtensionDescriptor] = []
        if var simplify = existing.descriptor(for: "simplify") {
            simplify.validate = valid
            simplify.run = { [weak self] parameters in
                guard let editing = target() else { return nil }
                if let amount = parameters?["amount"].flatMap(Double.init) {
                    Self.simplify(editing, amount: amount)
                    return parameters
                }
                self?.showSimplify(editing)
                return nil
            }
            result.append(simplify)
        }
        if var removeOverlap = existing.descriptor(for: "removeOverlap") {
            removeOverlap.validate = Self.closedPathSelected(target)
            removeOverlap.run = { _ in
                if let editing = target() { Self.removeOverlap(editing) }
                return nil
            }
            result.append(removeOverlap)
        }
        if let trap = trapDescriptor(existing: existing) { result.append(trap) }
        let operations: [(String, @MainActor ([OpID]) -> any WTModel.Command)] = [
            ("correctDirection", { CorrectDirection($0) }),
            ("fractalize", { Fractalize($0) }),
        ]
        for (id, make) in operations {
            guard var descriptor = existing.descriptor(for: id) else { continue }
            descriptor.validate = valid
            descriptor.run = { _ in
                guard let editing = target() else { return nil }
                let nodes = Self.paths(editing)
                if !nodes.isEmpty { editing.perform(make(nodes)) }
                return nil
            }
            result.append(descriptor)
        }
        return result
    }

    func install(commands registry: CommandRegistry, extensions: ExtensionRegistry) {
        for command in commands() { registry.replace(command) }
        for descriptor in extensionDescriptors(existing: extensions) { extensions.replace(descriptor) }
    }
}

/// The Simplify sheet (editing-paths.adoc, "Simplifying paths"): *Amount* 0–100; btn:[Apply]
/// shows the result on the canvas without writing it, btn:[OK] writes it (one change "Simplify"),
/// btn:[Cancel] puts the paths back as they were.
@MainActor
@Observable
final class SimplifyModel {
    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored let nodes: [OpID]
    var amount: Double
    private(set) var previewing = false
    @ObservationIgnored let finish: @MainActor (Double?) -> Void

    init(document: DocumentHandle, nodes: [OpID], amount: Double, finish: @escaping @MainActor (Double?) -> Void) {
        self.document = document
        self.nodes = nodes
        self.amount = min(max(amount, 0), 100)
        self.finish = finish
    }

    var command: SimplifyPaths { SimplifyPaths(nodes, amount: amount) }

    /// How many points the selected paths have now, and would have simplified.
    var pointCounts: (before: Int, after: Int) {
        let state = document.state
        let before = nodes.reduce(0) { total, node in
            total + VectorPath(state.props(node).path, node: node, state: state).contours.reduce(0) { $0 + $1.points.count }
        }
        let after = SimplifyPaths.preview(nodes, amount: amount, in: state).values.reduce(0) { total, path in
            total + path.contours.reduce(0) { $0 + $1.points.count }
        }
        return (before, after)
    }

    /// btn:[Apply].
    func apply() {
        previewing = true
        document.preview(command)
    }

    /// btn:[OK].
    @discardableResult
    func confirm() -> Task<Wiretuner_Doc_V1_Change?, Never> {
        endPreview()
        let task = document.perform(command)
        finish(amount)
        return task
    }

    /// btn:[Cancel].
    func cancel() {
        endPreview()
        finish(nil)
    }

    private func endPreview() {
        guard previewing else { return }
        previewing = false
        document.preview(nil)
    }
}

struct SimplifySheet: View {
    @Bindable var model: SimplifyModel

    static func applying(_ model: SimplifyModel) -> () -> Void { { model.apply() } }
    static func cancelling(_ model: SimplifyModel) -> () -> Void { { model.cancel() } }
    static func confirming(_ model: SimplifyModel) -> () -> Void { { model.confirm() } }

    static func text(_ model: SimplifyModel) -> Binding<String> {
        Binding(get: { String(Int(model.amount.rounded())) }, set: { if let value = Double($0) { model.amount = min(max(value, 0), 100) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Simplify").font(.headline)
            HStack {
                Slider(value: $model.amount, in: 0...100) { Text("Amount") }.accessibilityIdentifier("simplify.slider")
                TextField("", text: Self.text(model)).frame(width: 44).accessibilityIdentifier("simplify.amount")
            }
            let counts = model.pointCounts
            Text("\(counts.before) points → \(counts.after)").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("simplify.points")
            HStack {
                Button("Apply", action: Self.applying(model)).accessibilityIdentifier("simplify.apply")
                Spacer()
                Button("Cancel", action: Self.cancelling(model)).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.confirming(model)).keyboardShortcut(.defaultAction).accessibilityIdentifier("simplify.ok")
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
