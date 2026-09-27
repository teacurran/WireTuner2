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

/// WEB-003's link criterion in Find & Replace Graphics and WEB-017's frame numbers and playback
/// highlight in the Layers panel.
@Suite(.serialized) @MainActor struct WebExtrasTests {
    @Test func theLinkCriterionFindsObjectsAndBlocksInTheScope() async throws {
        let world = WebWorld()
        defer { world.close() }
        let document = world.document
        let center = world.setup.page.rect.center
        let ids = await document.addRectangles([Rect(x: center.x, y: center.y, width: 10, height: 10), Rect(x: center.x + 20, y: center.y, width: 10, height: 10),
                                                Rect(x: -3000, y: -3000, width: 10, height: 10)])
        let url = "https://shop.example"
        _ = await document.perform(SetLink([ids[0].opID, ids[2].opID], url: url)).value
        _ = await document.perform(SetLink([ids[1].opID], url: "https://other.example")).value
        let text = try #require(await document.addText("Buy now today", at: Point(x: center.x, y: center.y + 40)))
        let node = try #require(document.state.textNode(text))
        _ = await document.perform(SetTextLink(node: text, from: node.anchor(at: 0), to: node.anchor(at: 3), url: url)).value
        await document.settle()
        let active = ActiveSelection(model: world.window.selection.model, document: document, editing: world.window.objectEditing)
        let state = FindReplaceState()
        state.select(.select)
        state.attribute = .link
        #expect(FindReplaceState.Attribute.link.title == "Link" && FindReplaceState.Attribute.link.objectAttribute == nil)
        #expect(FindReplaceState.Attribute.available(in: .select).contains(.link) && !FindReplaceState.Attribute.available(in: .replace).contains(.link))
        // Nothing typed finds nothing.
        #expect(state.find(active).isEmpty && state.result == "0 objects found")
        state.link = url
        let found = state.find(active)
        #expect(Set(found) == [ids[0].opID, ids[2].opID, text] && state.result == "3 objects found")
        #expect(Set(world.window.selection.model.ids.map(\.opID)) == Set(found))
        // The page scope leaves out what is off the page; the selection scope what is not selected.
        state.scope = .page
        #expect(Set(state.find(active)) == [ids[0].opID, text])
        world.window.selection.model.set(Selection([ids[0]]))
        state.scope = .selection
        #expect(state.find(active) == [ids[0].opID] && state.result == "1 object found")
        #expect(LinkUseSearch.urls(in: document) == ["https://other.example", url])
        Render.view(FindReplacePanelBody(selection: active, state: state))
        PanelRendering.host(FindReplacePanelBody(selection: active, state: state))
        PanelRendering.host(Form { LinkUseSearchField(document: DocumentHandle.memory(title: "Empty"), link: .constant("")); LinkUseSearchField(document: nil, link: .constant("")) })
    }

    @Test func theLayersPanelNumbersFramesAndHighlightsThePlayingOne() async throws {
        let world = WebWorld()
        defer { world.close() }
        let layers = await world.animate()
        let document = world.document
        let numbers = LayerFrames.numbers(document)
        #expect(numbers[layers[0]] == 1 && numbers[layers[1]] == 2)
        let state = LayersPanelState()
        #expect(LayerFrames.marks(layers[0], document: document, state: state).number == nil)
        #expect(LayerFrames.toggleTitle(state) == "Show Frame Numbers")
        let model = LayersPanelModel(document: document, editing: world.window.objectEditing, state: state)
        model.optionItems.last?.run()
        #expect(state.showsFrameNumbers && LayerFrames.toggleTitle(state) == "Hide Frame Numbers")
        #expect(LayerFrames.marks(layers[1], document: document, state: state).number == 2)
        // The playing frame's layer is highlighted.
        let web = world.web
        let playing = LayerFrames.playingLayer
        LayerFrames.playingLayer = { doc in doc === document ? web.currentLayer : nil }
        defer { LayerFrames.playingLayer = playing }
        web.step(1)
        #expect(LayerFrames.marks(web.currentLayer!, document: document, state: state).playing)
        #expect(LayerFrames.background(playing: true, selected: false) != LayerFrames.background(playing: false, selected: true))
        #expect(LayerFrames.background(playing: false, selected: false) == SwiftUI.Color.clear)
        let active = ActiveSelection(model: world.window.selection.model, document: document, editing: world.window.objectEditing)
        PanelRendering.host(LayersPanelBody(selection: active, state: state))
        PanelRendering.host(LayerFrameNumber(number: 3))
        // Pages are no layer frames.
        _ = await document.perform(SetAnimationSettings(source: .pages)).value
        #expect(LayerFrames.numbers(document).isEmpty)
    }

