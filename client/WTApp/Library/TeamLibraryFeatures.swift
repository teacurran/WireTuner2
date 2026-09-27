import AppKit
import GRPCNIOTransportHTTP2
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTSync

/// A team library symbol dragged from the Library panel (LIB-016): the library document and the
/// symbol there, as "<document>|<counter>:<replica>" under a private pasteboard type the canvas
/// takes (`CanvasView`), which places an instance through `PlaceFromLibrary`.
enum TeamLibraryDrag {
    static let type = NSPasteboard.PasteboardType("com.villagecompute.wiretuner.team-library-symbol")

    /// What the canvas does with a drop (the app's `TeamLibraryFeatures`); nil takes none.
    @MainActor static var drop: (@MainActor (_ library: String, _ symbol: OpID, _ point: Point, _ document: DocumentHandle) -> Bool)?

    static func string(_ item: LibraryCatalog.Item) -> String {
        "\(item.library)|\(item.node.counter):\(item.node.replica)"
    }

    /// The drag's item provider.
    static func provider(_ item: LibraryCatalog.Item) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(string(item).utf8)
        provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// The library and symbol a string names.
    static func parse(_ string: String) -> (library: String, symbol: OpID)? {
        let parts = string.split(separator: "|")
        guard parts.count == 2 else { return nil }
        let id = parts[1].split(separator: ":").compactMap { UInt64($0) }
        guard id.count == 2 else { return nil }
        return (String(parts[0]), OpID(counter: id[0], replica: id[1]))
    }

    static func carries(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [type]) != nil
    }

    /// The canvas's drop at `point` (pasteboard space) in `document`.
    @MainActor
    static func perform(_ pasteboard: NSPasteboard, at point: Point, in document: DocumentHandle) -> Bool {
        guard let data = pasteboard.data(forType: type), let parsed = parse(String(decoding: data, as: UTF8.self)), let drop else { return false }
        return drop(parsed.library, parsed.symbol, point, document)
    }
}

/// Team libraries in the app (library.adoc, "Team libraries"; LIB-016's app half over
/// `TeamLibraryClient`): the account's teams' libraries listed through `ListLibraries` and read
/// through `LibraryStoreOpening` into the panels' *Team libraries* sections (COLLAB-015's
/// `TeamLibraryCatalogModel`, which this makes live); the Library panel's options menu gains *Show
/// Team Libraries*, *Update from Library* and *Export to Team Library…*; the canvas takes a library
/// symbol dropped on it (*Place*, with provenance); the document library window's *Use as Team
/// Library* marks a document.  Every one of these needs the connection and says so offline.
@MainActor
@Observable
final class TeamLibraryFeatures {
    static let exportSheet = "team-library.export-sheet"

    let catalog: TeamLibraryCatalogModel
    let library: LibraryModel
    @ObservationIgnored let documents: DocumentController
    @ObservationIgnored let client: TeamLibraryClient?
    @ObservationIgnored var sheets = SheetPresenter()
    /// The Library panel (for its selection).
    @ObservationIgnored weak var symbols: SymbolLibraryModel?
    /// The libraries last listed.
    private(set) var libraries: [Wiretuner_Docs_V1_Library] = []
    /// Why the last call failed.
    private(set) var message: String?
    /// The symbols or styles *Export to Team Library…* is about to send, while its sheet is open.
    private(set) var exporting: Export?
    var exportTarget: String?

    /// What an export sends.
    enum Export: Equatable {
        case symbols([OpID])
        case styles([OpID])

        var count: Int {
            switch self {
            case .symbols(let ids), .styles(let ids): ids.count
            }
        }
    }

    init(catalog: TeamLibraryCatalogModel, library: LibraryModel, documents: DocumentController, client: TeamLibraryClient?) {
        self.catalog = catalog
        self.library = library
        self.documents = documents
        self.client = client
        catalog.opener = client
        catalog.isOnline = client != nil && library.isOnline
    }

    var isOnline: Bool { catalog.isOnline }

    /// The team ids the account belongs to.
    var teams: [String] { library.cache.teams.map(\.id) }

    /// Lists the libraries and re-reads the catalog (the panels' sections and badges).
    func refresh() async {
        guard let client else {
            catalog.isOnline = false
            return
        }
        let listing = await client.libraries(teams: teams)
        libraries = listing.libraries
        catalog.isOnline = listing.isCurrent && library.isOnline
        await catalog.reload()
    }

