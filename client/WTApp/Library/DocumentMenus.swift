import AppKit
import GRPCNIOTransportHTTP2
import WTCRDT
import WTModel
import WTSync

/// One of the account's recent documents as the synced *Recent documents* list carries it
/// (`PreferenceCatalog.Document.recents`): enough to show and open it on a Mac that has not
/// listed it yet.
struct RecentEntry: Equatable, Sendable {
    var id: String
    var openedAt: Date
    var spaceID: String?
    var name: String

    /// One list item: id, milliseconds, space and name, tab-separated.
    var encoded: String {
        [id, String(Int64(openedAt.timeIntervalSince1970 * 1000)), spaceID ?? "", name.replacingOccurrences(of: "\t", with: " ")]
            .joined(separator: "\t")
    }

    init(id: String, openedAt: Date, spaceID: String?, name: String) {
        self.id = id
        self.openedAt = openedAt
        self.spaceID = spaceID
        self.name = name
    }

    init?(encoded: String) {
        let parts = encoded.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, !parts[0].isEmpty, let milliseconds = Int64(parts[1]) else { return nil }
        self.init(id: parts[0], openedAt: Date(timeIntervalSince1970: Double(milliseconds) / 1000), spaceID: parts[2].isEmpty ? nil : parts[2], name: parts[3])
    }
}

/// The document commands of the File and Window menus that follow the library and the open
/// windows (creating-opening.adoc; DOC-020): menu:File[Open Recent] (ten deep, merged by time
/// across the account's Macs through the synced *Recent documents* list) and the Window menu's
/// list of open documents, the front one checked.  Both are registry commands rebuilt when their
/// titles change, so the palette finds them too.
@MainActor
final class DocumentMenuFeatures {
    enum ID {
        static func recent(_ index: Int) -> CommandID { CommandID("file.openRecent.\(index)") }
        static func window(_ index: Int) -> CommandID { CommandID("window.document.\(index)") }
        static let clearRecents: CommandID = "file.openRecent.clear"
    }

    static let openRecent = "Open Recent"
    /// menu:File[Open Recent]'s depth.
    static let menuLimit = 10
    /// How many recents the synced list carries.
    static let syncedLimit = 20
    /// The Window menu's document section, below everything else.
    static let windowSection = 9

    /// A window the Window menu lists.
    struct WindowEntry: Equatable {
        var title: String
        var isActive: Bool
    }

    let library: LibraryModel
    let preferences: PreferenceStore
    /// The open document windows, in order, and how to bring one forward.
    var windows: @MainActor () -> [WindowEntry] = { [] }
    var activateWindow: @MainActor (Int) -> Void = { _ in }
    /// Rebuilds the menu bar after the commands changed.
    var rebuildMenu: @MainActor () -> Void = {}
    private(set) var recentTitles: [String] = []
    private(set) var windowTitles: [String] = []
    private weak var registry: CommandRegistry?

    init(library: LibraryModel, preferences: PreferenceStore) {
        self.library = library
        self.preferences = preferences
    }

    /// menu:File[Open Recent]'s documents: the ten most recent that are known and not trashed.
    var recentDocuments: [LibraryDocument] { Array(library.cache.recentDocuments.prefix(Self.menuLimit)) }

    func install(into registry: CommandRegistry) {
        self.registry = registry
        library.onRecentsChange = { [weak self] in
            self?.pushRecents()
            self?.sync()
        }
        preferences.observe { [weak self] change in
            if change.id == PreferenceCatalog.Document.recents.id { self?.remoteRecentsDidChange() }
        }
        remoteRecentsDidChange()
        sync()
    }

    // MARK: Recents across Macs

    /// This Mac's recents written into the synced list, merged with what it holds from the
    /// other Macs.
    func pushRecents() {
        let local = library.cache.recents.compactMap { recent in
            library.cache.documents[recent.documentID].map { RecentEntry(id: $0.id, openedAt: recent.openedAt, spaceID: $0.spaceID, name: $0.name) }
        }
        let merged = Self.merge(Self.decode(preferences[PreferenceCatalog.Document.recents]), local)
        let list = merged.prefix(Self.syncedLimit).map(\.encoded)
        if list != preferences[PreferenceCatalog.Document.recents] { _ = preferences.set(Array(list), for: PreferenceCatalog.Document.recents) }
    }

