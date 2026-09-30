import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTSync
@testable import WireTuner

/// menu:File[Export a Package…], menu:File[Open File…] and a package opened from the Finder
/// (IO-005, IO-006), and the app's wiring of the import and package commands.
@Suite(.serialized) @MainActor struct PackageCommandTests {
    /// A package controller over `world`'s blob cache, its alerts recorded.
    @MainActor
    final class Packages {
        let controller = PackageController()
        var alerts: [(String, String)] = []
        var created: [DocumentHandle] = []

        init(_ world: ImportWorld) {
            controller.blobs = world.imports.blobs
            controller.account = { ("account-1", "Pat") }
            controller.showAlert = { [unowned self] message, detail, _ in alerts.append((message, detail)) }
            controller.createDocument = { [unowned self] title in
                let handle = DocumentHandle.memory(title: title)
                created.append(handle)
                return handle
            }
        }
    }

    @Test func aDocumentRoundTripsThroughAPackageIntoANewDocument() async throws {
        let world = ImportWorld()
        defer { world.close() }
        let packages = Packages(world)
        let png = world.files.png()
        _ = await world.imports.place([png, world.files.text("shape.svg", ImportFiles.staticSVG)], on: world.window, at: Point(x: 50, y: 60))
        let url = world.files.directory.appending(path: "Poster.wiretuner")
        var panels: [NSSavePanel] = []
        packages.controller.runSavePanel = { panel, _ in
            panels.append(panel)
            return url
        }
        let summary = try #require(await packages.controller.exportPackage(of: world.window))
        #expect(panels.first?.nameFieldStringValue == "Untitled.wiretuner")
        #expect(summary.manifest.exportedBy == "account-1" && summary.manifest.exportedByName == "Pat" && summary.manifest.unsyncedChanges == 0)
        #expect(summary.manifest.missingBlobs.isEmpty && packages.alerts.isEmpty)

        // Opening makes a new, unrelated document holding the same objects and the blobs.
        try FileManager.default.removeItem(at: world.files.blobs)
        var chosen: [NSOpenPanel] = []
        packages.controller.runOpenPanel = { panel, _ in
            chosen.append(panel)
            return [url]
        }
        let copy = try #require(await packages.controller.openPackage())
        #expect(chosen.first?.allowedContentTypes == PackageController.openableTypes)
        #expect(copy.title == "Untitled" && packages.created.count == 1)
        let model = try #require(copy.model)
        #expect(model.undoTitle == "Undo Import package")
        let order = LayerOrder(copy.state)
        let objects = order.layers.flatMap { order.objects(on: $0.id, in: copy.state) }
        #expect(objects.count == 2)
        #expect(Set(objects).isDisjoint(with: world.objects))
        #expect(copy.state.props(objects[0]).image.common.name == "photo.png")
        let hash = ImportedBlob.hex(copy.state.props(objects[0]).image.pixels.blobSha256)
        #expect(BlobCache(directory: world.files.blobs).contains(hash), "the package's blobs are back in the cache")
    }

    @Test func exportWarnsAboutMissingBlobsAndReportsFailures() async throws {
        let world = ImportWorld()
        defer { world.close() }
        let packages = Packages(world)
        _ = await world.imports.place([world.files.png()], on: world.window, at: Point(x: 0, y: 0))
        // An image with no name whose blob was never here: named by its hash.
        var unnamed = Wiretuner_Doc_V1_NodeProps()
        unnamed.image.pixels.blobSha256 = Data(repeating: 0xCD, count: 32)
        let layer = try #require(LayerOrder(world.state).layers.last?.id)
        _ = await world.document.perform(OpsCommand("Unnamed", ops: [Ops.create(parent: layer, position: [0xF0], props: unnamed)])).value
        try FileManager.default.removeItem(at: world.files.blobs)
        packages.controller.runSavePanel = { _, _ in world.files.directory.appending(path: "Missing.wiretuner") }
        let summary = try #require(await packages.controller.exportPackage(of: world.window))
        #expect(summary.manifest.missingBlobs.count == 2)
        #expect(packages.alerts.last?.0 == "The package was exported with warnings." && packages.alerts.last?.1.contains("photo.png") == true)
        #expect(packages.alerts.last?.1.contains(String(repeating: "cd", count: 32)) == true)
        packages.controller.runSavePanel = { _, _ in URL(fileURLWithPath: "/nonexistent-folder-\(UUID().uuidString)/x.wiretuner") }
        #expect(await packages.controller.exportPackage(of: world.window) == nil)
        #expect(packages.alerts.last?.0 == "The package could not be exported.")
        packages.controller.runSavePanel = { _, _ in nil }
        #expect(await packages.controller.exportPackage(of: world.window) == nil)
        // The package without its image still opens; the image is a placeholder.
        let opened = try #require(await packages.controller.open(world.files.directory.appending(path: "Missing.wiretuner")))
        #expect(opened.state.liveChildren(WellKnown.assets).count == 2, "the photo's asset and a placeholder for the unnamed image")
        // A document without pages exports the Letter page's area.
        let pageless = DocumentHandle(title: "Pageless", model: WTModel.Document(memory: DocumentTemplate.core(replica: 7)))
        _ = try await packages.controller.export(pageless, to: world.files.directory.appending(path: "Pageless.wiretuner"))
        // A document whose model never opened has nothing to export.
        let broken = DocumentHandle(title: "Broken") { throw CocoaError(.fileNoSuchFile) }
        await #expect(throws: PackageError.self) { try await packages.controller.export(broken, to: world.files.directory.appending(path: "b.wiretuner")) }
    }

