import AppKit
import Foundation
import GRPCCore
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// Fork and CreateBranch calls, recorded.
final class FakeCopies: DocumentCopyTransport, ClosableTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var failure: (any Error)?
    private(set) var closed = 0

    var recorded: [String] { lock.withLock { calls } }

    func fork(_ request: Wiretuner_Docs_V1_ForkRequest, token: String) async throws -> Wiretuner_Docs_V1_ForkResponse {
        if let failure { throw failure }
        lock.withLock { calls.append("fork \(request.name) \(request.changes.count)") }
        return Wiretuner_Docs_V1_ForkResponse()
    }

    func createBranch(_ request: Wiretuner_Docs_V1_CreateBranchRequest, token: String) async throws -> Wiretuner_Docs_V1_CreateBranchResponse {
        if let failure { throw failure }
        lock.withLock { calls.append("branch \(request.name) \(request.initialChanges.count)") }
        return Wiretuner_Docs_V1_CreateBranchResponse()
    }

    func close() async { lock.withLock { closed += 1 } }
}

/// A connector whose sessions also carry the transport, copy calls and tokens.
@MainActor
final class CopyingConnector: SyncConnecting {
    let server = FakeSyncServer()
    let copies = FakeCopies()
    let blobs = FileManager.default.temporaryDirectory.appending(path: "WireTunerBlobs-\(UUID().uuidString)")

    func connect(store: LocalStore, sink: any RemoteChangeSink, presence: LocalPresence?) throws -> SyncConnection {
        let transport = FakeSyncTransport(server: server)
        let queue = BlobQueue(store: store, cache: BlobCache(directory: blobs), transport: transport, tokens: StaticTokens())
        let client = SyncClient(store: store, sink: sink, transport: transport, tokens: StaticTokens(), presence: presence, blobs: queue,
                                options: FakeSyncConnector.options)
        return SyncConnection(client: client, close: {}, transport: transport, copies: copies, tokens: StaticTokens())
    }
}

/// An access offer the test drives.
final class FakeAccessOffer: AccessOffering, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AccessController.Status>.Continuation?
    private var log: [String] = []
    var fails = false

    var calls: [String] { lock.withLock { log } }

    func statuses() async -> AsyncStream<AccessController.Status> {
        AsyncStream { continuation in
            continuation.yield(AccessController.Status())
            self.lock.withLock { self.continuation = continuation }
        }
    }

    func send(_ status: AccessController.Status) {
        _ = lock.withLock { continuation }?.yield(status)
    }

    func saveAsCopy(name: String, newDocumentID: String) async throws -> String {
        if fails { throw BranchError.noStore }
        lock.withLock { log.append("copy \(name)") }
        return newDocumentID
    }

    func discard() async throws {
        if fails { throw BranchError.noStore }
        lock.withLock { log.append("discard") }
    }

    func deleteStore() async throws {
        lock.withLock { log.append("delete") }
    }
}

/// `BranchService` in memory.
final class FakeBranchClient: BranchClient, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BranchInfo]
    var fails = false

    init(_ branches: [BranchInfo] = []) {
        stored = branches
    }

    var branches: [BranchInfo] { lock.withLock { stored } }

    func branch(_ id: String) async -> BranchInfo? {
        lock.withLock { stored.first { $0.id == id } }
    }

    func list(parent: String, includeArchived: Bool) async throws -> [BranchInfo] {
        if fails { throw BranchError.noStore }
        return lock.withLock { stored.filter { $0.parentID == parent && (includeArchived || $0.state == .active) } }
    }

    func create(parent: String, branchID: String, name: String, forkServerSeq: UInt64) async throws -> BranchInfo {
        if fails { throw BranchError.noStore }
        let branch = BranchInfo(id: branchID, parentID: parent, name: name, lastAuthor: "Ann", lastChange: Date())
        lock.withLock { stored.append(branch) }
        return branch
    }

    func rename(_ branch: String, to name: String) async throws -> BranchInfo {
        try update(branch) { $0.name = name }
    }

    func setArchived(_ branch: String, _ archived: Bool) async throws -> BranchInfo {
        try update(branch) { $0.state = archived ? .archived : .active }
    }

    func delete(_ branch: String) async throws {
        if fails { throw BranchError.noStore }
        lock.withLock { stored.removeAll { $0.id == branch } }
    }

    private func update(_ id: String, _ body: (inout BranchInfo) -> Void) throws -> BranchInfo {
        if fails { throw BranchError.noStore }
        return try lock.withLock {
            guard let index = stored.firstIndex(where: { $0.id == id }) else { throw BranchError.noStore }
            body(&stored[index])
            return stored[index]
        }
    }
}

/// A window with the collaboration features, the branch client and sheets captured.
@MainActor
struct CollaborationWorld {
    let environment = TestEnvironment()
    let window: DocumentWindowController
    let features = CollaborationFeatures()
    let client: FakeBranchClient
    let root = TestStores.directory()
    var opened: TestBox<[String]> = TestBox([])
    var sheets: TestBox<[NSWindow]> = TestBox([])
    var online: TestBox<Bool> = TestBox(true)

