import AppKit
import Foundation
import GRPCCore
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTSync
@testable import WireTuner

/// The library's `BranchService` and trash calls in memory.
final class FakeShelfClient: LibraryShelfClient, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BranchInfo]
    private var trashed: [LibraryTrashEntry]
    private var log: [String] = []
    var fails = false

    init(_ branches: [BranchInfo] = [], trash: [LibraryTrashEntry] = []) {
        stored = branches
        trashed = trash
    }

    var calls: [String] { lock.withLock { log } }
    var branches: [BranchInfo] { lock.withLock { stored } }

    private func enter(_ call: String) throws {
        try lock.withLock {
            log.append(call)
            if fails { throw RPCError(code: .internalError, message: "no \(call)") }
        }
    }

    func branches(inSpace spaceID: String) async throws -> [BranchInfo] {
        try enter("branches \(spaceID)")
        return lock.withLock { stored }
    }

    func trash(spaceID: String) async throws -> [LibraryTrashEntry] {
        try enter("trash \(spaceID)")
        return lock.withLock { trashed }
    }

    func restore(documentID: String) async throws {
        try enter("restore \(documentID)")
        lock.withLock {
            if let entry = trashed.first(where: { $0.id == documentID }), let parent = entry.parentID {
                stored.append(BranchInfo(id: entry.id, parentID: parent, name: entry.document.name))
            }
            trashed.removeAll { $0.id == documentID }
        }
    }

    func setArchived(_ branch: String, _ archived: Bool) async throws -> BranchInfo {
        try enter("archive \(branch) \(archived)")
        // A branch that is gone (trashed meanwhile) is an error, as on the server -- never a crash
        // that takes the whole test host down.
        return try lock.withLock {
            guard let index = stored.firstIndex(where: { $0.id == branch }) else { throw RPCError(code: .notFound, message: "no branch \(branch)") }
            stored[index].state = archived ? .archived : .active
            return stored[index]
        }
    }

    func deleteBranch(_ branch: String) async throws {
        try enter("delete \(branch)")
        lock.withLock {
            if let info = stored.first(where: { $0.id == branch }) {
                trashed.append(LibraryTrashEntry(document: LibraryDocument(id: branch, spaceID: "space", name: info.name, isTrashed: true), parentID: info.parentID))
            }
            stored.removeAll { $0.id == branch }
        }
    }
}

/// A library with two documents in the personal space and the branches model over a fake client.
@MainActor
struct LibraryBranchWorld {
    let server = FakeLibraryServer()
    let library: LibraryModel
    let branches: LibraryBranches
    let client: FakeShelfClient
    var online: TestBox<Bool> = TestBox(true)
    var opened: TestBox<[String]> = TestBox([])
    var local: TestBox<[BranchInfo]> = TestBox([])
    var confirms: TestBox<Bool> = TestBox(true)

    static let catalogue = "d-catalogue"
    static let poster = "d-poster"

    init(branches list: [BranchInfo] = LibraryBranchWorld.defaultBranches, trash: [LibraryTrashEntry] = []) {
        library = LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        client = FakeShelfClient(list, trash: trash)
        branches = LibraryBranches(library: library)
        library.branches = branches
        let client = client, online = online, opened = opened, local = local, confirms = confirms
        branches.client = { online.value ? client : nil }
        branches.localBranches = { local.value }
        branches.open = { id, name in opened.value.append("\(id) \(name)") }
        branches.confirm = { _, _ in confirms.value }
        let space = server.accountID
        server.put(LibraryDocument(id: Self.catalogue, spaceID: space, name: "Catalogue"))
        server.put(LibraryDocument(id: Self.poster, spaceID: space, name: "Poster"))
    }

    static let defaultBranches = [
        BranchInfo(id: "b-autumn", parentID: catalogue, name: "Autumn palette", lastAuthor: "Priya", lastChange: Date(timeIntervalSinceNow: -3600)),
        BranchInfo(id: "b-cover", parentID: catalogue, name: "Cover rework"),
        BranchInfo(id: "b-old", parentID: poster, name: "Old idea", state: .archived),
        BranchInfo(id: "b-merged", parentID: catalogue, name: "Spring", state: .merged),
    ]

