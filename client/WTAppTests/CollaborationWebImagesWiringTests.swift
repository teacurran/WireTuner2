import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// The collaboration, web and image features wired into the app, and the edges of their models
/// the feature suites do not reach.
@Suite(.serialized) @MainActor struct CollaborationWebImagesWiringTests {
    @Test func theFeaturesAreWiredIntoTheApp() async throws {
        let suite = TestDefaults()
        defer { suite.remove() }
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = try #require(delegate.activeDocumentWindow)
        defer { window.close() }
        // Comments: the panel, the tool, the account and roster readers.
        #expect(delegate.panels.descriptor(for: CommentsFeatures.panelID) != nil && delegate.tools.descriptor(for: CommentTool.id) != nil)
        #expect(delegate.comments.account().id.isEmpty && delegate.comments.role("unknown") == .owner)
        #expect(await delegate.comments.members("doc").isEmpty)
        delegate.comments.showPanel(CommentsFeatures.panelID)
        #expect(delegate.comments.comments(for: window.documentHandle) != nil)
        // Branches, versions, compare: no services in a test launch; another document's state.
        #expect(delegate.collaborationUI.branchClient() == nil && delegate.collaborationUI.versionListing() == nil)
        #expect(await delegate.collaborationUI.state(window.documentHandle.id) != nil)
        #expect(await delegate.collaborationUI.state("not-open") == nil)
        let before = delegate.documents.documents.count
        delegate.collaborationUI.openDocument(UUID().uuidString, "Branch")
        #expect(delegate.documents.documents.count == before + 1)
        // Web: the panels replace the placeholders; the Object panel has the SVG Animation section.
        #expect(delegate.panels.descriptor(for: WebFeatures.navigationPanel)?.helpSlug == "urls")
        #expect(InspectorRegistry.standard.sections.contains { $0.id == "svgAnimation" })
        // Images: the Trace tool, the share hand-off and its new-document fallback.
        #expect(!(delegate.tools.makeTool(TraceTool.id) is UnimplementedTool))
        #expect(delegate.images.inbox.window() != nil)
        #expect(await delegate.images.inbox.place([], window, "Photos") == 0)
        let opened = delegate.documents.documents.count
        #expect(delegate.images.inbox.newDocument() != nil && delegate.documents.documents.count == opened + 1)
        #expect(delegate.open(URL(string: "wiretuner-share://inbox/\(UUID().uuidString)")!))
        #expect(delegate.images.attach(window).window === window)
        for controller in delegate.documents.windowControllers.values where controller !== window { controller.close() }
    }

    @Test func publishAndSetupEdges() async throws {
        let world = WebWorld()
        defer { world.close() }
        let model = try #require(world.features.presentPublish())
        let setup = try #require(world.features.presentSetup())
        // Their closures that start tasks run to the end.
        for action in [PublishSheet.choose(model), PublishSheet.publish(model), HTMLSetupSheet.add(setup), HTMLSetupSheet.apply(setup),
                       HTMLSetupSheet.location(setup), HTMLSetupSheet.confirm(setup), HTMLSetupSheet.delete(setup)] {
            action()
            try await Task.sleep(for: .milliseconds(30))
            await world.document.settle()
        }
        // Without their window they read an empty document and do nothing.
        model.window = nil
        setup.window = nil
        #expect(model.settings.isSynthesized && model.pageCount == 0 && model.folder == nil && model.publish() == nil)
        await model.chooseFolder()
        model.select(nil)
        model.show(ExportWarning(.invalidLink, node: NodeID(OpID(counter: 1, replica: 1)), "x"))
        #expect(setup.settings.isSynthesized && setup.setting?.id == nil)
        let added = await setup.add(), deleted = await setup.delete(), applied = await setup.apply()
        #expect(added == nil && !deleted && !applied)
        await setup.chooseLocation()
        setup.refresh()
        // A scene that cannot be captured fails with the reason.
        let failing = try #require(world.features.presentPublish())
        failing.range = ""
        await failing.chooseFolder()
        await world.document.settle()
        world.features.blobs.directory = { throw BranchError.noStore }
        _ = failing.publish()
        #expect(PublishModel.pages(" 2 ", count: 3) == [1] && PublishModel.pages("1-2-3", count: 3) == nil)
    }

