import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Observation
import WTProto
import WTSync

/// A document in the space's trash (`DocumentService.List` with `LIST_SCOPE_TRASH`): a document, or
/// a branch trashed on its own, which names its parent.
struct LibraryTrashEntry: Equatable, Identifiable, Sendable {
    var document: LibraryDocument
    /// The parent's id when this is a branch.
    var parentID: String?
    var trashedAt: Date?

    var id: String { document.id }

    init(document: LibraryDocument, parentID: String? = nil, trashedAt: Date? = nil) {
        self.document = document
        self.parentID = parentID
        self.trashedAt = trashedAt
    }

    init(_ message: Wiretuner_Docs_V1_Document) {
        self.init(document: LibraryDocument(message), parentID: message.parentDocumentID.isEmpty ? nil : message.parentDocumentID,
                  trashedAt: message.hasTrashedAt ? message.trashedAt.date : nil)
    }
}

/// What the library window's branch nesting, *Archived* and *Trash* call (COLLAB-016): every branch
/// of a space's documents, the space's trash, and the lifecycle calls a row offers.
protocol LibraryShelfClient: Sendable {
    func branches(inSpace spaceID: String) async throws -> [BranchInfo]
    func trash(spaceID: String) async throws -> [LibraryTrashEntry]
    func restore(documentID: String) async throws
    func setArchived(_ branch: String, _ archived: Bool) async throws -> BranchInfo
    func deleteBranch(_ branch: String) async throws
}

/// The gRPC client, one unary call each through the app's `UnaryCaller`.
struct GRPCLibraryShelfClient: LibraryShelfClient {
    typealias Branches = Wiretuner_Docs_V1_BranchService.Method
    typealias Documents = Wiretuner_Docs_V1_DocumentService.Method

    let caller: any UnaryCaller
    let accessToken: @Sendable () async throws -> String

    private var branchCalls: GRPCBranchClient { GRPCBranchClient(caller: caller, accessToken: accessToken) }

    func branches(inSpace spaceID: String) async throws -> [BranchInfo] {
        var branches: [BranchInfo] = []
        var cursor = ""
        repeat {
            let request = Self.branchesRequest(spaceID: spaceID, cursor: cursor)
            let response: Branches.ListBranches.Output = try await caller.unary(Branches.ListBranches.descriptor, request, accessToken: try await accessToken())
            branches += response.branches.map(BranchInfo.init)
            cursor = response.nextCursor
        } while !cursor.isEmpty
        return branches
    }

    func trash(spaceID: String) async throws -> [LibraryTrashEntry] {
        var entries: [LibraryTrashEntry] = []
        var cursor = ""
        repeat {
            let request = Self.trashRequest(spaceID: spaceID, cursor: cursor)
            let response: Documents.List.Output = try await caller.unary(Documents.List.descriptor, request, accessToken: try await accessToken())
            entries += response.documents.map(LibraryTrashEntry.init)
            cursor = response.nextCursor
        } while !cursor.isEmpty
        return entries
    }

    func restore(documentID: String) async throws {
        var request = Wiretuner_Docs_V1_RestoreRequest()
        request.documentID = documentID
        let _: Documents.Restore.Output = try await caller.unary(Documents.Restore.descriptor, request, accessToken: try await accessToken())
    }

    func setArchived(_ branch: String, _ archived: Bool) async throws -> BranchInfo {
        try await branchCalls.setArchived(branch, archived)
    }

    func deleteBranch(_ branch: String) async throws {
        try await branchCalls.delete(branch)
    }

    static func branchesRequest(spaceID: String, cursor: String) -> Wiretuner_Docs_V1_ListBranchesRequest {
        var request = Wiretuner_Docs_V1_ListBranchesRequest()
        request.spaceID = spaceID
        request.includeArchived = true
        request.cursor = cursor
        request.pageSize = 50
        return request
    }

    static func trashRequest(spaceID: String, cursor: String) -> Wiretuner_Docs_V1_ListRequest {
        var request = Wiretuner_Docs_V1_ListRequest()
        request.spaceID = spaceID
        request.scope = .trash
        request.cursor = cursor
        request.pageSize = UInt32(LibraryListRequest.pageSize)
        return request
    }
}

