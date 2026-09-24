import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTInterchange
import WTModel
import WTProto

/// The Swatches panel's *Export…* sheet (exporting-colors.adoc, "Exporting a color library";
/// COLOR-018's sheet): tick colours (a base brings its tints; the defaults are never listed),
/// name the library, give the rows, columns and notes the library sheet lays it out with, pick
/// *WireTuner color library* (`.wtcolors`), *Adobe Swatch Exchange* (`.ase`) or *Photoshop
/// swatches* (`.aco`), and btn:[Save] to a file chosen in a save panel -- optionally also into
/// *My Libraries*.  What the format could not carry (gamut-mapped colours, spots written as
/// process, tints written as plain colours) is listed afterwards.
@MainActor
@Observable
final class ColorLibraryExportModel {
    let workspace: ColorWorkspace
    @ObservationIgnored let libraries: ColorLibraryMenu
    var ticked: Set<OpID> = []
    var name: String
    var rows = 0
    var columns = 0
    var notes = ""
    var format = ColorLibraryFormat.wtcolors
    /// Also write the library into *My Libraries* (always as `.wtcolors`).
    var saveToMyLibraries = false
    /// What went wrong, shown in the sheet.
    private(set) var message: String?
    /// The save running (tests await it).
    @ObservationIgnored private(set) var saving: Task<URL?, Never>?

    static let sheet = "color-library-export-sheet"
    /// The formats the sheet offers, with their names.
    static let formats: [(format: ColorLibraryFormat, title: String)] = [
        (.wtcolors, "WireTuner color library (.wtcolors)"), (.ase, "Adobe Swatch Exchange (.ase)"), (.aco, "Photoshop swatches (.aco)"),
    ]

    init(workspace: ColorWorkspace, libraries: ColorLibraryMenu) {
        self.workspace = workspace
        self.libraries = libraries
        name = workspace.document?.title ?? "Colors"
        ticked = Set(swatches.map(\.id))
    }

    /// The front document's colours, the defaults left out.
    var swatches: [Swatch] {
        workspace.swatches?.list.swatches.filter { !$0.isProtected } ?? []
    }

    func toggle(_ id: OpID) {
        if ticked.contains(id) { ticked.remove(id) } else { ticked.insert(id) }
    }

    /// The ticked colours (with their bases' tints) as a library with the sheet's fields.
    func library() -> ColorLibrary {
        let list = workspace.swatches?.list ?? SwatchList(EngineState())
        var library = ColorLibraries.library(named: name.isEmpty ? "Colors" : name, swatches: swatches.map(\.id).filter(ticked.contains), list: list)
        library.rows = UInt32(min(max(rows, 0), 1000))
        library.columns = UInt32(min(max(columns, 0), 1000))
        library.notes = String(notes.prefix(8192))
        return library
    }

    /// btn:[Save] from the sheet's button.
    @discardableResult
    func beginSave() -> Task<URL?, Never> {
        let task = Task { await save() }
        saving = task
        return task
    }

    /// Writes the library where the save panel says (and into *My Libraries* when ticked), then
    /// lists the writer's notes; the file written, nil when cancelled or refused.
    func save() async -> URL? {
        let library = library()
        let written: ColorLibraryExport
        do {
            written = try ColorLibraryFiles.write(library, format: format)
        } catch {
            message = String(describing: error)
            return nil
        }
        let panel = NSSavePanel()
        panel.title = "Export Colors"
        panel.prompt = "Save"
        panel.allowedContentTypes = ColorLibraryMenu.contentTypes([format])
        panel.nameFieldStringValue = "\(library.name).\(format.fileExtension)"
        guard let url = await libraries.runSavePanel(panel, NSApp.mainWindow) else { return nil }
        var lines = written.notes
        do {
            try written.data.write(to: url)
            if saveToMyLibraries {
                let copy = try libraries.registry.save(library)
                lines.append("Saved to My Libraries as \(copy.lastPathComponent).")
            }
        } catch {
            message = "The library could not be saved: \(error.localizedDescription)"
            return nil
        }
        message = nil
        workspace.dismiss(Self.sheet)
        if !written.notes.isEmpty || saveToMyLibraries {
            libraries.showAlert("\(library.name) was exported.", lines.joined(separator: "\n"), NSApp.mainWindow)
        }
        return url
    }

    func cancel() {
        workspace.dismiss(Self.sheet)
    }
}

/// The *Export…* sheet's view.
struct ColorLibraryExportSheet: View {
    @Bindable var model: ColorLibraryExportModel

    static func toggling(_ id: OpID, _ model: ColorLibraryExportModel) -> Binding<Bool> {
        Binding(get: { model.ticked.contains(id) }, set: { _ in model.toggle(id) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export Colors").font(.headline)
            if model.swatches.isEmpty {
                Text("The document has no colors of its own to export.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.swatches) { swatch in
                        Toggle(isOn: Self.toggling(swatch.id, model)) {
                            HStack {
                                ColorChipView(chip: .color(swatch.color))
                                Text(swatch.name)
                            }
                        }
                        .padding(.leading, Double(swatch.depth) * 14)
                        .accessibilityIdentifier("color-export.tick.\(swatch.name)")
                    }
                }
            }
            .frame(maxHeight: 240)
            Form {
                TextField("Name", text: $model.name).accessibilityIdentifier("color-export.name")
                Stepper("Rows: \(model.rows)", value: $model.rows, in: 0...1000)
                Stepper("Columns: \(model.columns)", value: $model.columns, in: 0...1000)
                TextField("Notes", text: $model.notes, axis: .vertical).lineLimit(2...4)
                Picker("Format", selection: $model.format) {
                    ForEach(ColorLibraryExportModel.formats, id: \.format) { Text($0.title).tag($0.format) }
                }
                .accessibilityIdentifier("color-export.format")
                Toggle("Also save to My Libraries", isOn: $model.saveToMyLibraries)
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction)
                Button("Save…", action: ColorAction.run(model.beginSave)).keyboardShortcut(.defaultAction).disabled(model.ticked.isEmpty)
                    .accessibilityIdentifier("color-export.save")
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