    func loaded() async {
        await library.refresh()
        await branches.load()
    }
}

func branchEvent(_ kind: Wiretuner_Sync_V1_BranchEventKind, branch: String, parent: String, name: String = "", actor: String = "Tom") -> Wiretuner_Sync_V1_BranchEvent {
    var event = Wiretuner_Sync_V1_BranchEvent()
    event.kind = kind
    event.branchDocumentID = branch
    event.parentDocumentID = parent
    event.name = name
    event.actor.displayName = actor
    event.actor.userID = "acct-\(actor.lowercased())"
    return event
}

@Suite(.serialized) @MainActor struct LibraryBranchesTests {
    // MARK: Nesting, Archived and Trash

    @Test func branchesNestUnderTheirParentsWithTheOnesNotYetOnTheServer() async throws {
        let world = LibraryBranchWorld()
        world.local.value = [BranchInfo(id: "b-local", parentID: LibraryBranchWorld.catalogue, name: "Kept offline", onServer: false),
                             BranchInfo(id: "b-autumn", parentID: LibraryBranchWorld.catalogue, name: "Autumn palette", onServer: false)]
        await world.loaded()
        let branches = world.branches
        #expect(world.client.calls == ["branches \(world.server.accountID)"])
        #expect(branches.branches(of: LibraryBranchWorld.catalogue).map(\.id) == ["b-autumn", "b-cover", "b-local"])
        #expect(branches.branches(of: LibraryBranchWorld.catalogue).last?.detail() == "Not yet on the server")
        #expect(branches.branches(of: LibraryBranchWorld.poster).isEmpty)
        #expect(branches.archived.map(\.id) == ["b-merged", "b-old"])
        #expect(branches.title(of: branches.archived[1]) == "Old idea — branch of Poster" && branches.parentName("nope") == "Untitled")
        #expect(!branches.isExpanded(LibraryBranchWorld.catalogue))
        branches.toggle(LibraryBranchWorld.catalogue)
        #expect(branches.isExpanded(LibraryBranchWorld.catalogue))
        // The tile shows "3 branches" and, expanded, each branch; the sidebar lists Archived and Trash.
        Render.view(LibraryView(model: world.library), size: CGSize(width: 900, height: 600))
        Render.view(LibraryNestedBranches(branches: branches, parent: LibraryDocument(id: LibraryBranchWorld.catalogue, spaceID: "s", name: "Catalogue")))
        Render.view(LibraryNestedBranches(branches: branches, parent: LibraryDocument(id: LibraryBranchWorld.poster, spaceID: "s", name: "Poster")))
        LibraryNestedBranches.toggle(branches, LibraryBranchWorld.catalogue)()
        #expect(!branches.isExpanded(LibraryBranchWorld.catalogue))
        LibraryNestedBranches.open(branches, branches.branches(of: LibraryBranchWorld.catalogue)[0])()
        #expect(world.opened.value == ["b-autumn Catalogue — Autumn palette"])
        // Opening a document of another space empties the lists until they load there.
        world.server.setTeams([LibrarySpace(id: "team-1", name: "Design", kind: .team)])
        await world.library.refresh()
        await world.library.switchSpace(to: "team-1")
        world.online.value = false
        await branches.load()
        #expect(branches.spaceID == "team-1" && branches.archived.isEmpty && branches.message == nil)
    }