    init(document: DocumentHandle = .memory(title: "Catalogue"), branches: [BranchInfo] = []) {
        window = DocumentWindowController(document: document, environment: environment.document)
        window.confirm = { _, _ in true }
        client = FakeBranchClient(branches)
        let client = client, root = root, opened = opened, sheets = sheets, online = online
        features.branchClient = { online.value ? client : nil }
        features.storeRoot = { root }
        features.openDocument = { id, name in opened.value.append("\(id) \(name)") }
        features.presentSheet = { sheet, _ in sheets.value.append(sheet) }
        features.makeID = { "branch-new" }
        let window = window
        features.install(commands: environment.commands) { [weak window] in window }
    }

    var ui: WindowCollaborationUI { features.attach(window) }
    var document: DocumentHandle { window.documentHandle }

    func close() {
        // The recorded sheets' models hold the window, and the features hold the sheets.
        sheets.value = []
        features.detach(window)
        window.close()
    }
}

@Suite(.serialized) @MainActor struct CollaborationFeaturesTests {
    // MARK: Access bar

    @Test func theAccessBarFollowsTheOfferAndCarriesOutTheChoice() async throws {
        let offer = FakeAccessOffer()
        let model = AccessBarModel(offer: offer, title: "Catalogue")
        var shown: [Bool] = []
        var opened: [String] = []
        var closed = 0
        model.onChange = { shown.append($0) }
        model.openDocument = { id, name in opened.append("\(id) \(name)") }
        model.closeWindow = { closed += 1 }
        model.makeID = { "copy-id" }
        model.start()
        #expect(await eventually { shown == [false] })
        offer.send(AccessController.Status(editable: false, reason: .role, unsent: 3))
        #expect(await eventually { model.isShown && model.offersChoice })
        #expect(model.detail == "3 changes of yours have not been sent." && model.status.banner == "You can no longer edit this document")
        Render.view(AccessBarView(model: model))
        await model.saveAsCopy()
        #expect(offer.calls == ["copy Catalogue (my changes)"] && opened == ["copy-id Catalogue (my changes)"] && model.message?.contains("saved") == true)
        offer.fails = true
        await model.saveAsCopy()
        await model.discard()
        #expect(model.message?.contains("could not be discarded") == true)
        offer.fails = false
        offer.send(AccessController.Status(editable: false, reason: .role, unsent: 1))
        #expect(await eventually { model.detail == "1 change of yours has not been sent." })
        AccessBarView.discard(model)()
        #expect(await eventually { offer.calls.last == "discard" })
        // A removal with changes waits for the choice, then deletes the copy and closes.
        offer.send(AccessController.Status(editable: false, reason: .accessRemoved, unsent: 2))
        #expect(await eventually { model.status.isRemoved })
        #expect(closed == 0)
        AccessBarView.save(model)()
        #expect(await eventually { closed == 1 && offer.calls.contains("delete") })
        await model.discard()
        #expect(closed == 2)
        // A removal with nothing unsent closes at once.
        offer.send(AccessController.Status(editable: false, reason: .accessRemoved, unsent: 0))
        #expect(await eventually { closed == 3 })
        offer.send(AccessController.Status())
        #expect(await eventually { !model.isShown && model.detail == nil })
        model.stop()
        // The accessory hides and shows with the bar.
        let window = TestWindow.make()
        let accessory = AccessBarAccessory(model: AccessBarModel(offer: offer, title: "T"), window: window)
        #expect(accessory.controller.isHidden && window.titlebarAccessoryViewControllers.count == 1)
        accessory.model.apply(AccessController.Status(editable: false, reason: .clientTooOld))
        #expect(!accessory.controller.isHidden)
        accessory.remove()
        #expect(window.titlebarAccessoryViewControllers.isEmpty)
    }

    @Test func aLoweredRoleFreezesTheUnsentChangesAndSavesThemAsACopy() async throws {
        let directory = TestStores.directory()
        let connector = CopyingConnector()
        await connector.server.update { $0.role = .viewer }
        let handle = TestStores.handle(in: directory)
        await handle.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        let session = DocumentSession(document: handle, connector: connector, localUserID: "me")
        #expect(session.makeAccessController() == nil)
        await session.start().value
        let controller = try #require(session.makeAccessController())
        await controller.start()
        let model = AccessBarModel(offer: controller, title: handle.title)
        model.start()
        #expect(await eventually { model.offersChoice })
        #expect(model.status.banner == "You can no longer edit this document")
        await model.saveAsCopy()
        #expect(connector.copies.recorded.first?.hasPrefix("fork Stored (my changes)") == true)
        #expect(await eventually { !model.offersChoice })
        model.stop()
        await session.stop()
    }