    /// The synced list changed (another Mac opened something): the library's recents take it.
    func remoteRecentsDidChange() {
        library.mergeRecents(Self.decode(preferences[PreferenceCatalog.Document.recents]))
        sync()
    }

    static func decode(_ list: [String]) -> [RecentEntry] { list.compactMap(RecentEntry.init(encoded:)) }

    /// Newest first, one entry per document (its latest open).
    static func merge(_ lhs: [RecentEntry], _ rhs: [RecentEntry]) -> [RecentEntry] {
        var byID: [String: RecentEntry] = [:]
        for entry in lhs + rhs where (byID[entry.id]?.openedAt ?? .distantPast) < entry.openedAt { byID[entry.id] = entry }
        return byID.values.sorted { ($0.openedAt, $0.id) > ($1.openedAt, $1.id) }
    }

    // MARK: Commands

    /// Re-registers the Open Recent and window commands when their titles changed.
    func sync() {
        guard let registry else { return }
        let recents = recentDocuments
        let windows = windows()
        let recentTitles = recents.map(\.name)
        let windowTitles = windows.map(\.title)
        guard recentTitles != self.recentTitles || windowTitles != self.windowTitles || !registry.contains(ID.clearRecents) else { return }
        registry.remove(Set((recents.count..<max(self.recentTitles.count, recents.count)).map(ID.recent)
            + (windows.count..<max(self.windowTitles.count, windows.count)).map(ID.window)))
        self.recentTitles = recentTitles
        self.windowTitles = windowTitles
        for command in commands(recents: recents, windows: windows) { registry.replace(command) }
        rebuildMenu()
    }

    func commands(recents: [LibraryDocument], windows: [WindowEntry]) -> [Command] {
        let path = MenuPath(StandardCommands.Menu.file, Self.openRecent)
        var commands: [Command] = recents.enumerated().map { index, document in
            let id = document.id
            return Command(
                id: ID.recent(index), title: document.name, menu: path, keywords: ["recent", "open"],
                validation: { [weak self] in
                    guard let self, let document = self.library.cache.documents[id] else { return .disabled("Not in the library") }
                    return self.library.isAvailable(document) ? .enabled : .disabled(LibraryModel.notOnThisMacMessage(document.name))
                },
                action: .perform { [weak self] in self?.openRecent(id) }
            )
        }
        commands.append(Command(
            id: ID.clearRecents, title: "Clear Menu", menu: MenuPath(StandardCommands.Menu.file, Self.openRecent, section: 0, subsection: 1),
            keywords: ["recent"], validation: { [weak self] in self?.recentDocuments.isEmpty == false ? .enabled : .disabled("No recent documents") },
            action: .perform { [weak self] in self?.clearRecents() }
        ))
        commands += windows.enumerated().map { index, window in
            Command(
                id: ID.window(index), title: window.title, menu: MenuPath(StandardCommands.Menu.window, section: Self.windowSection),
                keywords: ["document", "tab"], validation: { [weak self] in
                    let windows = self?.windows() ?? []
                    return .checked(windows.indices.contains(index) && windows[index].isActive)
                },
                action: .perform { [weak self] in self?.activateWindow(index) }
            )
        }
        return commands
    }

    /// Opens a recent document (bringing its window forward if open).
    func openRecent(_ id: String) {
        guard let document = library.cache.documents[id] else { return }
        library.open([document])
    }

    /// *Clear Menu*: this Mac's recents and the synced list.
    func clearRecents() {
        library.clearRecents()
        _ = preferences.set([String](), for: PreferenceCatalog.Document.recents)
        sync()
    }
}