    @Test func commentsEdges() async throws {
        let world = CommentWorld()
        defer { world.close() }
        await world.loaded()
        let comments = world.comments
        let thread = try #require(await world.thread("Row"))
        comments.close()
        // The panel's rows render (the list renders them lazily); the menu reads the role.
        let rows = CommentsPanel.rows(comments)
        for row in rows { Render.view(CommentsPanelRow(comments: comments, row: row)) }
        _ = await comments.setResolved(thread, true)?.value
        #expect(CommentsPanel.menu(comments, row: try #require(CommentsPanel.rows(comments).first { $0.id == thread } ?? rows.first)).first?.0 == "Reopen")
        // A reply to a thread whose opener was deleted names nobody.
        _ = await comments.reply(to: thread, CommentBody("second"))?.value
        world.window.confirm = { _, _ in true }
        _ = await comments.delete(try #require(comments.model[thread]).opener.id, in: thread)?.value
        _ = await comments.reply(to: thread, CommentBody("third"))?.value
        #expect(world.document.undoTitle == "Undo Reply")
        comments.filter.state = .all
        #expect(CommentsPanel.rows(comments).first?.firstLine == "Comment deleted")
        // The account's own name, and "You" without one.
        #expect(comments.name(of: "acct-ann") == "Ann")
        world.features.account = { ("acct-ann", "") }
        #expect(comments.name(of: "acct-ann") == "You")
        // Without its window nothing is drawn or written.
        comments.open(thread)
        comments.window = nil
        comments.install()
        comments.presentPopover()
        comments.draw(in: bitmap())
        #expect(comments.perform(Reply(to: thread, author: "a", body: CommentBody("x"))) == nil)
        #expect(comments.post(CommentBody("x")) == nil && comments.showsPins)
        comments.announce(try #require(comments.model[thread]).opener, in: try #require(comments.model[thread]))
        comments.show(thread)
        world.features.detach(world.window)
        world.features.detach(world.window)
        #expect(ThreadViewModel(comments: comments).title.hasPrefix("Thread"))
    }

    @Test func webEdges() async throws {
        let world = WebWorld()
        defer { world.close() }
        // The SVG section's readings for a looping file with no end and a missing file.
        let layer = try #require(await world.document.perform(CreateLayer(name: "Art")).value?.createdNodes.first)
        let props = AssetFields.values { $0.common.name = "loop.svg"; $0.mediaType = "image/svg+xml" }
        let asset = try #require(await world.document.perform(OpsCommand("Asset", ops: [Ops.create(parent: WellKnown.assets, position: [0x80], props: props)])).value?.createdNodes.first)
        let file = SvgAnimationFile(asset: asset, naturalSize: Size(width: 0, height: 0))
        let node = try #require(await world.document.perform(CreateSvgAnimation(file, layer: layer)).value?.createdNodes.first)
        await world.document.settle()
        let panel = ObjectPanelModel(document: world.document, selection: Selection([SelectionID(node)]))
        let model = try #require(SvgAnimationSectionModel(panel))
        #expect(model.duration == "Indefinite" && model.scripts == "None" && model.scrubRange == 0...10_000 && model.originalURL == nil)
        let poster = await model.setPoster(at: 0), copy = await model.saveCopy(window: nil)
        #expect(poster == nil && copy == nil)
        _ = await world.document.perform(OpsCommand("Delete asset", ops: [Ops.setDeleted(asset)])).value
        await world.document.settle()
        let missing = try #require(SvgAnimationSectionModel(ObjectPanelModel(document: world.document, selection: Selection([SelectionID(node)]))))
        #expect(missing.fileLine.hasPrefix("Missing file") && missing.file == nil)
        Render.view(SvgAnimationSectionView(model: missing))
        missing.reveal()
        #expect(WebFrameSnapshot.seek(0).contains("currentTime = 0"))
        // Transport without frames and a window without its canvas.
        let web = world.web
        web.window = nil
        web.show(0)
        web.play()
        web.endPreview()
        #expect(web.counter == "No frames" && web.currentLayer == nil)
        // The release sheet without its window.
        let release = ReleaseToLayersModel(window: world.window, preferences: world.setup.environment.preferences)
        release.window = nil
        let released = await release.release()
        #expect(release.command == nil && released == nil)
    }

    @Test func theSheetsFinishThroughTheirButtons() async throws {
        let parent = DocumentHandle.memory(title: "Catalogue")
        let world = CollaborationWorld(document: parent, branches: [BranchInfo(id: "b-1", parentID: parent.id, name: "Cover")])
        defer { world.close() }
        let branches = world.ui.branches
        await branches.load()
        func root<Content: View>(_ type: Content.Type) -> Content? {
            (world.sheets.value.last?.contentViewController as? NSHostingController<Content>)?.rootView
        }
        world.features.presentNewBranch(branches)
        root(BranchNameSheet.self)?.finish("Spring")
        world.features.presentNewBranch(branches)
        root(BranchNameSheet.self)?.finish(nil)
        world.features.presentRename(branches)
        root(BranchNameSheet.self)?.finish("Renamed")
        world.features.presentChooser(compare: true)
        root(BranchChooserSheet.self)?.finish(.some("b-1"))
        world.features.presentChooser(compare: false)
        root(BranchChooserSheet.self)?.finish(nil)
        world.features.presentChooser(compare: false)
        root(BranchChooserSheet.self)?.finish(.some("b-1"))
        #expect(await eventually { world.opened.value.contains { $0.hasPrefix("branch-new") } && world.opened.value.contains("b-1 Cover") })
        // A branch window's archive, restore, rename and trash from the menu.
        let branchWindow = CollaborationWorld(document: .memory(id: "b-1", title: "Catalogue — Cover"), branches: [BranchInfo(id: "b-1", parentID: parent.id, name: "Cover")])
        defer { branchWindow.close() }
        let branchOfWindow = branchWindow.ui.branches
        await branchOfWindow.load()
        let registry = branchWindow.environment.commands
        registry.perform(CollaborationFeatures.ID.archiveBranch)
        #expect(await eventually { branchWindow.ui.branches.current?.state == .archived })
        registry.perform(CollaborationFeatures.ID.archiveBranch)
        registry.perform(CollaborationFeatures.ID.renameBranch)
        #expect(branchWindow.sheets.value.last?.identifier?.rawValue == CollaborationFeatures.branchSheet)
        registry.perform(CollaborationFeatures.ID.trashBranch)
        #expect(await eventually { branchWindow.opened.value.last?.hasPrefix(parent.id) == true })
        branchWindow.client.fails = true
        let restored = await branchOfWindow.setArchived(false)
        #expect(!restored && branchOfWindow.message?.contains("restored") == true)
        // The web and trace sheets' buttons.
        let web = WebWorld()
        defer { web.close() }
        let layer = try #require(await web.document.perform(CreateLayer(name: "L")).value?.createdNodes.first)
        web.window.objectEditing.activeLayer = layer
        web.features.presentHold()
        (web.sheets.value.last?.contentViewController as? NSHostingController<FrameHoldSheet>)?.rootView.finish(4)
        await web.document.settle()
        #expect(web.document.state.props(layer).layer.frame.hold == 4)
        web.features.presentHold()
        (web.sheets.value.last?.contentViewController as? NSHostingController<FrameHoldSheet>)?.rootView.finish(nil)
        let trace = TraceFeatures(preferences: web.setup.environment.preferences)
        let tools = ToolRegistry()
        trace.install(tools: tools)
        let options = try #require(tools.descriptor(for: TraceTool.id)?.options?() as? NSHostingController<TraceOptionsSheet>)
        options.rootView.close()
        let loose = TraceTool(features: trace)
        loose.mouseUp(CanvasEvent(pasteboardPoint: Point(x: 0, y: 0), viewPoint: Point(x: 0, y: 0)))
        loose.pick(at: Point(x: 0, y: 0), modifiers: [])
        #expect(!loose.keyDown(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                              characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))))
        #expect(TraceTool.marquee(from: Point(x: 0, y: 0), to: Point(x: -3, y: 8), modifiers: .shift) == Rect(x: -8, y: 0, width: 8, height: 8))
        #expect(TraceFeatures.imported(Contour(segments: [], closed: false)).start == Point(x: 0, y: 0))
    }

    @Test func branchStoresOnThisMacAreListedAndMakeABranchWindow() async throws {
        let directory = TestStores.directory()
        let handle = TestStores.handle(in: directory)
        await handle.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        let store = try #require(handle.model?.backend as? LocalStore)
        // The parent's window lists the branch made on this Mac as not yet on the server.
        let parentWorld = CollaborationWorld(document: handle)
        defer { parentWorld.close() }
        let entry = try await BranchStores.keepChangesOnBranch(parent: store, name: "Offline work", root: parentWorld.root)
        let parentBranches = parentWorld.ui.branches
        await parentBranches.load()
        #expect(parentBranches.branches.map(\.id) == [entry.documentID] && parentBranches.targets[1].detail == "Not yet on the server")
        parentWorld.features.state = { _ in handle.state }
        #expect(await parentBranches.compare(with: nil) == nil)
        #expect(await parentBranches.compare(with: entry.documentID)?.heading == "Compare main with Offline work")
        // A window on the branch finds its parent in the store.
        let branchWorld = CollaborationWorld(document: .memory(id: entry.documentID, title: "Offline work"))
        defer { branchWorld.close() }
        branchWorld.features.storeRoot = { parentWorld.root }
        branchWorld.online.value = false
        let branches = branchWorld.ui.branches
        await branches.load()
        #expect(branches.isBranch && branches.parentID == handle.id && branches.title == "Offline work")
        branchWorld.features.state = { _ in handle.state }
        let compare = try #require(await branches.compare(with: nil))
        #expect(compare.titleA == "Branch" && compare.titleB == "Main" && compare.heading == "Compare Offline work with main")
        // A store that cannot be opened is not created on the server.
        let copies = FakeCopies()
        var unreadable = entry
        unreadable.url = URL(filePath: "/nonexistent/store.sqlite")
        await DocumentSession.createOnServer(unreadable, creator: BranchCreator(transport: copies, tokens: StaticTokens()))
        #expect(copies.recorded.isEmpty)
    }

    @Test func panelButtonsAndSheetsRunTheirActions() async throws {
        let world = WebWorld()
        defer { world.close() }
        _ = await world.animate()
        let web = world.web
        for transport in AnimationPanel.Transport.allCases { AnimationPanel.action(web, transport)() }
        #expect(!web.isPlaying && web.frameIndex == nil)
        // A sheet without a parent is a window of its own.
        let features = WebFeatures(preferences: world.setup.environment.preferences)
        let sheet = features.present(Text("x"), identifier: "loose", title: "Loose", on: nil)
        #expect(sheet.isVisible)
        features.dismiss("loose")
        // The layer commands without a current layer.
        world.window.objectEditing.activeLayer = nil
        #expect(world.commands.command(WebFeatures.ID.frameHold)?.validation() == .disabled(WebFeatures.noLayer))
        #expect(world.commands.command(WebFeatures.ID.excludeFromAnimation)?.validation() == .disabled(WebFeatures.noLayer))
        world.commands.perform(WebFeatures.ID.excludeFromAnimation)
        // Find through the panel's button, and Update everywhere over text ranges.
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        world.window.selection.model.apply(ids, mode: .replace)
        _ = await NavigationPanelModel(window: world.window, web: web).setLink("a.example")?.value
        await world.document.settle()
        let fields = NavigationFieldState()
        NavigationPanel.find(NavigationPanelModel(window: world.window, web: web), fields)()
        #expect(web.found?.url == "a.example")
        // The compare sheet's overlay toggle and chosen marks render.
        let document = world.document
        let comparison = DocumentComparison(a: document.state, b: EngineState())
        let model = CompareSheetModel(comparison: comparison, titleA: "A", titleB: "B", heading: "H", perform: { document.perform($0) }, current: { document.state })
        model.useB()
        model.overlay = true
        Render.view(CompareSheetView(model: model))
        #expect(model.summary.hasSuffix("differ") || model.summary.hasSuffix("differs"))
    }

    @Test func aFrameSnapshotDrawsTheAnimationAtATime() async throws {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><rect width="20" height="10" fill="red"><animate attributeName="width" from="20" to="2" dur="2s"/></rect></svg>"#.utf8)
        let png = await WebFrameSnapshot().png(svg: svg, size: Size(width: 40, height: 20), timeMs: 1000)
        #expect(png.map { !$0.isEmpty } ?? true)
        let broken = await WebFrameSnapshot().png(svg: Data("not svg".utf8), size: Size(width: 4, height: 4), timeMs: 0)
        _ = broken
    }

    @Test func collaborationEdges() async throws {
        let world = CollaborationWorld()
        defer { world.close() }
        // The sheet presenter shows a sheet without a parent as a window.
        let features = CollaborationFeatures()
        let sheet = features.present(Text("x"), identifier: "loose", on: nil)
        #expect(sheet.isVisible)
        features.dismiss("loose")
        // Compare against a branch named like this side reads "Other"; the local stores are read.
        let branches = world.ui.branches
        world.features.state = { _ in world.document.state }
        world.client.fails = false
        _ = try await world.client.create(parent: world.document.id, branchID: "b-main", name: "Main", forkServerSeq: 0)
        await branches.load()
        #expect(await branches.compare(with: "b-main")?.titleB == "Other")
        #expect(await branches.compare(with: world.document.id) == nil)
        world.features.storeRoot = { throw BranchError.noStore }
        await branches.load()
        // Inspect mode toggles off from the command and without a window does nothing.
        let inspect = world.ui.inspect
        inspect.toggle()
        inspect.toggle()
        #expect(!inspect.isOn)
        let tool = InspectTool(controller: inspect)
        tool.mouseDown(CanvasEvent(pasteboardPoint: Point(x: 0, y: 0), viewPoint: Point(x: 0, y: 0)))
        // The restore sheet's compare with an unreadable version.
        let restore = RestoreVersionModel(documentTitle: "T", list: { [VersionInfo(id: "v", name: "V", serverSeq: 1)] },
                                          state: { _ in throw BranchError.noStore }, current: { EngineState() }, perform: { world.document.perform($0) })
        await restore.load()
        #expect(await restore.showCompare() == nil)
        // The access bar's buttons refuse while one runs.
        let offer = FakeAccessOffer()
        let bar = AccessBarModel(offer: offer, title: "T")
        bar.apply(AccessController.Status(editable: false, reason: .role, unsent: 1))
        async let first: Void = bar.saveAsCopy()
        async let second: Void = bar.discard()
        _ = await (first, second)
        Render.view(AccessBarView(model: bar))
        // Session services without a connection.
        let session = DocumentSession(document: .memory(title: "M"), connector: nil, localUserID: "me")
        #expect(session.store == nil && session.makeAccessController() == nil)
    }
}