    @Test func keepingChangesOnABranchWritesABranchStoreAndCreatesItOnTheServer() async throws {
        let directory = TestStores.directory()
        let root = TestStores.directory()
        let connector = CopyingConnector()
        let handle = TestStores.handle(in: directory)
        let session = DocumentSession(document: handle, connector: connector, localUserID: "me")
        await expectThrows { _ = try await session.keepChangesOnBranch(name: "x", root: root) }
        await expectThrows { _ = try await session.state(atServerSeq: 1) }
        await handle.settle()
        await handle.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        await session.start().value
        #expect(await eventually { await connector.server.head == 1 })
        #expect(try await session.state(atServerSeq: 1).store.nodes.isEmpty == false)
        await handle.addRectangles([Rect(x: 20, y: 0, width: 10, height: 10)])
        let id = try await session.keepChangesOnBranch(name: "Autumn", root: root)
        let entries = try BranchStores.branches(in: root)
        #expect(entries.map(\.documentID) == [id] && entries[0].meta.name == "Autumn")
        #expect(BranchInfo(entries[0]).parentID == handle.id)
        await session.stop()
        // Without the server holding it, a lazily made copy transport is never opened.
        let lazy = LazyDocumentCopyTransport { connector.copies }
        #expect(!lazy.isMade)
        await lazy.close()
        _ = try await lazy.createBranch(Wiretuner_Docs_V1_CreateBranchRequest(), token: "t")
        _ = try await lazy.fork(Wiretuner_Docs_V1_ForkRequest(), token: "t")
        await lazy.close()
        #expect(lazy.isMade && connector.copies.closed == 1)
    }

    // MARK: Branches

    @Test func theBranchPopupListsMainAndTheBranchesAndActs() async throws {
        let parent = DocumentHandle.memory(title: "Catalogue")
        let other = BranchInfo(id: "b-1", parentID: parent.id, name: "Cover rework", lastAuthor: "Priya", lastChange: Date(timeIntervalSinceNow: -3600))
        let old = BranchInfo(id: "b-0", parentID: parent.id, name: "Old", state: .archived)
        let world = CollaborationWorld(document: parent, branches: [other, old])
        defer { world.close() }
        let branches = world.ui.branches
        await branches.load()
        #expect(!branches.isBranch && branches.title == "main" && branches.branches.map(\.id) == ["b-1"] && branches.archived.map(\.id) == ["b-0"])
        #expect(branches.targets.map(\.title) == ["main", "Cover rework"] && branches.targets[1].detail.hasPrefix("Priya · "))
        Render.view(BranchPopupView(branches: branches))
        // Create opens the branch; compare shows the sheet; switch opens and closes.
        let created = await branches.create(named: " Autumn ")
        #expect(created?.name == "Autumn" && world.opened.value == ["branch-new Autumn"])
        #expect(await branches.create(named: "  ") == nil)
        #expect(await branches.compare(with: "b-1") == nil && branches.message == "That version is not on this Mac yet")
        world.features.state = { _ in parent.state }
        let compare = try #require(await branches.compare(with: "b-1"))
        #expect(compare.titleA == "Main" && compare.titleB == "Cover rework" && world.sheets.value.last?.identifier == CompareSheet.identifier)
        compare.close()
        branches.switchTo(nil)
        #expect(world.opened.value.count == 1)
        branches.switchTo("b-1")
        #expect(world.opened.value.last == "b-1 Cover rework")
        // In the parent, rename, archive and trash do nothing.
        let renamed = await branches.rename(to: "x"), archived = await branches.setArchived(true), trashed = await branches.trash()
        #expect(!renamed && !archived && !trashed)
        // Offline: listing keeps the local stores, creating says why.
        world.online.value = false
        #expect(await branches.create(named: "Later") == nil && branches.message == CollaborationFeatures.offline)
        world.online.value = true
        world.client.fails = true
        await branches.load()
        #expect(branches.message?.hasPrefix("Branches could not be listed") == true)
        #expect(await branches.create(named: "Fails") == nil)
    }

    @Test func aBranchWindowRenamesArchivesAndTrashesItsBranch() async throws {
        let branch = DocumentHandle.memory(id: "b-1", title: "Catalogue — Cover")
        let info = BranchInfo(id: "b-1", parentID: "parent-1", name: "Cover")
        let world = CollaborationWorld(document: branch, branches: [info])
        defer { world.close() }
        let branches = world.ui.branches
        await branches.load()
        #expect(branches.isBranch && branches.title == "Cover" && branches.parentID == "parent-1")
        // The commands follow: in a branch, online.
        let registry = world.environment.commands
        #expect(registry.command(CollaborationFeatures.ID.renameBranch)?.validation() == .enabled)
        #expect(registry.command(CollaborationFeatures.ID.archiveBranch)?.validation().title == "Archive Branch")
        #expect(await branches.rename(to: "Cover v2") && branches.current?.name == "Cover v2")
        #expect(await branches.setArchived(true) && branches.current?.state == .archived)
        #expect(registry.command(CollaborationFeatures.ID.archiveBranch)?.validation().title == "Restore Branch")
        #expect(await branches.setArchived(false))
        world.window.confirm = { _, _ in false }
        #expect(await !branches.trash())
        world.window.confirm = { _, _ in true }
        world.client.fails = true
        let renamed = await branches.rename(to: "x"), archived = await branches.setArchived(true), trashed = await branches.trash()
        #expect(!renamed && !archived && !trashed)
        #expect(branches.message?.contains("Trash") == true)
        world.client.fails = false
        #expect(await branches.trash())
        #expect(world.opened.value.last == "parent-1 Catalogue")
        #expect(world.features.parentTitle(branch) == "Catalogue")
    }