extension AppDelegate {
    /// DOC-019/020/029/030: the gallery, New from the default template, Save as Template, Open
    /// Recent, the Window menu's documents and, with *Show the gallery at launch*, the gallery
    /// instead of an untitled document at launch.
    func installDocumentMenus() {
        let documents = documents!
        templates.states = templateStates()
        templates.writeCopy = { [weak self] id, template in try await self?.writeTemplateCopy(id, template) }
        templates.install(into: commands) { documents.activeWindowController }
        documentMenus.windows = {
            let active = documents.activeWindowController
            return documents.allWindowControllers.map { DocumentMenuFeatures.WindowEntry(title: $0.window?.title ?? $0.documentHandle.title, isActive: $0 === active) }
        }
        documentMenus.activateWindow = { index in
            let controllers = documents.allWindowControllers
            guard controllers.indices.contains(index) else { return }
            let controller = controllers[index]
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        documentMenus.rebuildMenu = { [weak self] in self?.rebuildMainMenu() }
        documentMenus.install(into: commands)
    }

    /// The open windows changed: the Window menu follows.
    func documentMenusDidChange() {
        documentMenus.sync()
    }

    /// Launch with no session to restore: the gallery when *Show the gallery at launch* is on
    /// (test launches only when they ask, `-WTShowGallery`), else an untitled document made as
    /// menu:File[New] makes one -- recorded in the Library with a UUIDv7, from the default
    /// template -- so it is listed, renamed and trashed like any other (D-079).
    func openUntitledAtLaunch() {
        if preferences[PreferenceCatalog.General.showGalleryAtLaunch], launchEnvironment.showsGalleryAtLaunch() {
            templates.showGallery()
        } else {
            templates.newDocumentNow()
        }
    }

    /// Template content: an open window's, else the template's local store, else the server's
    /// head, cached on this Mac.  Test launches have memory documents and no network.
    func templateStates() -> TemplateStates {
        let documents = documents!
        let testing = launchEnvironment.isTesting
        let account = account
        let library = library
        let configuration = AuthConfiguration(infoDictionary: Bundle.main.infoDictionary)
        let identity = GRPCSyncTransport<HTTP2ClientTransport.Posix>.Identity(
            clientVersion: LaunchEnvironment.clientVersion(Bundle.main.infoDictionary), deviceID: DeviceIdentity.current(defaults: preferences.defaults)
        )
        return TemplateStates(
            open: { id in documents.document(id: id).flatMap { $0.model == nil ? nil : $0.state } },
            isCached: { id in !testing && ((try? LocalStore.defaultURL(documentID: id)).map(TemplateDownload.isCached(at:)) ?? false) },
            load: { id in
                guard !testing else { throw TemplateDownload.Failure.notCached }
                let online = library.isOnline && account.isSignedIn
                let transport = online ? try? GRPCSyncTransport.http2(api: configuration.api, identity: identity) : nil
                defer { if let transport { Task { await transport.close() } } }
                let auth = account.auth
                return try await TemplateDownload.state(documentID: id, at: try LocalStore.defaultURL(documentID: id), transport: transport,
                                                        token: { try await auth.validAccessToken() })
            }
        )
    }

    /// Save as Template's copy: its local store holding the creation change, uploaded in the
    /// background once the library has created it.  Test launches keep nothing.
    func writeTemplateCopy(_ id: String, _ template: DocumentCreation.Template) async throws {
        guard !launchEnvironment.isTesting else { return }
        let store = try await LocalStore.open(documentID: id, at: try LocalStore.defaultURL(documentID: id))
        _ = try await store.perform(CreateDocument(template), recording: DocumentCore.Recording(limit: 1, now: Date()))
        await library.pendingUploads[id]?.value
        guard let connector = sessions.connector else {
            try await store.close()
            return
        }
        let connection = try connector.connect(store: store, sink: store, presence: nil)
        let upload = HeadlessUpload(documentID: id, title: library.cache.documents[id]?.name ?? "Template", store: store, connection: connection)
        sessions.add(upload)
        await upload.start()
    }
}

extension LaunchEnvironment {
    /// Makes a test launch show the gallery at launch (UI tests of DOC-029).
    static let showGalleryArgument = "-WTShowGallery"

    /// Whether this launch may show the gallery at launch: always outside tests.
    func showsGalleryAtLaunch(arguments: [String]? = nil) -> Bool {
        !isTesting || (arguments.map { $0.contains(Self.showGalleryArgument) } ?? asksForGallery)
    }
}
