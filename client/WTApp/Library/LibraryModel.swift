import AppKit
import Foundation
import GRPCCore
import Observation

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
    }

    static let searchDebounce: Duration = .milliseconds(300)
    static let namesOnlyHint = "Searching names only — connect to search contents"
    static let offlineActionMessage = "You are offline. Connect to change documents in the library."
    static let untitled = "Untitled"
    /// The personal space's id until `Me` has told us the account id (documents created
    /// before then are moved into the real space when they upload).
    static let localPersonalID = "personal"

    @ObservationIgnored let services: LibraryServices
    @ObservationIgnored let store: LibraryCacheStore?
    @ObservationIgnored let thumbnails: ThumbnailCache
    @ObservationIgnored var debounce: Duration
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }
    @ObservationIgnored var makeID: @MainActor () -> String = { UUIDv7.make() }
    /// Opens documents in tabs (`DocumentController`).
    @ObservationIgnored var onOpen: @MainActor ([LibraryDocument]) -> Void = { _ in }

    private(set) var cache: LibraryCacheFile
    private(set) var currentSpaceID: String?
    private(set) var section: Section = .folder(nil)
    private(set) var isOnline = true
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var nextCursor: String?
    /// nil while not searching.
    private(set) var searchResults: [LibraryRow]?
    /// Bumped when a thumbnail arrives, so the grid redraws.
    private(set) var thumbnailRevision = 0
    var selection: Set<String> = []
    var isShowingGallery = false
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

    /// A new document (menu:File[New], btn:[New]): recorded and opened at once with a UUIDv7,
    /// then `DocumentService.Create` runs; offline it waits with the *Waiting to upload* badge
    /// and uploads on the next refresh.
    @discardableResult
    func createDocument(name: String = LibraryModel.untitled) -> LibraryDocument {
        let target = creationTarget
        let document = LibraryDocument(
            id: makeID(), spaceID: target.spaceID, folderID: target.folderID, name: name, role: .owner, updatedAt: now(), isPendingUpload: true
        )
        cache.documents[document.id] = document
        open([document])
        let id = document.id
        pendingUploads[id] = Task { [weak self] in await self?.upload(id) }
        return document
    }

    /// The template gallery's choice.  Library templates arrive with DOC-019; until then the
    /// gallery offers the built-in template only.
    func createFromGallery() {
        isShowingGallery = false
        createDocument()
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

    func trash(_ id: String) async {
        store(await perform { try await services.documents.trash(documentID: id, accessToken: $0) })
        selection.remove(id)
    }

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
                    && document.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
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
