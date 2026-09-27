import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTModel
import WTProto
import WTSync

/// The Styles panel's *Import…* and *Export…* (styles.adoc, "Copying styles between documents";
/// LIB-022's app half over `ImportStyles`, `StylePackage` and `StyleSources`).  *Import…* reads
/// the styles of another open document, of a document cached on this Mac (its local store, offline
/// too), of a team library, or of a style library file (`.wtstyles`, btn:[Choose File…]); the
/// sheet lists them for a selection (kbd:[Shift]- and kbd:[Cmd]-click), with *Replace styles with
/// the same name*, and btn:[Import] makes one change in the front document.  *Export…* lists the
/// front document's styles; btn:[To File…] writes a style library file with the assets' bytes and
/// btn:[To Team Library…] hands them to *Export to Team Library…* (`TeamLibraryFeatures`).
@MainActor
@Observable
final class StyleTransferModel {
    static let importSheet = "styles.import-sheet"
    static let exportSheet = "styles.export-sheet"

    /// Where *Import…* reads from.
    enum Source: Hashable, Identifiable {
        /// A document open in a window, or cached on this Mac.
        case document(id: String, name: String)
        /// A team library (its state is in the catalog).
        case library(id: String, name: String)
        /// A style library file.
        case file(URL)

        var id: String {
            switch self {
            case .document(let id, _): "document:\(id)"
            case .library(let id, _): "library:\(id)"
            case .file(let url): "file:\(url.path)"
            }
        }

        var title: String {
            switch self {
            case .document(_, let name): name
            case .library(_, let name): "\(name) (team library)"
            case .file(let url): url.lastPathComponent
            }
        }
    }

    @ObservationIgnored let documents: DocumentController
    @ObservationIgnored let teamLibraries: TeamLibraryFeatures?
    @ObservationIgnored var sheets = SheetPresenter()
    /// Where a document's local store is (`LocalStore.defaultURL`; tests use a scratch folder).
    @ObservationIgnored var storeLocation: @Sendable (String) throws -> URL = DocumentOpener.defaultLocation
    /// The blob cache for a file's asset bytes.
    @ObservationIgnored var blobCache: () -> BlobCache? = { (try? BlobCache.defaultDirectory()).map(BlobCache.init(directory:)) }
    /// Chooses a style library file to read; nil when cancelled.
    @ObservationIgnored var chooseFile: @MainActor () -> URL? = StyleTransferModel.openPanel
    /// Chooses where to write a style library file; nil when cancelled.
    @ObservationIgnored var chooseDestination: @MainActor (String) -> URL? = StyleTransferModel.savePanel

    /// The import sheet's source, package, selection and option.
    var source: Source?
    /// The source pop-up's value (reading follows it).
    var picked: Source?
    private(set) var package: StylePackage?
    var chosen: Set<OpID> = []
    var replacing = false
    /// The export sheet's selection.
    var exportChosen: Set<OpID> = []
    private(set) var message: String?
    private(set) var files: [URL] = []

    init(documents: DocumentController, teamLibraries: TeamLibraryFeatures?) {
        self.documents = documents
        self.teamLibraries = teamLibraries
    }

    /// Makes the Styles panel's *Import…* and *Export…* live.
    func install(panels: PanelRegistry) {
        guard var descriptor = panels.descriptor(for: PanelID("styles")) else { return }
        let base = descriptor.optionsMenu
        descriptor.optionsMenu = { [weak self] in
            base().map { item in
                guard let self else { return item }
                switch item.title {
                case "Import…": return PanelMenuItem(title: item.title, isEnabled: self.front != nil) { [weak self] in self?.beginImport() }
                case "Export…": return PanelMenuItem(title: item.title, isEnabled: self.front != nil) { [weak self] in self?.beginExport() }
                default: return item
                }
            }
        }
        panels.replace(descriptor)
    }

    /// The front document.
    var front: DocumentHandle? { documents.activeWindowController?.documentHandle }

    // MARK: Import