    @Test func theBranchCommandsValidateAndPresentTheirSheets() async throws {
        let world = CollaborationWorld()
        defer { world.close() }
        let registry = world.environment.commands
        await world.ui.branches.load()
        typealias ID = CollaborationFeatures.ID
        #expect(registry.command(ID.newBranch)?.validation() == .enabled)
        #expect(registry.command(ID.renameBranch)?.validation() == .disabled(CollaborationFeatures.notABranch))
        #expect(registry.command(ID.mergeBranch)?.validation() == .disabled(CollaborationFeatures.mergeLater))
        #expect(registry.command(ID.restoreVersion)?.validation() == .disabled(CollaborationFeatures.noVersions))
        #expect(registry.command(ID.archiveBranch)?.validation() == .disabled(CollaborationFeatures.notABranch))
        registry.perform(ID.mergeBranch)
        for id in [ID.newBranch, ID.switchBranch, ID.compareBranch] {
            registry.perform(id)
            #expect(world.sheets.value.last?.identifier?.rawValue == CollaborationFeatures.branchSheet)
            world.features.dismiss(CollaborationFeatures.branchSheet)
        }
        registry.perform(ID.renameBranch)
        registry.perform(ID.archiveBranch)
        registry.perform(ID.trashBranch)
        // The sheets' own actions.
        world.features.presentNewBranch(world.ui.branches)
        Render.view(BranchNameSheet(title: "New Branch", button: "Create", name: "") { _ in })
        BranchNameSheet.confirm("Spring", { _ in })()
        BranchNameSheet.cancel({ _ in })()
        Render.view(BranchChooserSheet(title: "Switch To", targets: world.ui.branches.targets + [("x", "X", "detail")]) { _ in })
        BranchChooserSheet.choose(nil, { _ in })()
        BranchChooserSheet.cancel({ _ in })()
        BranchPopupView.newBranch(world.ui.branches)()
        BranchPopupView.switchTo(world.ui.branches, nil)()
        world.features.presentRename(world.ui.branches)
        world.features.dismiss("none")
        // Offline and windowless.
        world.online.value = false
        #expect(registry.command(ID.newBranch)?.validation() == .disabled(CollaborationFeatures.offline))
        world.features.window = { nil }
        for id in [ID.newBranch, ID.switchBranch, ID.renameBranch, ID.restoreVersion, ID.inspectMode] {
            #expect(registry.command(id)?.validation() == .disabled(CollaborationFeatures.noDocument))
        }
        world.features.presentChooser(compare: false)
        #expect(world.features.presentRestore() == nil)
    }