    func install(panels: PanelRegistry) {
        TeamLibraryDrag.drop = { [weak self] library, symbol, point, document in
            self?.place(symbol, from: library, at: point, in: document) != nil
        }
        library.useAsTeamLibrary = { [weak self] document in
            Task { await self?.useAsTeamLibrary(document) }
        }
        library.teamLibraryRefusal = { [weak self] document in self?.refusal(for: document) }
        if var descriptor = panels.descriptor(for: PanelID("library")) {
            let base = descriptor.optionsMenu
            descriptor.optionsMenu = { [weak self] in base() + (self?.libraryMenu() ?? []) }
            panels.replace(descriptor)
        }
        Task { await refresh() }
    }

    // MARK: Library panel

    /// The selected symbol of the Library panel that came from a team library, with its library.
    var selectedCopy: (symbol: OpID, library: LibrarySource)? {
        guard let model = symbols, let symbol = model.selectedSymbol, let state = model.document?.state,
              let provenance = LibraryBadge.of(symbol, in: state, catalog: catalog.catalog),
              let source = catalog.catalog.library(provenance.documentID) else { return nil }
        return (symbol, source)
    }

    /// The Library panel's options menu additions.
    func libraryMenu() -> [PanelMenuItem] {
        let symbols = self.symbols?.selectedRows.filter { $0.kind == .symbol }.map(\.id) ?? []
        return [
            PanelMenuItem(title: catalog.showsInLibraryPanel ? "Hide Team Libraries" : "Show Team Libraries") { [weak self] in
                self?.catalog.showsInLibraryPanel.toggle()
            },
            PanelMenuItem(title: "Update from Library", isEnabled: isOnline && selectedCopy != nil) { [weak self] in self?.updateSelected() },
            PanelMenuItem(title: "Export to Team Library…", isEnabled: isOnline && !symbols.isEmpty && !libraries.isEmpty) { [weak self] in
                self?.beginExport(.symbols(symbols))
            },
        ]
    }

    /// *Update from Library* on the selected symbol: one undoable change.
    @discardableResult
    func updateSelected() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard isOnline else {
            message = TeamLibraryCatalogModel.offline
            return nil
        }
        guard let (symbol, source) = selectedCopy, let document = symbols?.document else { return nil }
        return document.perform(UpdateFromLibrary([symbol], from: source))
    }

    /// A library symbol dropped on the canvas at `point`: copied (or its copy reused) and placed.
    @discardableResult
    func place(_ symbol: OpID, from libraryID: String, at point: Point, in document: DocumentHandle) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard isOnline else {
            message = TeamLibraryCatalogModel.offline
            return nil
        }
        guard let source = catalog.catalog.library(libraryID) else { return nil }
        let layer = documents.windowControllers[document.id]?.objectEditing.activeLayer
        return document.perform(PlaceFromLibrary(symbol, from: source, at: point, layer: layer))
    }

    // MARK: Export

    /// The libraries an export can go to: those this account can edit (the document library's
    /// role), by name.
    var exportLibraries: [Wiretuner_Docs_V1_Library] {
        libraries.filter { LibraryPickerModel.canEdit(library.cache.documents[$0.documentID]?.role) }
    }

    func beginExport(_ export: Export) {
        guard isOnline else {
            message = TeamLibraryCatalogModel.offline
            return
        }
        exporting = export
        exportTarget = exportLibraries.first?.documentID
        sheets.present(TeamLibraryExportSheet(model: self), title: "Export to Team Library", identifier: Self.exportSheet)
    }

    func cancelExport() {
        exporting = nil
        sheets.dismiss(Self.exportSheet)
    }

    /// btn:[Export]: the library document opens (a tab) and the symbols or styles are imported
    /// into it, one change there.
    @discardableResult
    func confirmExport() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let export = exporting, let target = exportTarget, let state = activeState,
              let entry = libraries.first(where: { $0.documentID == target }) else { return nil }
        cancelExport()
        let command: any WTModel.Command
        switch export {
        case .symbols(let ids): command = ImportSymbols(SymbolPackage(symbols: ids, from: state))
        case .styles(let ids): command = ImportStyles(StylePackage(styles: ids, from: state))
        }
        let handle = documents.document(id: target) ?? documents.environment.makeDocument(id: target, title: entry.name)
        documents.open(handle)
        return Task { @MainActor in
            _ = await handle.openedModel()
            return await handle.perform(command).value
        }
    }

    private var activeState: EngineState? { documents.activeWindowController?.documentHandle.state }

    // MARK: Use as Team Library

    /// Why *Use as Team Library* is disabled for `document`, or nil.
    func refusal(for document: LibraryDocument) -> String? {
        guard client != nil, library.isOnline else { return TeamLibraryCatalogModel.offline }
        guard library.cache.teams.contains(where: { $0.id == document.spaceID }) else { return "Move the document to a team folder first" }
        guard document.role == nil || document.role == .owner else { return "Only the document's owner can make it a team library" }
        return nil
    }

    /// *Use as Team Library* in the document library window.
    func useAsTeamLibrary(_ document: LibraryDocument) async {
        if let refused = refusal(for: document) {
            message = refused
            library.show(message: refused)
            return
        }
        do {
            try await client?.setLibrary(document.id, isLibrary: true)
            message = nil
            await refresh()
        } catch {
            message = "The document could not be made a team library: \(error.localizedDescription)"
            library.show(message: message!)
        }
    }
}

