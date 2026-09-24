import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The brush pop-up and its action menu in the Brush stroke editor (stroke-attributes.adoc,
/// "Brush strokes"; ATTR-009): choosing a brush applies it to every selected stroke; *Edit…*,
/// *Duplicate*, *Remove…*, *Import…* and *Export…* act on the brush the strokes use.
@MainActor
struct BrushControlsModel {
    let context: AttributeEditorContext
    var files = BrushFiles()

    var state: EngineState { context.document.state }

    /// The document's brushes, in the pop-up's order.
    var brushes: [BrushEntry] { Brushes.list(state) }

    /// The brush every selected stroke uses; nil when none or they differ.
    var current: OpID? {
        BrushStrokes.brush(of: context.entries).flatMap { brush in Brushes.isBrush(brush, in: state) ? brush : nil }
    }

    /// The pop-up's title.
    var title: String {
        guard let current else { return context.entries.count > 1 && BrushStrokes.brush(of: context.entries) == nil ? "Mixed" : "Choose Brush" }
        return brushes.first { $0.id == current }.map { $0.name.isEmpty ? "Brush" : $0.name } ?? "Choose Brush"
    }

    /// The selected stroke rows.
    var strokes: [BrushStrokeRow] { context.item.targets.map { BrushStrokeRow(node: $0.node, element: $0.row.element) } }

    func apply(_ brush: OpID) -> any WTModel.Command { ApplyBrush(strokes, brush: brush) }

    /// *Edit…*: the sheet's draft for the current brush.
    func editor() -> BrushEditorModel? {
        current.map { BrushEditorModel(document: context.document, purpose: .edit($0, strokes: strokes)) }
    }

    func duplicate() -> (any WTModel.Command)? { current.map(DuplicateBrush.init) }

    /// *Remove…*'s answer: *Release* or *Delete*.
    func remove(release: Bool) -> (any WTModel.Command)? {
        current.map { RemoveBrush($0, release ? .release : .delete) }
    }

    /// *Import…* after picking brushes in a brush file.
    func importing(_ brushes: [OpID], from file: EngineState) -> (any WTModel.Command)? {
        brushes.isEmpty ? nil : ImportBrushes(from: file, brushes: brushes)
    }
}

/// What the brush controls are showing: a sheet, or the Remove prompt.
@MainActor
@Observable
final class BrushControlsState {
    enum Sheet: Identifiable {
        case edit(BrushEditorModel)
        case pickImport(EngineState)
        case pickExport

        var id: String {
            switch self {
            case .edit: "edit"
            case .pickImport: "import"
            case .pickExport: "export"
            }
        }
    }

    var sheet: Sheet?
    var removing = false

    init() {}
}

struct BrushControls: View {
    let model: BrushControlsModel
    @State private var state = BrushControlsState()

    // Actions of the controls, as functions the tests can call.

    static func apply(_ brush: OpID, model: BrushControlsModel) {
        model.context.perform(model.apply(brush))
    }

    static func edit(_ model: BrushControlsModel, state: BrushControlsState) {
        state.sheet = model.editor().map(BrushControlsState.Sheet.edit)
    }

    static func duplicate(_ model: BrushControlsModel) {
        model.context.perform(model.duplicate())
    }

    static func remove(_ model: BrushControlsModel, release: Bool, state: BrushControlsState) {
        model.context.perform(model.remove(release: release))
        state.removing = false
    }

    /// *Import…*: the file panel, then the picker over the file's brushes.
    @discardableResult
    static func startImport(_ model: BrushControlsModel, state: BrushControlsState) -> Task<Void, Never> {
        Task { @MainActor in
            if let file = await model.files.chooseFile() { state.sheet = .pickImport(file) }
        }
    }

    /// A sheet closed: performs what it made.
    static func finish(_ command: (any WTModel.Command)?, model: BrushControlsModel, state: BrushControlsState) {
        state.sheet = nil
        model.context.perform(command)
    }

    /// The export picker closed: the save panel for the picked brushes.
    @discardableResult
    static func export(_ brushes: [OpID], model: BrushControlsModel, state: BrushControlsState) -> Task<Bool, Never> {
        state.sheet = nil
        let snapshot = model.state
        return Task { @MainActor in await model.files.export(brushes, from: snapshot) }
    }

    // The menus' actions, as closures the tests can call.

    static func applying(_ brush: OpID, model: BrushControlsModel) -> () -> Void { { apply(brush, model: model) } }
    static func editing(_ model: BrushControlsModel, state: BrushControlsState) -> () -> Void { { edit(model, state: state) } }
    static func duplicating(_ model: BrushControlsModel) -> () -> Void { { duplicate(model) } }
    static func askingToRemove(_ state: BrushControlsState) -> () -> Void { { state.removing = true } }
    static func importing(_ model: BrushControlsModel, state: BrushControlsState) -> () -> Void { { startImport(model, state: state) } }
    static func pickingExport(_ state: BrushControlsState) -> () -> Void { { state.sheet = .pickExport } }

    static func removing(_ model: BrushControlsModel, release: Bool, state: BrushControlsState) -> () -> Void {
        { remove(model, release: release, state: state) }
    }

    /// The import picker's answer: the picked brushes of `file` imported.
    static func finishingImport(_ file: EngineState, model: BrushControlsModel, state: BrushControlsState) -> @MainActor ([OpID]) -> Void {
        { finish(model.importing($0, from: file), model: model, state: state) }
    }

    static func finishingExport(_ model: BrushControlsModel, state: BrushControlsState) -> @MainActor ([OpID]) -> Void {
        { export($0, model: model, state: state) }
    }

    @ViewBuilder static func sheet(_ sheet: BrushControlsState.Sheet, model: BrushControlsModel, state: BrushControlsState) -> some View {
        switch sheet {
        case .edit(let editor):
            BrushEditorSheet(model: editor, finish: finishing(model, state: state))
        case .pickImport(let file):
            BrushPickerSheet(title: "Import", brushes: Brushes.list(file), finish: finishingImport(file, model: model, state: state))
        case .pickExport:
            BrushPickerSheet(title: "Export", brushes: model.brushes, finish: finishingExport(model, state: state))
        }
    }

    static func finishing(_ model: BrushControlsModel, state: BrushControlsState) -> @MainActor ((any WTModel.Command)?) -> Void {
        { finish($0, model: model, state: state) }
    }

    var body: some View {
        @Bindable var state = state
        HStack {
            Menu(model.title) {
                ForEach(model.brushes, id: \.id) { brush in
                    Button(BrushPickerSheet.name(brush), action: Self.applying(brush.id, model: model))
                }
            }
            .accessibilityIdentifier("stroke.brush.popup")
            Menu {
                Button("Edit…", action: Self.editing(model, state: state)).disabled(model.current == nil)
                Button("Duplicate", action: Self.duplicating(model)).disabled(model.current == nil)
                Button("Remove…", action: Self.askingToRemove(state)).disabled(model.current == nil)
                Divider()
                Button("Import…", action: Self.importing(model, state: state))
                Button("Export…", action: Self.pickingExport(state)).disabled(model.brushes.isEmpty)
            } label: {
                Image(systemName: "gearshape")
            }
            .fixedSize()
            .accessibilityIdentifier("stroke.brush.actions")
        }
        .sheet(item: $state.sheet) { Self.sheet($0, model: model, state: state) }
        .confirmationDialog("Remove the brush?", isPresented: $state.removing) {
            Button("Release", action: Self.removing(model, release: true, state: state))
            Button("Delete", role: .destructive, action: Self.removing(model, release: false, state: state))
        } message: {
            Text("Release turns each stroke using it into ordinary objects grouped with its path; Delete removes the brush and the paths using it.")
        }
    }
}
