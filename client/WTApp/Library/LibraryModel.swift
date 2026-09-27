import AppKit
import Foundation
import GRPCCore
import Observation
import WTModel

/// What the library talks to.  Injected so tests use fakes (no network).
struct LibraryServices: Sendable {
    var documents: any LibraryDocumentClient
    var teams: any TeamListClient
    var blobs: any BlobDownloadClient
    /// `AccountService.Me`, for the account id (the personal space).
    var account: any AccountClient
    /// `AuthService.validAccessToken()`; throws `AuthError.notSignedIn` when signed out, which
    /// the library treats like being offline.
    var accessToken: @Sendable () async throws -> String
}

/// The library window's state (APP-009; creating-opening.adoc, "Opening a document"): the
/// space and section shown, the documents and folders in it, search, thumbnails, offline
/// availability, and the document operations.  Everything listed lives in `cache`, so the
/// window shows the same thing online and offline; a refresh only updates the cache.
@MainActor
@Observable
final class LibraryModel {
    /// What the sidebar selects.
    enum Section: Hashable, Sendable {
        case recents
        case sharedWithMe
        /// A folder of the current space; nil is its top level.
        case folder(String?)
        /// The current space's templates (DOC-030).
        case templates
    }

    static let searchDebounce: Duration = .milliseconds(300)
    static let namesOnlyHint = "Searching names only — connect to search contents"
    static let offlineActionMessage = "You are offline. Connect to change documents in the library."
    static let templateFlagOfflineMessage = "You are offline. Connect to change whether a document is a template."
    static let untitled = "Untitled"
    /// The personal space's id until `Me` has told us the account id (documents created
    /// before then are moved into the real space when they upload).
    static let localPersonalID = "personal"