    @Test func pageLinksShowABadgeWithTheOverlayAndNameTheirPage() async throws {
        let world = WebWorld()
        defer { world.close() }
        let document = world.document
        await document.addPage().value
        let pages = document.pageList.pages
        let target = pages[1]
        let center = pages[0].rect.center
        let ids = await document.addRectangles([Rect(x: center.x, y: center.y, width: 40, height: 30), Rect(x: center.x + 60, y: center.y, width: 40, height: 30)])
        _ = await document.perform(SetGoToPage([ids[0].opID], page: target.id)).value
        _ = await document.perform(SetLink([ids[1].opID], url: "https://example.com")).value
        await document.settle()
        let badges = LinkBadges.badges(document)
        #expect(badges.count == 1 && badges[0].node == ids[0].opID && badges[0].page == (target.name.isEmpty ? "Page 2" : target.name))
        let viewport = world.window.canvas.viewport
        let square = LinkBadges.rect(badges[0], viewport: viewport)
        #expect(square.width == LinkBadges.size && abs(square.maxX - viewport.toView(Point(x: badges[0].bounds.maxX, y: 0)).x) < 1e-9)
        let inside = viewport.toPasteboard(Point(x: square.midX, y: square.midY))
        #expect(LinkBadges.page(at: inside, document: document, viewport: viewport)?.hasPrefix("Go to ") == true)
        #expect(LinkBadges.page(at: center, document: document, viewport: viewport) == nil)
        // Drawn with the Show Links overlay; hovering the badge names the page.
        let links = LinkOverlayFeatures(window: { [weak window = world.window] in window })
        links.toggle(world.window)
        links.draw(in: PrintWorld.context(), window: world.window)
        links.hover(inside, window: world.window)
        #expect(world.window.canvas.toolTip?.hasPrefix("Go to ") == true)
        LinkBadges.draw(DocumentHandle.memory(title: "None"), in: PrintWorld.context(), viewport: viewport)
        // A page deleted underneath: no badge.
        _ = await document.perform(SetGoToPage([ids[0].opID], page: nil)).value
        #expect(LinkBadges.badges(document).isEmpty)
    }