/// The library window's branches (COLLAB-016; branches.adoc, "Switching between the parent and its
/// branches" and "Archiving and deleting a branch"): each document's active branches nested under
/// it, the space's archived and merged branches under *Archived*, and the space's trash -- documents
/// and branches trashed on their own -- under *Trash*.  Branch stores on this Mac that the server does
/// not hold yet are nested too, marked "Not yet on the server".  `BranchEvent`s any open window hears
/// update the lists at once.
@MainActor
@Observable
final class LibraryBranches {
    /// The list shown in place of the library's grid.
    enum Shelf: Hashable, Sendable {
        case archived, trash
    }

    static let offlineMessage = "You are offline. Connect to see archived branches and the Trash."

    @ObservationIgnored weak var library: LibraryModel?
    /// `BranchService` and `DocumentService` for the lists; nil offline or signed out.
    @ObservationIgnored var client: @MainActor () -> (any LibraryShelfClient)? = { nil }
    /// The branch stores on this Mac (their `meta`), for branches not yet on the server.
    @ObservationIgnored var localBranches: @MainActor () -> [BranchInfo] = { [] }
    /// Opens a document window by id and title.
    @ObservationIgnored var open: @MainActor (String, String) -> Void = { _, _ in }
    @ObservationIgnored var confirm: @MainActor (String, String) -> Bool = { _, _ in true }

    /// Every live branch of the space shown, from the server.
    private(set) var listed: [BranchInfo] = []
    private(set) var trash: [LibraryTrashEntry] = []
    private(set) var shelf: Shelf?
    /// Parents whose branches are shown under their tile.
    private(set) var expanded: Set<String> = []
    private(set) var message: String?
    private(set) var spaceID: String?

    init(library: LibraryModel? = nil) {
        self.library = library
    }

    // MARK: What the window shows