    @Test func theBranchAndVersionClientsSpeakTheServices() async throws {
        typealias Branches = Wiretuner_Docs_V1_BranchService.Method
        typealias Versions = Wiretuner_Docs_V1_VersionService.Method
        let caller = FakeUnaryCaller([
            route(Branches.GetBranch.descriptor) { (request: Wiretuner_Docs_V1_GetBranchRequest) -> Wiretuner_Docs_V1_GetBranchResponse in
                guard request.branchDocumentID == "b1" else { throw RPCError(code: .notFound, message: "no") }
                return .with { $0.branch = BranchMessages.branch("b1", "One") }
            },
            route(Branches.ListBranches.descriptor) { (request: Wiretuner_Docs_V1_ListBranchesRequest) -> Wiretuner_Docs_V1_ListBranchesResponse in
                request.cursor.isEmpty
                    ? .with { $0.branches = [BranchMessages.branch("b1", "One")]; $0.nextCursor = "2" }
                    : .with { $0.branches = [BranchMessages.branch("b2", "Two", .archived), BranchMessages.branch("b3", "Three", .merged)] }
            },
            route(Branches.CreateBranch.descriptor) { (request: Wiretuner_Docs_V1_CreateBranchRequest) -> Wiretuner_Docs_V1_CreateBranchResponse in
                .with { $0.branch = BranchMessages.branch(request.branchDocumentID, request.name) }
            },
            route(Branches.RenameBranch.descriptor) { (request: Wiretuner_Docs_V1_RenameBranchRequest) -> Wiretuner_Docs_V1_RenameBranchResponse in
                .with { $0.branch = BranchMessages.branch(request.branchDocumentID, request.name) }
            },
            route(Branches.SetBranchState.descriptor) { (request: Wiretuner_Docs_V1_SetBranchStateRequest) -> Wiretuner_Docs_V1_SetBranchStateResponse in
                .with { $0.branch = BranchMessages.branch(request.branchDocumentID, "One", request.state) }
            },
            route(Branches.DeleteBranch.descriptor) { (_: Wiretuner_Docs_V1_DeleteBranchRequest) -> Wiretuner_Docs_V1_DeleteBranchResponse in .init() },
            route(Versions.ListVersions.descriptor) { (request: Wiretuner_Docs_V1_ListVersionsRequest) -> Wiretuner_Docs_V1_ListVersionsResponse in
                request.cursor.isEmpty
                    ? .with { $0.versions = [.with { $0.id = "v1"; $0.name = "Approved"; $0.serverSeq = 4; $0.createdAt = .init(date: Date()) }]; $0.nextCursor = "n" }
                    : .with { $0.versions = [.with { $0.id = "v2"; $0.name = "Later"; $0.serverSeq = 9 }] }
            },
        ])
        let client = GRPCBranchClient(caller: caller) { "token" }
        let found = await client.branch("b1"), missing = await client.branch("nope")
        #expect(found?.name == "One" && missing == nil)
        let listed = try await client.list(parent: "p", includeArchived: true)
        #expect(listed.map(\.state) == [.active, .archived, .merged] && listed[0].detail().hasPrefix("Priya · "))
        #expect(try await client.create(parent: "p", branchID: "b9", name: "Nine", forkServerSeq: 3).id == "b9")
        #expect(try await client.rename("b1", to: "Uno").name == "Uno")
        #expect(try await client.setArchived("b1", true).state == .archived)
        try await client.delete("b1")
        let failing = GRPCBranchClient(caller: caller) { throw BranchError.noStore }
        #expect(await failing.branch("b1") == nil)
        let versions = try await GRPCVersionListing(caller: caller) { "token" }.versions(of: "doc")
        #expect(versions.map(\.id) == ["v1", "v2"] && versions[0].createdAt != nil && versions[1].createdAt == nil)
        #expect(BranchInfo(id: "x", parentID: "p", name: "X", onServer: false).detail() == "Not yet on the server")
        #expect(BranchInfo(id: "x", parentID: "p", name: "X").detail().isEmpty)
    }

    // MARK: Compare mode

