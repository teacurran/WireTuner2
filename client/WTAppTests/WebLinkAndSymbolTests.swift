import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTSync
@testable import WireTuner

/// Publishing to a web link and the Published links sheet (WEB-013), and importing, exporting and
/// pasting symbols (LIB-013).
@Suite(.serialized) @MainActor struct WebLinkAndSymbolTests {
    // MARK: Web link (WEB-013)

    @Test func publishingToTheWebLinkUploadsCopiesAndResumes() async throws {
        let world = WebWorld()
        defer { world.close() }
        let services = FakeWebLinkServices()
        WebLinks.services = services
        let pasteboard = NSPasteboard.withUniqueName()
        WebLinks.pasteboard = pasteboard
        defer {
            WebLinks.services = nil
            WebLinks.pasteboard = .general
            pasteboard.releaseGlobally()
        }
        let model = try #require(world.features.presentPublish())
        #expect(model.webLinkAvailable)
        model.destination = .webLink
        model.access = .anyoneWithLink
        Render.view(PublishSheet(model: model))
        await model.publish()?.value
        let url = "https://pub.example/d/\(world.document.id)/"
        #expect(model.phase == .done(URL(string: url)!) && model.webLink.url == url && pasteboard.string(forType: .string) == url)
        #expect(services.server.publishes.first?.access == .anyoneWithLink && services.server.publishes.first?.serverSeq == 7)
        Render.view(PublishSheet(model: model))
        // Offline, the destination is refused with the note.
        services.isOnline = false
        #expect(!model.webLinkAvailable && model.publish() == nil && model.phase == .failed("Publishing to a web link needs a connection"))
        WebLinks.services = nil
        #expect(model.publish() == nil)
        services.isOnline = true
        WebLinks.services = services
        // A dropped upload keeps the job for the resume.
        services.server.offline = true
        await model.publish()?.value
        if case .failed = model.phase {} else { Issue.record("expected a failure, got \(model.phase)") }
        #expect(model.webLink.job != nil)
        services.server.offline = false
        await model.publish()?.value
        #expect(model.webLink.job == nil && services.server.publishes.count == 2)
        model.range = "9"
        #expect(model.publish() == nil)
        #expect(WebLinkUpload.label(PublishProgress(phase: .checking, sentBytes: 0, totalBytes: 0, blobsDone: 0, blobCount: 1)).hasPrefix("Checking"))
        #expect(WebLinkUpload.label(PublishProgress(phase: .uploading, sentBytes: 1024, totalBytes: 4096, blobsDone: 0, blobCount: 1)).hasPrefix("Uploading"))
        #expect(WebLinkUpload.label(PublishProgress(phase: .registering, sentBytes: 0, totalBytes: 0, blobsDone: 1, blobCount: 1)) == "Publishing…")
        #expect(WebLinkUpload.label(PublishProgress(phase: .published(.init()), sentBytes: 0, totalBytes: 0, blobsDone: 1, blobCount: 1)) == "Published")
        #expect(WebLinks.title(.members) == "People with access to this document" && WebLinks.title(.anyoneWithLink) == "Anyone with the link")
    }

    @Test func thePublishedLinksSheetListsFollowsAndChangesPublishes() async throws {
        let world = WebWorld()
        defer { world.close() }
        let services = FakeWebLinkServices()
        WebLinks.services = services
        let pasteboard = NSPasteboard.withUniqueName()
        WebLinks.pasteboard = pasteboard
        defer {
            WebLinks.services = nil
            WebLinks.pasteboard = .general
            pasteboard.releaseGlobally()
        }
        let upload = WebLinkUpload()
        let bundle = [PublishBundleFile(path: "index.html", data: Data("<html></html>".utf8), mediaType: "text/html")]
        _ = try await upload.publish(bundle, document: world.document, settingName: "Default", access: .members, services: services)
        let model = try #require(world.features.presentPublishedLinks())
        #expect(await eventually { model.isLoaded && model.listing.publishes.count == 1 })
        let publish = model.listing.publishes[0]
        #expect(model.isEditable && PublishedLinksModel.detail(publish).contains("Default"))
        Render.view(PublishedLinksSheet(model: model))
        // Another client publishes: the document event refreshes the list.
        _ = try await upload.publish(bundle + [PublishBundleFile(path: "a.css", data: Data("a{}".utf8), mediaType: "text/css")], document: world.document,
                                     settingName: "Default", access: .members, services: services)
        services.events.continuation.yield(.document(.with { $0.publishesChanged = .init() }))
        #expect(await eventually { model.listing.publishes.count == 2 })
        model.copyLink(publish)
        #expect(pasteboard.string(forType: .string) == publish.url && model.message == "Link copied")
        var opened: [URL] = []
        model.open = { opened.append($0) }
        model.openLink(publish)
        #expect(opened.first?.absoluteString == publish.url)
        await model.setAccess(.anyoneWithLink, of: publish)?.value
        #expect(services.server.publishes.first { $0.publishID == publish.publishID }?.access == .anyoneWithLink)
        let folder = TestStores.directory()
        model.chooseFolder = { folder }
        await model.download(publish)?.value
        #expect(model.message?.hasPrefix("Downloaded") == true)
        await model.unpublish(publish)?.value
        #expect(await eventually { model.listing.publishes.count == 1 })
        // Offline: the cached list, read-only.
        services.server.offline = true
        services.isOnline = false
        #expect(await services.links(for: world.document)?.refresh().isCurrent == false)
        #expect(await eventually { !model.listing.isCurrent })
        #expect(!model.isEditable && model.setAccess(.members, of: publish) == nil && model.unpublish(publish) == nil)
        Render.view(PublishedLinksSheet(model: model))
        services.isOnline = true
        await model.download(publish)?.value
        #expect(model.message?.contains("could not be downloaded") == true)
        model.chooseFolder = { nil }
        await model.download(publish)?.value
        model.close()
        // Without services the sheet says it needs a connection.
        let bare = PublishedLinksModel(document: world.document, services: nil)
        bare.start()
        #expect(bare.download(publish) == nil && bare.message == "Downloading needs a connection" && bare.setAccess(.members, of: publish) == nil)
    }

