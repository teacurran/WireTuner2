import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// DOC-012: the master page tab and the master notices.
@Suite(.serialized) @MainActor struct MasterTabTests {
    /// A window whose page 1 follows a new master; returns the master.
    static func childPage(_ world: GlueWorld) async throws -> OpID {
        let page = world.document.activePage.id
        let master = try #require(await world.document.perform(NewMasterPage(from: page)).value?.createdObjects.first)
        _ = await world.document.perform(ApplyMasterPage(master, to: [page])).value
        await world.document.settle()
        return master
    }

    static func square(_ rect: Rect) -> CreateShape {
        CreateShape(.rectangle(CornerRadii()), size: Size(width: rect.width, height: rect.height), transform: .translation(x: rect.minX, y: rect.minY),
                    appearance: TestAppearance.filled)
    }

    @Test func theEditButtonOpensTheMasterInItsTabWhichDrawsOnTheMaster() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let tabs = MasterTabs()
        #expect(MasterTabs.editableMaster(in: world.window) == nil, "page 1 follows no master")
        #expect(tabs.open(OpID(counter: 99, replica: 9), from: world.window) == nil, "not a master")
        let master = try await Self.childPage(world)
        #expect(MasterTabs.editableMaster(in: world.window) == master)
        DocumentPanelModel.editMaster = { window, master in tabs.open(master, from: window) }
        defer { DocumentPanelModel.editMaster = { _, _ in } }
        let model = DocumentPanelModel(window: world.window)
        Render.view(DocumentPanelControls(model: model, state: DocumentPanelState()))
        DocumentPanelControls.editMaster(model)()
        let tab = try #require(tabs.tabs.values.first)
        defer { tab.window?.close() }
        #expect(tab.documentHandle.canvasNode == master && tab.documentHandle.masterCanvasNode == master)
        #expect(tab.documentHandle.glyphCanvasNode == nil && world.document.glyphCanvasNode == nil && world.document.masterCanvasNode == nil)
        #expect(tab.documentHandle.id == MasterCanvas.tabID(document: world.document.id, master: master) && MasterCanvas.isTab(tab.documentHandle.id))
        #expect(GlyphCanvas.documentID(ofTab: tab.documentHandle.id) == world.document.id)
        #expect(tab.window?.title == "Master 1" && tab.statusBar.pageField.isHidden && tab.statusBar.addPage.isHidden)
        #expect(!tab.isPrimaryView && tabs.documentWindow(of: tab) === tab, "outside the app its own window is the document's")
        #expect(tab.session == nil && tab.environment.makePresence(tab.documentHandle) === world.window.presence)
        #expect(tab.environment.makeSyncStatus(tab.documentHandle) === world.window.syncStatus && tab.environment.session(tab.documentHandle) == nil)
        tab.environment.documentDidClose(tab.documentHandle)
        #expect(tabs.open(master, from: world.window) === tab, "one tab per master")
        // What is drawn on the tab lands on the master's canvas.
        let square = try #require(await tab.documentHandle.perform(Self.square(Rect(x: 10, y: 10, width: 30, height: 30))).value?.createdObjects.first)
        await world.document.settle()
        #expect(CanvasMembership.placement(of: square, in: world.state) == .canvas(master))
        #expect(MasterContent.objects(of: master, in: world.state).flatMap(\.objects) == [square])
        #expect(!MasterCanvas.background(of: master, in: world.state).isEmpty)
        #expect(MasterCanvas.frame(of: master, in: world.state)?.rect == Rect(x: 0, y: 0, width: 612, height: 792))
        // Renamed: the tab follows; deleted: it closes.
        _ = await world.document.perform(RenamePage(master, to: "Cover", in: world.state)).value
        await world.document.settle()
        #expect(tab.documentHandle.title == "Cover")
        _ = await world.document.perform(DeleteMasterPage(master)).value
        await world.document.settle()
        #expect(tabs.tabs.isEmpty && MasterCanvas.frame(of: master, in: world.state) == nil && MasterCanvas.background(of: master, in: world.state).isEmpty)
        tabs.forget(tab)
        #expect(MasterCanvas.name(of: OpID(counter: 99, replica: 9), in: world.state) == "Master")
    }

    @Test func aClosedTabIsForgotten() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let tabs = MasterTabs()
        let master = try await Self.childPage(world)
        let tab = try #require(tabs.open(master, from: world.window))
        tab.window?.close()
        #expect(tabs.tabs.isEmpty)
        // Without an open model nothing opens.
        let failing = DocumentHandle(title: "Pending") { () async throws -> WTModel.Document in throw CancellationError() }
        let pending = DocumentWindowController(document: failing, environment: world.setup.environment.document)
        defer { pending.close() }
        #expect(tabs.open(master, from: pending) == nil)
    }

    @Test func aStaleReleaseOffersToUpdateTheCopies() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let master = try await Self.childPage(world)
        let page = world.document.activePage.id
        let tab = try #require(MasterTabs().open(master, from: world.window))
        _ = await tab.documentHandle.perform(Self.square(Rect(x: 0, y: 0, width: 20, height: 20))).value
        tab.window?.close()
        let notices = MasterNotices(window: world.window)
        defer { notices.stop() }
        let now = TestBox(Date())
        notices.clock = { now.value }
        _ = await world.editing.perform(ReleaseChildPages([page], in: world.state)).value
        await world.document.settle()
        let release = try #require(notices.releases.first?.release)
        #expect(release.page == page && release.master == master && release.groups.count == 1)
        // Someone else draws on the master: the notice.
        let remote = try #require(await world.document.receiveRemote(CanvasPlacedCommand(base: Self.square(Rect(x: 30, y: 30, width: 10, height: 10)), canvas: master)))
        #expect(MasterRelease.writes(remote, on: master, state: world.state))
        let notice = try #require(world.window.pageNotices.notices.last)
        #expect(notice.text == MasterNotices.staleText(author: "Someone", master: "Master 1", page: 1) && notice.action == MasterNotices.updateCopies)
        #expect(notices.releases.isEmpty, "one notice per release")
        world.window.performNotice(notice.id)
        await world.document.settle()
        #expect(!world.state.isLive(release.groups[0]), "the stale copies go")
        let layer = try #require(LayerOrder(world.state).drawingLayer)
        let copies = world.state.liveChildren(layer).filter { world.state.props($0).group.common.name == "Released master content" }
        #expect(copies.count == 1 && world.state.liveChildren(copies[0]).count == 2, "the current master's two objects")
        #expect(world.document.undoTitle == "Undo Update the copies")
        // A release long ago is forgotten; a remote change elsewhere posts nothing.
        let second = try await Self.childPage(world)
        _ = await world.editing.perform(ReleaseChildPages([page], in: world.state)).value
        await world.document.settle()
        now.value += MasterNotices.recent + 1
        #expect(await world.document.receiveRemote(CanvasPlacedCommand(base: Self.square(Rect(x: 0, y: 0, width: 5, height: 5)), canvas: second)) != nil)
        #expect(notices.releases.isEmpty)
        let count = world.window.pageNotices.notices.count
        _ = await world.document.receiveRemote(Self.square(Rect(x: 0, y: 0, width: 5, height: 5)))
        #expect(world.window.pageNotices.notices.count == count)
        #expect(MasterRelease.releases(in: remote, state: world.state).isEmpty && MasterRelease.canvas(of: OpID(counter: 99, replica: 9), in: world.state) == nil)
        #expect(MasterRelease.target(Wiretuner_Doc_V1_Op(), OpID(counter: 1, replica: 1)) == nil)
        // Every kind of op names the node it writes.
        let node = OpID(counter: 7, replica: 7), id = node.proto
        let ops: [Wiretuner_Doc_V1_Op] = [
            .with { $0.set = .with { $0.node = id } }, .with { $0.move = .with { $0.node = id } }, .with { $0.setDeleted = .with { $0.node = id } },
            .with { $0.elementInsert = .with { $0.node = id } }, .with { $0.elementMove = .with { $0.node = id } },
            .with { $0.elementDelete = .with { $0.node = id } }, .with { $0.textInsert = .with { $0.node = id } },
            .with { $0.textDelete = .with { $0.node = id } }, .with { $0.textMark = .with { $0.node = id } },
        ]
        #expect(ops.allSatisfy { MasterRelease.target($0, OpID(counter: 1, replica: 1)) == node })
    }

    @Test func aDeletedMasterThatPagesFollowOffersRestore() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let master = try await Self.childPage(world)
        let notices = MasterNotices(window: world.window)
        defer { notices.stop() }
        _ = await world.document.receiveRemote(DeleteMasterPage(master))
        let notice = try #require(world.window.pageNotices.notices.last)
        #expect(notice.text == "Someone deleted Master 1; 1 page is an ordinary page now" && notice.action == "Restore")
        world.window.performNotice(notice.id)
        await world.document.settle()
        #expect(world.state.isLive(master))
        #expect(MasterNotices.deletedText(author: "Tom", master: "A", pages: 2) == "Tom deleted A; 2 pages are ordinary pages now")
        // A master nobody follows goes quietly.
        let unused = try #require(await world.document.perform(NewMasterPage()).value?.createdObjects.first)
        let count = world.window.pageNotices.notices.count
        let square = try #require(await world.document.addRectangles([Rect(x: 0, y: 0, width: 5, height: 5)]).first)
        _ = await world.document.receiveRemote(ClearObjects([square.opID]))
        _ = await world.document.receiveRemote(DeleteMasterPage(unused))
        #expect(world.window.pageNotices.notices.count == count && MasterNotices.followers(of: unused, in: world.state) == 0)
    }
}
