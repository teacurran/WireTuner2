import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTInterchange
import WTModel
import WTProto
import WTRender

/// The Swatches panel's *Replace…* (editing-colors.adoc, "Replacing a color"; the WTApp half of
/// COLOR-015): a segmented control choosing the source -- *Color list* (another swatch of this
/// document, not the swatch's own tints) or *Library* (a colour of one of the libraries *Import*
/// offers) -- the chooser for it, and btn:[Replace], which performs `ReplaceSwatch` with the panel's
/// index as one change.
@MainActor
@Observable
final class ReplaceSwatchModel {
    enum Source: String, CaseIterable, Identifiable {
        case list = "Color list"
        case library = "Library"
        var id: String { rawValue }
    }

    static let sheet = "swatches.replace-sheet"

    let workspace: ColorWorkspace
    /// The swatch being replaced.
    let swatch: OpID
    /// The libraries on offer: the bundled ones, then *My Libraries*.
    let libraries: [ColorLibrary]
    var source = Source.list
    /// The chosen replacement swatch.
    var chosenSwatch: OpID?
    /// The chosen library (an index into `libraries`) and colour key.
    var libraryIndex = 0
    var chosenKey: String?

    init(workspace: ColorWorkspace, swatch: OpID, libraries: [ColorLibrary]) {
        self.workspace = workspace
        self.swatch = swatch
        self.libraries = libraries
    }

    /// The protected defaults and *None* cannot be replaced.
    static func canReplace(_ swatch: Swatch?) -> Bool {
        guard let swatch else { return false }
        return swatch.role == nil
    }

    var list: SwatchList? { workspace.swatches?.list }

    /// Whether `candidate` is the swatch or one of its tints (at any depth).
    func isOwn(_ candidate: Swatch) -> Bool {
        guard let list else { return true }
        var current: Swatch? = candidate
        var seen: Set<OpID> = []
        while let swatch = current, seen.insert(swatch.id).inserted {
            if swatch.id == self.swatch { return true }
            current = swatch.base.flatMap { list[$0] }
        }
        return false
    }

    /// The other swatches, in list order.
    var candidates: [Swatch] { (list?.swatches ?? []).filter { !isOwn($0) } }

    /// The chosen library's colours (a repeated key once).
    var libraryColors: [LibraryColor] {
        guard libraries.indices.contains(libraryIndex) else { return [] }
        var seen = Set<String>()
        return libraries[libraryIndex].colors.filter { seen.insert($0.key).inserted }
    }

    /// The replacement the choices make; nil until one is chosen.
    var replacement: ReplaceSwatch.Source? {
        switch source {
        case .list:
            return chosenSwatch.map { .swatch($0) }
        case .library:
            guard let key = chosenKey, let color = libraryColors.first(where: { $0.key == key }) else { return nil }
            return .library(color, origin: libraries[libraryIndex].name)
        }
    }

    var canCommit: Bool { replacement != nil }

    /// btn:[Replace].
    @discardableResult
    func replace() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let replacement, let document = workspace.document else { return nil }
        workspace.dismiss(Self.sheet)
        return workspace.perform(ReplaceSwatch(swatch, with: replacement, in: document.state, index: workspace.swatches?.index))
    }

    func cancel() {
        workspace.dismiss(Self.sheet)
    }
}

/// The Replace sheet.
struct ReplaceSwatchSheet: View {
    @Bindable var model: ReplaceSwatchModel

    static func chip(_ color: RenderColor) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(SwiftUI.Color(cgColor: color.cgColor)).frame(width: 14, height: 14)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replace \u{201C}\(model.list?[model.swatch]?.name ?? "")\u{201D}").font(.headline)
            Picker("Replace with", selection: $model.source) {
                ForEach(ReplaceSwatchModel.Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("swatches.replace.source")
            if model.source == .list {
                List(model.candidates, id: \.id, selection: $model.chosenSwatch) { swatch in
                    HStack { Self.chip(swatch.color); Text(swatch.name) }.tag(swatch.id)
                }
                .frame(height: 200)
                .accessibilityIdentifier("swatches.replace.list")
            } else {
                Picker("Library", selection: $model.libraryIndex) {
                    ForEach(model.libraries.indices, id: \.self) { Text(model.libraries[$0].name).tag($0) }
                }
                List(model.libraryColors, id: \.key, selection: $model.chosenKey) { color in
                    HStack { Self.chip(ColorLibrarySheetModel.entry(color).color); Text(color.name.isEmpty ? color.key : color.name) }.tag(color.key)
                }
                .frame(height: 200)
                .accessibilityIdentifier("swatches.replace.library")
            }
            HStack {
                Spacer()
                Button("Cancel", action: ColorAction.run(model.cancel)).keyboardShortcut(.cancelAction)
                Button("Replace", action: ColorAction.run(model.replace)).keyboardShortcut(.defaultAction).disabled(!model.canCommit)
                    .accessibilityIdentifier("swatches.replace.ok")
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

extension ColorFeatures {
    /// The Options menu's *Replace…*: one replaceable swatch selected.
    func replaceMenuItem() -> PanelMenuItem {
        let selection = swatchesPanel.selection
        let enabled = selection.count == 1 && ReplaceSwatchModel.canReplace(selection.first)
        return PanelMenuItem(title: "Replace…", isEnabled: enabled) { [weak self] in self?.showReplace() }
    }

    /// Shows the Replace sheet for the selected swatch.
    func showReplace() {
        guard let swatch = swatchesPanel.selection.first else { return }
        let libraries = BundledColorLibraries.all + libraries.registry.files().compactMap { try? ColorLibraryFiles.read(contentsOf: $0) }
        let model = ReplaceSwatchModel(workspace: workspace, swatch: swatch.id, libraries: libraries)
        workspace.present(ReplaceSwatchSheet(model: model), title: "Replace Color", identifier: ReplaceSwatchModel.sheet)
    }
}
