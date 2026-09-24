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

/// DOC-023: the Links window over a document with linked and embedded files.
@Suite(.serialized) @MainActor struct LinksTests {
    /// A document holding an image placed from a linked file in a scratch folder.
    @MainActor
    struct World {
        let setup: SetupWindow
        let file: URL
        let asset: OpID
        let image: OpID
        let model: LinksModel

        static func make(device: String = "this-mac", path: String? = nil) async throws -> World {
            let folder = TestEnvironment.temporaryDirectory()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "photo.png")
            try Data([1, 2, 3]).write(to: file)
            let setup = SetupWindow()
            let page = setup.page
            var props = Wiretuner_Doc_V1_NodeProps()
            props.asset.sha256 = ImportedBlob.hash(Data([1, 2, 3]))
            props.asset.byteSize = 3
            props.asset.mediaType = "image/png"
            props.asset.link.kind = .localFile
            props.asset.link.path = path ?? file.path
            props.asset.link.device = device
            props.asset.link.displayName = "photo.png"
            props.asset.link.sourceModifiedMs = 1
            let created = await setup.document.perform(OpsCommand("Import", ops: [Ops.create(parent: WellKnown.assets, position: [0x80], props: props)])).value
            let asset = try #require(created?.opIDs.first)
            var image = Wiretuner_Doc_V1_NodeProps()
            image.image.source.id = asset.proto
            image.image.common.transform.a = 1
            image.image.common.transform.d = 1
            image.image.common.transform.tx = page.rect.minX + 20
            image.image.common.transform.ty = page.rect.minY + 20
            image.image.pixels.pixelWidth = 10
            image.image.pixels.pixelHeight = 10
            image.image.pixels.blobSha256 = ImportedBlob.hash(Data([1, 2, 3]))
            _ = await setup.document.perform(CreateLayer(name: "Art")).value
            let layer = try #require(LayerOrder(setup.document.state).drawingLayer)
            let placed = await setup.document.perform(OpsCommand("Place", ops: [Ops.create(parent: layer, position: [0x90], props: image)])).value
            let imageID = try #require(placed?.opIDs.first)
            let model = LinksModel(document: setup.document, device: "this-mac") { setup.window.objectEditing.perform($0) }
            model.selectObjects = { [weak window = setup.window] ids in window?.select(ids) }
            return World(setup: setup, file: file, asset: asset, image: imageID, model: model)
        }

        init(setup: SetupWindow, file: URL, asset: OpID, image: OpID, model: LinksModel) {
            self.setup = setup
            self.file = file
            self.asset = asset
            self.image = image
            self.model = model
        }

        var document: DocumentHandle { setup.document }
        func link() -> AssetLink? { AssetLink.read(asset, in: document.state) }

