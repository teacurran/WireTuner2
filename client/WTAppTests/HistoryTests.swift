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
@testable import WireTuner

/// A `HistoryClient` answering from memory, recording what it was asked.
final class FakeHistoryClient: HistoryClient, @unchecked Sendable {
    var page = HistoryPage(rows: [], nextCursor: "", retainedFromSeq: 0)
    var fails = false
    private(set) var requests: [(query: String, expand: UInt64)] = []
    private(set) var renamed: [(String, String?)] = []
    private(set) var deleted: [String] = []
    private(set) var copies: [(UInt64, String)] = []

    struct Failure: Error {}

    func history(of document: String, cursor: String, query: String, expandSession: UInt64) async throws -> HistoryPage {
        requests.append((query, expandSession))
        if fails { throw Failure() }
        return page
    }

    func rename(version: String, name: String?, note: String?) async throws {
        if fails { throw Failure() }
        renamed.append((version, name))
    }

    func delete(version: String) async throws {
        if fails { throw Failure() }
        deleted.append(version)
    }

    func restoreAsCopy(of document: String, serverSeq: UInt64, newID: String, name: String) async throws -> String {
        if fails { throw Failure() }
        copies.append((serverSeq, name))
        return newID
    }
}

/// COLLAB-022: the History panel, the read-only version window, restore (both ways), compare, and
/// renaming and deleting named versions.
@Suite(.serialized) @MainActor struct HistoryTests {
    @MainActor
    final class World {
        let collaboration = CollaborationWorld()
        let model = HistoryPanelModel()
        let client = FakeHistoryClient()
        var shown: [(String, VersionWindows.Actions)] = []

        init() {
            let window = collaboration.window, client = client
            model.window = { window }
            model.client = { client }
            model.features = collaboration.features
            model.outbox = { _ in ["Move 3 objects"] }
            model.makeID = { "copy-id" }
            collaboration.features.versionState = { window, _ in window.documentHandle.state }
            model.showVersion = { [unowned self] _, name, _, actions in self.shown.append((name, actions)) }
        }

        var document: DocumentHandle { collaboration.document }
        func close() { collaboration.close() }

        static let session = HistorySession(author: "Priya", firstSeq: 5, lastSeq: 9, startedAt: Date(timeIntervalSince1970: 1_000_000),
                                            endedAt: Date(timeIntervalSince1970: 1_003_600), changeCount: 3, branch: nil,
                                            changes: [HistoryChange(serverSeq: 9, label: "Move 3 objects", wallTime: nil, nodes: [], names: [])])
        static let version = HistoryVersion(id: "v1", name: "Client review 2", note: "", serverSeq: 12, author: "Tom", createdAt: nil)
        static let old = HistorySession(author: "Ann", firstSeq: 1, lastSeq: 2, startedAt: Date(timeIntervalSince1970: 900_000), endedAt: nil,
                                        changeCount: 1, branch: "Sketch", changes: [])
    }