    @Test func archivedBranchesAreRestoredOpenedAndTrashed() async throws {
        let world = LibraryBranchWorld()
        await world.loaded()
        let branches = world.branches
        await branches.show(.archived)
        #expect(branches.shelf == .archived && world.client.calls.count == 2)
        let view = Render.view(LibraryView(model: world.library), size: CGSize(width: 900, height: 600))
        #expect(LibraryToolbar(model: world.library).title == "Personal › Archived")
        _ = view
        let old = try #require(branches.archived.first { $0.id == "b-old" })
        LibraryShelfList.open(branches, old)()
        #expect(world.opened.value == ["b-old Poster — Old idea"])
        #expect(await branches.setArchived(old, false))
        #expect(branches.branches(of: LibraryBranchWorld.poster).map(\.id) == ["b-old"] && !branches.archived.contains { $0.id == "b-old" })
        #expect(await branches.setArchived(old, true))
        // Trashing asks first.
        world.confirms.value = false
        #expect(await !branches.trashBranch(old))
        world.confirms.value = true
        #expect(await branches.trashBranch(old))
        #expect(!branches.archived.contains { $0.id == "b-old" } && world.client.calls.last == "delete b-old")
        // Failing and offline, the row says why and nothing changes.
        world.client.fails = true
        let merged = try #require(branches.archived.first)
        #expect(await !branches.setArchived(merged, false) && branches.message == "no archive b-merged false")
        world.client.fails = false
        world.online.value = false
        #expect(await !branches.trashBranch(merged) && branches.message == LibraryModel.offlineActionMessage)
        await branches.load()
        #expect(branches.message == LibraryBranches.offlineMessage)
        Render.view(LibraryShelfList(branches: branches))
        // The row buttons reach the same calls.
        world.online.value = true
        LibraryShelfList.restore(branches, merged)()
        // Wait for the restore to land (not just for the call to start), or the trash below can
        // overtake it.
        #expect(await eventually { world.client.calls.last == "archive b-merged false" && !branches.archived.contains { $0.id == "b-merged" } })
        LibraryShelfList.trash(branches, merged)()
        #expect(await eventually { world.client.calls.last == "delete b-merged" })
        await branches.show(nil)
        #expect(branches.shelf == nil)
        Render.view(LibraryShelfList(branches: branches))
    }

    @Test func theTrashListsDocumentsAndBranchesAndRestoresThem() async throws {
        let trashedAt = Date(timeIntervalSinceNow: -86_400)
        let world = LibraryBranchWorld(trash: [
            LibraryTrashEntry(document: LibraryDocument(id: "b-gone", spaceID: "s", name: "Gone branch", isTrashed: true), parentID: LibraryBranchWorld.catalogue,
                              trashedAt: trashedAt),
            LibraryTrashEntry(document: LibraryDocument(id: "d-flyer", spaceID: "s", name: "Flyer", isTrashed: true)),
        ])
        await world.loaded()
        let branches = world.branches
        await branches.show(.trash)
        #expect(branches.trash.map(\.id) == ["b-gone", "d-flyer"])
        let list = LibraryShelfList(branches: branches)
        #expect(list.detail(branches.trash[0]).hasPrefix("Branch of Catalogue · deleted ") && list.detail(branches.trash[1]) == "kept 30 days")
        Render.view(LibraryView(model: world.library), size: CGSize(width: 900, height: 600))
        #expect(LibraryToolbar(model: world.library).title == "Personal › Trash")
        branches.openTrashed(branches.trash[1])
        #expect(branches.message == "Restore “Flyer” to open it.")
        // Restoring a branch puts it back under its parent; a document reloads the section.
        #expect(await branches.restore(branches.trash[0]))
        #expect(branches.branches(of: LibraryBranchWorld.catalogue).contains { $0.id == "b-gone" } && branches.trash.map(\.id) == ["d-flyer"])
        LibraryShelfList.restore(branches, branches.trash[0])()
        #expect(await eventually { branches.trash.isEmpty })
        Render.view(LibraryShelfList(branches: branches))
        // Trashing a branch from its nested row while the Trash shows lists it there.
        let cover = try #require(branches.branches(of: LibraryBranchWorld.catalogue).first { $0.id == "b-cover" })
        #expect(await branches.trashBranch(cover))
        #expect(branches.trash.map(\.id) == ["b-cover"])
        LibraryNestedBranches.archive(branches, branches.branches(of: LibraryBranchWorld.catalogue)[0])()
        #expect(await eventually { world.client.calls.last?.hasPrefix("archive") == true })
        LibraryNestedBranches.trash(branches, branches.branches(of: LibraryBranchWorld.catalogue)[0])()
        #expect(await eventually { world.client.calls.filter { $0.hasPrefix("delete") }.count == 2 })
        // A list that fails says so.
        world.client.fails = true
        await branches.load()
        #expect(branches.message == "no branches \(world.server.accountID)")
        world.client.fails = false
        world.online.value = false
        #expect(await !branches.restore(branches.trash[0]))
    }