    /// The sources offered: the other open documents, documents cached on this Mac, the team
    /// libraries, and the files chosen this time.
    var sources: [Source] {
        let frontID = front?.id
        var out: [Source] = []
        var seen: Set<String> = []
        for handle in documents.documents where handle.id != frontID && seen.insert(handle.id).inserted {
            out.append(.document(id: handle.id, name: handle.title))
        }
        if let library = teamLibraries?.library {
            for document in library.cache.recentDocuments where document.id != frontID && !seen.contains(document.id) {
                guard let url = try? storeLocation(document.id), FileManager.default.fileExists(atPath: url.path) else { continue }
                seen.insert(document.id)
                out.append(.document(id: document.id, name: document.name))
            }
        }
        for library in teamLibraries?.catalog.catalog.libraries ?? [] {
            out.append(.library(id: library.documentID, name: library.name))
        }
        return out + files.map(Source.file)
    }

    func beginImport() {
        guard front != nil else { return }
        message = nil
        package = nil
        chosen = []
        replacing = false
        source = nil
        sheets.present(StyleImportSheet(model: self), title: "Import Styles", identifier: Self.importSheet)
        if let first = sources.first { Task { await choose(first) } }
    }

    /// btn:[Choose File…].
    func chooseStyleFile() async {
        guard let url = chooseFile() else { return }
        if !files.contains(url) { files.append(url) }
        await choose(.file(url))
    }

    /// Reads `source`'s styles into the sheet (all chosen).
    func choose(_ source: Source) async {
        self.source = source
        picked = source
        do {
            let read = try await package(of: source)
            package = read
            chosen = Set(read.styles.compactMap(\.source))
            message = read.isEmpty ? "No styles to import" : nil
        } catch {
            package = nil
            chosen = []
            message = Self.describe(error)
        }
    }

    static func describe(_ error: any Error) -> String {
        if error is StylePackage.FileError { return "The file is not a style library" }
        return "The styles could not be read: \(error.localizedDescription)"
    }

    /// The package `source` offers.
    func package(of source: Source) async throws -> StylePackage {
        switch source {
        case .document(let id, _):
            if let handle = documents.document(id: id), await handle.openedModel() != nil {
                return StylePackage(allStylesOf: handle.state)
            }
            let state = try await SymbolSources.cachedState(documentID: id, at: storeLocation(id))
            return StylePackage(allStylesOf: state)
        case .library(let id, _):
            guard let library = teamLibraries?.catalog.catalog.library(id) else { throw StylePackage.FileError.notAStyleLibrary }
            return StylePackage(allStylesOf: library.state)
        case .file(let url):
            let package = try StylePackage(fileData: Data(contentsOf: url))
            if let cache = blobCache() { try StyleSources.storeBlobs(of: package, in: cache) }
            return package
        }
    }

    var canImport: Bool { package.map { !$0.isEmpty } == true && !chosen.isEmpty && front != nil }

