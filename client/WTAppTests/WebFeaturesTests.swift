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
@testable import WireTuner

/// A document window with the web features installed; sheets and folders captured.
@MainActor
struct WebWorld {
    let setup: SetupWindow
    let features: WebFeatures
    let extensions = ExtensionRegistry()
    let folder = TestStores.directory()
    let sheets = TestBox<[NSWindow]>([])
    let revealed = TestBox<[URL]>([])
    let opened = TestBox<[URL]>([])

    init(tools: [ToolDescriptor] = []) {
        setup = SetupWindow(tools: tools)
        features = WebFeatures(preferences: setup.environment.preferences)
        let sheets = sheets, folder = folder, revealed = revealed, opened = opened
        features.presentSheet = { sheet, _ in sheets.value.append(sheet) }
        features.chooseFolder = { _ in folder }
        features.reveal = { revealed.value += $0 }
        features.open = { opened.value.append($0) }
        let blobs = folder.appending(path: "blobs")
        features.blobs.directory = { blobs }
        WebSections.blobs.directory = { blobs }
        let window = setup.window
        features.install(commands: setup.environment.commands, panels: setup.environment.panels, extensions: extensions) { [weak window] in window }
    }

    var window: DocumentWindowController { setup.window }
    var document: DocumentHandle { setup.document }
    var web: WindowWeb { features.attach(window) }
    var commands: CommandRegistry { setup.environment.commands }

    func close() {
        // The sheets' models hold the window, and the features hold the sheets.
        for id in Array(features.sheets.keys) { features.dismiss(id) }
        sheets.value = []
        features.detach(window)
        setup.close()
    }

    /// Two frame layers, each with a rectangle, animated from layers.
    func animate() async -> [OpID] {
        var layers: [OpID] = []
        for name in ["Frame 1", "Frame 2"] {
            if let layer = await document.perform(CreateLayer(name: name, above: layers.last)).value?.createdNodes.first { layers.append(layer) }
        }
        for (index, layer) in layers.enumerated() {
            _ = await document.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 20), transform: .translation(x: Double(index) * 40, y: 0),
                                                   appearance: TestAppearance.filled, layer: layer)).value
        }
        _ = await document.perform(SetAnimationSettings(source: .layers, fps: 10)).value
        await document.settle()
        return layers
    }
}

@Suite(.serialized) @MainActor struct WebFeaturesTests {
    // MARK: Install and commands

