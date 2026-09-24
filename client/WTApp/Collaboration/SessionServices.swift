import Foundation
import GRPCCore
import SwiftProtobuf
import WTCRDT
import WTModel
import WTProto
import WTSync

/// A document copy transport made on first use, so an open document holds no copy connection
/// until a copy or branch is made (the connector hands one to every session).
final class LazyDocumentCopyTransport: DocumentCopyTransport, @unchecked Sendable {
    private let make: @Sendable () throws -> any DocumentCopyTransport & ClosableTransport
    private let lock = NSLock()
    private var made: (any DocumentCopyTransport & ClosableTransport)?

    init(_ make: @escaping @Sendable () throws -> any DocumentCopyTransport & ClosableTransport) {
        self.make = make
    }

    private func transport() throws -> any DocumentCopyTransport & ClosableTransport {
        try lock.withLock {
            if let made { return made }
            let transport = try make()
            made = transport
            return transport
        }
    }

    var isMade: Bool { lock.withLock { made != nil } }

    func fork(_ request: Wiretuner_Docs_V1_ForkRequest, token: String) async throws -> Wiretuner_Docs_V1_ForkResponse {
        try await transport().fork(request, token: token)
    }

    func createBranch(_ request: Wiretuner_Docs_V1_CreateBranchRequest, token: String) async throws -> Wiretuner_Docs_V1_CreateBranchResponse {
        try await transport().createBranch(request, token: token)
    }

    func close() async {
        let made = lock.withLock { self.made }
        await made?.close()
    }
}

/// A transport that closes its connection.
protocol ClosableTransport: Sendable {
    func close() async
}

extension GRPCDocumentCopyTransport: ClosableTransport {}

extension DocumentSession {
    /// The document's local store, once open.
    var store: LocalStore? { document.model?.backend as? LocalStore }

    /// The role-change controller over this session's client (nil before it connects or
    /// without copy calls).
    func makeAccessController() -> AccessController? {
        guard let connection, let store, let transport = connection.transport, let copies = connection.copies, let tokens = connection.tokens else { return nil }
        return AccessController(store: store, client: connection.client, sync: transport, copies: copies, tokens: tokens)
    }

    /// *Keep my changes on a branch* (branches.adoc, "Branches while offline"): the unsent changes
    /// go to a branch store on this Mac (`BranchStores.keepChangesOnBranch`), which is created on
    /// the server now when it can be (`BranchCreator`) and at a later opportunity otherwise.  The
    /// review sheet then reverts the parent.  Returns the branch's id.
    func keepChangesOnBranch(name: String, root: URL? = nil) async throws -> String {
        guard let store else { throw BranchError.noStore }
        let entry = try await BranchStores.keepChangesOnBranch(parent: store, name: name, root: root)
        if let copies = connection?.copies, let tokens = connection?.tokens {
            await Self.createOnServer(entry, creator: BranchCreator(transport: copies, tokens: tokens))
        }
        return entry.documentID
    }

    /// Creates `entry`'s branch on the server when it can; offline it stays "not yet on the server".
    static func createOnServer(_ entry: BranchStores.Entry, creator: BranchCreator) async {
        guard let branch = try? await LocalStore.open(documentID: entry.documentID, at: entry.url) else { return }
        _ = try? await creator.ensureOnServer(branch)
        try? await branch.close()
    }

    /// The document's state at `serverSeq` (the local log when it can, else the server).
    func state(atServerSeq serverSeq: UInt64) async throws -> EngineState {
        guard let store else { throw BranchError.noStore }
        let tokens = connection?.tokens
        return try await VersionStates.state(at: serverSeq, store: store, transport: connection?.transport) {
            guard let tokens else { throw VersionStates.Failure.incomplete(through: 0) }
            return try await tokens.accessToken(forceRefresh: false)
        }
    }
}

/// Why a branch action could not run.
enum BranchError: Error, Equatable {
    /// The document has no local store (a memory document).
    case noStore
}

/// A branch as the popup and the menus show it (branches.adoc, "Switching between the parent and
/// its branches").
struct BranchInfo: Equatable, Identifiable, Sendable {
    enum State: Equatable, Sendable {
        case active, archived, merged
    }

    var id: String
    var parentID: String
    var name: String
    var state: State = .active
    var lastAuthor: String = ""
    var lastChange: Date?
    /// False for a branch made on this Mac that the server does not hold yet.
    var onServer = true
    var forkServerSeq: UInt64 = 0

    init(id: String, parentID: String, name: String, state: State = .active, lastAuthor: String = "", lastChange: Date? = nil, onServer: Bool = true,
         forkServerSeq: UInt64 = 0) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.state = state
        self.lastAuthor = lastAuthor
        self.lastChange = lastChange
        self.onServer = onServer
        self.forkServerSeq = forkServerSeq
    }

    init(_ branch: Wiretuner_Docs_V1_Branch) {
        self.init(id: branch.branchDocumentID, parentID: branch.parentDocumentID, name: branch.name,
                  state: branch.state == .archived ? .archived : branch.state == .merged ? .merged : .active,
                  lastAuthor: branch.lastAuthorDisplayName, lastChange: branch.hasLastChangeAt ? branch.lastChangeAt.date : nil,
                  forkServerSeq: branch.forkServerSeq)
    }

    init(_ entry: BranchStores.Entry) {
        self.init(id: entry.documentID, parentID: entry.meta.parentDocumentID, name: entry.meta.name, onServer: entry.meta.onServer,
                  forkServerSeq: entry.meta.forkServerSeq)
    }

    /// "Priya · 3 h ago", or "Not yet on the server".
    func detail(now: Date = Date()) -> String {
        guard onServer else { return "Not yet on the server" }
        let when = lastChange.map { $0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)) }
        return [lastAuthor.isEmpty ? nil : lastAuthor, when].compactMap { $0 }.joined(separator: " · ")
    }
}