    /// btn:[Import]: one change in the front document.
    @discardableResult
    func confirmImport() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard canImport, let package, let front else { return nil }
        let command = ImportStyles(package, selection: chosen, replacingSameName: replacing)
        cancelImport()
        return front.perform(command)
    }

    func cancelImport() {
        sheets.dismiss(Self.importSheet)
    }

    // MARK: Export

    /// The front document's graphic styles, as the panel names them.
    var exportable: [(id: OpID, name: String)] {
        guard let state = front?.state else { return [] }
        let resolver = GraphicStyleResolver(state)
        let names = GraphicStyleFields.displayNames(in: state, resolver)
        return GraphicStyleFields.styles(in: state, resolver).map { ($0, names[$0] ?? "") }
    }

    func beginExport() {
        guard front != nil else { return }
        message = nil
        exportChosen = Set(exportable.map(\.id))
        sheets.present(StyleExportSheet(model: self), title: "Export Styles", identifier: Self.exportSheet)
    }

    func cancelExport() {
        sheets.dismiss(Self.exportSheet)
    }

    /// The chosen styles in panel order.
    private var exportIDs: [OpID] { exportable.map(\.id).filter(exportChosen.contains) }

    /// btn:[To File…]: a style library file with the assets' bytes cached here.
    @discardableResult
    func exportToFile() -> URL? {
        guard let state = front?.state, !exportIDs.isEmpty, let url = chooseDestination("Styles.\(StylePackage.fileExtension)") else { return nil }
        let package = StyleSources.package(of: state, styles: exportIDs, cache: blobCache())
        do {
            try package.fileData.write(to: url, options: .atomic)
            cancelExport()
            return url
        } catch {
            message = "The style library could not be written: \(error.localizedDescription)"
            return nil
        }
    }

    /// Whether *To Team Library…* can run: online, with a library to add to.
    var canExportToTeamLibrary: Bool {
        guard let teamLibraries else { return false }
        return teamLibraries.isOnline && !teamLibraries.exportLibraries.isEmpty && !exportIDs.isEmpty
    }

    /// btn:[To Team Library…].
    func exportToTeamLibrary() {
        guard canExportToTeamLibrary, let teamLibraries else { return }
        let ids = exportIDs
        cancelExport()
        teamLibraries.beginExport(.styles(ids))
    }

    // MARK: Panels

    static func openPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: StylePackage.fileExtension) ?? .data]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func savePanel(_ name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: StylePackage.fileExtension) ?? .data]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// The Import Styles sheet.
struct StyleImportSheet: View {
    @Bindable var model: StyleTransferModel

    /// The picker chose `source` (the model reads it unless it already did).
    static func chosen(_ source: StyleTransferModel.Source?, _ model: StyleTransferModel) {
        guard let source else { return }
        Task { await model.choose(source) }
    }

    static func file(_ model: StyleTransferModel) -> () -> Void { { Task { await model.chooseStyleFile() } } }
    static func cancel(_ model: StyleTransferModel) -> () -> Void { { model.cancelImport() } }
    static func confirm(_ model: StyleTransferModel) -> () -> Void { { model.confirmImport() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import Styles").font(.headline)
            HStack {
                Picker("From", selection: $model.picked) {
                    ForEach(model.sources) { source in Text(source.title).tag(Optional(source)) }
                }
                .onChange(of: model.picked) { _, source in Self.chosen(source, model) }
                .accessibilityIdentifier("styles.import.source")
                Button("Choose File…", action: Self.file(model))
            }
            List(model.package?.styles ?? [], id: \.source, selection: $model.chosen) { style in
                Text(style.props.style.common.name.isEmpty ? "Untitled" : style.props.style.common.name)
            }
            .frame(minHeight: 160)
            .accessibilityIdentifier("styles.import.list")
            Toggle("Replace styles with the same name", isOn: $model.replacing).accessibilityIdentifier("styles.import.replace")
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancel(model)).keyboardShortcut(.cancelAction)
                Button("Import", action: Self.confirm(model)).keyboardShortcut(.defaultAction).disabled(!model.canImport)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

/// The Export Styles sheet.
struct StyleExportSheet: View {
    @Bindable var model: StyleTransferModel

    static func cancel(_ model: StyleTransferModel) -> () -> Void { { model.cancelExport() } }
    static func file(_ model: StyleTransferModel) -> () -> Void { { model.exportToFile() } }
    static func library(_ model: StyleTransferModel) -> () -> Void { { model.exportToTeamLibrary() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export Styles").font(.headline)
            List(model.exportable, id: \.id, selection: $model.exportChosen) { style in
                Text(style.name)
            }
            .frame(minHeight: 160)
            .accessibilityIdentifier("styles.export.list")
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel", action: Self.cancel(model)).keyboardShortcut(.cancelAction)
                Spacer()
                Button("To Team Library…", action: Self.library(model)).disabled(!model.canExportToTeamLibrary)
                    .help(model.teamLibraries?.isOnline == false ? TeamLibraryCatalogModel.offline : "Add the styles to a team library")
                Button("To File…", action: Self.file(model)).keyboardShortcut(.defaultAction).disabled(model.exportChosen.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