    @Test func thePanelsCommandsAndReleaseOperationAreInstalled() async throws {
        let world = WebWorld()
        defer { world.close() }
        let panels = world.setup.environment.panels
        #expect(panels.descriptor(for: WebFeatures.navigationPanel)?.title == "Navigation" && panels.descriptor(for: WebFeatures.animationPanel)?.title == "Animation")
        typealias ID = WebFeatures.ID
        #expect(world.commands.command(ID.publish)?.validation() == .enabled)
        #expect(world.commands.command(ID.play)?.validation() == .disabled(WebFeatures.noFrames))
        #expect(world.commands.command(ID.play)?.defaultKey == KeyEquivalent("return", [.command, .option]))
        #expect(world.commands.command(ID.exportAnimatedSVG)?.validation() == .disabled(WebFeatures.noFrames))
        let release = try #require(world.extensions.descriptor(for: "releaseToLayers"))
        #expect(release.validate?() == .disabled(ObjectMenuCommands.noSelection))
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 20, y: 0, width: 10, height: 10)])
        world.window.selection.model.apply(ids, mode: .replace)
        #expect(release.validate?() == .enabled)
        _ = release.run?(nil)
        #expect(world.sheets.value.last?.identifier?.rawValue == WebFeatures.releaseSheet)
        world.features.dismiss(WebFeatures.releaseSheet)
        world.features.dismiss("none")
        world.commands.perform(ID.publish)
        #expect(world.sheets.value.last?.identifier?.rawValue == WebFeatures.publishSheet)
        world.commands.perform(ID.htmlSetup)
        #expect(world.sheets.value.last?.identifier?.rawValue == WebFeatures.setupSheet)
        // Layer frame commands act on the current layer.
        let layers = await world.animate()
        world.window.objectEditing.activeLayer = layers[0]
        #expect(world.commands.command(ID.excludeFromAnimation)?.validation() == .checked(false))
        world.commands.perform(ID.excludeFromAnimation)
        await world.document.settle()
        #expect(world.document.state.props(layers[0]).layer.frame.excluded)
        world.commands.perform(ID.frameHold)
        #expect(world.sheets.value.last?.identifier?.rawValue == "frame-hold-sheet")
        Render.view(FrameHoldSheet(hold: 3) { _ in })
        FrameHoldSheet.confirm(20_000, { #expect($0 == 10_000) })()
        FrameHoldSheet.cancel({ #expect($0 == nil) })()
        world.window.objectEditing.activeLayer = nil
        #expect(WebFeatures.targetLayer(world.window) == nil)
        // Without a window nothing runs.
        world.features.window = { nil }
        for id in [ID.publish, ID.play, ID.frameHold, ID.excludeFromAnimation] {
            #expect(world.commands.command(id)?.validation() == .disabled(WebFeatures.noDocument))
        }
        #expect(release.validate?() == .disabled(WebFeatures.noDocument))
        #expect(world.features.presentPublish() == nil && world.features.presentSetup() == nil && world.features.presentReleaseToLayers() == nil)
        world.features.presentHold()
        #expect(await world.features.exportAnimatedSVG() == nil)
    }

    // MARK: Animation

    @Test func theAnimationPanelSetsTheSettingsAndDrivesTheTransport() async throws {
        let world = WebWorld()
        defer { world.close() }
        let web = world.web
        #expect(web.counter == "No frames")
        web.show(0)
        web.step(1)
        web.play()
        #expect(web.frameIndex == nil && !web.isPlaying)
        let layers = await world.animate()
        let window = world.window
        Render.view(AnimationPanelBody(state: world.features.panel))
        // Settings: each control writes one change.
        AnimationPanel.source(window).wrappedValue = .pages
        AnimationPanel.fps(window).wrappedValue = 24.004
        AnimationPanel.loop(window).wrappedValue = false
        AnimationPanel.autoplay(window).wrappedValue = false
        AnimationPanel.background(window).wrappedValue = .transparent
        await world.document.settle()
        let info = AnimationInfo(world.document.state)
        #expect(info.source == .pages && info.fps == 24 && !info.loop && !info.autoplay && AnimationFrameBackground.current(in: world.document.state) == .transparent)
        #expect(AnimationPanel.source(window).wrappedValue == .pages && AnimationPanel.background(window).wrappedValue == .transparent)
        #expect(!AnimationPanel.loop(window).wrappedValue && !AnimationPanel.autoplay(window).wrappedValue && AnimationPanel.fps(window).wrappedValue == 24)
        AnimationPanel.source(window).wrappedValue = .layers
        await world.document.settle()
        // Transport: step, scrub, first, last; stepping stops at the ends without loop.
        #expect(web.counter == "1 / 2")
        AnimationPanel.action(web, .forward)()
        #expect(web.frameIndex == 1 && web.counter == "2 / 2" && web.currentLayer == layers[1])
        web.step(1)
        #expect(web.frameIndex == 1)
        AnimationPanel.scrub(web).wrappedValue = 0
        #expect(web.frameIndex == 0 && AnimationPanel.scrub(web).wrappedValue == 0)
        web.last()
        web.first()
        #expect(world.window.canvas.previewFrame == web.frames[0])
        Render.view(AnimationPanelBody(state: world.features.panel))
        // Looping wraps.
        AnimationPanel.loop(window).wrappedValue = true
        await world.document.settle()
        web.step(-1)
        #expect(web.frameIndex == 1)
        // Play and stop through the commands.
        let ticker = DisplayLinkTicker(view: world.window.canvas)
        web.makeTicker = { _ in ticker }
        world.commands.perform(WebFeatures.ID.play)
        #expect(web.isPlaying && ticker.isRunning)
        web.play()
        ticker.fire(at: 10)
        ticker.fire(at: 10.15)
        #expect(web.frameIndex == 0)
        Render.view(AnimationPanelBody(state: world.features.panel))
        world.commands.perform(WebFeatures.ID.play)
        #expect(!web.isPlaying)
        web.stop()
        for id in [WebFeatures.ID.nextFrame, WebFeatures.ID.previousFrame, WebFeatures.ID.firstFrame, WebFeatures.ID.lastFrame] { world.commands.perform(id) }
        web.endPreview()
        #expect(web.frameIndex == nil && world.window.canvas.previewFrame == nil && web.currentLayer == nil)
        // A non-looping run ends on its last frame.
        AnimationPanel.loop(window).wrappedValue = false
        await world.document.settle()
        web.play()
        ticker.fire(at: 20)
        ticker.fire(at: 25)
        #expect(!web.isPlaying)
        world.features.panel.window = { nil }
        Render.view(AnimationPanelBody(state: world.features.panel))
    }

    @Test func animatedSVGExportsTheFramesIntoTheChosenFolder() async throws {
        let world = WebWorld()
        defer { world.close() }
        _ = await world.animate()
        #expect(world.commands.command(WebFeatures.ID.exportAnimatedSVG)?.validation() == .enabled)
        try FileManager.default.createDirectory(at: world.folder, withIntermediateDirectories: true)
        let url = try #require(await world.features.exportAnimatedSVG())
        #expect(url.lastPathComponent == "Setup.svg" && world.revealed.value == [url])
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("@keyframes"))
        world.features.chooseFolder = { _ in nil }
        #expect(await world.features.exportAnimatedSVG() == nil)
        #expect(await world.features.exportAnimatedSVG(to: URL(filePath: "/nonexistent-folder-\(UUID().uuidString)")) == nil)
        world.commands.perform(WebFeatures.ID.exportAnimatedSVG)
    }

    // MARK: Navigation

    @Test func theNavigationPanelReadsAndWritesLinks() async throws {
        let world = WebWorld()
        defer { world.close() }
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 20, y: 0, width: 10, height: 10)])
        let web = world.web
        let fields = NavigationFieldState()
        let state = world.features.panel
        Render.view(NavigationPanelBody(state: state, fields: fields))
        // Nothing selected: the link list and Find.
        var model = NavigationPanelModel(window: world.window, web: web)
        #expect(!model.hasSelection && model.setName("x") == nil && model.setAlt("x") == nil && model.setLink("x") == nil)
        #expect(model.setTarget(.newTab) == nil && model.setClick(.nothing) == nil && model.text.isEmpty)
        // One object: every field writes one change.
        world.window.selection.model.apply([ids[0]], mode: .replace)
        model = NavigationPanelModel(window: world.window, web: web)
        _ = await model.setLink("example.com")?.value
        _ = await model.setAlt("Home")?.value
        _ = await model.setName("Logo")?.value
        _ = await model.setTarget(.newTab)?.value
        let page = world.setup.page
        _ = await model.setClick(.page(page.id))?.value
        await world.document.settle()
        model = NavigationPanelModel(window: world.window, web: web)
        #expect(model.link == .some("example.com") && model.alt == .some("Home") && model.name == .some("Logo") && model.target == .some(.newTab))
        #expect(model.click == .some(.page(page.id)) && model.documentLinks == ["example.com"])
        _ = await model.setClick(.nothing)?.value
        await world.document.settle()
        #expect(NavigationPanelModel(window: world.window, web: web).click == .some(.link))
        Render.view(NavigationPanelBody(state: state, fields: fields))
        // Two objects with different links read as Mixed.
        world.window.selection.model.apply(ids, mode: .replace)
        model = NavigationPanelModel(window: world.window, web: web)
        #expect(model.link == .none && model.name == .none)
        Render.view(NavigationPanelBody(state: state, fields: fields))
        // Find selects every use; editing the link then replaces it everywhere.
        world.window.selection.model.apply([ids[1]], mode: .replace)
        _ = await NavigationPanelModel(window: world.window, web: web).setLink("example.com")?.value
        await world.document.settle()
        world.window.selection.model.clear()
        model = NavigationPanelModel(window: world.window, web: web)
        #expect(model.find("example.com") == 2 && world.window.selection.selection.ids.count == 2)
        model = NavigationPanelModel(window: world.window, web: web)
        _ = await model.setLink("wiretuner.app")?.value
        await world.document.settle()
        #expect(world.document.undoTitle.contains("2") && web.links.urls(in: world.document.state) == ["wiretuner.app"])
        #expect(model.find("nothing.example") == 0)
        #expect(NavigationPanelModel(window: world.window, web: web).find("wiretuner.app") == 2)
        // A deleted page target reads as (deleted page).
        await world.document.addPage().value
        let second = world.document.pageList.pages[1]
        world.window.selection.model.apply([ids[0]], mode: .replace)
        _ = await NavigationPanelModel(window: world.window, web: web).setClick(.page(second.id))?.value
        _ = await world.document.perform(OpsCommand("Delete page", ops: [Ops.setDeleted(second.id)])).value
        await world.document.settle()
        #expect(NavigationPanelModel(window: world.window, web: web).click == .some(.deletedPage))
        Render.view(NavigationPanelBody(state: state, fields: fields))
        #expect(NavigationPanelModel.shared([Int]()) == .some(nil))
        world.features.panel.window = { nil }
        Render.view(NavigationPanelBody(state: state, fields: fields))
    }

    @Test func aTextRangeTakesALinkMarkAndShowsItsWords() async throws {
        let world = WebWorld(tools: [TextTool.descriptor])
        defer { world.close() }
        let node = try #require(await world.document.addText("Visit our site today", at: Point(x: 50, y: 50)))
        world.window.editText(node, at: Point(x: 50, y: 50))
        let editor = try #require(world.window.textEditor)
        editor.select(anchor: 6, focus: 14)
        let web = world.web
        var model = NavigationPanelModel(window: world.window, web: web)
        #expect(model.isTextRange && model.text == "our site" && model.link == .some(""))
        _ = await model.setLink("https://wiretuner.app")?.value
        await world.document.settle()
        model = NavigationPanelModel(window: world.window, web: web)
        #expect(model.link == .some("https://wiretuner.app") && web.links.urls(in: world.document.state) == ["https://wiretuner.app"])
        Render.view(NavigationPanelBody(state: world.features.panel, fields: NavigationFieldState()))
        // The whole block selected shows its own links.
        world.window.toolManager.select(.pointer)
        world.window.selection.model.apply([SelectionID(node)], mode: .replace)
        #expect(NavigationPanelModel(window: world.window, web: web).text == "https://wiretuner.app")
    }

    @Test func fieldsCommitOnReturnAndShowChangesUnderneath() async throws {
        let world = WebWorld()
        defer { world.close() }
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        world.window.selection.model.apply(ids, mode: .replace)
        let model = NavigationPanelModel(window: world.window, web: world.web)
        let fields = NavigationFieldState()
        #expect(fields.text("link", stored: "a") == "a" && !fields.changedUnderneath("link", stored: "a"))
        NavigationPanel.binding(fields, "link", stored: "a").wrappedValue = "ab.example"
        #expect(NavigationPanel.binding(fields, "link", stored: "a").wrappedValue == "ab.example")
        #expect(fields.changedUnderneath("link", stored: "remote"))
        NavigationPanel.commit(fields, "link", model)()
        NavigationPanel.commit(fields, "link", model)()
        fields.edit("name", "Badge", stored: "")
        NavigationPanel.commit(fields, "name", model)()
        fields.edit("alt", "Home page", stored: "")
        NavigationPanel.commit(fields, "alt", model)()
        await world.document.settle()
        let written = NavigationPanelModel(window: world.window, web: world.web)
        #expect(written.link == .some("ab.example") && written.name == .some("Badge") && written.alt == .some("Home page"))
        fields.edit("alt", "x", stored: "")
        fields.revert("alt")
        #expect(fields.text("alt", stored: "y") == "y")
    }

    @Test func thePanelHelpersWriteThroughTheModel() async throws {
        let world = WebWorld()
        defer { world.close() }
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        world.window.selection.model.apply(ids, mode: .replace)
        let model = NavigationPanelModel(window: world.window, web: world.web)
        let fields = NavigationFieldState()
        NavigationPanel.target(model).wrappedValue = .newTab
        NavigationPanel.target(model).wrappedValue = nil
        NavigationPanel.click(model).wrappedValue = .nothing
        NavigationPanel.click(model).wrappedValue = nil
        NavigationPanel.chooseLink(model, fields, "a.example")()
        await world.document.settle()
        #expect(NavigationPanelModel(window: world.window, web: world.web).link == .some("a.example"))
        #expect(NavigationPanel.target(NavigationPanelModel(window: world.window, web: world.web)).wrappedValue == .newTab)
        NavigationPanel.find(NavigationPanelModel(window: world.window, web: world.web), fields)()
        world.window.selection.model.clear()
        let empty = NavigationPanelModel(window: world.window, web: world.web)
        NavigationPanel.chooseLink(empty, fields, "b.example")()
        #expect(fields.text("link", stored: "") == "b.example")
        // A change without a change record rebuilds the index.
        world.web.documentDidChange(ContentChange(summary: ChangeSummary(origin: .remote), before: world.document.displayList, after: world.document.displayList, change: nil))
        #expect(world.web.links.urls(in: world.document.state) == ["a.example"])
    }

    // MARK: Release to Layers

    @Test func releaseToLayersRemembersItsChoicesAndReleasesInOneChange() async throws {
        let world = WebWorld()
        defer { world.close() }
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 20, y: 0, width: 10, height: 10)])
        world.window.selection.model.apply(ids, mode: .replace)
        let model = try #require(world.features.presentReleaseToLayers())
        #expect(model.mode == .sequence && model.trail == 2)
        Render.view(ReleaseToLayersSheet(model: model))
        model.mode = .trail
        model.trail = 1
        model.useExistingLayers = true
        model.sendToBack = true
        model.reverse = true
        #expect(model.releaseMode == .trail(1))
        Render.view(ReleaseToLayersSheet(model: model))
        let before = LayerOrder(world.document.state).layers.count
        _ = await model.release()
        await world.document.settle()
        #expect(world.document.undoTitle == "Undo Release to Layers" && LayerOrder(world.document.state).layers.count >= before)
        let again = ReleaseToLayersModel(window: world.window, preferences: world.setup.environment.preferences)
        #expect(again.mode == .trail && again.trail == 1 && again.reverse && again.useExistingLayers && again.sendToBack)
        for mode in ReleaseToLayersModel.Mode.allCases {
            again.mode = mode
            _ = again.releaseMode
        }
        // Nothing to release: the sheet says so.
        world.window.selection.model.clear()
        #expect(await again.release() == nil)
        world.window.selection.model.apply([ids[0]], mode: .replace)
        let single = ReleaseToLayersModel(window: world.window, preferences: world.setup.environment.preferences)
        single.mode = .sequence
        _ = await single.release()
        #expect(single.message != nil || world.document.undoTitle == "Undo Release to Layers")
        ReleaseToLayersSheet.cancel(single)()
        ReleaseToLayersSheet.release(single)()
        Render.view(ReleaseToLayersSheet(model: single))
    }

    // MARK: Publishing

    @Test func publishingWritesTheBundleRevealsItAndListsWarnings() async throws {
        let world = WebWorld()
        defer { world.close() }
        let page = world.setup.page.rect
        let ids = await world.document.addRectangles([Rect(x: page.minX + 20, y: page.minY + 20, width: 40, height: 40)])
        world.window.selection.model.apply(ids, mode: .replace)
        _ = await world.document.perform(SetLink([ids[0].opID], url: "http://bad host")).value
        await world.document.settle()
        let model = try #require(world.features.presentPublish())
        #expect(PublishModel.pages("", count: 3) == [0, 1, 2] && PublishModel.pages("1-2, 3", count: 3) == [0, 1, 2])
        #expect(PublishModel.pages("4", count: 3) == nil && PublishModel.pages("2-1", count: 3) == nil && PublishModel.pages("x", count: 3) == nil)
        Render.view(PublishSheet(model: model))
        // No folder yet: Publish asks for one, and says so when it is cancelled.
        let chosen = world.features.chooseFolder
        world.features.chooseFolder = { _ in nil }
        await model.publish()?.value
        #expect(model.phase == .failed("Choose a folder to publish to"))
        world.features.chooseFolder = chosen
        await model.chooseFolder()
        await world.document.settle()
        #expect(model.folder?.lastPathComponent == "Setup")
        model.range = "9"
        #expect(model.publish() == nil)
        model.range = ""
        model.openWhenDone = true
        await model.publish()?.value
        let folder = try #require(model.folder)
        #expect(model.phase == .done(folder) && FileManager.default.fileExists(atPath: folder.appending(path: "index.html").path))
        #expect(world.revealed.value == [folder] && world.opened.value == [folder.appending(path: "index.html")])
        let warning = try #require(model.visibleWarnings.first { $0.kind == .invalidLink })
        Render.view(PublishSheet(model: model))
        world.window.selection.model.clear()
        PublishSheet.show(model, warning)()
        #expect(world.window.selection.selection.ids == ids)
        model.show(ExportWarning(.clampedPage, "no node"))
        model.showWarnings = false
        #expect(model.visibleWarnings.isEmpty)
        // Choosing a setting is remembered; cancelling a publish writes nothing new.
        PublishSheet.selection(model).wrappedValue = nil
        let task = model.publish()
        #expect(model.phase == .publishing && model.publish() == nil)
        Render.view(PublishSheet(model: model))
        model.cancel()
        await task?.value
        #expect(model.phase == .ready)
        PublishSheet.cancel(model)()
        PublishSheet.publish(model)()
        PublishSheet.choose(model)()
        PublishSheet.setup(model)()
        world.features.chooseFolder = { _ in nil }
        await model.chooseFolder()
    }

    @Test func publishingWithNoFolderAsksForOneAndPublishesIntoIt() async throws {
        let world = WebWorld()
        defer { world.close() }
        let model = try #require(world.features.presentPublish())
        #expect(model.folder == nil)
        await model.publish()?.value
        let folder = try #require(model.folder)
        #expect(folder.deletingLastPathComponent().lastPathComponent == world.folder.lastPathComponent)
        #expect(model.phase == .done(folder) && FileManager.default.fileExists(atPath: folder.appending(path: "index.html").path))
    }

    @Test func aChosenFolderIsRememberedForWritingInsideIt() throws {
        let world = WebWorld()
        defer { world.close() }
        let key = WebFeatures.folderBookmarkPrefix + world.folder.path(percentEncoded: false)
        defer { world.features.folderBookmarks.removeObject(forKey: key) }
        try FileManager.default.createDirectory(at: world.folder, withIntermediateDirectories: true)
        world.features.remember(world.folder)
        #expect(world.features.folderBookmarks.data(forKey: key) != nil)
        let inside = world.folder.appending(path: "Site").path(percentEncoded: false)
        #expect(world.features.withAccess(to: inside) { 7 } == 7)
        #expect(world.features.withAccess(to: "/nowhere/at/all") { 8 } == 8)
    }

    @Test func aPanelOverASheetGoesOnTheSheet() async throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer { parent.close() }
        #expect(ModalUI.host(parent) === parent && ModalUI.host(nil) == nil)
        parent.beginSheet(sheet, completionHandler: nil)
        #expect(await eventually { parent.attachedSheet === sheet })
        #expect(ModalUI.host(parent) === sheet)
        parent.endSheet(sheet)
        sheet.close()
    }

    @Test func theSetupSheetAddsRenamesEditsAndDeletesSettings() async throws {
        let world = WebWorld()
        defer { world.close() }
        let model = try #require(world.features.presentSetup())
        #expect(model.selected == nil && model.name == "Default" && !model.canDelete)
        Render.view(HTMLSetupSheet(model: model))
        // Editing the synthesized Default materializes it.
        HTMLSetupSheet.option(model, \.pageMode, .pageMode).wrappedValue = .separateFiles
        HTMLSetupSheet.name(model).wrappedValue = "Site"
        #expect(await model.apply())
        await world.document.settle()
        #expect(model.settings.settings.first?.name == "Site" && model.settings.settings.first?.settings.pageMode == .separateFiles)
        // Add, edit, a remote change underneath, delete.
        let added = try #require(await model.add())
        #expect(model.selected == added && model.canDelete)
        HTMLSetupSheet.option(model, \.scale, .scale).wrappedValue = 3
        _ = await world.document.perform(EditHTMLSetting(added, settings: HTMLPublishSettings(title: "Remote"), options: [.title])).value
        await world.document.settle()
        model.refresh()
        #expect(model.draft.scale == 3 && model.draft.title == "Remote")
        for option in HTMLSettingOption.allCases { model.set(\.title, "T", option: option) }
        model.refresh()
        Render.view(HTMLSetupSheet(model: model))
        await model.chooseLocation()
        await world.document.settle()
        #expect(model.setting?.location == world.folder.path(percentEncoded: false))
        Render.view(HTMLSetupSheet(model: model))
        await model.confirm()
        #expect(await model.delete())
        let deletedDefault = await model.delete()
        #expect(model.selected == model.settings.settings.first?.id && !deletedDefault)
        HTMLSetupSheet.selection(model).wrappedValue = model.settings.settings.first?.id
        model.choose(OpID(counter: 9_999, replica: 9))
        #expect(model.name == model.settings.settings[0].name)
        for action in [HTMLSetupSheet.add(model), HTMLSetupSheet.apply(model), HTMLSetupSheet.confirm(model), HTMLSetupSheet.cancel(model),
                       HTMLSetupSheet.location(model), HTMLSetupSheet.delete(model)] { action() }
        world.features.chooseFolder = { _ in nil }
        await model.chooseLocation()
        #expect(await model.apply() == false)
    }

    // MARK: SVG animations

    @Test func theSvgAnimationSectionReadsTheNodeAndWritesItsSettings() async throws {
        let world = WebWorld()
        defer { world.close() }
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><rect width="20" height="10"/></svg>"#.utf8)
        let blob = ImportedBlob(data: svg, uti: "public.svg-image")
        try await world.features.blobs.store([blob], for: world.document)
        let props = AssetFields.values {
            $0.common.name = "spin.svg"
            $0.sha256 = blob.sha256
            $0.mediaType = "image/svg+xml"
            $0.link.kind = .localFile
            $0.link.path = world.folder.path
        }
        let asset = try #require(await world.document.perform(OpsCommand("Asset", ops: [Ops.create(parent: WellKnown.assets, position: [0x80], props: props)])).value?.createdNodes.first)
        let file = SvgAnimationFile(asset: asset, naturalSize: Size(width: 200, height: 100), durationMs: 2000, kinds: SvgAnimationKinds(css: true, script: true))
        let layer = try #require(await world.document.perform(CreateLayer(name: "Art")).value?.createdNodes.first)
        let node = try #require(await world.document.perform(CreateSvgAnimation(file, transform: .scale(0.5), layer: layer)).value?.createdNodes.first)
        await world.document.settle()
        let selection = Selection([SelectionID(node)])
        let panel = ObjectPanelModel(document: world.document, selection: selection)
        let model = try #require(SvgAnimationSectionModel(panel))
        #expect(model.size == Size(width: 100, height: 50) && model.scale.x == 50 && model.duration == "2.00 s" && model.scripts.hasPrefix("Uses script"))
        #expect(model.fileLine.hasSuffix(", 200 × 100") && model.scrubRange == 0...2000)
        Render.view(SvgAnimationSectionView(model: model))
        // On the web.
        SvgAnimationSectionView.autoplay(model).wrappedValue = false
        SvgAnimationSectionView.loop(model).wrappedValue = .once
        SvgAnimationSectionView.hover(model).wrappedValue = true
        await world.document.settle()
        let web = try #require(SvgAnimationInfo(node, in: world.document.state)).web
        #expect(!web.autoplay && web.loop == .once && web.playOnHover)
        // The scrubber: a rendered frame becomes the poster; the strip's cache answers again.
        var renders = 0
        WebSections.frames = [:]
        WebSections.renderFrame = { _, _, _ in
            renders += 1
            return Data([1, 2, 3])
        }
        #expect(await model.setPoster(at: 500) != nil)
        #expect(await model.setPoster(at: 500) != nil && renders == 1)
        #expect(try #require(SvgAnimationInfo(node, in: world.document.state)).posterTimeMs == 500)
        WebSections.renderFrame = { _, _, _ in nil }
        #expect(await model.setPoster(at: 900) == nil)
        SvgAnimationSectionView.released(model, 100)()
        // Save a copy writes the stored bytes; Reveal shows the original.
        let copy = world.folder.appending(path: "copy.svg")
        WebSections.chooseDestination = { _, _ in copy }
        #expect(await model.saveCopy(window: nil) == copy)
        #expect(try Data(contentsOf: copy) == svg)
        WebSections.chooseDestination = { _, _ in URL(filePath: "/nonexistent-\(UUID().uuidString)/x.svg") }
        #expect(await model.saveCopy(window: nil) == nil)
        WebSections.chooseDestination = { _, _ in nil }
        #expect(await model.saveCopy(window: nil) == nil)
        var revealed: [URL] = []
        WebSections.reveal = { revealed += $0 }
        try FileManager.default.createDirectory(at: world.folder, withIntermediateDirectories: true)
        SvgAnimationSectionView.reveal(model)()
        #expect(revealed == [world.folder])
        SvgAnimationSectionView.saveCopy(model)()
        // The section appears only for one selected animation.
        let registry = InspectorRegistry()
        WebSections.register(into: registry)
        // The scene does not draw placed animations yet (WEB-026), so the panel lists no kind for
        // the node; the section itself builds for it.
        #expect(registry.sections.first { $0.id == "svgAnimation" }?.make(panel) != nil)
        #expect(SvgAnimationSectionModel(ObjectPanelModel(document: world.document, selection: Selection())) == nil)
        #expect(WebFrameSnapshot.seek(1500).contains("1.5"))
        #expect(SvgAnimationSectionModel.seconds(0) == "0.00 s")
    }

    // MARK: Export web presets

    @Test func theExportSheetsWebPresetsFillTheFormatAndEstimateTheSize() async throws {
        let world = WebWorld()
        defer { world.close() }
        await world.document.addRectangles([Rect(x: 0, y: 0, width: 30, height: 30)])
        let exports = ExportController(defaults: world.setup.environment.preferences.defaults)
        let sheet = ExportSheetModel(context: exports.context(for: world.window), settings: ExportSettings(), presets: exports.presets, registry: exports.registry)
        let web = exports.webPresets(for: world.window, sheet: sheet)
        sheet.web = web
        #expect(web.presets.map(\.id).contains("web.png-2x"))
        Render.view(ExportAccessory(model: sheet))
        await web.choose("web.svg", sheet: sheet)?.value
        #expect(sheet.settings.format == .svg && web.estimate?.hasPrefix("About") == true)
        let quick = ExportWebPresetModel(defaults: world.setup.environment.preferences.defaults) { nil }
        ExportWebPresetSection.choice(sheet, quick).wrappedValue = "web.jpeg-80"
        #expect(sheet.settings.format == .jpeg && quick.estimate == nil)
        Render.view(ExportAccessory(model: sheet))
        for preset in WebExportPreset.builtIn + [WebExportPreset(id: "a", name: "A", format: .avif), WebExportPreset(id: "g", name: "G", format: .gif)] {
            var options = ExportFormatOptions()
            ExportWebPresetModel.apply(preset, to: &options)
        }
        #expect(web.choose("", sheet: sheet) == nil && web.estimate == nil)
        let empty = ExportWebPresetModel(defaults: world.setup.environment.preferences.defaults) { nil }
        #expect(empty.estimateSize(WebExportPreset.builtIn[0]) == nil)
    }

    /// WEB-006's rest: the preset editor in the Export sheet -- save the sheet's settings, rename,
    /// duplicate, delete, and `.wtpreset` files out and in.
    @Test func thePresetEditorManagesTheUsersPresets() async throws {
        let world = WebWorld()
        defer { world.close() }
        let suite = "wt.test.webeditor.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let exports = ExportController(defaults: world.setup.environment.preferences.defaults)
        let sheet = ExportSheetModel(context: exports.context(for: world.window), settings: ExportSettings(), presets: exports.presets, registry: exports.registry)
        let web = ExportWebPresetModel(defaults: defaults) { nil }
        sheet.web = web
        // Save the sheet's settings (JPEG at quality 55) as a preset: it is chosen.
        sheet.settings.format = .jpeg
        sheet.settings.options.jpeg.quality = 55
        web.beginNaming(.saving)
        #expect(web.naming == .saving && web.name.isEmpty && ExportWebPresetSection.naming(web).wrappedValue)
        ExportWebPresetSection.name(web).wrappedValue = "Banner"
        let saved = try #require(web.commitName(sheet: sheet))
        #expect(saved.name == "Banner" && saved.format == .jpeg && saved.quality == 55 && web.choice == saved.id && web.canEdit && web.naming == nil)
        Render.view(ExportWebPresetSection(model: sheet, web: web))
        // Rename; duplicate; a built-in preset refuses rename and delete.
        web.beginNaming(.renaming)
        #expect(web.name == "Banner")
        web.name = "Hero"
        #expect(web.commitName(sheet: sheet)?.name == "Hero")
        let copy = try #require(web.duplicateChosen())
        #expect(copy.name == "Hero 2" && web.choice == copy.id)
        web.choice = "web.png-2x"
        #expect(!web.canEdit && web.renameChosen(to: "X") == nil && web.message == "Built-in presets cannot be changed.")
        web.deleteChosen()
        #expect(web.message == "Built-in presets cannot be changed.")
        #expect(web.duplicateChosen()?.name == "Web — PNG 2× 2")
        // Export the user's presets, delete them, import them back.
        let url = FileManager.default.temporaryDirectory.appending(component: "presets-\(UUID().uuidString).wtpreset")
        web.chooseExportURL = { _ in url }
        #expect(web.exportPresets() == url && web.message == "Exported 3 presets.")
        for preset in web.store.userPresets {
            web.choice = preset.id
            web.deleteChosen()
        }
        #expect(web.store.userPresets.isEmpty && web.choice == "")
        #expect(web.exportPresets() == nil && web.message == "There are no presets of yours to export.")
        web.chooseImportURL = { url }
        #expect(web.importPresets() == 3 && web.message == "Imported 3 presets.")
        let bad = FileManager.default.temporaryDirectory.appending(component: "bad-\(UUID().uuidString).wtpreset")
        try Data("x".utf8).write(to: bad)
        web.chooseImportURL = { bad }
        #expect(web.importPresets() == 0 && web.message == "The file is not a preset file.")
        web.chooseImportURL = { nil }
        #expect(web.importPresets() == 0)
        web.chooseExportURL = { _ in nil }
        #expect(web.exportPresets() == nil)
        // A format no web preset names cannot be saved; Cancel leaves nothing.
        sheet.settings.format = .pdf
        #expect(web.saveCurrent(named: "P", sheet: sheet) == nil && web.message == "Web presets are PNG, JPEG, WebP, AVIF, GIF or SVG.")
        web.naming = nil
        #expect(web.commitName(sheet: sheet) == nil)
        ExportWebPresetSection.naming(web).wrappedValue = false
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: bad)
    }
}
