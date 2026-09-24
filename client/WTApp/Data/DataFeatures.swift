import AppKit
import Foundation
import Observation
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTSync

/// The Data panel's app-wide state: the front window it follows and a revision its body reads.
@MainActor
@Observable
final class DataPanelState {
    private(set) var revision = 0
    /// The front document window.
    @ObservationIgnored var window: @MainActor () -> DocumentWindowController? = { nil }
    /// The session of a window (the features make it on first use).
    @ObservationIgnored var session: @MainActor (DocumentWindowController) -> DataSession? = { _ in nil }

    init() {}

    func touch() { revision += 1 }
}

/// The data merge features (the DATA epic's client-ui tasks): menu:Window[Data], the menu:File[Data
/// Merge] submenu, the source, credentials, hosts, field, barcode and merge sheets, the record
/// navigator's shortcuts, the canvas marks and the *field removed* notice.  One object per app;
/// every command acts on the front window, each window keeping its own `DataSession`.
@MainActor
final class DataFeatures {
    enum ID {
        static let insertField: CommandID = "data.insertField"
        static let insertBarcode: CommandID = "data.insertBarcode"
        static let addFieldsFromSource: CommandID = "data.addFieldsFromSource"
        static let embedSample: CommandID = "data.embedSample"
        static let embedAll: CommandID = "data.embedAll"
        static let refresh: CommandID = "data.refresh"
        static let exportData: CommandID = "data.exportData"
        static let credentials: CommandID = "data.credentials"
        static let showHosts: CommandID = "data.showHosts"
        static let merge: CommandID = "data.merge"
        static let togglePreview: CommandID = "data.preview"
        static let nextRecord: CommandID = "data.nextRecord"
        static let previousRecord: CommandID = "data.previousRecord"
    }

    static let menu = "Data Merge"
    static let noDocument = DocumentSetupFeatures.noDocument
    static let noSource = "No data source is connected"
    static let noRecords = "The source has no records"
    static let panelGroup = "Data"

    let preferences: PreferenceStore
    let panel = DataPanelState()
    var services = DataServices()
    /// Where embedded samples go and are read.
    var blobs = BlobPlacement()
    /// The front document window.
    var window: @MainActor () -> DocumentWindowController? = { nil }
    /// Shows a panel by id (menu:Window[Data]).
    var showPanel: @MainActor (PanelID) -> Void = { _ in }
    private var sessions: [ObjectIdentifier: (window: DocumentWindowController, session: DataSession, overlay: DataCanvasOverlay, closing: NSObjectProtocol?)] = [:]
    private var observers: [NSObjectProtocol] = []

    init(preferences: PreferenceStore) {
        self.preferences = preferences
    }

