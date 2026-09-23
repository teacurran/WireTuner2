import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTRender

/// *Restore Deleted Colors…* (swatches.adoc, "Removing colors"; COLOR-016): the swatches removed
/// in the last thirty days, from the local log, each marked when objects still refer to it;
/// restoring the ticked ones re-links those objects with no write on them (their references
/// resolve again by themselves).
@MainActor
@Observable
final class RestoreDeletedModel {
    let workspace: ColorWorkspace
    let entries: [DeletedSwatch]
    var ticked: Set<OpID> = []

    static let sheet = "swatches.restore-sheet"

    init(workspace: ColorWorkspace, now: Date = Date()) {
        self.workspace = workspace
        entries = workspace.swatches?.deleted(now: now) ?? []
    }

    /// "Still used by 3 objects", or nil.
    func usage(_ id: OpID) -> String? {
        let count = workspace.swatches?.userCount(of: [id]) ?? 0
        return count == 0 ? nil : "Still used by \(count) \(count == 1 ? "object" : "objects")"
    }

    func toggle(_ id: OpID) {
        if ticked.contains(id) { ticked.remove(id) } else { ticked.insert(id) }
    }

    @discardableResult
    func restore() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        workspace.dismiss(Self.sheet)
        let ids = entries.map(\.id).filter(ticked.contains)
        return ids.isEmpty ? nil : workspace.perform(RestoreSwatches(ids))
    }

    func cancel() {
        workspace.dismiss(Self.sheet)
    }
}

struct RestoreDeletedSheet: View {
    let model: RestoreDeletedModel

    static func toggling(_ id: OpID, _ model: RestoreDeletedModel) -> Binding<Bool> {
        Binding(get: { model.ticked.contains(id) }, set: { _ in model.toggle(id) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore Deleted Colors").font(.headline)
            if model.entries.isEmpty {
                Text("No colors were removed in the last 30 days.").foregroundStyle(.secondary)
            }
            ForEach(model.entries) { entry in
                HStack {
                    Toggle(isOn: Self.toggling(entry.id, model)) { EmptyView() }.labelsHidden().accessibilityIdentifier("restore.tick.\(entry.name)")
                    ColorChipView(chip: .color(entry.color))
                    Text(entry.name)
                    Spacer()
                    if let usage = model.usage(entry.id) { Text(usage).font(.caption).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction)
                Button("Restore", action: ColorAction.run(model.restore)).keyboardShortcut(.defaultAction)
                    .disabled(model.ticked.isEmpty)
                    .accessibilityIdentifier("restore.restore")
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// menu:Extensions[Delete > Unused Named Colors] (swatches.adoc; COLOR-007): the preview sheet
/// listing what goes, with the presence line when others are editing.
@MainActor
struct DeleteUnusedModel {
    let workspace: ColorWorkspace
    /// The swatches that would go, by name.
    let names: [String]
    /// "N people are editing. …", or nil when nobody else is.
    let presenceLine: String?

    static let sheet = "swatches.delete-unused-sheet"

    init(workspace: ColorWorkspace) {
        self.workspace = workspace
        let state = workspace.document?.state ?? EngineState()
        let list = workspace.swatches?.list ?? SwatchList(state)
        names = DeleteUnusedSwatches.unused(in: state, index: workspace.swatches?.index).compactMap { list[$0]?.name }
        let others = workspace.selection.presence?.participants.count ?? 0
        presenceLine = others == 0 ? nil
            : "\(others) \(others == 1 ? "person is" : "people are") editing.  A color they apply before this reaches them stays on their objects as an unnamed color."
    }

    @discardableResult
    func remove() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        workspace.dismiss(Self.sheet)
        return names.isEmpty ? nil : workspace.perform(DeleteUnusedSwatches(index: workspace.swatches?.index))
    }

    func cancel() {
        workspace.dismiss(Self.sheet)
    }
}

struct DeleteUnusedSheet: View {
    let model: DeleteUnusedModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete Unused Named Colors").font(.headline)
            if model.names.isEmpty {
                Text("Every named color is in use.").foregroundStyle(.secondary)
            } else {
                Text(model.names.joined(separator: ", ")).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("delete-unused.names")
            }
            if let line = model.presenceLine { Text(line).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction)
                Button("Remove", action: ColorAction.run(model.remove)).keyboardShortcut(.defaultAction).disabled(model.names.isEmpty)
                    .accessibilityIdentifier("delete-unused.remove")
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// *Import from Document…* (exporting-colors.adoc; COLOR-019): another open document's swatches
/// to tick and copy in (with their tints; fresh node ids; a clashing name becomes the colour's mix
/// values).
@MainActor
@Observable
final class ImportFromDocumentModel {
    let workspace: ColorWorkspace
    /// The other open documents.
    let sources: [DocumentHandle]
    var source: DocumentHandle?
    var ticked: Set<OpID> = []

    static let sheet = "swatches.import-document-sheet"

    init(workspace: ColorWorkspace, documents: [DocumentHandle]) {
        self.workspace = workspace
        sources = documents.filter { $0.id != workspace.document?.id && $0.model != nil }
        source = sources.first
    }

    /// The chosen document's colours (not its defaults).
    var colors: [Swatch] {
        source.map { SwatchList($0.state).swatches.filter { !$0.isProtected } } ?? []
    }

    func choose(_ id: String) {
        source = sources.first { $0.id == id }
        ticked = []
    }

    func toggle(_ id: OpID) {
        if ticked.contains(id) { ticked.remove(id) } else { ticked.insert(id) }
    }

    @discardableResult
    func importColors() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        workspace.dismiss(Self.sheet)
        guard let source, !ticked.isEmpty else { return nil }
        let list = SwatchList(source.state)
        let chosen = list.swatches.map(\.id).filter(ticked.contains)
        let library = ColorLibraries.library(named: source.title, swatches: chosen, list: list)
        return workspace.perform(ImportLibraryColors(library, origin: ColorDrop.origin(source.id), group: ""))
    }

    func cancel() {
        workspace.dismiss(Self.sheet)
    }
}

struct ImportFromDocumentSheet: View {
    let model: ImportFromDocumentModel

    static func sourceBinding(_ model: ImportFromDocumentModel) -> Binding<String> {
        Binding(get: { model.source?.id ?? "" }, set: { model.choose($0) })
    }

    static func toggling(_ id: OpID, _ model: ImportFromDocumentModel) -> Binding<Bool> {
        Binding(get: { model.ticked.contains(id) }, set: { _ in model.toggle(id) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from Document").font(.headline)
            if model.sources.isEmpty {
                Text("Open another document to import its colors.").foregroundStyle(.secondary)
            } else {
                Picker("Document", selection: Self.sourceBinding(model)) {
                    ForEach(model.sources) { Text($0.title).tag($0.id) }
                }
                .accessibilityIdentifier("import-document.source")
                ForEach(model.colors) { swatch in
                    Toggle(isOn: Self.toggling(swatch.id, model)) {
                        HStack {
                            ColorChipView(chip: .color(swatch.color))
                            Text(swatch.name)
                        }
                    }
                    .padding(.leading, Double(swatch.depth) * 14)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction)
                Button("Import", action: ColorAction.run(model.importColors)).keyboardShortcut(.defaultAction).disabled(model.ticked.isEmpty)
                    .accessibilityIdentifier("import-document.import")
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