    @Test func theSvgAnimationSectionReplacesAndEditsItsFile() async throws {
        let world = WebWorld()
        defer { world.close() }
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><rect width="20" height="10"/></svg>"#.utf8)
        let blob = ImportedBlob(data: svg, uti: "public.svg-image")
        try await world.features.blobs.store([blob], for: world.document)
        let props = AssetFields.values {
            $0.common.name = "spin.svg"
            $0.sha256 = blob.sha256
            $0.mediaType = "image/svg+xml"
        }
        let asset = try #require(await world.document.perform(OpsCommand("Asset", ops: [Ops.create(parent: WellKnown.assets, position: [0x80], props: props)])).value?.createdNodes.first)
        let file = SvgAnimationFile(asset: asset, naturalSize: Size(width: 200, height: 100), durationMs: 2000, kinds: SvgAnimationKinds(css: true))
        let layer = try #require(await world.document.perform(CreateLayer(name: "Art")).value?.createdNodes.first)
        let node = try #require(await world.document.perform(CreateSvgAnimation(file, transform: .scale(0.5), layer: layer)).value?.createdNodes.first)
        await world.document.settle()
        func model() throws -> SvgAnimationSectionModel {
            try #require(SvgAnimationSectionModel(ObjectPanelModel(document: world.document, selection: Selection([SelectionID(node)]))))
        }
        let placed = try model().size
        #expect(placed == Size(width: 100, height: 50))
        // Replace…: an animated file in its place, the size kept.
        let replacement = Data("<svg id='b'/>".utf8)
        var conversions = 0
        let convert = SvgAnimationFileActions.convert, store = SvgAnimationFileActions.storeBlobs, choose = SvgAnimationFileActions.chooseFile
        defer { SvgAnimationFileActions.convert = convert; SvgAnimationFileActions.storeBlobs = store; SvgAnimationFileActions.chooseFile = choose }
        SvgAnimationFileActions.convert = { url in
            conversions += 1
            let data = (try? Data(contentsOf: url)) ?? replacement
            let placed = ImportedPlacedFile(kind: .svgAnimation(css: false, smil: true, script: false, durationMs: 1000), blob: ImportedBlob(data: data, uti: "public.svg-image"),
                                            bounds: Rect(x: 0, y: 0, width: 50, height: 50), name: "b.svg")
            return ImportedScene(kind: .placed, name: "b.svg", bounds: placed.bounds, nodes: [.placed(placed)])
        }
        SvgAnimationFileActions.storeBlobs = { _, _ in ImportedPoster(blob: ImportedBlob(data: Data([7]), uti: "public.png")) }
        let folder = TestEnvironment.temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let chosen = folder.appending(path: "b.svg")
        try replacement.write(to: chosen)
        SvgAnimationFileActions.chooseFile = { nil }
        #expect(await SvgAnimationFileActions.replace(try model()) == nil)
        SvgAnimationFileActions.chooseFile = { chosen }
        SvgAnimationFileActions.replacing(try model())()
        for _ in 0..<100 where try model().info.naturalSize.width != 50 { try await Task.sleep(for: .milliseconds(10)) }
        var info = try model().info
        #expect(info.naturalSize == Size(width: 50, height: 50) && info.poster != nil && world.document.undoTitle == "Undo Replace SVG animation")
        let sized = try model().size
        #expect(abs(sized.width - 100) < 1e-9 && abs(sized.height - 50) < 1e-9)
        Render.view(SvgAnimationSectionView(model: try model()))
        // A file that is not an animation replaces nothing.
        SvgAnimationFileActions.convert = { _ in ImportedScene(kind: .vector, name: "x", bounds: .zero, nodes: []) }
        #expect(await SvgAnimationFileActions.replace(node, with: chosen, in: world.document) == nil)
        SvgAnimationFileActions.convert = { url in
            let placed = ImportedPlacedFile(kind: .svgAnimation(css: true, smil: false, script: false, durationMs: 0),
                                            blob: ImportedBlob(data: (try? Data(contentsOf: url)) ?? Data(), uti: "public.svg-image"), bounds: Rect(x: 0, y: 0, width: 25, height: 25))
            return ImportedScene(kind: .placed, name: "e.svg", bounds: placed.bounds, nodes: [.placed(placed)])
        }
        // Edit With…: each save in the editor replaces the file.
        let editing = ExternalEditing()
        var opened: [URL] = []
        editing.systemDefault = { _ in URL(fileURLWithPath: "/Applications/Editor.app") }
        editing.confirm = { _ in true }
        editing.directory = { folder }
        editing.open = { file, _ in opened.append(file) }
        let current = try model()
        try await world.features.blobs.store([ImportedBlob(data: replacement, uti: "public.svg-image")], for: world.document)
        let session = try #require(SvgAnimationFileActions.editWith(current, editing: editing))
        session.debounce = .milliseconds(20)
        #expect(opened == [session.file] && FileManager.default.fileExists(atPath: session.file.path))
        try Data("<svg id='edited'/>".utf8).write(to: session.file)
        for _ in 0..<150 where session.replacements == 0 { try await Task.sleep(for: .milliseconds(10)) }
        info = try model().info
        #expect(session.replacements == 1 && info.naturalSize == Size(width: 25, height: 25))
        #expect(await session.reload() == false, "an unchanged file replaces nothing")
        session.done()
        #expect(!FileManager.default.fileExists(atPath: session.file.path))
        // Declined, or no editor: nothing.
        editing.confirm = { _ in false }
        #expect(SvgAnimationFileActions.editWith(try model(), editing: editing) == nil)
        editing.systemDefault = { _ in nil }
        #expect(SvgAnimationFileActions.editWith(try model(), editing: editing) == nil)
        SvgAnimationFileActions.editing(try model())()
        #expect(conversions >= 1)
    }
}