    // MARK: Live updates

    @Test func branchEventsUpdateTheLibraryAtOnce() async throws {
        let world = LibraryBranchWorld()
        await world.loaded()
        let branches = world.branches
        let catalogue = LibraryBranchWorld.catalogue
        branches.apply(branchEvent(.created, branch: "b-new", parent: catalogue, name: "Winter"))
        #expect(branches.branches(of: catalogue).map(\.name).contains("Winter"))
        #expect(branches.branches(of: catalogue).first { $0.id == "b-new" }?.lastAuthor == "Tom")
        branches.apply(branchEvent(.renamed, branch: "b-new", parent: catalogue, name: "Winter v2", actor: ""))
        #expect(branches.branches(of: catalogue).first { $0.id == "b-new" }?.name == "Winter v2")
        branches.apply(branchEvent(.archived, branch: "b-new", parent: catalogue))
        #expect(branches.archived.contains { $0.id == "b-new" && $0.name == "Winter v2" })
        branches.apply(branchEvent(.restored, branch: "b-new", parent: catalogue))
        #expect(branches.branches(of: catalogue).contains { $0.id == "b-new" })
        branches.apply(branchEvent(.merged, branch: "b-new", parent: catalogue))
        #expect(branches.archived.first { $0.id == "b-new" }?.state == .merged)
        branches.apply(branchEvent(.trashed, branch: "b-new", parent: catalogue))
        #expect(!branches.archived.contains { $0.id == "b-new" } && !branches.branches(of: catalogue).contains { $0.id == "b-new" })
        branches.apply(branchEvent(.unspecified, branch: "b-cover", parent: catalogue))
        #expect(branches.branches(of: catalogue).contains { $0.id == "b-cover" })
    }

    @Test func aWindowsBranchPopupFollowsBranchEventsFromAnotherClient() async throws {
        let parent = DocumentHandle.memory(id: "parent-1", title: "Catalogue")
        let world = CollaborationWorld(document: parent, branches: [BranchInfo(id: "b-1", parentID: "parent-1", name: "Cover")])
        defer { world.close() }
        let heard = TestBox<[String]>([])
        world.features.branchEvent = { heard.value.append($0.name) }
        let branches = world.ui.branches
        await branches.load()
        // Events reach the popup through the window's subscription, and the app (the library) too.
        var frame = Wiretuner_Sync_V1_DocumentEvent()
        frame.branch = branchEvent(.created, branch: "b-2", parent: "parent-1", name: "Autumn")
        world.window.collaboration.documentEvent(frame)
        #expect(branches.targets.map(\.title) == ["main", "Autumn", "Cover"] && heard.value == ["Autumn"])
        #expect(branches.branches.first?.lastAuthor == "Tom")
        branches.apply(branchEvent(.renamed, branch: "b-2", parent: "parent-1", name: "Autumn palette"))
        #expect(branches.targets.map(\.title) == ["main", "Autumn palette", "Cover"])
        branches.apply(branchEvent(.archived, branch: "b-2", parent: "parent-1"))
        #expect(branches.branches.map(\.id) == ["b-1"] && branches.archived.map(\.id) == ["b-2"])
        branches.apply(branchEvent(.renamed, branch: "b-2", parent: "parent-1", name: "Autumn old"))
        #expect(branches.archived.first?.name == "Autumn old")
        branches.apply(branchEvent(.restored, branch: "b-2", parent: "parent-1"))
        #expect(branches.branches.map(\.id) == ["b-2", "b-1"])
        branches.apply(branchEvent(.merged, branch: "b-2", parent: "parent-1"))
        #expect(branches.archived.first?.state == .merged)
        branches.apply(branchEvent(.trashed, branch: "b-1", parent: "parent-1"))
        #expect(branches.branches.isEmpty && branches.message == nil)
        branches.apply(branchEvent(.unspecified, branch: "b-2", parent: "parent-1"))
        branches.apply(branchEvent(.unspecified, branch: "b-9", parent: "parent-1"))
        #expect(branches.archived.map(\.id) == ["b-2"])
        // Another document's branches are not this window's.
        branches.apply(branchEvent(.created, branch: "b-x", parent: "other"))
        #expect(!branches.branches.contains { $0.id == "b-x" })
        Render.view(BranchPopupView(branches: branches))
    }