    func install(commands: CommandRegistry, panels: PanelRegistry, window: @escaping @MainActor () -> DocumentWindowController?) {
        self.window = window
        panel.window = window
        panel.session = { [weak self] in self?.session(for: $0) }
        panels.groupDefaults[Self.panelGroup] = panels.groupDefaults[Self.panelGroup] ?? PanelGroupDefaults(position: 10, isOpen: false)
        panels.registerIfAbsent(DataPanel.descriptor(state: panel, features: self))
        for command in self.commands() { commands.replace(command) }
        // Every window becoming main gets its session and marks, and the panel follows it.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowBecameMain(window?.windowController as? DocumentWindowController) }
        })
    }

    func windowBecameMain(_ controller: DocumentWindowController?) {
        if let controller { attach(controller) }
        panel.touch()
    }

    // MARK: Sessions

    /// The window's session, made (with its canvas marks) on first use.
    @discardableResult
    func attach(_ window: DocumentWindowController) -> DataSession {
        let key = ObjectIdentifier(window)
        if let existing = sessions[key] { return existing.session }
        let session = DataSession(document: window.documentHandle, services: services, blobs: blobs, preferences: preferences)
        session.window = window
        let overlay = DataCanvasOverlay(document: window.documentHandle)
        let preferences = preferences
        overlay.highlights = { preferences[PreferenceCatalog.Automation.highlightDataFields] }
        overlay.previewing = { [weak session] in session?.preview.showing == true }
        let previous = window.canvas.furnitureDrawer
        window.canvas.furnitureDrawer = { [weak window, weak overlay] ctx in
            previous?(ctx)
            if let window { overlay?.draw(in: ctx, viewport: window.canvas.viewport) }
        }
        let closing = window.window.map { nswindow in
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nswindow, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated { if let window { self?.detach(window) } }
            }
        }
        sessions[key] = (window, session, overlay, closing)
        Task { await session.load() }
        return session
    }

    func session(for window: DocumentWindowController) -> DataSession { attach(window) }

    func overlay(for window: DocumentWindowController) -> DataCanvasOverlay? { sessions[ObjectIdentifier(window)]?.overlay }

    func detach(_ window: DocumentWindowController) {
        guard let entry = sessions.removeValue(forKey: ObjectIdentifier(window)) else { return }
        entry.session.close()
        if let closing = entry.closing { NotificationCenter.default.removeObserver(closing) }
    }

    /// The front window and its session.
    var front: (window: DocumentWindowController, session: DataSession)? {
        guard let window = window() else { return nil }
        return (window, session(for: window))
    }

    // MARK: Commands

    func commands() -> [Command] {
        let file = StandardCommands.Menu.file
        func item(_ subsection: Int) -> MenuPath { MenuPath(file, Self.menu, section: 3, subsection: subsection) }
        let needsWindow: @MainActor @Sendable () -> CommandValidation = { [weak self] in self?.window() == nil ? .disabled(Self.noDocument) : .enabled }
        let needsSource: @MainActor @Sendable () -> CommandValidation = { [weak self] in
            guard let front = self?.front else { return .disabled(Self.noDocument) }
            return front.session.model.activeSource == nil ? .disabled(Self.noSource) : .enabled
        }
        let needsRecords: @MainActor @Sendable () -> CommandValidation = { [weak self] in
            guard let front = self?.front else { return .disabled(Self.noDocument) }
            return front.session.records.isEmpty ? .disabled(Self.noRecords) : .enabled
        }
        let previewing: @MainActor @Sendable () -> CommandValidation = { [weak self] in
            guard let front = self?.front else { return .disabled(Self.noDocument) }
            return front.session.records.isEmpty ? .disabled(Self.noRecords) : .checked(front.session.preview.showing)
        }
        let perform: (@escaping @MainActor (DataFeatures) -> Void) -> CommandAction = { body in .perform { [weak self] in if let self { body(self) } } }
        return [
            Command(id: ID.insertField, title: "Insert Field…", menu: item(0), keywords: ["placeholder", "data merge"],
                    validation: needsWindow, action: perform { $0.presentInsertField() }),
            Command(id: ID.insertBarcode, title: "Insert Barcode…", menu: item(0), keywords: ["qr", "code 128", "barcode"],
                    validation: needsWindow, action: perform { $0.presentInsertBarcode() }),
            Command(id: ID.addFieldsFromSource, title: "Add Fields from Source", menu: item(1), keywords: ["data merge", "columns"],
                    validation: needsRecords, action: perform { $0.addFieldsFromSource() }),
            Command(id: ID.embedSample, title: "Embed Sample", menu: item(1), keywords: ["data merge", "offline"],
                    validation: needsRecords, action: perform { features in Task { await features.front?.session.embed(all: false) } }),
            Command(id: ID.embedAll, title: "Embed All Records", menu: item(1), keywords: ["data merge", "offline"],
                    validation: needsRecords, action: perform { features in Task { await features.front?.session.embed(all: true) } }),
            Command(id: ID.refresh, title: "Refresh", menu: item(1), keywords: ["data merge", "fetch", "reload"],
                    validation: needsSource, action: perform { features in Task { await features.front?.session.refresh() } }),
            Command(id: ID.exportData, title: "Export Data…", menu: item(1), keywords: ["data merge", "csv"],
                    validation: needsRecords, action: perform { features in Task { await features.exportData() } }),
            Command(id: ID.credentials, title: "Credentials…", menu: item(2), keywords: ["data merge", "api", "token", "secret"],
                    validation: needsWindow, action: perform { $0.presentCredentials() }),
            Command(id: ID.showHosts, title: "Show Hosts", menu: item(2), keywords: ["data merge", "api", "allowlist"],
                    validation: needsWindow, action: perform { $0.presentHosts() }),
            Command(id: ID.togglePreview, title: "Preview Records", menu: item(3), keywords: ["data merge", "record"],
                    validation: previewing, action: perform { features in
                        if let session = features.front?.session { session.setPreview(!session.preview.showing) }
                    }),
            Command(id: ID.nextRecord, title: "Next Record", menu: item(3),
                    keywords: ["data merge", "preview"], validation: needsRecords, action: perform { $0.front?.session.next() }),
            Command(id: ID.previousRecord, title: "Previous Record", menu: item(3),
                    keywords: ["data merge", "preview"], validation: needsRecords, action: perform { $0.front?.session.previous() }),
            Command(id: ID.merge, title: "Merge…", menu: item(4), keywords: ["data merge", "mail merge", "labels"],
                    validation: needsRecords, action: perform { $0.presentMerge() }),
        ]
    }

    // MARK: Field commands

    /// *Add Fields from Source*: every column that is not a field yet, its type guessed, one
    /// change.
    @discardableResult
    func addFieldsFromSource() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let (window, session) = front, let table = session.table else { return nil }
        let model = session.model
        let fields = RecordSet.suggestedFields(for: table.records, columns: table.columns, model: model, source: model.activeSource)
        guard !fields.isEmpty else { return nil }
        return window.objectEditing.perform(AddFields(fields))
    }

    /// *Export Data…*: the resolved records as CSV (UTF-8 with a byte-order mark for
    /// spreadsheets), a `record` column first.
    @discardableResult
    func exportData(to chosen: URL? = nil) async -> URL? {
        guard let (window, session) = front, !session.records.isEmpty else { return nil }
        let destination: URL?
        if let chosen {
            destination = chosen
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(window.documentHandle.title) data.csv"
            panel.allowedContentTypes = [.commaSeparatedText]
            destination = await ModalUI.url(panel, on: window.window)
        }
        guard let destination else { return nil }
        let text = Self.exportTable(session.records).csv(bom: true)
        do {
            try Data(text.utf8).write(to: destination, options: .atomic)
            return destination
        } catch {
            ModalUI.alert("The data could not be exported.", error.localizedDescription, on: window.window)
            return nil
        }
    }

    /// The resolved records as a table: `record`, then each field by name, formatted values.
    static func exportTable(_ records: RecordSet) -> DataTable {
        let fields = records.fields.filter { !$0.name.isEmpty }
        let rows = records.records.map { record in
            var values = ["record": String(record.number)]
            for field in fields {
                let value = record.value(field.id)
                if value.raw != nil { values[field.name] = value.text }
            }
            return DataRecord(values)
        }
        return DataTable(columns: ["record"] + fields.map(\.name), records: rows)
    }
}