    @Test func compareModeListsTheDifferencesAndReassertsOneSide() async throws {
        let document = DocumentHandle.memory(title: "Compare")
        let ids = await document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20), Rect(x: 40, y: 0, width: 20, height: 20)])
        let base = document.state
        _ = await document.perform(MoveObjects(ids.map(\.opID), by: Vector(dx: 5, dy: 0))).value
        let a = document.state
        _ = await document.perform(OpsCommand("Delete", ops: [Ops.setDeleted(ids[1].opID)])).value
        let added = await document.addRectangles([Rect(x: 90, y: 0, width: 5, height: 5)])
        let b = document.state
        let comparison = DocumentComparison(a: a, b: b, base: base)
        let kinds = Dictionary(uniqueKeysWithValues: comparison.entries.map { ($0.node, $0.kind) })
        #expect(kinds[ids[1].opID] == .onlyA && kinds[added[0].opID] == .onlyB && kinds[ids[0].opID] == nil)
        #expect(comparison.entry(ids[1].opID)?.overlaps == true && comparison.entry(OpID(counter: 1, replica: 1)) == nil)
        let changed = DocumentComparison(a: base, b: a)
        #expect(changed.entries.contains { $0.node == ids[0].opID && $0.kind == .changed } && !changed.entries[0].overlaps)
        // Use A: brings the deleted rectangle back, deletes the added one, re-asserts a move.
        #expect(DocumentComparison.useA(ids[1].opID, a: a, target: b, name: "R")?.ops.count == 2)
        #expect(DocumentComparison.useA(added[0].opID, a: a, target: b, name: "R")?.ops.count == 1)
        #expect(DocumentComparison.useA(ids[0].opID, a: base, target: a, name: "R")?.ops.count == 1)
        #expect(DocumentComparison.useA(ids[0].opID, a: a, target: a, name: "R") == nil)
        #expect(DocumentComparison.useA(OpID(counter: 5, replica: 5), a: a, target: b, name: "R") == nil)
        // The sheet, with a write target.
        let model = CompareSheetModel(comparison: DocumentComparison(a: a, b: b), titleA: "Branch", titleB: "Main", heading: "Compare",
                                      perform: { document.perform($0) }, current: { document.state })
        #expect(!model.isReadOnly && model.summary == "2 objects differ" && model.rows.count == 2)
        #expect(model.kindTitle(.onlyA) == "Only in Branch" && model.kindTitle(.onlyB) == "Only in Main" && model.kindTitle(.changed) == "Changed")
        CompareSheetView.select(model, ids[1].opID)()
        #expect(model.previewImage() != nil)
        CompareSheetView.side(model, .b)()
        CompareSheetView.overlay(model)()
        #expect(model.previewImage() != nil)
        Render.view(CompareSheetView(model: model))
        _ = await model.useA()?.value
        #expect(document.state.isLive(ids[1].opID) && model.isChosen(ids[1].opID))
        CompareSheetView.useA(model)()
        CompareSheetView.select(model, added[0].opID)()
        CompareSheetView.useB(model)()
        #expect(model.isChosen(added[0].opID) && document.state.isLive(added[0].opID))
        CompareSheetView.close(model)()
        // Read only: no choices; the summary counts overlaps.
        let readOnly = CompareSheetModel(comparison: comparison, titleA: "Older", titleB: "Now", heading: "Versions")
        #expect(readOnly.isReadOnly && readOnly.useA() == nil && readOnly.summary.contains("changed on both sides"))
        readOnly.useB()
        readOnly.selected = nil
        #expect(readOnly.previewImage() == nil)
        Render.view(CompareSheetView(model: readOnly))
        let single = CompareSheetModel(comparison: DocumentComparison(a: base, b: a), titleA: "A", titleB: "B", heading: "One")
        #expect(single.summary.hasPrefix(single.comparison.entries.count == 1 ? "1 object" : "\(single.comparison.entries.count)"))
        let window = TestWindow.make()
        let sheet = CompareSheet.present(readOnly, on: window)
        #expect(sheet.identifier == CompareSheet.identifier)
        readOnly.close()
        CompareSheet.present(readOnly, on: nil)
        readOnly.close()
    }

    // MARK: Restore

    @Test func restoringAVersionConfirmsWithTheSummaryAndRestoresAsOneChange() async throws {
        let document = DocumentHandle.memory(title: "Poster")
        let ids = await document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20)])
        let version = document.state
        await document.addRectangles([Rect(x: 40, y: 0, width: 20, height: 20)])
        let failing = TestBox(true)
        let model = RestoreVersionModel(
            documentTitle: "Poster",
            list: {
                if failing.value { throw BranchError.noStore }
                return [VersionInfo(id: "v1", name: "Approved", serverSeq: 3, createdAt: Date()), VersionInfo(id: "v0", name: "Draft one", serverSeq: 1)]
            },
            state: { seq in
                if seq == 1 { throw BranchError.noStore }
                return version
            },
            current: { document.state }, perform: { document.perform($0) })
        var closed = 0
        var compared: [CompareSheetModel] = []
        model.onClose = { closed += 1 }
        model.compare = { compared.append($0) }
        await model.load()
        #expect(model.phase == .failed("Versions could not be listed: \(BranchError.noStore.localizedDescription)"))
        Render.view(RestoreVersionSheet(model: model))
        failing.value = false
        await model.load()
        #expect(model.versions.map(\.id) == ["v1", "v0"] && model.selected == "v1" && model.phase == .choosing)
        Render.view(RestoreVersionSheet(model: model))
        #expect(model.restore() == nil && model.confirmation == nil)
        await model.prepare()
        #expect(model.confirmation?.hasPrefix("Restore “Approved”?") == true)
        Render.view(RestoreVersionSheet(model: model))
        _ = await model.restore()?.value
        await document.settle()
        #expect(closed == 1 && document.undoTitle == "Undo Restore 'Approved'" && document.state.isLive(ids[0].opID))
        // Already matching: nothing to restore.
        await model.prepare()
        #expect(model.confirmation == "The document already matches “Approved”." && model.restore() == nil)
        RestoreVersionSheet.back(model)()
        #expect(model.phase == .choosing)
        // Compare, then a version that cannot be read.
        #expect(await model.showCompare()?.titleA == "Older" && compared.count == 1)
        RestoreVersionSheet.selection(model).wrappedValue = "v0"
        await model.prepare()
        #expect(model.phase == .failed("The version could not be read: \(BranchError.noStore.localizedDescription)"))
        Render.view(RestoreVersionSheet(model: model))
        #expect(await model.showCompare() != nil)
        RestoreVersionSheet.prepare(model)()
        RestoreVersionSheet.compare(model)()
        RestoreVersionSheet.restore(model)()
        RestoreVersionSheet.cancel(model)()
        let empty = RestoreVersionModel(documentTitle: "E", list: { [] }, state: { _ in EngineState() }, current: { EngineState() }, perform: { document.perform($0) })
        await empty.load()
        await empty.prepare()
        #expect(await empty.showCompare() == nil)
        Render.view(RestoreVersionSheet(model: empty))
    }

    @Test func theRestoreCommandPresentsTheSheetOverTheWindow() async throws {
        let world = CollaborationWorld()
        defer { world.close() }
        world.features.versionListing = { OneVersion() }
        world.features.versionState = { _, _ in EngineState() }
        await world.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        #expect(world.environment.commands.command(CollaborationFeatures.ID.restoreVersion)?.validation() == .enabled)
        world.environment.commands.perform(CollaborationFeatures.ID.restoreVersion)
        #expect(world.sheets.value.last?.identifier?.rawValue == CollaborationFeatures.restoreSheet)
        let model = try #require(world.features.presentRestore())
        await model.load()
        await model.prepare()
        #expect(model.confirmation?.hasPrefix("Restore “V”?") == true)
        _ = await model.showCompare()
        #expect(world.sheets.value.last?.identifier == CompareSheet.identifier)
        _ = await model.restore()?.value
        await world.document.settle()
        #expect(world.document.undoTitle == "Undo Restore 'V'")
        model.cancel()
        // A real parent window takes the sheets as sheets.
        let presenter = CollaborationFeatures()
        let parented = presenter.present(Text("x"), identifier: "parented", on: world.window)
        #expect(parented.sheetParent === world.window.window)
        presenter.dismiss("parented")
        // The default version state needs a session.
        await expectThrows { _ = try await CollaborationFeatures().versionState(world.window, 1) }
    }

    // MARK: Inspect mode

    @Test func inspectModeMeasuresAndMakesEveryCommandInert() async throws {
        let world = CollaborationWorld()
        defer { world.close() }
        let document = world.document
        let page = document.pageList.pages[0]
        let ids = await document.addRectangles([Rect(x: page.rect.minX + 20, y: page.rect.minY + 20, width: 40, height: 30),
                                                Rect(x: page.rect.minX + 100, y: page.rect.minY + 20, width: 40, height: 30)])
        let registry = world.environment.commands
        let inspect = world.ui.inspect
        #expect(registry.command(CollaborationFeatures.ID.inspectMode)?.validation() == .checked(false))
        #expect(registry.command(CollaborationFeatures.ID.inspectMode)?.defaultKey == KeyEquivalent("i", [.command, .shift]))
        registry.perform(CollaborationFeatures.ID.inspectMode)
        #expect(inspect.isOn && world.window.toolManager.activeToolID == InspectTool.id)
        inspect.enter()
        // Hovering an object outlines it and measures to the page.
        let viewport = world.window.viewport
        let over = Point(x: page.rect.minX + 40, y: page.rect.minY + 35)
        let event = CanvasEvent(pasteboardPoint: over, viewPoint: viewport.toView(over))
        let tool = try #require(inspect.tool)
        tool.pointerMoved(event)
        #expect(inspect.overlay.state.shown.outline != nil && inspect.overlay.state.shown.lines.count == 4)
        // Click selects; hovering the other measures the gap.
        tool.mouseDown(event)
        tool.mouseDragged(event)
        tool.mouseUp(event)
        #expect(world.window.selection.selection.ids == [ids[0]])
        let other = Point(x: page.rect.minX + 120, y: page.rect.minY + 35)
        #expect(!inspect.measurements(at: CanvasEvent(pasteboardPoint: other, viewPoint: viewport.toView(other))).lines.isEmpty)
        let option = CanvasEvent(pasteboardPoint: over, viewPoint: viewport.toView(over), modifiers: .option)
        _ = inspect.measurements(at: option)
        tool.flagsChanged(CanvasEvent(pasteboardPoint: over, viewPoint: over, modifiers: .shift))
        #expect(inspect.overlay.frozen)
        tool.flagsChanged(event)
        tool.drawOverlay(in: bitmap(), viewport: viewport)
        tool.cancel()
        #expect(tool.cursor == .crosshair)
        // Nothing can be changed.
        let before = document.changeCount
        _ = await document.perform(OpsCommand("Delete", ops: [Ops.setDeleted(ids[0].opID)])).value
        await document.settle()
        #expect(document.changeCount == before && document.state.isLive(ids[0].opID) && inspect.refused == 1)
        #expect(throws: InspectModeError.readOnly) { var builder = ChangeBuilder(replica: 1, startCounter: 1); try InertCommand(label: "x").execute(&builder, state: EngineState()) }
        // Scrolling keeps the overlay in step; Esc leaves.
        world.window.canvas.setViewport(world.window.canvas.navigation.zoom(viewport, to: 2))
        #expect(inspect.overlay.viewport == world.window.canvas.viewport)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        #expect(tool.keyDown(key) && inspect.isOn)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                   characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(tool.keyDown(escape) && !inspect.isOn)
        inspect.leave()
        _ = await document.perform(OpsCommand("Delete", ops: [Ops.setDeleted(ids[0].opID)])).value
        await document.settle()
        #expect(!document.state.isLive(ids[0].opID))
        #expect(InspectModeController.format(for: .millimeters).unit == .millimeters && InspectModeController.format(for: .pixels).unit == .pixels)
        #expect(InspectModeController.format(for: .inches).unit == .inches && InspectModeController.format(for: .centimeters).unit == .centimeters)
        #expect(InspectModeController.format(for: .picas).unit == .points)
        let loose = InspectModeController(window: world.window)
        loose.window = nil
        loose.enter()
        loose.leave()
        #expect(loose.measurements(at: event) == .empty)
    }

    /// COLLAB-035's rest: undo and redo are inert in Inspect mode, a hovered path point reads out,
    /// and a viewer's window opens in Inspect mode.
    @Test func inspectModeLocksHistoryReadsPointsAndOpensForViewers() async throws {
        let world = CollaborationWorld()
        defer { world.close() }
        let document = world.document
        let page = document.pageList.pages[0]
        let ids = await document.addRectangles([Rect(x: page.rect.minX + 20, y: page.rect.minY + 20, width: 40, height: 30)])
        await document.settle()
        #expect(document.canUndo)
        let inspect = world.ui.inspect
        inspect.enter()
        #expect(!document.canUndo && document.historyLocked)
        #expect(await document.undo().value == nil && document.state.isLive(ids[0].opID))
        #expect(await document.redo().value == nil)
        // The rectangle's top-left corner under the pointer reads out as a point.
        let viewport = world.window.viewport
        let corner = Point(x: page.rect.minX + 20, y: page.rect.minY + 20)
        let measured = inspect.measurements(at: CanvasEvent(pasteboardPoint: corner, viewPoint: viewport.toView(corner)))
        #expect(measured.point.map { $0.distance(to: corner) < 0.01 } == true)
        let middle = Point(x: page.rect.minX + 40, y: page.rect.minY + 35)
        #expect(inspect.measurements(at: CanvasEvent(pasteboardPoint: middle, viewPoint: viewport.toView(middle))).point == nil)
        inspect.leave()
        #expect(document.canUndo && !document.historyLocked)
        // A viewer's window opens in Inspect mode; an editor's does not.
        let viewer = CollaborationWorld()
        defer { viewer.close() }
        viewer.features.role = { _ in .viewer }
        #expect(viewer.ui.inspect.isOn)
        let editor = CollaborationWorld()
        defer { editor.close() }
        editor.features.role = { _ in .editor }
        #expect(!editor.ui.inspect.isOn)
        #expect(InspectPoints.anchor(of: OpID(counter: 999, replica: 9), near: corner, tolerance: 1, in: document.state) == nil)
    }

    // MARK: Windows and the review sheet

    @Test func eachWindowGetsItsPopupAndTheAccessBarOnceConnected() async throws {
        let world = CollaborationWorld()
        let offer = FakeAccessOffer()
        let offered = TestBox(false)
        world.features.accessOffer = { _ in offered.value ? offer : nil }
        let ui = world.ui
        #expect(ui.popup != nil && ui.access == nil && world.features.front === ui)
        offered.value = true
        ui.attachAccess(features: world.features)
        #expect(ui.access != nil)
        ui.attachAccess(features: world.features)
        world.close()
        world.features.detach(world.window)
        // The app's default offer needs a connected session.
        #expect(CollaborationFeatures().accessOffer(world.window) == nil)
    }

    @Test func theReviewSheetKeepsChangesOnABranchOnThisMac() async throws {
        let document = DocumentHandle.memory(title: "Logo")
        let harness = ReviewHarness()
        var context = harness.context(document, work: .some(nil))
        #expect(ReviewSheetModel(review: heldReview(OpID(counter: 1, replica: 1)), merged: document.state, context: context).unavailableReason(.keepBranch) != nil)
        let kept = TestBox<[String]>([])
        let fails = TestBox(false)
        context.keepOnBranch = { name in
            if fails.value { throw BranchError.noStore }
            kept.value.append(name)
            return "branch-1"
        }
        let model = ReviewSheetModel(review: heldReview(OpID(counter: 1, replica: 1)), merged: document.state, context: context)
        #expect(model.unavailableReason(.keepBranch) == nil && model.unavailableReason(.keepMerged) == nil && model.unavailableReason(.saveCopy) != nil)
        Render.view(ReviewSheetView(model: model))
        fails.value = true
        await model.run(.keepBranch)
        #expect(model.message?.hasPrefix("Your changes could not be kept") == true)
        fails.value = false
        await model.run(.keepBranch)
        #expect(kept.value == ["Sam's offline edits"] && harness.resolutions == [.discardLocalChanges] && harness.opened == ["branch-1 Sam's offline edits"])
    }
}

/// `BranchService` messages for the gRPC client's routes.
enum BranchMessages {
    @Sendable
    static func branch(_ id: String, _ name: String, _ state: Wiretuner_Docs_V1_BranchState = .active) -> Wiretuner_Docs_V1_Branch {
        Wiretuner_Docs_V1_Branch.with {
            $0.branchDocumentID = id
            $0.parentDocumentID = "p"
            $0.name = name
            $0.state = state
            $0.lastAuthorDisplayName = "Priya"
            $0.lastChangeAt = .init(date: Date(timeIntervalSince1970: 1_000))
        }
    }
}

/// One version to list.
struct OneVersion: VersionListing {
    func versions(of document: String) async throws -> [VersionInfo] { [VersionInfo(id: "v", name: "V", serverSeq: 2)] }
}

/// Asserts that `body` throws.
@MainActor
func expectThrows(_ body: @MainActor () async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
        try await body()
        Issue.record("expected a throw", sourceLocation: sourceLocation)
    } catch {}
}