    @Test func aBranchWindowHearsItsOwnRenameArchiveAndTrash() async throws {
        let branch = DocumentHandle.memory(id: "b-1", title: "Catalogue — Cover")
        let world = CollaborationWorld(document: branch, branches: [BranchInfo(id: "b-1", parentID: "parent-1", name: "Cover")])
        defer { world.close() }
        let branches = world.ui.branches
        await branches.load()
        branches.apply(branchEvent(.renamed, branch: "b-1", parent: "parent-1", name: "Cover v2"))
        #expect(branches.title == "Cover v2")
        branches.apply(branchEvent(.archived, branch: "b-1", parent: "parent-1"))
        #expect(branches.current?.state == .archived)
        world.environment.commands.command(CollaborationFeatures.ID.archiveBranch).map { #expect($0.validation().title == "Restore Branch") }
        branches.apply(branchEvent(.trashed, branch: "b-1", parent: "parent-1", actor: "Priya"))
        #expect(branches.message == "“Cover v2” was moved to the Trash by Priya")
        branches.apply(branchEvent(.trashed, branch: "b-1", parent: "parent-1", actor: ""))
        #expect(branches.message?.hasSuffix("by someone") == true)
    }

    // MARK: Creating pending branches

    @Test func branchStoresMadeOfflineAreCreatedOnTheServerAtLaunchAndWhenTheirSessionStarts() async throws {
        let directory = TestStores.directory()
        let root = TestStores.directory()
        let parent = TestStores.handle(in: directory)
        await parent.settle()
        await parent.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        let store = try #require(parent.model?.backend as? LocalStore)
        let first = try await BranchStores.keepChangesOnBranch(parent: store, name: "At launch", root: root)
        await parent.addRectangles([Rect(x: 20, y: 0, width: 10, height: 10)])
        let second = try await BranchStores.keepChangesOnBranch(parent: store, name: "On open", root: root)
        #expect(try BranchStores.pendingCreations(in: root).count == 2)
        // A copy transport that is offline creates nothing and the branches wait.
        let copies = FakeCopies()
        copies.failure = RPCError(code: .unavailable, message: "offline")
        #expect(await PendingBranches.create(root: root, creator: BranchCreator(transport: copies, tokens: StaticTokens())).isEmpty)
        // Launch creates one of them (the other is being opened meanwhile: take it out of the root).
        let aside = TestStores.directory()
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: second.url.deletingLastPathComponent(), to: aside.appending(path: second.documentID))
        copies.failure = nil
        #expect(await PendingBranches.create(root: root, creator: BranchCreator(transport: copies, tokens: StaticTokens())) == [first.documentID])
        let remaining = try BranchStores.pendingCreations(in: root)
        #expect(copies.recorded.count == 1 && copies.recorded[0].hasPrefix("branch At launch ") && remaining.isEmpty)
        // A branch store's session creates it on the server before its client pushes.
        let connector = CopyingConnector()
        let handle = TestStores.handle(id: second.documentID, in: aside)
        let session = DocumentSession(document: handle, connector: connector, localUserID: "me")
        await session.start().value
        #expect(await eventually { connector.copies.recorded.first?.hasPrefix("branch On open ") == true })
        #expect(try BranchStores.pendingCreations(in: aside).isEmpty)
        await session.stop()
        await DocumentOpener.close(try #require(parent.model?.backend))
    }

    // MARK: gRPC

    @Test func theShelfClientListsBranchesOfASpaceAndTheTrashRestoresAndRetires() async throws {
        let log = RequestLog()
        typealias Branches = Wiretuner_Docs_V1_BranchService.Method
        typealias Documents = Wiretuner_Docs_V1_DocumentService.Method
        var branch = Wiretuner_Docs_V1_Branch()
        branch.branchDocumentID = "b-1"
        branch.parentDocumentID = "p-1"
        branch.name = "Autumn"
        branch.state = .archived
        var trashed = Wiretuner_Docs_V1_Document()
        trashed.id = "b-2"
        trashed.name = "Gone"
        trashed.parentDocumentID = "p-1"
        trashed.trashedAt = .init(date: Date(timeIntervalSince1970: 1_000))
        var plain = Wiretuner_Docs_V1_Document()
        plain.id = "d-3"
        plain.name = "Flyer"
        let (branchReply, trashedReply, plainReply) = (branch, trashed, plain)
        let caller = FakeUnaryCaller([
            route(Branches.ListBranches.descriptor) { (request: Wiretuner_Docs_V1_ListBranchesRequest) in
                log.append("list \(request.spaceID) \(request.includeArchived) \(request.cursor) \(request.parentDocumentID.isEmpty)")
                var response = Wiretuner_Docs_V1_ListBranchesResponse()
                response.branches = [branchReply]
                if request.cursor.isEmpty { response.nextCursor = "next" }
                return response
            },
            route(Documents.List.descriptor) { (request: Wiretuner_Docs_V1_ListRequest) in
                log.append("trash \(request.spaceID) \(request.scope == .trash) \(request.cursor)")
                var response = Wiretuner_Docs_V1_ListResponse()
                response.documents = request.cursor.isEmpty ? [trashedReply] : [plainReply]
                if request.cursor.isEmpty { response.nextCursor = "p2" }
                return response
            },
            route(Documents.Restore.descriptor) { (request: Wiretuner_Docs_V1_RestoreRequest) in
                log.append("restore \(request.documentID)")
                return Wiretuner_Docs_V1_RestoreResponse()
            },
            route(Branches.SetBranchState.descriptor) { (request: Wiretuner_Docs_V1_SetBranchStateRequest) in
                log.append("state \(request.branchDocumentID) \(request.state == .archived)")
                var response = Wiretuner_Docs_V1_SetBranchStateResponse()
                response.branch = branchReply
                return response
            },
            route(Branches.DeleteBranch.descriptor) { (request: Wiretuner_Docs_V1_DeleteBranchRequest) in
                log.append("delete \(request.branchDocumentID)")
                return Wiretuner_Docs_V1_DeleteBranchResponse()
            },
        ])
        let client = GRPCLibraryShelfClient(caller: caller) { "token" }
        let listed = try await client.branches(inSpace: "space-1")
        #expect(listed.map(\.id) == ["b-1", "b-1"] && listed[0].state == .archived && listed[0].parentID == "p-1")
        let trash = try await client.trash(spaceID: "space-1")
        #expect(trash.map(\.id) == ["b-2", "d-3"] && trash[0].parentID == "p-1" && trash[1].parentID == nil)
        #expect(trash[0].trashedAt == Date(timeIntervalSince1970: 1_000) && trash[1].trashedAt == nil && trash[0].document.name == "Gone")
        try await client.restore(documentID: "b-2")
        #expect(try await client.setArchived("b-1", true).name == "Autumn")
        try await client.deleteBranch("b-1")
        #expect(log.all == ["list space-1 true  true", "list space-1 true next true", "trash space-1 true ", "trash space-1 true p2",
                            "restore b-2", "state b-1 true", "delete b-1"])
        #expect(caller.tokens.all.allSatisfy { $0 == "token" })
    }
}