        func close() { setup.close() }
    }

    @Test func rowsShowNameKindSizePageAndStatus() async throws {
        let world = try await World.make()
        defer { world.close() }
        let model = world.model
        let row = try #require(model.rows.first)
        #expect(row.name == "photo.png" && row.kind == "PNG" && row.status == "Linked (modified)" && !row.isBroken && row.canUpdate)
        #expect(row.size == ByteCountFormatter.string(fromByteCount: 3, countStyle: .file))
        #expect(LinksModel.objects(placing: world.asset, in: world.document.state) == [world.image])
        // Selecting a row selects the image.
        model.select(world.asset)
        #expect(world.setup.window.selection.model.ids.map(\.opID) == [world.image])
        model.select(nil)
        #expect(model.infoLines(world.asset).map(\.0) == ["Name", "Kind", "Size", "Source", "Modified"])
        #expect(model.infoLines(OpID(counter: 99, replica: 9)).isEmpty)
        #expect(LinksModel.kind(of: "image/svg+xml") == "SVG animation" && LinksModel.kind(of: "application/postscript") == "EPS" && LinksModel.kind(of: "") == "File")
        #expect(LinksModel.kind(of: "x/unknown") == "x/unknown")
        #expect(model.statusText(.embedded) == "Embedded" && model.statusText(.linked) == "Linked" && model.statusText(.library) == "Library")
        #expect(model.statusText(.unavailable(device: nil)) == "Unavailable" && model.statusText(.unavailable(device: "x")) == "Unavailable (another Mac)")
        model.deviceOwner = { _ in "Priya" }
        #expect(model.statusText(.unavailable(device: "x")) == "Unavailable (on Priya’s Mac)")
        _ = LinksView(model: model).body
    }

    @Test func updateEmbedChangeAndExtract() async throws {
        let world = try await World.make()
        defer { world.close() }
        let model = world.model
        var stored: [ImportedBlob] = []
        model.storeBlob = { stored.append($0) }
        // Update re-reads the file.
        try Data([4, 5, 6, 7]).write(to: world.file)
        _ = await model.update(world.asset)
        #expect(world.link()?.byteSize == 4 && stored.count == 1 && world.document.undoTitle == "Undo Update link")
        // Update All takes every modified link.
        try Data([8]).write(to: world.file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: world.file.path)
        _ = await model.updateAll()
        #expect(world.link()?.byteSize == 1 && world.document.undoTitle == "Undo Update all links")
        #expect(await model.updateAll() == nil, "nothing modified")
        // Change… relinks to another file.
        let other = world.file.deletingLastPathComponent().appending(path: "other.jpg")
        try Data([9, 9]).write(to: other)
        model.chooseFile = { other }
        _ = await model.change(world.asset)
        #expect(world.link()?.path == other.path && world.link()?.mediaType == "image/jpeg" && world.document.undoTitle == "Undo Relink")
        model.chooseFile = { nil }
        #expect(await model.change(world.asset) == nil)
        model.chooseFile = { other.deletingLastPathComponent().appending(path: "missing.png") }
        #expect(await model.change(world.asset) == nil && model.message != nil)
        // Extract… writes the stored copy and relinks to it.
        let extracted = world.file.deletingLastPathComponent().appending(path: "copy.jpg")
        model.cachedBlob = { _ in Data([9, 9]) }
        model.chooseDestination = { _ in extracted }
        _ = await model.extract(world.asset)
        #expect(FileManager.default.contents(atPath: extracted.path) == Data([9, 9]) && world.link()?.path == extracted.path)
        // Over an existing file it asks; declining writes nothing.
        model.confirmReplace = { _ in false }
        #expect(await model.extract(world.asset) == nil && model.message != nil)
        model.chooseDestination = { _ in nil }
        #expect(await model.extract(world.asset) == nil)
        model.cachedBlob = { _ in nil }
        #expect(await model.extract(world.asset) == nil && model.message?.contains("not arrived") == true)
        #expect(await model.extract(OpID(counter: 99, replica: 9)) == nil)
        // Embed breaks the link.
        _ = await model.embed(world.asset).value
        #expect(world.link()?.kind == .embedded && model.rows.first?.status == "Embedded")
        #expect(await model.update(world.asset) == nil, "an embedded file has no source")
    }

    @Test func aBrokenLinkIsItalicAndFoundOnOpen() async throws {
        let moved = TestEnvironment.temporaryDirectory()
        let deep = moved.appending(path: "a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: deep.appending(path: "photo.png"))
        let world = try await World.make(path: "/nowhere/photo.png")
        defer { world.close() }
        #expect(world.model.rows.first?.isBroken == true && world.model.rows.first?.status == "Unavailable")
        #expect(await world.model.update(world.asset) == nil && world.model.message != nil)
        let found = await MissingLinks.repair(world.document, device: "this-mac", searchFolder: moved.path, bookmark: { _ in Data([7]) }) {
            world.setup.window.objectEditing.perform($0)
        }
        #expect(found.map(\.asset) == [world.asset] && world.link()?.path == deep.appending(path: "photo.png").path)
        #expect(world.document.undoTitle == "Undo Relink missing files")
        #expect(await MissingLinks.bookmark(world.asset, of: world.document) == Data([7]), "kept as the asset's local-only bookmark")
        let none = await MissingLinks.repair(world.document, device: "this-mac", searchFolder: nil) { world.setup.window.objectEditing.perform($0) }
        #expect(none.isEmpty)
        // The app searches when a document opens, when the preference is on.
        let features = DocumentSetupFeatures(preferences: world.setup.environment.preferences, device: "this-mac")
        let task = features.documentDidOpen(world.setup.window)
        #expect(await task?.value.isEmpty == true)
        world.setup.environment.preferences.set(false, for: PreferenceCatalog.Document.searchMissingLinks)
        #expect(features.documentDidOpen(world.setup.window) == nil)
    }

    @Test func theWindowShowsTheFrontDocument() async throws {
        let world = try await World.make()
        defer { world.close() }
        let features = DocumentSetupFeatures(preferences: world.setup.environment.preferences, device: "this-mac")
        features.install(commands: world.setup.environment.commands, panels: world.setup.environment.panels, tools: world.setup.environment.tools) {
            world.setup.window
        }
        let model = features.linksModel(for: world.setup.window)
        #expect(model.rows.count == 1)
        model.selectObjects([world.image])
        #expect(world.setup.window.selection.model.ids.map(\.opID) == [world.image])
        _ = model.cachedBlob(Data(repeating: 0, count: 32))
        #expect(world.setup.environment.commands.perform(DocumentSetupFeatures.ID.links))
        let controller = try #require(features.links)
        #expect(controller.window?.title == "Links — Setup")
        features.showLinks()
        controller.close()
    }
}