    @Test func aStoredDocumentExportsItsUnsyncedChanges() async throws {
        let world = ImportWorld()
        defer { world.close() }
        let packages = Packages(world)
        let stored = TestStores.handle(in: TestStores.directory())
        _ = await stored.perform(CreateLayer(name: "Stored")).value
        let summary = try await packages.controller.export(stored, to: world.files.directory.appending(path: "Stored.wiretuner"))
        #expect(summary.manifest.unsyncedChanges == 1)
        stored.close()
    }

    @Test func damagedPackagesAndFailedCreationAreRefused() async throws {
        let world = ImportWorld()
        defer { world.close() }
        let packages = Packages(world)
        let damaged = world.files.text("Damaged.wiretuner", "not a zip")
        #expect(await packages.controller.open(damaged) == nil)
        #expect(packages.alerts.last?.0 == "“Damaged.wiretuner” could not be opened." && packages.created.isEmpty)
        packages.controller.runOpenPanel = { _, _ in [] }
        #expect(await packages.controller.openPackage() == nil)

        // A good package with no title is named after its file; a document that cannot be made
        // is reported.
        let url = world.files.directory.appending(path: "Named.wiretuner")
        let contents = DocumentPackage.contents(of: EngineState(), info: DocumentPackage.Info(documentID: "d", title: ""),
                                                page: Pasteboard.letterPage) { _ in nil }
        _ = try PackageWriter().write(contents, to: url)
        #expect(await packages.controller.open(url)?.title == "Named")
        packages.controller.createDocument = { _ in nil }
        #expect(await packages.controller.open(url) == nil)
        #expect(packages.alerts.last?.1 == "A new document could not be created for it.")
        // Blobs that cannot be stored leave the document partly opened.
        packages.controller.createDocument = { DocumentHandle.memory(title: $0) }
        let png = world.files.png()
        _ = await world.imports.place([png], on: world.window, at: Point(x: 0, y: 0))
        let withBlob = world.files.directory.appending(path: "Blob.wiretuner")
        packages.controller.runSavePanel = { _, _ in withBlob }
        _ = await packages.controller.exportPackage(of: world.window)
        packages.controller.blobs.directory = { throw CocoaError(.fileWriteNoPermission) }
        #expect(await packages.controller.open(withBlob) != nil)
        #expect(packages.alerts.last?.0 == "“Blob.wiretuner” was only partly opened.")
        #expect(PackageController.contentType.conforms(to: .zip))
    }

    @Test func theAppWiresImportsPackagesAndFinderOpens() async throws {
        let suite = TestDefaults()
        let server = FakeLibraryServer()
        let library = LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults, library: library)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            for id in delegate.documents.documents.map(\.id) { delegate.documents.close(id) }
            suite.remove()
        }
        #expect(delegate.commands.command(ImportCommands.ID.openPackage) != nil)
        #expect(delegate.commands.command(ImportCommands.ID.importFile)?.validation() == .enabled)
        let window = try #require(delegate.activeDocumentWindow)
        #expect(window.canvas.onFileDrop?([URL(fileURLWithPath: "/tmp/readme.xyz")], Point(x: 0, y: 0)) == false)
        #expect(delegate.imports.blobs.queue(window.documentHandle) == nil, "test launches run no sync session")
        #expect(delegate.packages.account() == ("", ""))
        let created = try #require(delegate.packages.createDocument("From package"))
        #expect(created.title == "From package" && delegate.documents.document(id: created.id) === created)
        var alerts: [String] = []
        delegate.packages.showAlert = { message, _, _ in alerts.append(message) }
        #expect(delegate.open(URL(fileURLWithPath: "/tmp/nothing-\(UUID().uuidString).wiretuner")))
        #expect(await eventually { alerts.count == 1 })
        #expect(!delegate.open(URL(string: "https://example.com/x")!))
    }
}