    @Test func theAppsServicesFindTheSessionsTransports() async {
        let sessions = DocumentSessions(connector: nil)
        let server = FakeWebLinkServer()
        let services = AppWebLinkServices(sessions: sessions, isReachable: { true }, token: { "t" }, makeTransport: { server })
        let handle = DocumentHandle.memory(title: "Web")
        #expect(services.isOnline && services.blobs(for: handle) == nil && services.uploader(for: handle) == nil && services.events(for: handle) == nil)
        let links = services.links(for: handle)
        #expect(links != nil && services.links(for: handle) === links)
        #expect(await services.serverSeq(of: handle) == 0)
    }

    // MARK: Symbols (LIB-013)

    /// A document holding one symbol named `name`, made from a rectangle.
    static func symbolDocument(_ name: String = "Badge") async throws -> (DocumentHandle, OpID) {
        let document = DocumentHandle.memory(title: "Symbols \(name)")
        await document.settle()
        let rect = try #require(await document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20)]).first?.opID)
        _ = await document.perform(ConvertToSymbol([rect], name: name)).value
        let symbol = try #require(Symbols.symbols(in: document.state).first)
        return (document, symbol)
    }

    @Test func exportingWritesASymbolLibraryAndImportingReadsItBack() async throws {
        let (source, symbol) = try await Self.symbolDocument()
        let features = SymbolTransferFeatures()
        features.presenter.present = { _ in }
        let target = GlueWorld()
        defer { target.close() }
        features.window = { target.window }
        let file = TestStores.directory().appending(path: "Badge.wtsymbols")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        features.chooseDestination = { _ in file }
        features.cachedBlob = { _ in nil }

        let export = SymbolExportModel(document: source, features: features)
        #expect(export.chosen == [symbol] && export.symbols.map(\.name) == ["Badge"] && export.package.symbols.count == 1)
        Render.view(SymbolExportSheet(model: export))
        var exported = false
        export.onClose = { exported = true }
        await export.exportToFile()?.value
        #expect(exported && FileManager.default.fileExists(atPath: file.path))
        export.chosen = []
        #expect(export.exportToFile() == nil)
        features.chooseDestination = { _ in URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x.wtsymbols") }
        export.chosen = [symbol]
        await export.exportToFile()?.value
        #expect(export.message?.contains("could not be written") == true)
        export.cancel()

        // Import the file into the target document.
        var stored: [(data: Data, mediaType: String)] = []
        features.storeBlobs = { blobs, _ in stored += blobs }
        let model = try #require(features.presentImport())
        #expect(model.package == nil && model.sources.isEmpty)
        Render.view(SymbolImportSheet(model: model))
        await model.load(file: file).value
        #expect(model.symbols.map(\.name) == ["Badge"] && model.chosen.count == 1 && model.sourceName == "Badge.wtsymbols")
        Render.view(SymbolImportSheet(model: model))
        var imported = false
        model.onClose = { imported = true }
        await model.importChosen()?.value
        #expect(imported && Symbols.symbols(in: target.document.state).count == 1)
        model.chosen = []
        #expect(model.importChosen() == nil)
        // A file that is not a symbol library.
        let junk = file.deletingLastPathComponent().appending(path: "junk.wtsymbols")
        try Data("nope".utf8).write(to: junk)
        await model.load(file: junk).value
        #expect(model.message?.contains("could not be read") == true)
        features.chooseFile = { nil }
        await model.chooseFile()
        model.cancel()
        #expect(features.menuItems(for: SymbolLibraryModel(selection: ActiveSelection())).map(\.title) == ["Import…", "Export…"])
        #expect(SymbolTransferFeatures.mediaType(Data("%PDF-1.4".utf8)) == "application/pdf" && SymbolTransferFeatures.mediaType(Data([1])) == "application/octet-stream")
        #expect(SymbolTransferFeatures.mediaType(PackageGlueTests.png()) == "image/png")
    }

    @Test func importingFromADocumentReadsTheOpenCopyTheStoreOrTheCloud() async throws {
        let (source, _) = try await Self.symbolDocument("Star")
        let features = SymbolTransferFeatures()
        features.presenter.present = { _ in }
        let target = GlueWorld()
        defer { target.close() }
        features.window = { target.window }
        features.openDocuments = { [source] }
        features.libraryDocuments = { [(id: source.id, name: "Stars"), (id: target.document.id, name: "Here"), (id: "gone", name: "Gone")] }
        features.storeURL = { _ in nil }
        let model = try #require(features.presentImport())
        #expect(model.sources.map(\.name) == ["Stars", "Gone"])
        await model.load(document: model.sources[0]).value
        #expect(model.symbols.map(\.name) == ["Star"])
        // Not open, not on this Mac and offline.
        await model.load(document: model.sources[1]).value
        #expect(model.message == "That document is not on this Mac; connect to import from it")
        features.cloudState = { _ in source.state }
        await model.load(document: model.sources[1]).value
        #expect(model.symbols.map(\.name) == ["Star"])
        // A cached store on this Mac.
        let directory = TestStores.directory()
        let stored = TestStores.handle(id: "cached", in: directory)
        await stored.addRectangles([Rect(x: 0, y: 0, width: 5, height: 5)])
        stored.close()
        features.storeURL = { id in directory.appending(components: id, "store.sqlite") }
        #expect(await eventually { (try? await features.package(of: "cached")) != nil })
        // An empty package says so.
        let empty = TestStores.directory().appending(path: "Empty.wtsymbols")
        try FileManager.default.createDirectory(at: empty.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SymbolPackage().fileData.write(to: empty)
        await model.load(file: empty).value
        #expect(model.message == "Empty.wtsymbols has no symbols")
        #expect(SymbolTransferFeatures.opens(URL(fileURLWithPath: "/tmp/x.txt")) == false)
    }

    @Test func aPackageFileBringsItsSymbolsAndAssetBytes() async throws {
        let (source, _) = try await Self.symbolDocument("Seal")
        let contents = DocumentPackage.contents(of: source.state, info: DocumentPackage.Info(documentID: source.id, title: "Seal"),
                                                page: Rect(x: 0, y: 0, width: 100, height: 100), cached: { _ in nil })
        let url = TestStores.directory().appending(path: "Seal.wiretuner")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PackageWriter().data(contents).data.write(to: url)
        let package = try SymbolTransferFeatures.package(file: url)
        #expect(package.names == ["Seal"])
    }

    @Test func copiedInstancesCarryTheirSymbolIntoAnotherDocument() async throws {
        let (source, symbol) = try await Self.symbolDocument("Coin")
        let world = GlueWorld()
        defer { world.close() }
        let placed = try #require(await source.perform(PlaceInstance(symbol, at: Point(x: 50, y: 50))).value?.createdObjects.first)
        let pasteboard = SystemObjectPasteboard(world.pasteboard)
        // Copy in the source document's editing, paste in the world's.
        let sourceEditing = ObjectEditing(document: source, selection: SelectionController(document: source), pasteboard: pasteboard)
        sourceEditing.selection.model.set(Selection([SelectionID(placed)]))
        sourceEditing.copy()
        #expect(pasteboard.readSymbols() != nil)
        await world.editing.paste()?.value
        #expect(Symbols.symbols(in: world.state).count == 1)
        // Pasting into the same document keeps the plain paste.
        let paste = Paste(ClipboardPayload(nodes: [], sourceDocument: world.document.id), placement: .top(layer: nil, center: nil))
        #expect(SymbolClipboard.command(paste, into: world.document.id, from: pasteboard) is Paste)
        // A pasteboard that cannot carry symbols writes and reads nothing.
        let plain = PlainPasteboard()
        SymbolClipboard.write(ClipboardPayload(nodes: []), from: world.state, to: plain)
        #expect(SymbolClipboard.command(paste, into: "other", from: plain) is Paste)
    }
}

/// A pasteboard without the symbols companion.
@MainActor
final class PlainPasteboard: ObjectPasteboard {
    var payload: [UInt8]?
    func write(_ payload: [UInt8]) { self.payload = payload }
    func read() -> [UInt8]? { payload }
}

/// The remaining edges of the web-link and symbol glue.
@Suite(.serialized) @MainActor struct WebLinkAndSymbolEdgeTests {
    @Test func theAppsServicesOutsideATestLaunch() async throws {
        let suite = TestDefaults()
        defer { suite.remove() }
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        var environment = LaunchEnvironment()
        environment.isUnitTesting = false
        environment.isUITesting = false
        let services = try #require(environment.makeWebLinkServices(sessions: delegate.sessions, account: delegate.account, library: delegate.library,
                                                                    infoDictionary: nil, defaults: suite.defaults))
        #expect(!services.isOnline && services.uploader(for: DocumentHandle.memory(title: "W")) == nil)
        // A stored document answers the version its local copy reached.
        let directory = TestStores.directory()
        let stored = TestStores.handle(in: directory)
        _ = await stored.openedModel()
        #expect(await services.serverSeq(of: stored) == 0)
        stored.close()
    }