extension AppDelegate {
    /// The DATA epic's panel, commands and sheets, and the Scripts menu and editor.
    func installDataMerge() {
        let documents = documents!
        let account = account
        let library = library
        let collaboration = collaboration
        let client = launchEnvironment.makeDataSourceClient(account: account, infoDictionary: Bundle.main.infoDictionary, defaults: preferences.defaults)
        dataMerge.blobs = imports.blobs
        dataMerge.services.client = { account.isSignedIn ? client : nil }
        dataMerge.services.accountID = { account.profile?.accountID }
        dataMerge.services.scope = { document in
            await DataScopes.scope(of: document.id, library: library, account: account.profile?.accountID, collaboration: collaboration)
        }
        let layout = layout
        dataMerge.showPanel = { layout.showPanel($0) }
        dataMerge.install(commands: commands, panels: panels) { documents.activeWindowController }
        scripts.data = dataMerge
        // A test launch keeps its scripts in a folder of its own and watches nothing.
        let testing = launchEnvironment.isTesting
        if testing { scripts.folder = ScriptsFolder(url: FileManager.default.temporaryDirectory.appending(path: "WireTunerScripts-\(UUID().uuidString)")) }
        scripts.install(commands: commands, watch: !testing) { documents.activeWindowController }
        scripts.menuDidChange = { [weak self] in self?.rebuildMainMenu() }
    }
}

/// The document's data scope from the library cache and, for a team, the caller's team role.
@MainActor
enum DataScopes {
    static func scope(of documentID: String, library: LibraryModel, account: String?, collaboration: CollaborationServices) async -> DataScope? {
        guard let account else { return nil }
        let entry = library.cache.documents[documentID]
        let space = entry?.spaceID ?? library.cache.personalSpaceID ?? account
        guard let team = library.cache.teams.first(where: { $0.id == space }) else {
            return DataScope(kind: .personal(account: account), canManage: entry?.role == nil || entry?.role == .owner)
        }
        var administers = false
        do {
            let token = try await collaboration.accessToken()
            administers = try await collaboration.teams.getTeam(teamID: team.id, accessToken: token).callerRole?.administers == true
        } catch {}
        return DataScope(kind: .team(id: team.id, name: team.name), canManage: administers)
    }
}
