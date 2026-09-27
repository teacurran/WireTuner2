import AppKit
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTInterchange
import WTModel
import WTProto
import WTSync

/// The app half of LIB-013 (library.adoc, "Importing and exporting symbols"): the Library panel's
/// *Import…* -- pick a document from the library (the open copy, else the cached one on this Mac,
/// else the cloud's head) or a WireTuner package or symbol library file on disk, then choose the
/// symbols in the Import Symbols sheet -- and *Export…* -- choose symbols and write a `.wtsymbols`
/// file.  Imported assets' bytes go into the blob cache and are queued for upload.  Copying
/// objects puts their symbol package on the pasteboard beside the objects
/// (`com.villagecompute.wiretuner.symbols`), and pasting them into another document brings the
/// symbols along (`PasteWithSymbols`).
@MainActor
final class SymbolTransferFeatures {
    static let importSheet = "symbols-import-sheet"
    static let exportSheet = "symbols-export-sheet"

    /// The one the app installed.
    static var shared: SymbolTransferFeatures?

    let presenter: SheetPresenter
    /// The front document window.
    var window: @MainActor () -> DocumentWindowController? = { nil }
    /// The documents open in windows (their state is read as it is).
    var openDocuments: @MainActor () -> [DocumentHandle] = { [] }
    /// The library's documents (name and id), for the source list.
    var libraryDocuments: @MainActor () -> [(id: String, name: String)] = { [] }
    /// Where a document's store lives on this Mac, nil when it has none.
    var storeURL: @MainActor (String) -> URL? = { id in
        (try? HeadlessUploads.defaultDirectory()).map { $0.appending(components: id, "store.sqlite") }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
    /// The cloud's head of a document (`SymbolSources.cloudState`), nil offline.
    var cloudState: @MainActor (String) async throws -> EngineState? = { _ in nil }
    /// Stores blobs for a document (the import controller's placement: cached, then queued).
    var storeBlobs: @MainActor ([(data: Data, mediaType: String)], DocumentHandle) async throws -> Void = { _, _ in }
    /// The blob cache's bytes of a hash, for *Export…*.
    var cachedBlob: @MainActor (String) -> Data? = { hash in
        (try? BlobCache.defaultDirectory()).flatMap { try? Data(contentsOf: BlobCache(directory: $0).url(for: hash)) }
    }
    /// Runs the open and save panels; replaceable in tests.
    var chooseFile: @MainActor () async -> URL? = {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [SymbolTransferFeatures.libraryType, UTType(exportedAs: PackageController.typeIdentifier)]
        return await panel.begin() == .OK ? panel.url : nil
    }
    var chooseDestination: @MainActor (String) async -> URL? = { name in
        let panel = NSSavePanel()
        panel.allowedContentTypes = [SymbolTransferFeatures.libraryType]
        panel.nameFieldStringValue = name
        return await panel.begin() == .OK ? panel.url : nil
    }

    /// The `.wtsymbols` file type.
    static let libraryType = UTType(exportedAs: "com.villagecompute.wiretuner.symbol-library", conformingTo: .data)

    init(presenter: SheetPresenter = SheetPresenter()) {
        self.presenter = presenter
    }

    /// The Library panel's options menu items.
    func menuItems(for model: SymbolLibraryModel) -> [PanelMenuItem] {
        let hasDocument = model.document != nil
        let hasSymbols = model.document.map { !Symbols.symbols(in: $0.state).isEmpty } ?? false
        return [
            PanelMenuItem(title: "Import…", isEnabled: hasDocument) { [weak self] in self?.presentImport() },
            PanelMenuItem(title: "Export…", isEnabled: hasSymbols) { [weak self] in self?.presentExport() },
        ]
    }

    // MARK: Import

    /// *Import…*: the source list over the front document.
    @discardableResult
    func presentImport(file: URL? = nil) -> SymbolImportModel? {
        guard let window = window() else { return nil }
        let model = SymbolImportModel(target: window.documentHandle, features: self)
        model.onClose = { [weak self] in self?.presenter.dismiss(Self.importSheet) }
        presenter.present(SymbolImportSheet(model: model), title: "Import Symbols", identifier: Self.importSheet)
        if let file { model.load(file: file) }
        return model
    }

    /// The package of `documentID`: its open copy, the cached one on this Mac, else the cloud's.
    func package(of documentID: String) async throws -> SymbolPackage {
        if let open = openDocuments().first(where: { $0.id == documentID }) {
            return SymbolSources.package(of: open.state, cache: nil)
        }
        if let url = storeURL(documentID) {
            return SymbolSources.package(of: try await SymbolSources.cachedState(documentID: documentID, at: url))
        }
        guard let state = try await cloudState(documentID) else { throw SymbolImportModel.Failure.offline }
        return SymbolSources.package(of: state)
    }

    /// The package in a file: a symbol library file, or a WireTuner package's symbols with the
    /// package's asset bytes.
    nonisolated static func package(file url: URL) throws -> SymbolPackage {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if data.starts(with: SymbolPackage.fileMagic) { return try SymbolPackage(fileData: data) }
        let opened = try DocumentPackage.reader.open(data)
        let state = try DocumentPackage.state(of: opened)
        let bytes = Dictionary(opened.blobs.map { (ImportedBlob.hex($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        return withBlobs(SymbolPackage(symbols: Symbols.symbols(in: state), from: state)) { bytes[$0] }
    }

    /// `package` carrying the bytes `lookup` has of each asset it needs.
    nonisolated static func withBlobs(_ package: SymbolPackage, _ lookup: (String) -> Data?) -> SymbolPackage {
        var package = package
        for hash in package.assetHashes {
            if let data = lookup(hash) { package.blobs[hash] = data }
        }
        return package
    }

    /// The media type of an asset's bytes (an image's, else a PDF, else octet-stream).
    nonisolated static func mediaType(_ data: Data) -> String {
        if let source = CGImageSourceCreateWithData(data as CFData, nil), let uti = CGImageSourceGetType(source) as String?,
           let mime = UTType(uti)?.preferredMIMEType {
            return mime
        }
        return data.starts(with: Array("%PDF".utf8)) ? "application/pdf" : "application/octet-stream"
    }

    // MARK: Export

    /// *Export…*: the front document's symbols.
    @discardableResult
    func presentExport() -> SymbolExportModel? {
        guard let window = window() else { return nil }
        let model = SymbolExportModel(document: window.documentHandle, features: self)
        model.onClose = { [weak self] in self?.presenter.dismiss(Self.exportSheet) }
        presenter.present(SymbolExportSheet(model: model), title: "Export Symbols", identifier: Self.exportSheet)
        return model
    }

    /// A `.wtsymbols` file opened from the Finder: the Import Symbols sheet over the front window.
    static func opens(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == SymbolPackage.fileExtension, let shared else { return false }
        return shared.presentImport(file: url) != nil
    }
}

/// The Import Symbols sheet: a source, then its symbols to choose from.
@MainActor
@Observable
final class SymbolImportModel {
    enum Failure: Error, Equatable {
        case offline
    }

    struct Source: Identifiable, Hashable {
        let id: String
        let name: String
    }

    let target: DocumentHandle
    @ObservationIgnored let features: SymbolTransferFeatures
    /// The source's package once read.
    private(set) var package: SymbolPackage?
    /// Where it came from ("Logo kit", "Icons.wtsymbols").
    private(set) var sourceName: String?
    /// The chosen symbols (source ids); every symbol when the package loads.
    var chosen: Set<OpID> = []
    private(set) var message: String?
    private(set) var isLoading = false
    @ObservationIgnored var onClose: @MainActor () -> Void = {}
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(target: DocumentHandle, features: SymbolTransferFeatures) {
        self.target = target
        self.features = features
    }

    /// The library's documents other than the target.
    var sources: [Source] {
        features.libraryDocuments().filter { $0.id != target.id }.map { Source(id: $0.id, name: $0.name) }
    }

    /// The package's symbols: source id and name.
    var symbols: [(id: OpID, name: String)] {
        package?.symbols.compactMap { tree in tree.source.map { ($0, tree.props.symbol.common.name) } } ?? []
    }

    @discardableResult
    func load(document source: Source) -> Task<Void, Never> {
        start(named: source.name) { [features] in try await features.package(of: source.id) }
    }

    @discardableResult
    func load(file url: URL) -> Task<Void, Never> {
        start(named: url.lastPathComponent) { try await Task.detached { try SymbolTransferFeatures.package(file: url) }.value }
    }

    /// btn:[Choose File…].
    func chooseFile() async {
        guard let url = await features.chooseFile() else { return }
        await load(file: url).value
    }

    private func start(named name: String, _ read: @escaping @MainActor () async throws -> SymbolPackage) -> Task<Void, Never> {
        loading?.cancel()
        isLoading = true
        message = nil
        let task = Task { [weak self] in
            do {
                let package = try await read()
                guard let self, !Task.isCancelled else { return }
                self.package = package
                self.sourceName = name
                self.chosen = Set(package.symbols.compactMap(\.source))
                if package.symbols.isEmpty { self.message = "\(name) has no symbols" }
            } catch {
                self?.message = error as? Failure == .offline ? "That document is not on this Mac; connect to import from it"
                    : "The symbols could not be read: \(error.localizedDescription)"
            }
            self?.isLoading = false
        }
        loading = task
        return task
    }

    /// btn:[Import]: the chosen symbols in one change, their assets' bytes stored and queued.
    @discardableResult
    func importChosen() -> Task<Void, Never>? {
        guard let package, !chosen.isEmpty else { return nil }
        let command = ImportSymbols(package, selection: chosen)
        let blobs = package.blobs.sorted { $0.key < $1.key }.map { (data: $0.value, mediaType: SymbolTransferFeatures.mediaType($0.value)) }
        let target = target
        let features = features
        return Task { [weak self] in
            do {
                if !blobs.isEmpty { try await features.storeBlobs(blobs, target) }
                _ = await target.perform(command).value
                self?.onClose()
            } catch {
                self?.message = "The symbols' images could not be stored: \(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        loading?.cancel()
        onClose()
    }
}

struct SymbolImportSheet: View {
    @Bindable var model: SymbolImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.package == nil {
                Text("Import symbols from").font(.headline)
                List(model.sources) { source in
                    Button(source.name) { model.load(document: source) }.buttonStyle(.plain)
                        .accessibilityIdentifier("symbols.import.source.\(source.id)")
                }
                .frame(minHeight: 180)
                Button("Choose File…") { Task { await model.chooseFile() } }.accessibilityIdentifier("symbols.import.file")
            } else {
                Text(model.sourceName ?? "").font(.headline)
                List(model.symbols, id: \.id, selection: $model.chosen) { symbol in
                    Text(symbol.name).tag(symbol.id)
                }
                .frame(minHeight: 200)
                .accessibilityIdentifier("symbols.import.list")
            }
            if model.isLoading { ProgressView().controlSize(.small) }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("symbols.import.message") }
            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button("Import") { model.importChosen() }.keyboardShortcut(.defaultAction)
                    .disabled(model.package == nil || model.chosen.isEmpty)
                    .accessibilityIdentifier("symbols.import.import")
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

/// The Export Symbols sheet: the document's symbols to choose, written to a symbol library file.
@MainActor
@Observable
final class SymbolExportModel {
    let document: DocumentHandle
    @ObservationIgnored let features: SymbolTransferFeatures
    var chosen: Set<OpID>
    private(set) var message: String?
    @ObservationIgnored var onClose: @MainActor () -> Void = {}

    init(document: DocumentHandle, features: SymbolTransferFeatures) {
        self.document = document
        self.features = features
        chosen = Set(Symbols.symbols(in: document.state))
    }

    var symbols: [(id: OpID, name: String)] {
        let state = document.state
        return Symbols.symbols(in: state).map { ($0, state.props($0).symbol.common.name) }
    }

    /// The package of the chosen symbols with the cached bytes of their assets.
    var package: SymbolPackage {
        SymbolTransferFeatures.withBlobs(SymbolPackage(symbols: symbols.map(\.id).filter(chosen.contains), from: document.state), features.cachedBlob)
    }

    /// btn:[To File…].
    @discardableResult
    func exportToFile() -> Task<Void, Never>? {
        guard !chosen.isEmpty else { return nil }
        let data = package.fileData
        let name = "\(document.title) Symbols.\(SymbolPackage.fileExtension)"
        return Task { [weak self] in
            guard let self, let url = await self.features.chooseDestination(name) else { return }
            do {
                try data.write(to: url)
                self.onClose()
            } catch {
                self.message = "The file could not be written: \(error.localizedDescription)"
            }
        }
    }

    func cancel() { onClose() }
}

struct SymbolExportSheet: View {
    @Bindable var model: SymbolExportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            List(model.symbols, id: \.id, selection: $model.chosen) { symbol in
                Text(symbol.name).tag(symbol.id)
            }
            .frame(minHeight: 200)
            .accessibilityIdentifier("symbols.export.list")
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("\(model.chosen.count) of \(model.symbols.count) symbols").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button("To File…") { model.exportToFile() }.keyboardShortcut(.defaultAction)
                    .disabled(model.chosen.isEmpty)
                    .accessibilityIdentifier("symbols.export.file")
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

// MARK: The pasteboard

/// A window pasteboard that can carry the symbol package of copied objects beside them.
@MainActor
protocol SymbolPasteboard: AnyObject {
    var pasteboard: NSPasteboard { get }
}

extension SymbolPasteboard {
    static var symbolsType: NSPasteboard.PasteboardType { NSPasteboard.PasteboardType(SymbolPackage.pasteboardType) }

    /// Adds `bytes` to what the last copy wrote.
    func writeSymbols(_ bytes: [UInt8]) {
        pasteboard.addTypes([Self.symbolsType], owner: nil)
        pasteboard.setData(Data(bytes), forType: Self.symbolsType)
    }

    func readSymbols() -> [UInt8]? {
        pasteboard.data(forType: Self.symbolsType).map { Array($0) }
    }
}

extension SystemObjectPasteboard: SymbolPasteboard {}
extension FormatsPasteboard: SymbolPasteboard {}

enum SymbolClipboard {
    /// After a copy of `payload` from `state`: the package of what it references, when it
    /// references a symbol, swatch, style or brush.
    @MainActor
    static func write(_ payload: ClipboardPayload, from state: EngineState, to pasteboard: any ObjectPasteboard) {
        guard let symbols = pasteboard as? any SymbolPasteboard else { return }
        let package = SymbolPackage(referencedBy: payload.nodes, from: state)
        if !package.isEmpty { symbols.writeSymbols(package.encoded()) }
    }

    /// The paste of `paste` into `document`: with the pasteboard's package when the objects came
    /// from another document, so their symbols come along.
    @MainActor
    static func command(_ paste: Paste, into document: String, from pasteboard: any ObjectPasteboard) -> any WTModel.Command {
        guard paste.payload.sourceDocument != document, let symbols = pasteboard as? any SymbolPasteboard, let bytes = symbols.readSymbols(),
              let package = SymbolPackage(decoding: bytes), !package.isEmpty else { return paste }
        return PasteWithSymbols(paste, package: package)
    }
}