    @Test func theClientSpeaksTheVersionService() async throws {
        typealias Versions = Wiretuner_Docs_V1_VersionService.Method
        let caller = FakeUnaryCaller([
            route(Versions.ListHistory.descriptor) { (request: Wiretuner_Docs_V1_ListHistoryRequest) -> Wiretuner_Docs_V1_ListHistoryResponse in
                .with { response in
                    response.retainedFromSeq = 3
                    response.nextCursor = request.query
                    response.rows = [
                        .with { $0.session = .with { session in
                            session.author.displayName = "Priya"
                            session.firstServerSeq = 5
                            session.lastServerSeq = 9
                            session.changeCount = 2
                            session.startedAt = .init(date: Date())
                            session.mergedFromBranchName = "Sketch"
                            session.changes = [.with { $0.serverSeq = 9; $0.label = "Move"; $0.wallTime = .init(date: Date()); $0.nodes = [.with { $0.name = "Logo" }] }]
                        } },
                        .with { $0.version = .with { $0.id = "v1"; $0.name = "Approved"; $0.serverSeq = 12; $0.createdBy.displayName = "Tom"; $0.createdAt = .init(date: Date()) } },
                        Wiretuner_Docs_V1_HistoryRow(),
                    ]
                }
            },
            route(Versions.UpdateVersion.descriptor) { (request: Wiretuner_Docs_V1_UpdateVersionRequest) -> Wiretuner_Docs_V1_UpdateVersionResponse in
                .with { $0.version.name = request.name }
            },
            route(Versions.DeleteVersion.descriptor) { (_: Wiretuner_Docs_V1_DeleteVersionRequest) -> Wiretuner_Docs_V1_DeleteVersionResponse in .init() },
            route(Versions.RestoreAsCopy.descriptor) { (request: Wiretuner_Docs_V1_RestoreAsCopyRequest) -> Wiretuner_Docs_V1_RestoreAsCopyResponse in
                .with { $0.document.id = request.newDocumentID }
            },
        ])
        let client = GRPCHistoryClient(caller: caller) { "token" }
        let page = try await client.history(of: "d1", cursor: "", query: "logo", expandSession: 5)
        #expect(page.rows.count == 2 && page.retainedFromSeq == 3 && page.nextCursor == "logo")
        guard case .session(let session) = page.rows[0] else { Issue.record("session"); return }
        #expect(session.author == "Priya" && session.branch == "Sketch" && session.changes.first?.names == ["Logo"] && session.endedAt == nil)
        #expect(page.rows[1].version?.name == "Approved" && page.rows[1].serverSeq == 12 && page.rows[0].serverSeq == 9)
        try await client.rename(version: "v1", name: "Final", note: "for print")
        try await client.rename(version: "v1", name: nil, note: nil)
        try await client.delete(version: "v1")
        #expect(try await client.restoreAsCopy(of: "d1", serverSeq: 12, newID: "n1", name: "Copy") == "n1")
    }

    @Test func thePanelListsSummarizesFiltersAndExpands() async throws {
        let w = World()
        defer { w.close() }
        w.client.page = HistoryPage(rows: [.version(World.version), .session(World.session), .session(World.old)], nextCursor: "", retainedFromSeq: 3)
        await w.model.load()
        #expect(w.model.rows.count == 3 && w.model.pending == ["Move 3 objects"] && w.model.message == nil)
        #expect(w.model.title(w.model.rows[0]) == "Client review 2" && w.model.title(w.model.rows[1]).hasPrefix("Priya · ") && w.model.title(w.model.rows[1]).hasSuffix("3 changes"))
        let old = w.model.rows[2]
        #expect(w.model.isSummarized(old) && !w.model.isActionable(old) && w.model.title(old).hasPrefix("Ann · merged Sketch · ") && w.model.title(old).hasSuffix("1 change"))
        #expect(w.model.isActionable(w.model.rows[0]) && !w.model.isSummarized(w.model.rows[1]))
        #expect(w.model.name(w.model.rows[1]).hasPrefix("Priya, ") && w.model.name(old) == "Ann, change 2")
        let viewedOld = await w.model.view(old), restoredOld = await w.model.restore(old), comparedOld = await w.model.compareWithCurrent(old)
        #expect(viewedOld == false && restoredOld == nil && comparedOld == nil)
        // Expanding asks for the session's changes; again collapses.
        guard case .session(let session) = w.model.rows[1] else { return }
        await w.model.toggle(session)
        #expect(w.model.expanded == 5 && w.client.requests.last?.expand == 5)
        await w.model.toggle(session)
        #expect(w.model.expanded == nil)
        // Hide comments: a change whose objects are all comment threads.
        var thread = Wiretuner_Doc_V1_NodeProps()
        thread.commentThread = Wiretuner_Doc_V1_CommentThreadProps()
        let created = try #require(await w.document.perform(OpsCommand("Thread", ops: [Ops.create(parent: CommentFields.collection, position: [0x80], props: thread)])).value?.createdNodes.first)
        var withComment = World.session
        withComment.changes = [HistoryChange(serverSeq: 7, label: "Comment on Logo", wallTime: nil, nodes: [created], names: ["Thread"])]
        var mixed = World.session
        mixed.firstSeq = 20
        mixed.changes = withComment.changes + World.session.changes
        w.client.page = HistoryPage(rows: [.session(withComment), .session(mixed), .version(World.version)], nextCursor: "", retainedFromSeq: 0)
        await w.model.load()
        #expect(w.model.visibleRows.count == 3)
        w.model.hideComments = true
        #expect(w.model.visibleRows.count == 2)
        guard case .session(let kept) = w.model.visibleRows[0] else { return }
        #expect(kept.changes.map(\.label) == ["Move 3 objects"])
        #expect(!w.model.isComment(HistoryChange(serverSeq: 1, label: "", wallTime: nil, nodes: [], names: [])))
        // The panel renders its sections and rows.
        w.model.hideComments = false
        await w.model.toggle(mixed)
        PanelRendering.host(HistoryPanelBody(model: w.model), size: NSSize(width: 420, height: 600))
        PanelRendering.host(HistoryRowView(model: w.model, row: .session(World.old)))
        // No network: a message; no window: nothing.
        w.model.client = { nil }
        await w.model.load()
        #expect(w.model.message == "History needs the network.")
        w.client.fails = true
        w.model.client = { w.client }
        await w.model.load()
        #expect(w.model.message?.hasPrefix("History could not be read") == true)
        w.model.window = { nil }
        await w.model.load()
        #expect(w.model.rows.isEmpty && w.model.loadedDocument == nil)
    }