    /// `parent`'s active branches, with the ones made on this Mac that the server does not hold, by name.
    func branches(of parent: String) -> [BranchInfo] {
        let server = listed.filter { $0.parentID == parent && $0.state == .active }
        let ids = Set(listed.map(\.id))
        let pending = localBranches().filter { $0.parentID == parent && !ids.contains($0.id) }
        return (server + pending).sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// The archived and merged branches of the space, by parent name then name.
    var archived: [BranchInfo] {
        listed.filter { $0.state != .active }.sorted { (parentName($0.parentID), $0.name, $0.id) < (parentName($1.parentID), $1.name, $1.id) }
    }

    /// The parent's name as the library knows it.
    func parentName(_ id: String) -> String {
        library?.cache.documents[id]?.name ?? "Untitled"
    }

    /// "Autumn palette — branch of Catalogue".
    func title(of branch: BranchInfo) -> String {
        "\(branch.name) — branch of \(parentName(branch.parentID))"
    }

    func isExpanded(_ parent: String) -> Bool { expanded.contains(parent) }

    func toggle(_ parent: String) {
        if expanded.contains(parent) { expanded.remove(parent) } else { expanded.insert(parent) }
    }

    // MARK: Loading

    /// The space's branches, and the trash while it is shown.  Offline the lists stay as they were
    /// (the local branches are always there).
    func load() async {
        let space = library?.currentSpace.id
        if space != spaceID {
            listed = []
            trash = []
            spaceID = space
        }
        guard let space, let client = client() else {
            if shelf != nil { message = Self.offlineMessage }
            return
        }
        do {
            listed = try await client.branches(inSpace: space)
            if shelf == .trash { trash = try await client.trash(spaceID: space) }
            message = nil
        } catch {
            message = LibraryModel.message(for: error)
        }
    }

    /// Shows *Archived* or *Trash* in place of the grid (nil: the library's own section).
    func show(_ shelf: Shelf?) async {
        self.shelf = shelf
        message = nil
        if shelf != nil { await load() }
    }

    // MARK: Row actions

    func openBranch(_ branch: BranchInfo) {
        open(branch.id, "\(parentName(branch.parentID)) — \(branch.name)")
    }

    func openTrashed(_ entry: LibraryTrashEntry) {
        message = "Restore “\(entry.document.name)” to open it."
    }

    /// Runs one call; offline or failing, says why.
    private func perform(_ body: (any LibraryShelfClient) async throws -> Void) async -> Bool {
        guard let client = client() else {
            message = LibraryModel.offlineActionMessage
            return false
        }
        do {
            try await body(client)
            message = nil
            return true
        } catch {
            message = LibraryModel.message(for: error)
            return false
        }
    }

    /// *Archive Branch* / *Restore Branch* on a row.
    @discardableResult
    func setArchived(_ branch: BranchInfo, _ archived: Bool) async -> Bool {
        var changed: BranchInfo?
        guard await perform({ changed = try await $0.setArchived(branch.id, archived) }), let changed else { return false }
        listed.removeAll { $0.id == branch.id }
        listed.append(changed)
        return true
    }

    /// *Move to Trash* on a branch row: `DeleteBranch`, confirmed; kept 30 days.
    @discardableResult
    func trashBranch(_ branch: BranchInfo) async -> Bool {
        guard confirm("Move “\(branch.name)” to the Trash?", "The branch is kept in the Trash for 30 days.") else { return false }
        guard await perform({ try await $0.deleteBranch(branch.id) }) else { return false }
        listed.removeAll { $0.id == branch.id }
        if shelf == .trash { await load() }
        return true
    }

    /// *Restore* in the Trash: `DocumentService.Restore`; a document goes back to its folder, a
    /// branch back under its parent.
    @discardableResult
    func restore(_ entry: LibraryTrashEntry) async -> Bool {
        guard await perform({ try await $0.restore(documentID: entry.id) }) else { return false }
        trash.removeAll { $0.id == entry.id }
        await load()
        if entry.parentID == nil { await library?.reloadSection() }
        return true
    }

    // MARK: Live updates

    /// A `BranchEvent` any window heard: the nesting and *Archived* follow without listing again.
    func apply(_ event: Wiretuner_Sync_V1_BranchEvent) {
        let id = event.branchDocumentID
        var info = listed.first { $0.id == id } ?? BranchInfo(id: id, parentID: event.parentDocumentID, name: event.name)
        if !event.name.isEmpty { info.name = event.name }
        if !event.actor.displayName.isEmpty { info.lastAuthor = event.actor.displayName }
        info.lastChange = Date()
        listed.removeAll { $0.id == id }
        switch event.kind {
        case .created, .restored: info.state = .active
        case .archived: info.state = .archived
        case .merged: info.state = .merged
        case .trashed: return
        default: break
        }
        listed.append(info)
    }
}

/// Creates on the server the branch stores this Mac made offline that are not there yet (COLLAB-017's
/// "created on next launch"), one at a time; each stays "not yet on the server" when it cannot be.
enum PendingBranches {
    static func create(root: URL? = nil, creator: BranchCreator) async -> [String] {
        var created: [String] = []
        for entry in (try? BranchStores.pendingCreations(in: root)) ?? [] {
            guard let store = try? await LocalStore.open(documentID: entry.documentID, at: entry.url) else { continue }
            if (try? await creator.ensureOnServer(store)) == true { created.append(entry.documentID) }
            try? await store.close()
        }
        return created
    }
}

extension AppDelegate {
    /// The library window's branches, *Archived* and *Trash* (COLLAB-016), and the branch stores made
    /// offline created on the server at launch.
    func installLibraryBranches() {
        let library = library
        let account = account
        let documents = documents!
        let infoDictionary = Bundle.main.infoDictionary
        let configuration = AuthConfiguration(infoDictionary: infoDictionary)
        let caller = GRPCUnaryCaller(api: configuration.api, clientVersion: LaunchEnvironment.clientVersion(infoDictionary),
                                     deviceID: DeviceIdentity.current(defaults: preferences.defaults))
        let auth = account.auth
        let shelf = GRPCLibraryShelfClient(caller: caller) { try await auth.validAccessToken() }
        let testing = launchEnvironment.isTesting
        let branches = LibraryBranches(library: library)
        branches.client = { !testing && account.isSignedIn && library.isOnline ? shelf : nil }
        branches.localBranches = { testing ? [] : ((try? BranchStores.branches()) ?? []).map(BranchInfo.init) }
        branches.open = { id, name in documents.open(documents.environment.makeDocument(id: id, title: name)) }
        library.branches = branches
        let previous = collaborationUI.branchEvent
        collaborationUI.branchEvent = { [weak branches] event in
            previous(event)
            branches?.apply(event)
        }
        guard !testing, account.isSignedIn else { return }
        let identity = GRPCSyncTransport<HTTP2ClientTransport.Posix>.Identity(
            clientVersion: LaunchEnvironment.clientVersion(infoDictionary), deviceID: DeviceIdentity.current(defaults: preferences.defaults)
        )
        let api = configuration.api
        let tokens = AuthTokenProvider(auth: auth)
        Task.detached {
            guard let transport = try? GRPCDocumentCopyTransport<HTTP2ClientTransport.Posix>.http2(api: api, identity: identity) else { return }
            _ = await PendingBranches.create(creator: BranchCreator(transport: transport, tokens: tokens))
            await transport.close()
        }
    }
}