/// *Export to Team Library…*: the library to add to.
struct TeamLibraryExportSheet: View {
    @Bindable var model: TeamLibraryFeatures

    static func cancel(_ model: TeamLibraryFeatures) -> () -> Void { { model.cancelExport() } }
    static func export(_ model: TeamLibraryFeatures) -> () -> Void { { model.confirmExport() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export to Team Library").font(.headline)
            let count = model.exporting?.count ?? 0
            Text(count == 1 ? "1 item will be added to the library." : "\(count) items will be added to the library.").foregroundStyle(.secondary)
            if model.exportLibraries.isEmpty {
                Text("No team library you can edit").foregroundStyle(.secondary)
            } else {
                Picker("Library", selection: $model.exportTarget) {
                    ForEach(model.exportLibraries, id: \.documentID) { library in
                        Text(library.name).tag(Optional(library.documentID))
                    }
                }
                .accessibilityIdentifier("team-library.export.target")
            }
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancel(model)).keyboardShortcut(.cancelAction)
                Button("Export", action: Self.export(model)).keyboardShortcut(.defaultAction).disabled(model.exportTarget == nil)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

extension LaunchEnvironment {
    /// The team library client over the configured API, caching listings in the libraries folder
    /// and reading libraries this Mac holds from their stores; none in test launches.
    @MainActor
    func makeTeamLibraryClient(account: AccountModel, infoDictionary: [String: Any]?, defaults: UserDefaults) -> TeamLibraryClient? {
        guard !isTesting, let directory = try? TeamLibraryClient.defaultDirectory() else { return nil }
        let configuration = AuthConfiguration(infoDictionary: infoDictionary)
        let identity = GRPCSyncTransport<HTTP2ClientTransport.Posix>.Identity(
            clientVersion: Self.clientVersion(infoDictionary), deviceID: DeviceIdentity.current(defaults: defaults)
        )
        guard let transport = try? GRPCTeamLibraryTransport.http2(api: configuration.api, identity: identity) else { return nil }
        let sync = try? GRPCSyncTransport.http2(api: configuration.api, identity: identity)
        let auth = account.auth
        return TeamLibraryClient(transport: transport, sync: sync, directory: directory,
                                 local: TeamLibraryClient.cachedStore(location: DocumentOpener.defaultLocation)) { try await auth.validAccessToken() }
    }
}

extension AppDelegate {
    /// Team libraries in the panels, the canvas and the document library window (LIB-016), and
    /// the Styles panel's *Import…* and *Export…* (LIB-022); after `installDocumentGlue`.
    func installLibraryTransfer() {
        let client = launchEnvironment.makeTeamLibraryClient(account: account, infoDictionary: Bundle.main.infoDictionary, defaults: preferences.defaults)
        let features = TeamLibraryFeatures(catalog: documentGlue.teamLibraries, library: library, documents: documents, client: client)
        features.symbols = SymbolLibraryModel.installed
        features.install(panels: panels)
        let styles = StyleTransferModel(documents: documents, teamLibraries: features)
        styles.install(panels: panels)
        // LIB-022's rest: uncached documents from the server, and a file's asset bytes queued.
        let library = library
        styles.libraryDocuments = { library.cache.documents.values.filter { !$0.isTrashed }.sorted { $0.name < $1.name }.map { (id: $0.id, name: $0.name) } }
        styles.isOnline = { library.isOnline }
        styles.cloudState = { id in try await SymbolTransferFeatures.shared?.cloudState(id) }
        let imports = imports
        styles.storeBlobs = { blobs, document in try await imports.blobs.store(blobs, for: document) }
        StyleTransferModel.shared = styles
        libraryTransfer = (features, styles)
    }
}