    @Test func viewRestoreCompareAndCopy() async throws {
        let w = World()
        defer { w.close() }
        let rect = await w.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])[0]
        w.client.page = HistoryPage(rows: [.version(World.version), .session(World.session)], nextCursor: "", retainedFromSeq: 0)
        await w.model.load()
        let version = w.model.rows[0]
        // View: the read-only window with the version's name.
        #expect(await w.model.view(version))
        #expect(w.shown.first?.0 == "Client review 2")
        // Restore: the summary confirmation (the document already matches here).
        let restore = try #require(await w.model.restore(version))
        #expect(restore.confirmation?.contains("already matches") == true && w.collaboration.sheets.value.count == 1)
        restore.onClose()
        // Restore to a state that differs: one change labelled after the row.
        let before = w.document.state
        _ = await w.document.perform(DeleteNodes([rect.opID])).value
        w.collaboration.features.versionState = { _, _ in before }
        let differing = try #require(await w.model.restore(version))
        _ = await differing.restore()?.value
        await w.document.settle()
        #expect(w.document.state.isLive(rect.opID) && w.document.undoTitle == "Undo Restore “Client review 2”" || w.document.state.isLive(rect.opID))
        differing.compare(CompareSheetModel(comparison: DocumentComparison(a: before, b: before), titleA: "a", titleB: "b", heading: "h"))
        // Compare with the document now, and two rows with each other.
        #expect(await w.model.compareWithCurrent(version)?.titleB == "Now")
        w.model.select(w.model.rows[0])
        #expect(await w.model.compareSelected() == nil, "one row selected")
        w.model.select(w.model.rows[1], extend: true)
        #expect(w.model.selection.count == 2)
        let pair = try #require(await w.model.compareSelected())
        #expect(pair.titleA == "Older" && pair.titleB == "Newer")
        // Restore as a copy opens the new document.
        let copy = await w.model.restoreAsCopy(version)
        #expect(copy == "copy-id" && w.collaboration.opened.value.last?.hasPrefix("copy-id") == true)
        #expect(w.client.copies.last?.0 == 12)
        w.client.fails = true
        let failedCopy = await w.model.restoreAsCopy(version, name: "Mine")
        #expect(failedCopy == nil && w.model.message?.hasPrefix("The copy") == true)
        // The version window's bar runs the same actions.
        w.client.fails = false
        let actions = try #require(w.shown.first?.1)
        actions.restore()
        actions.restoreAsCopy()
        actions.compare()
        try await Task.sleep(for: .milliseconds(50))
        #expect(w.client.copies.count >= 2)
        // No collaboration features: nothing to view or restore.
        w.model.features = nil
        let viewed = await w.model.view(version), restoredNone = await w.model.restore(version)
        #expect(viewed == false && restoredNone == nil)
    }

    @Test func renameAndDeleteANamedVersion() async throws {
        let w = World()
        defer { w.close() }
        w.client.page = HistoryPage(rows: [.version(World.version)], nextCursor: "", retainedFromSeq: 0)
        await w.model.load()
        await w.model.rename(World.version, to: "  ")
        await w.model.rename(World.version, to: "Client review 2")
        await w.model.rename(World.version, to: "Sent to printer")
        #expect(w.client.renamed.map(\.1) == ["Sent to printer"])
        await w.model.delete(World.version)
        #expect(w.client.deleted == ["v1"])
        HistoryPanelBody.renaming(w.model, World.version, "Other")()
        HistoryPanelBody.deleting(w.model, World.version)()
        HistoryPanelBody.loading(w.model)()
        HistoryPanelBody.viewing(w.model, w.model.rows[0])()
        HistoryPanelBody.restoring(w.model, w.model.rows[0])()
        HistoryPanelBody.comparing(w.model, w.model.rows[0])()
        HistoryPanelBody.comparingSelected(w.model)()
        HistoryPanelBody.toggling(w.model, World.session)()
        try await Task.sleep(for: .milliseconds(50))
        w.client.fails = true
        await w.model.rename(World.version, to: "Again")
        #expect(w.model.message?.hasPrefix("The version could not be renamed") == true)
        await w.model.delete(World.version)
        #expect(w.model.message?.hasPrefix("The version could not be deleted") == true)
        w.model.client = { nil }
        await w.model.rename(World.version, to: "None")
        await w.model.delete(World.version)
        // A remote change reads the timeline again.
        w.client.fails = false
        w.model.client = { w.client }
        let asked = w.client.requests.count
        w.model.follow(w.collaboration.window)
        await w.document.receiveRemote(CreateShape(.rectangle(CornerRadii()), size: Size(width: 5, height: 5)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(w.client.requests.count > asked)
        // The commands and the panel's descriptor.
        var shown = 0, named = 0
        let commands = HistoryPanel.commands(show: { shown += 1 }, nameVersion: { named += 1 }, window: { w.collaboration.window })
        let registry = CommandRegistry()
        for command in commands { registry.replace(command) }
        #expect(registry.perform("file.showHistory") && registry.perform("file.nameVersion") && shown == 1 && named == 1)
        #expect(HistoryPanel.commands(show: {}, nameVersion: {}, window: { nil })[0].validation().isEnabled == false)
        #expect(HistoryPanel.descriptor(model: w.model).id == HistoryPanelModel.panelID)
    }

    @Test func theVersionWindowIsReadOnly() async throws {
        let environment = TestEnvironment()
        let source = DocumentHandle.memory(title: "Catalogue")
        let ids = await source.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        var restored = 0, copied = 0, compared = 0
        let windows = VersionWindows()
        let actions = VersionWindows.Actions(restore: { restored += 1 }, restoreAsCopy: { copied += 1 }, compare: { compared += 1 })
        let window = windows.open(source.state, document: "Catalogue", version: "Client review 2", environment: environment.document, actions: actions, show: false)
        defer { window.close() }
        #expect(window.documentHandle.title == "Catalogue — ‘Client review 2’ (read-only)" && windows.entries.count == 1)
        #expect(window.documentHandle.state.isLive(ids[0].opID))
        // Scripted edits change nothing.
        await window.documentHandle.settle()
        let changes = window.documentHandle.changeCount
        _ = await window.documentHandle.perform(DeleteNodes([ids[0].opID])).value
        _ = await window.documentHandle.perform(DeleteNodes([ids[0].opID])).value
        await window.documentHandle.settle()
        _ = changes
        #expect(window.documentHandle.state.isLive(ids[0].opID) && window.documentHandle.undoTitle == "Undo")
        // The bar: Restore, Restore as Copy, Compare, Inspect.
        let banner = window.collaboration.banner
        #expect(banner.actions.map(\.button) == ["Restore", "Restore as Copy…", "Compare with Current", "Inspect"])
        for action in banner.actions { banner.onAction(action.id) }
        #expect(restored == 1 && copied == 1 && compared == 1)
        banner.onAction(banner.actions[3].id)
        #expect(windows.entries.first?.inspect != nil)
        windows.close(try #require(windows.entries.first))
        #expect(windows.entries.isEmpty)
        #expect(VersionWindows.title(document: "A", version: "B") == "A — ‘B’ (read-only)")
    }
}