    @Test func exportAndFinderOpenGoThroughTheFrontWindow() async throws {
        let (source, _) = try await WebLinkAndSymbolTests.symbolDocument("Leaf")
        let world = GlueWorld()
        defer { world.close() }
        let features = SymbolTransferFeatures()
        features.presenter.present = { _ in }
        #expect(features.presentExport() == nil && features.presentImport() == nil)
        // The defaults before the app sets them.
        #expect(features.storeURL("no-such-document-\(UUID().uuidString)") == nil && features.cachedBlob(String(repeating: "0", count: 64)) == nil)
        #expect(features.openDocuments().isEmpty && features.libraryDocuments().isEmpty)
        #expect(try await features.cloudState("x") == nil)
        try await features.storeBlobs([], world.document)
        features.window = { world.window }
        let export = try #require(features.presentExport())
        export.onClose()
        #expect(features.presenter.sheets[SymbolTransferFeatures.exportSheet] == nil)
        // A file opened from the Finder.
        let file = TestStores.directory().appending(path: "Leaf.wtsymbols")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SymbolSources.package(of: source.state).fileData.write(to: file)
        SymbolTransferFeatures.shared = features
        defer { SymbolTransferFeatures.shared = nil }
        #expect(SymbolTransferFeatures.opens(file))
        let model = try #require(features.presentImport())
        features.chooseFile = { file }
        await model.chooseFile()
        #expect(model.symbols.map(\.name) == ["Leaf"])
        // Storing the images fails: the sheet says why.
        struct Refused: Error {}
        features.storeBlobs = { _, _ in throw Refused() }
        var package = try #require(model.package)
        package.blobs["00"] = Data([1])
        let withImages = file.deletingLastPathComponent().appending(path: "Images.wtsymbols")
        try package.fileData.write(to: withImages)
        let failing = SymbolImportModel(target: world.document, features: features)
        await failing.load(file: withImages).value
        await failing.importChosen()?.value
        #expect(failing.message?.contains("could not be stored") == true)
        features.cachedBlob = { _ in Data([1]) }
        let withBlob = SymbolExportModel(document: source, features: features)
        #expect(withBlob.package.symbols.count == 1)
        // An asset the package needs takes the bytes found for it.
        var asset = Wiretuner_Doc_V1_NodeProps()
        asset.asset.sha256 = Data(repeating: 0xAB, count: 32)
        let needing = SymbolPackage(resources: [SymbolPackage.Resource(collection: WellKnown.assets, tree: NodeTree(props: asset))])
        let hash = try #require(needing.assetHashes.first)
        #expect(SymbolTransferFeatures.withBlobs(needing) { $0 == hash ? Data([9]) : nil }.blobs == [hash: Data([9])])
    }
}

/// The glue over a connected session: its transport is the blob transport of a web-link upload and
/// the cloud source of a symbol import.
@Suite(.serialized) @MainActor struct ConnectedGlueTests {
    @Test func aConnectedSessionLendsItsTransport() async throws {
        let suite = TestDefaults()
        defer { suite.remove() }
        let connector = CopyingConnector()
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults, syncConnector: connector)
        delegate.installPackageGlue()
        let handle = TestStores.handle(in: TestStores.directory())
        let session = delegate.sessions.session(for: handle)
        await session.start().value
        #expect(session.connection?.transport != nil)
        let services = AppWebLinkServices(sessions: delegate.sessions, isReachable: { true }, token: { "t" }, makeTransport: { FakeWebLinkServer() })
        let uploader = services.uploader(for: handle)
        #expect(uploader != nil && services.uploader(for: handle) === uploader && services.blobs(for: handle) != nil && services.events(for: handle) != nil)
        _ = try? await SymbolTransferFeatures.shared?.cloudState(handle.id)
        await session.stop()
        handle.close()
    }
}