    @ObservationIgnored let services: LibraryServices
    @ObservationIgnored let store: LibraryCacheStore?
    @ObservationIgnored let thumbnails: ThumbnailCache
    @ObservationIgnored var debounce: Duration
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }
    /// The sync state of a document's running session, for the row's badge (IO-002); nil when
    /// none runs.
    @ObservationIgnored var syncState: @MainActor (String) -> SyncState? = { _ in nil }
    @ObservationIgnored var makeID: @MainActor () -> String = { UUIDv7.make() }
    /// Opens documents in tabs (`DocumentController`).
    @ObservationIgnored var onOpen: @MainActor ([LibraryDocument]) -> Void = { _ in }
    /// Team settings and joining a team (SEC-003); nil leaves them out.
    @ObservationIgnored var collaboration: CollaborationServices?
    /// `ListMentionedDocuments` (the mention dots); nil shows none.
    @ObservationIgnored var mentions: (any MentionedDocumentsClient)?
    /// How often the dots are read again while the app runs (comments.adoc: on open and every
    /// five minutes).
    @ObservationIgnored var mentionInterval: Duration = .seconds(300)
    @ObservationIgnored private(set) var mentionPolling: Task<Void, Never>?
    /// Documents holding a comment that mentions this account and that it has not seen: a dot
    /// beside the name.
    private(set) var mentioned: Set<String> = []

    private(set) var cache: LibraryCacheFile
    private(set) var currentSpaceID: String?
    private(set) var section: Section = .folder(nil)
    private(set) var isOnline = true
    /// *Use as Team Library* on a document (LIB-016; the team library features).
    @ObservationIgnored var useAsTeamLibrary: (@MainActor (LibraryDocument) -> Void)?
    /// Why *Use as Team Library* is disabled for a document, or nil when it applies.
    @ObservationIgnored var teamLibraryRefusal: (@MainActor (LibraryDocument) -> String?)?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var nextCursor: String?
    /// nil while not searching.
    private(set) var searchResults: [LibraryRow]?
    /// Bumped when a thumbnail arrives, so the grid redraws.
    private(set) var thumbnailRevision = 0
    var selection: Set<String> = []
    /// Shows the template gallery (menu:File[New from Template…], btn:[New from Template…]).
    @ObservationIgnored var showGallery: @MainActor () -> Void = {}
    /// btn:[New]: a document from the default template (`TemplateFeatures`); nil creates from
    /// the built-in template.
    @ObservationIgnored var makeNewDocument: (@MainActor () -> Void)?
    /// The recents changed on this Mac (menu:File[Open Recent] and its account sync, DOC-020).
    @ObservationIgnored var onRecentsChange: @MainActor () -> Void = {}
    /// The team settings sheet, while shown.
    var teamSettings: TeamSettingsModel?
    /// The Join Team sheet, while shown.
    var joinTeam: JoinTeamModel?
    var searchText = "" {
        didSet { if searchText != oldValue { searchTextDidChange() } }
    }

    @ObservationIgnored private(set) var pendingSearch: Task<Void, Never>?
    @ObservationIgnored private(set) var pendingUploads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var downloading: Set<String> = []

    init(services: LibraryServices, store: LibraryCacheStore?, thumbnails: ThumbnailCache, debounce: Duration = LibraryModel.searchDebounce) {
        self.services = services
        self.store = store
        self.thumbnails = thumbnails
        self.debounce = debounce
        cache = store?.load() ?? LibraryCacheFile()
        currentSpaceID = cache.personalSpaceID ?? Self.localPersonalID
    }

    // MARK: What the window shows

    var personalSpace: LibrarySpace { .personal(id: cache.personalSpaceID ?? Self.localPersonalID) }

    /// Personal, then every team (the space switcher).
    var spaces: [LibrarySpace] { [personalSpace] + cache.teams }

    var currentSpace: LibrarySpace { spaces.first { $0.id == currentSpaceID } ?? personalSpace }

    /// The folders shown above the documents: the current folder's subfolders.
    var folders: [LibraryFolder] {
        guard case let .folder(parent) = section else { return [] }
        return cache.folders(in: currentSpace.id, parent: parent)
    }

    /// The current folder and its ancestors, top first (the path bar).
    var folderPath: [LibraryFolder] {
        guard case var .folder(id) = section else { return [] }
        var path: [LibraryFolder] = []
        while let folderID = id, let folder = cache.folders[folderID], !path.contains(folder) {
            path.insert(folder, at: 0)
            id = folder.parentID
        }
        return path
    }

    var documents: [LibraryDocument] {
        switch section {
        case .recents: cache.recentDocuments
        case .sharedWithMe: cache.documents(in: .sharedWithMe, spaceID: nil)
        case let .folder(folderID): cache.documents(in: .folder(folderID), spaceID: currentSpace.id)
        case .templates: cache.documents(in: .templates, spaceID: currentSpace.id)
        }
    }

    /// Search results while searching, else the section's documents.
    var rows: [LibraryRow] { searchResults ?? documents.map { LibraryRow(document: $0) } }

    var searchHint: String? {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty || isOnline ? nil : Self.namesOnlyHint
    }

    /// Whether this Mac has a copy (the offline badge).
    func isOfflineAvailable(_ document: LibraryDocument) -> Bool {
        document.isPendingUpload || cache.offlineAvailable.contains(document.id)
    }

    /// Whether the document can be opened now; the rest are dimmed while offline.
    func isAvailable(_ document: LibraryDocument) -> Bool {
        isOnline || isOfflineAvailable(document)
    }

    static func notOnThisMacMessage(_ name: String) -> String {
        "“\(name)” is not on this Mac yet. Connect to the internet to open it."
    }

    func thumbnailImage(for document: LibraryDocument) -> NSImage? {
        _ = thumbnailRevision
        return document.thumbnail.flatMap(thumbnails.image(for:))
    }

    // MARK: Loading

    /// Everything: the account id, the teams, uploads waiting from offline, the section.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let token = try await services.accessToken()
            if cache.personalSpaceID == nil {
                let accountID = try await services.account.me(accessToken: token).accountID
                if !accountID.isEmpty {
                    cache.personalSpaceID = accountID
                    if currentSpaceID == Self.localPersonalID { currentSpaceID = accountID }
                }
            }
            cache.teams = try await services.teams.listTeams(accessToken: token)
            if !spaces.contains(where: { $0.id == currentSpaceID }) { currentSpaceID = personalSpace.id }
            try await uploadPending(accessToken: token)
            try await list(accessToken: token, cursor: nil)
            wentOnline()
        } catch {
            handle(error)
        }
        save()
        await prefetchThumbnails()
    }

    /// The mention dots, read again (kept as they were when the call fails).
    func refreshMentions() async {
        guard let mentions, let documents = try? await mentions.mentionedDocuments() else { return }
        mentioned = documents
    }

    /// Reads the dots now and every `mentionInterval` (idempotent).
    func startMentionPolling() {
        guard mentionPolling == nil else { return }
        let interval = mentionInterval
        mentionPolling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMentions()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopMentionPolling() {
        mentionPolling?.cancel()
        mentionPolling = nil
    }

    /// The current section only.
    func reloadSection() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let token = try await services.accessToken()
            try await list(accessToken: token, cursor: nil)
            wentOnline()
        } catch {
            handle(error)
        }
        save()
        await prefetchThumbnails()
    }

    /// The next page of the section (`List` cursors).
    func loadMore() async {
        guard let cursor = nextCursor else { return }
        do {
            try await list(accessToken: try await services.accessToken(), cursor: cursor)
        } catch {
            handle(error)
        }
        save()
        await prefetchThumbnails()
    }

    private var listScope: LibraryListRequest.Scope? {
        switch section {
        case .recents: nil
        case .sharedWithMe: .sharedWithMe
        case let .folder(folderID): .folder(folderID)
        case .templates: .templates
        }
    }

    private func list(accessToken: String, cursor: String?) async throws {
        guard let scope = listScope else {
            nextCursor = nil
            return
        }
        let spaceID = currentSpace.id
        let page = try await services.documents.list(LibraryListRequest(spaceID: spaceID, scope: scope, cursor: cursor), accessToken: accessToken)
        cache.apply(page, scope: scope, spaceID: spaceID, firstPage: cursor == nil)
        nextCursor = page.nextCursor
    }

    func show(_ section: Section) async {
        self.section = section
        nextCursor = nil
        selection = []
        searchText = ""
        await reloadSection()
    }

    func switchSpace(to id: String) async {
        currentSpaceID = spaces.contains { $0.id == id } ? id : personalSpace.id
        await show(.folder(nil))
    }

    private func wentOnline() {
        isOnline = true
        errorMessage = nil
    }

    private func handle(_ error: any Error) {
        if LibraryConnectivity.isOffline(error) {
            isOnline = false
        } else {
            errorMessage = Self.message(for: error)
        }
    }

    static func message(for error: any Error) -> String? {
        if let error = error as? RPCError { return error.message.isEmpty ? "\(error.code)" : error.message }
        return AccountModel.message(for: error)
    }

    private func save() {
        try? store?.save(cache)
    }

    // MARK: Opening

    /// Opens `documents` in tabs; those without a copy on this Mac are refused while offline.
    func open(_ documents: [LibraryDocument]) {
        let available = documents.filter(isAvailable)
        if let refused = documents.first(where: { !isAvailable($0) }) { errorMessage = Self.notOnThisMacMessage(refused.name) }
        guard !available.isEmpty else { return }
        for document in available { cache.markOpened(document, at: now()) }
        save()
        onRecentsChange()
        onOpen(available)
    }

    func openSelection() {
        open(rows.map(\.document).filter { selection.contains($0.id) })
    }

    /// *Keep Available Offline*.  Marks the document as kept on this Mac; SYNC-001 turns the
    /// mark into a download of its store.
    func keepAvailableOffline(_ id: String) {
        cache.offlineAvailable.insert(id)
        save()
    }

    // MARK: Creating

    /// The space and folder a new document goes to: the current folder of the current space,
    /// else the personal top level.
    private var creationTarget: (spaceID: String, folderID: String?) {
        if case let .folder(folderID) = section { return (currentSpace.id, folderID) }
        return (personalSpace.id, nil)
    }

    /// *Clear Menu* of menu:File[Open Recent] (DOC-020).
    func clearRecents() {
        guard !cache.recents.isEmpty else { return }
        cache.recents = []
        save()
    }

    /// btn:[New]: from the default template when the app says how, else built-in.
    func newDocument() {
        if let makeNewDocument { makeNewDocument() } else { createDocument() }
    }

    /// Takes the account's recents from other Macs (DOC-020): merged with this Mac's by time,
    /// newest first, `LibraryCacheFile.recentsLimit` kept.  A document not listed here yet is
    /// recorded by name so Open Recent can show and open it.
    func mergeRecents(_ entries: [RecentEntry]) {
        var byID: [String: LibraryRecent] = Dictionary(cache.recents.map { ($0.documentID, $0) }) { first, _ in first }
        for entry in entries {
            if let known = byID[entry.id], known.openedAt >= entry.openedAt { continue }
            byID[entry.id] = LibraryRecent(documentID: entry.id, openedAt: entry.openedAt)
            if cache.documents[entry.id] == nil, let space = entry.spaceID {
                cache.documents[entry.id] = LibraryDocument(id: entry.id, spaceID: space, name: entry.name, role: nil)
            }
        }
        let merged = byID.values.sorted { ($0.openedAt, $0.documentID) > ($1.openedAt, $1.documentID) }.prefix(LibraryCacheFile.recentsLimit)
        guard Array(merged) != cache.recents else { return }
        cache.recents = Array(merged)
        save()
    }

    /// A new document (menu:File[New], btn:[New]): recorded and opened at once with a UUIDv7,
    /// then `DocumentService.Create` runs; offline it waits with the *Waiting to upload* badge
    /// and uploads on the next refresh.
    @discardableResult
    func createDocument(name: String = LibraryModel.untitled, template: DocumentCreation.Template? = nil) -> LibraryDocument {
        let document = recordDocument(name: name)
        if let template { pendingTemplates[document.id] = template }
        open([document])
        return document
    }

    /// What a new document's first change is made from, kept until its window opens it
    /// (`takeTemplate`); a document created without one gets the built-in template.
    @ObservationIgnored private(set) var pendingTemplates: [String: DocumentCreation.Template] = [:]

    /// The template `id` was created from, once: the window writes it as the first change.
    func takeTemplate(for id: String) -> DocumentCreation.Template? {
        pendingTemplates.removeValue(forKey: id)
    }

    /// A document not yet created on the server (IO-004's deferred creation): recorded with a
    /// UUIDv7 in `source`'s space and folder (else where a new document goes), listed at once with
    /// the *Waiting to upload* badge, and `DocumentService.Create` started -- offline it waits for
    /// the next refresh.  Not opened: the caller opens it (a duplicate opens without the
    /// new-document template, its content being re-issued into it).
    @discardableResult
    func recordDocument(name: String, like source: String? = nil, in destination: (spaceID: String, folderID: String?)? = nil,
                        isTemplate: Bool = false) -> LibraryDocument {
        let target = destination ?? source.flatMap { cache.documents[$0] }.map { (spaceID: $0.spaceID, folderID: $0.folderID) } ?? creationTarget
        var document = LibraryDocument(
            id: makeID(), spaceID: target.spaceID, folderID: target.folderID, name: name, role: .owner, updatedAt: now(), isPendingUpload: true
        )
        document.isTemplate = isTemplate
        cache.documents[document.id] = document
        save()
        let id = document.id
        pendingUploads[id] = Task { [weak self] in await self?.upload(id) }
        return document
    }

    private func upload(_ id: String) async {
        do {
            try await upload(id, accessToken: try await services.accessToken())
        } catch {
            handle(error)
        }
        pendingUploads[id] = nil
    }

    private func uploadPending(accessToken: String) async throws {
        for document in cache.documents.values.filter(\.isPendingUpload).sorted(by: { $0.id < $1.id }) {
            try await upload(document.id, accessToken: accessToken)
        }
    }

    private func upload(_ id: String, accessToken: String) async throws {
        guard var document = cache.documents[id], document.isPendingUpload else { return }
        if document.spaceID == Self.localPersonalID, let personal = cache.personalSpaceID { document.spaceID = personal }
        var uploaded: LibraryDocument
        do {
            uploaded = try await services.documents.create(document, accessToken: accessToken)
        } catch let error as RPCError where error.code == .alreadyExists {
            // An earlier Create reached the server but its answer did not reach us.
            uploaded = document
        }
        if document.isTemplate, !uploaded.isTemplate {
            // Saved as a template offline (templates.adoc, "Offline behavior"): flagged once it exists.
            uploaded = try await services.documents.setTemplate(documentID: id, isTemplate: true, accessToken: accessToken)
        }
        uploaded.isPendingUpload = false
        cache.documents[id] = uploaded
        save()
    }

    // MARK: Changing documents and folders

    /// Runs one RPC with a token; offline it changes nothing and says why.
    private func perform<Result>(_ body: (String) async throws -> Result) async -> Result? {
        do {
            let result = try await body(try await services.accessToken())
            wentOnline()
            return result
        } catch {
            handle(error)
            if !isOnline { errorMessage = Self.offlineActionMessage }
            return nil
        }
    }

    private func store(_ document: LibraryDocument?) {
        guard let document else { return }
        cache.documents[document.id] = document
        save()
    }

    /// The document's Document Info keywords as last seen here, which the offline search matches
    /// (file-info.adoc, *Keywords*; IO-011).
    func recordKeywords(_ id: String, _ keywords: [String]) {
        guard var document = cache.documents[id], (document.keywords ?? []) != keywords else { return }
        document.keywords = keywords
        store(document)
    }

    /// *Use as Template* and *Use as Document* (templates.adoc): `SetTemplate`, which needs the
    /// server -- offline it changes nothing and says why.  A document still waiting to upload
    /// keeps the flag locally and is flagged after its `Create`.
    func setTemplate(_ id: String, _ isTemplate: Bool) async {
        guard var document = cache.documents[id], document.isTemplate != isTemplate else { return }
        if document.isPendingUpload {
            document.isTemplate = isTemplate
            store(document)
            return
        }
        store(await perform { try await services.documents.setTemplate(documentID: id, isTemplate: isTemplate, accessToken: $0) })
        if !isOnline { errorMessage = Self.templateFlagOfflineMessage }
    }

    /// The gallery's library templates: *My templates* (the personal space) and each team's, from
    /// the cache.
    var templateGroups: [(space: LibrarySpace, templates: [LibraryDocument])] {
        spaces.map { space in (space, cache.documents(in: .templates, spaceID: space.id)) }
    }

    /// Lists every space's templates into the cache (the gallery opening); offline the cache
    /// stands.
    func refreshTemplates() async {
        do {
            let token = try await services.accessToken()
            for space in spaces {
                let page = try await services.documents.list(LibraryListRequest(spaceID: space.id, scope: .templates), accessToken: token)
                cache.apply(page, scope: .templates, spaceID: space.id, firstPage: true)
            }
            wentOnline()
        } catch {
            handle(error)
        }
        save()
        await prefetchThumbnails(for: templateGroups.flatMap(\.templates))
    }

    func rename(_ id: String, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, var document = cache.documents[id] else { return }
        if document.isPendingUpload {
            document.name = name
            store(document)
            return
        }
        store(await perform { try await services.documents.rename(documentID: id, name: name, accessToken: $0) })
    }

    /// The document `id` for opening by id (a Handoff or Spotlight continuation, IO-035/IO-036):
    /// the cached entry, else `DocumentService.Get`, stored; nil offline or without access.
    func document(withID id: String) async -> LibraryDocument? {
        if let cached = cache.documents[id] { return cached }
        let fetched = await perform { try await services.documents.get(documentID: id, accessToken: $0) }
        store(fetched)
        return fetched
    }

    /// Shows `message` above the library's list (a continuation that could not open a document).
    func show(message: String) {
        errorMessage = message
    }

    func trash(_ id: String) async {
        let trashed = await perform { try await services.documents.trash(documentID: id, accessToken: $0) }
        store(trashed)
        selection.remove(id)
        if trashed != nil { onTrashed(id) }
    }

    /// A document was moved to the trash (Spotlight drops it, IO-035).
    @ObservationIgnored var onTrashed: @MainActor (String) -> Void = { _ in }

    @discardableResult
    func duplicate(_ id: String) async -> LibraryDocument? {
        guard let source = cache.documents[id] else { return nil }
        let copy = await perform { try await services.documents.duplicate(documentID: id, newDocumentID: makeID(), name: "\(source.name) copy", accessToken: $0) }
        store(copy)
        return copy
    }

    /// Moves a document to `folderID` of the current space (drag onto a folder); nil is the
    /// top level.
    func move(_ id: String, toFolder folderID: String?) async {
        let spaceID = currentSpace.id
        store(await perform { try await services.documents.move(documentID: id, spaceID: spaceID, folderID: folderID, accessToken: $0) })
    }

    @discardableResult
    func createFolder(named name: String) async -> LibraryFolder? {
        let target = creationTarget
        let folder = await perform { try await services.documents.createFolder(spaceID: target.spaceID, parentFolderID: target.folderID, name: name, accessToken: $0) }
        if let folder {
            cache.folders[folder.id] = folder
            save()
        }
        return folder
    }

    func renameFolder(_ id: String, to name: String) async {
        guard let folder = await perform({ try await services.documents.renameFolder(folderID: id, name: name, accessToken: $0) }) else { return }
        cache.folders[folder.id] = folder
        save()
    }

    func deleteFolder(_ id: String) async {
        guard await perform({ try await services.documents.deleteFolder(folderID: id, accessToken: $0) }) != nil else { return }
        cache.folders[id] = nil
        if section == .folder(id) { section = .folder(nil) }
        await reloadSection()
    }

    // MARK: Teams (SEC-003)

    /// Whether the toolbar offers Team Settings: a team is the current space.
    var canShowTeamSettings: Bool { collaboration != nil && currentSpace.kind == .team }

    /// The team settings sheet for the current team space, loading.
    @discardableResult
    func showTeamSettings() -> Task<Void, Never>? {
        guard let collaboration, currentSpace.kind == .team else { return nil }
        let model = TeamSettingsModel(teamID: currentSpace.id, services: collaboration, accountID: cache.personalSpaceID)
        model.onDone = { [weak self] in self?.teamSettings = nil }
        teamSettings = model
        return Task { await model.load() }
    }

    /// The Join Team sheet, with `link` (an invitation URL the app was asked to open) filled in.
    @discardableResult
    func showJoinTeam(link: String = "") -> JoinTeamModel? {
        guard let collaboration else { return nil }
        let model = JoinTeamModel(services: collaboration, link: link)
        model.onDone = { [weak self] in self?.joinTeam = nil }
        model.onJoined = { [weak self] team in await self?.didJoin(team) }
        joinTeam = model
        return model
    }

    /// The toolbar's and sidebar's buttons.
    func openTeamSettings() { showTeamSettings() }
    func openJoinTeam() { showJoinTeam() }

    /// A joined team is a space at once (also in the offline cache), then shown.
    func didJoin(_ team: TeamDetail) async {
        if !cache.teams.contains(where: { $0.id == team.id }) { cache.teams.append(LibrarySpace(id: team.id, name: team.name, kind: .team)) }
        save()
        await refresh()
        await switchSpace(to: team.id)
    }

    // MARK: Search

    private func searchTextDidChange() {
        pendingSearch?.cancel()
        pendingSearch = nil
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = nil
            return
        }
        searchResults = nameMatches(query).map { LibraryRow(document: $0) }
        guard isOnline else { return }
        pendingSearch = Task { [weak self, debounce] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            await self?.runSearch(query)
        }
    }

    /// Cached documents of the space (or shared with me) whose name contains `query`: the
    /// offline search, and the rows shown while the online search is out.
    func nameMatches(_ query: String) -> [LibraryDocument] {
        let shared = section == .sharedWithMe
        let spaceID = currentSpace.id
        return cache.documents.values
            .filter { document in
                !document.isTrashed && (shared ? document.isSharedWithMe : !document.isSharedWithMe && document.spaceID == spaceID)
                    && ([document.name] + (document.keywords ?? [])).contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
            .sorted(by: LibraryCacheFile.byName)
    }

    /// `DocumentService.Search` for `query`, merged with the cached name matches it did not
    /// return; dropped if the field changed meanwhile.
    func runSearch(_ query: String) async {
        do {
            let token = try await services.accessToken()
            let page = try await services.documents.search(query: query, spaceID: currentSpace.id, cursor: nil, accessToken: token)
            var rows: [LibraryRow] = []
            for hit in page.hits {
                guard let document = await document(hit.documentID, accessToken: token), !document.isTrashed else { continue }
                rows.append(LibraryRow(document: document, snippet: hit.displaySnippet))
            }
            let found = Set(rows.map(\.id))
            rows += nameMatches(query).filter { !found.contains($0.id) }.map { LibraryRow(document: $0) }
            guard searchText.trimmingCharacters(in: .whitespaces) == query else { return }
            searchResults = rows
            wentOnline()
            save()
            await prefetchThumbnails(for: rows.map(\.document))
        } catch {
            handle(error)
        }
    }

    /// A hit's document from the cache, else `Get` (a document in a folder not listed yet).
    private func document(_ id: String, accessToken: String) async -> LibraryDocument? {
        if let cached = cache.documents[id] { return cached }
        guard let fetched = try? await services.documents.get(documentID: id, accessToken: accessToken) else { return nil }
        cache.documents[id] = fetched
        return fetched
    }

    // MARK: Thumbnails

    /// Downloads the thumbnails of `documents` (default: the rows shown) that are not in the
    /// disk cache.  A new `thumbnail_blob` hash after an upload is simply a new key, so the
    /// picture updates on the next list refresh.
    func prefetchThumbnails(for documents: [LibraryDocument]? = nil) async {
        guard isOnline else { return }
        let wanted = (documents ?? rows.map(\.document)).filter { document in
            document.thumbnail.map { !thumbnails.contains($0) && !downloading.contains($0) } ?? false
        }
        guard !wanted.isEmpty, let token = try? await services.accessToken() else { return }
        for document in wanted {
            guard let hash = document.thumbnail, let sha256 = Data(hexString: hash), !downloading.contains(hash) else { continue }
            downloading.insert(hash)
            defer { downloading.remove(hash) }
            do {
                let data = try await services.blobs.download(documentID: document.id, sha256: sha256, accessToken: token)
                try thumbnails.store(data, for: hash)
                thumbnailRevision += 1
            } catch where LibraryConnectivity.isOffline(error) {
                isOnline = false
                return
            } catch {
                continue
            }
        }
    }
}