/// `BranchService` as the branch UI calls it (COLLAB-016): list, create, rename, archive or
/// restore, delete.
protocol BranchClient: Sendable {
    /// The branch `id`; nil when it is not a branch (the parent, or one the server does not hold).
    func branch(_ id: String) async -> BranchInfo?
    func list(parent: String, includeArchived: Bool) async throws -> [BranchInfo]
    func create(parent: String, branchID: String, name: String, forkServerSeq: UInt64) async throws -> BranchInfo
    func rename(_ branch: String, to name: String) async throws -> BranchInfo
    func setArchived(_ branch: String, _ archived: Bool) async throws -> BranchInfo
    func delete(_ branch: String) async throws
}

/// The gRPC client, one unary call each through the app's `UnaryCaller`.
struct GRPCBranchClient: BranchClient {
    typealias Methods = Wiretuner_Docs_V1_BranchService.Method

    let caller: any UnaryCaller
    let accessToken: @Sendable () async throws -> String

    func branch(_ id: String) async -> BranchInfo? {
        var request = Wiretuner_Docs_V1_GetBranchRequest()
        request.branchDocumentID = id
        guard let token = try? await accessToken(),
              let response: Methods.GetBranch.Output = try? await caller.unary(Methods.GetBranch.descriptor, request, accessToken: token) else { return nil }
        return BranchInfo(response.branch)
    }

    func list(parent: String, includeArchived: Bool) async throws -> [BranchInfo] {
        var branches: [BranchInfo] = []
        var cursor = ""
        repeat {
            var request = Wiretuner_Docs_V1_ListBranchesRequest()
            request.parentDocumentID = parent
            request.includeArchived = includeArchived
            request.cursor = cursor
            request.pageSize = 50
            let response: Methods.ListBranches.Output = try await caller.unary(Methods.ListBranches.descriptor, request, accessToken: try await accessToken())
            branches += response.branches.map(BranchInfo.init)
            cursor = response.nextCursor
        } while !cursor.isEmpty
        return branches
    }

    func create(parent: String, branchID: String, name: String, forkServerSeq: UInt64) async throws -> BranchInfo {
        let request = ReviewRequests.createBranch(parent: parent, branchID: branchID, name: name, forkServerSeq: forkServerSeq, changes: [])
        let response: Methods.CreateBranch.Output = try await caller.unary(Methods.CreateBranch.descriptor, request, accessToken: try await accessToken())
        return BranchInfo(response.branch)
    }

    func rename(_ branch: String, to name: String) async throws -> BranchInfo {
        var request = Wiretuner_Docs_V1_RenameBranchRequest()
        request.branchDocumentID = branch
        request.name = String(name.prefix(256))
        let response: Methods.RenameBranch.Output = try await caller.unary(Methods.RenameBranch.descriptor, request, accessToken: try await accessToken())
        return BranchInfo(response.branch)
    }

    func setArchived(_ branch: String, _ archived: Bool) async throws -> BranchInfo {
        var request = Wiretuner_Docs_V1_SetBranchStateRequest()
        request.branchDocumentID = branch
        request.state = archived ? .archived : .active
        let response: Methods.SetBranchState.Output = try await caller.unary(Methods.SetBranchState.descriptor, request, accessToken: try await accessToken())
        return BranchInfo(response.branch)
    }

    func delete(_ branch: String) async throws {
        var request = Wiretuner_Docs_V1_DeleteBranchRequest()
        request.branchDocumentID = branch
        let _: Methods.DeleteBranch.Output = try await caller.unary(Methods.DeleteBranch.descriptor, request, accessToken: try await accessToken())
    }
}

/// A named version as the restore sheet lists it.
struct VersionInfo: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var serverSeq: UInt64
    var createdAt: Date?
}

/// `VersionService.ListVersions`, the call menu:File[Restore Version…] lists versions with.
protocol VersionListing: Sendable {
    func versions(of document: String) async throws -> [VersionInfo]
}

struct GRPCVersionListing: VersionListing {
    typealias Methods = Wiretuner_Docs_V1_VersionService.Method

    let caller: any UnaryCaller
    let accessToken: @Sendable () async throws -> String

    func versions(of document: String) async throws -> [VersionInfo] {
        var versions: [VersionInfo] = []
        var cursor = ""
        repeat {
            var request = Wiretuner_Docs_V1_ListVersionsRequest()
            request.documentID = document
            request.cursor = cursor
            request.pageSize = 50
            let response: Methods.ListVersions.Output = try await caller.unary(Methods.ListVersions.descriptor, request, accessToken: try await accessToken())
            versions += response.versions.map { VersionInfo(id: $0.id, name: $0.name, serverSeq: $0.serverSeq, createdAt: $0.hasCreatedAt ? $0.createdAt.date : nil) }
            cursor = response.nextCursor
        } while !cursor.isEmpty
        return versions
    }
}
