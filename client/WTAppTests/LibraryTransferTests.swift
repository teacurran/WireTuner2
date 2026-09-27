import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// `LibraryService` in memory for the app's team library features.
final class FakeTeamLibraryService: TeamLibraryTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _libraries: [String: [Wiretuner_Docs_V1_Library]] = [:]
    private var _offline = false
    private var _published: [String] = []

    struct Offline: Error {}

    var offline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }

    var published: [String] { lock.withLock { _published } }

    func add(team: String, id: String, name: String, head: UInt64) {
        lock.withLock {
            _libraries[team, default: []].append(.with {
                $0.documentID = id
                $0.teamID = team
                $0.name = name
                $0.headSeq = head
            })
        }
    }

    private func check() throws {
        if offline { throw Offline() }
    }

    func setLibrary(_ request: Wiretuner_Docs_V1_SetLibraryRequest, token: String) async throws -> Wiretuner_Docs_V1_SetLibraryResponse {
        try check()
        lock.withLock { _published.append(request.documentID) }
        return .with { $0.library = .with { $0.documentID = request.documentID } }
    }

    func listLibraries(_ request: Wiretuner_Docs_V1_ListLibrariesRequest, token: String) async throws -> Wiretuner_Docs_V1_ListLibrariesResponse {
        try check()
        let libraries = lock.withLock { _libraries[request.teamID] ?? [] }
        return .with { $0.libraries = libraries }
    }

    func getLibrary(_ request: Wiretuner_Docs_V1_GetLibraryRequest, token: String) async throws -> Wiretuner_Docs_V1_GetLibraryResponse {
        try check()
        return .with { $0.library = .with { $0.documentID = request.documentID } }
    }
}

/// LIB-016's app half: the libraries listed and read into the catalog, *Show Team Libraries*,
/// *Update from Library*, placing by drag, *Export to Team Library…*, *Use as Team Library*, and
/// every one disabled offline.
@Suite(.serialized) @MainActor struct TeamLibraryFeaturesTests {
    static let teamID = "0190a0d4-0000-7000-8000-0000000000aa"
    static let libraryID = "0190a0d4-0000-7000-8000-00000000000a"

    /// A library document holding the symbol Badge.
    static func libraryDocument() async throws -> (DocumentHandle, OpID) {
        let handle = DocumentHandle.memory(id: "library-source", title: "Marketing")
        let art = try #require(await handle.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)]).first)
        _ = await handle.perform(ConvertToSymbol([art.opID], name: "Badge")).value
        await handle.settle()
        return (handle, try #require(Symbols.symbols(in: handle.state).first))
    }

    @MainActor struct World {
        let environment = TestEnvironment()
        let documents: DocumentController
        let server = FakeLibraryServer()
        let service = FakeTeamLibraryService()
        let library: LibraryModel
        let window: DocumentWindowController
        let features: TeamLibraryFeatures
        let presented = TestBox<[String]>([])

        init(source: DocumentHandle, client: Bool = true) {
            documents = DocumentController(environment: environment.document)
            window = documents.open(.memory(title: "Poster"), show: false)
            library = LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
            server.setTeams([LibrarySpace(id: TeamLibraryFeaturesTests.teamID, name: "Studio", kind: .team)])
            server.put(LibraryDocument(id: TeamLibraryFeaturesTests.libraryID, spaceID: TeamLibraryFeaturesTests.teamID, name: "Marketing", role: .editor))
            service.add(team: TeamLibraryFeaturesTests.teamID, id: TeamLibraryFeaturesTests.libraryID, name: "Marketing", head: 5)
            let state = source.state
            let made = client ? TeamLibraryClient(transport: service, sync: nil,
                                                 directory: FileManager.default.temporaryDirectory.appending(component: "libs-\(UUID().uuidString)"),
                                                 local: { _ in (state, 5) }, token: { "t" }) : nil
            features = TeamLibraryFeatures(catalog: TeamLibraryCatalogModel(), library: library, documents: documents, client: made)
            let presented = presented
            let sheets = SheetPresenter()
            sheets.present = { presented.value.append($0.identifier?.rawValue ?? "") }
            features.sheets = sheets
        }

        func close() { window.close() }
    }

    static func panels() -> PanelRegistry {
        let panels = PanelRegistry()
        _ = panels.registerIfAbsent(PanelDescriptor(id: "library", title: "Library", defaultGroup: "g", menuOrder: 1, optionsMenu: {
            [PanelMenuItem(title: "New Folder") {}]
        }) { NSView() })
        return panels
    }

    @Test func librariesAreListedPlacedUpdatedAndExported() async throws {
        let (source, badge) = try await Self.libraryDocument()
        let world = World(source: source)
        defer { world.close() }
        await world.library.refresh()
        let panels = Self.panels()
        world.features.install(panels: panels)
        await world.features.refresh()
        #expect(world.features.libraries.map(\.name) == ["Marketing"] && world.features.isOnline)
        #expect(world.features.catalog.catalog.libraries.map(\.name) == ["Marketing"])

        // *Show Team Libraries* toggles the section; the menu keeps the panel's own items.
        let menu = try #require(panels.descriptor(for: PanelID("library"))).optionsMenu()
        #expect(menu.map(\.title) == ["New Folder", "Hide Team Libraries", "Update from Library", "Export to Team Library…"])
        menu[1].action()
        #expect(!world.features.catalog.showsInLibraryPanel)
        Render.view(TeamLibraryCatalogSection(model: world.features.catalog, kind: .symbol, inLibraryPanel: true))
        world.features.libraryMenu()[0].action()
        #expect(world.features.catalog.showsInLibraryPanel)
        world.features.catalog.isExpanded(Self.libraryID).wrappedValue = true
        Render.view(TeamLibraryCatalogSection(model: world.features.catalog, kind: .symbol, inLibraryPanel: true))

        // A drop on the canvas places an instance of a copy with its provenance.
        let item = try #require(world.features.catalog.sections(.symbol).first?.items.first)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("team-lib-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(Data(TeamLibraryDrag.string(item).utf8), forType: TeamLibraryDrag.type)
        #expect(TeamLibraryDrag.carries(pasteboard))
        #expect(TeamLibraryDrag.perform(pasteboard, at: Point(x: 40, y: 50), in: world.window.documentHandle))
        await world.window.documentHandle.settle()
        let state = world.window.documentHandle.state
        let copy = try #require(Symbols.symbols(in: state).first)
        #expect(LibraryBadge.of(copy, in: state, catalog: world.features.catalog.catalog)?.sourceNode == badge)
        #expect(Symbols.instanceIndex(in: state)[copy]?.count == 1)
        #expect(TeamLibraryDrag.parse("nope") == nil && TeamLibraryDrag.parse("a|b") == nil)
        #expect(TeamLibraryDrag.provider(item).hasItemConformingToTypeIdentifier(TeamLibraryDrag.type.rawValue))

        // *Update from Library* on the selected symbol.
        let symbols = SymbolLibraryModel(selection: ActiveSelection(model: world.window.selection.model, document: world.window.documentHandle,
                                                                   editing: world.window.objectEditing))
        world.features.symbols = symbols
        #expect(world.features.selectedCopy == nil && world.features.updateSelected() == nil)
        symbols.click(copy)
        #expect(world.features.selectedCopy?.symbol == copy)
        #expect(world.features.libraryMenu()[1].isEnabled)
        #expect(await world.features.updateSelected()?.value?.label == "Update from Library")

        // *Export to Team Library…*: the library opens and the symbol is added to it.
        #expect(world.features.exportLibraries.map(\.name) == ["Marketing"])
        world.features.libraryMenu()[2].action()
        #expect(world.presented.value == [TeamLibraryFeatures.exportSheet] && world.features.exporting == .symbols([copy]))
        Render.view(TeamLibraryExportSheet(model: world.features))
        let exported = await world.features.confirmExport()?.value
        #expect(exported?.label == "Import Symbol")
        let opened = try #require(world.documents.document(id: Self.libraryID))
        #expect(Symbols.symbols(in: opened.state).count == 1)
        world.features.beginExport(.styles([]))
        world.features.cancelExport()
        #expect(world.features.exporting == nil)
        #expect(TeamLibraryFeatures.Export.styles([copy, copy]).count == 2)
        world.documents.windowControllers[Self.libraryID]?.close()
    }

    @Test func useAsTeamLibraryNeedsATeamDocumentItsOwnerAndTheConnection() async throws {
        let (source, _) = try await Self.libraryDocument()
        let world = World(source: source)
        defer { world.close() }
        await world.library.refresh()
        world.features.install(panels: Self.panels())
        let personal = LibraryDocument(id: "p", spaceID: "me", name: "Mine", role: .owner)
        let shared = LibraryDocument(id: "e", spaceID: Self.teamID, name: "Theirs", role: .editor)
        let owned = LibraryDocument(id: "0190a0d4-0000-7000-8000-0000000000ee", spaceID: Self.teamID, name: "Icons", role: .owner)
        #expect(world.features.refusal(for: personal) == "Move the document to a team folder first")
        #expect(world.features.refusal(for: shared) == "Only the document's owner can make it a team library")
        #expect(world.library.teamLibraryRefusal?(owned) == nil)
        await world.features.useAsTeamLibrary(personal)
        #expect(world.features.message == "Move the document to a team folder first")
        await world.features.useAsTeamLibrary(owned)
        #expect(world.service.published == [owned.id] && world.features.message == nil)
        world.library.useAsTeamLibrary?(owned)
        world.service.offline = true
        await world.features.useAsTeamLibrary(owned)
        #expect(world.features.message?.hasPrefix("The document could not be made a team library") == true)

        // Offline: the listing is the cached one, and placing and updating say why they cannot.
        await world.features.refresh()
        #expect(!world.features.isOnline)
        #expect(world.features.place(OpID(counter: 1, replica: 1), from: Self.libraryID, at: .zero, in: world.window.documentHandle) == nil)
        #expect(world.features.message == TeamLibraryCatalogModel.offline)
        #expect(world.features.updateSelected() == nil)
        world.features.beginExport(.symbols([]))
        #expect(world.presented.value.isEmpty)
        #expect(!world.features.libraryMenu()[1].isEnabled && !world.features.libraryMenu()[2].isEnabled)
        Render.view(TeamLibraryCatalogSection(model: world.features.catalog, kind: .symbol, inLibraryPanel: true))
    }

    @Test func withoutAClientNothingIsOffered() async throws {
        let (source, _) = try await Self.libraryDocument()
        let world = World(source: source, client: false)
        defer { world.close() }
        await world.features.refresh()
        #expect(!world.features.isOnline)
        #expect(world.features.refusal(for: LibraryDocument(id: "x", spaceID: Self.teamID, name: "X", role: .owner)) == TeamLibraryCatalogModel.offline)
        #expect(world.features.confirmExport() == nil)
    }
}

/// LIB-022's app half: *Import…* from another document, a team library or a file, with *Replace
/// styles with the same name*; *Export…* to a file or a team library.
@Suite(.serialized) @MainActor struct StyleTransferModelTests {
    @Test func stylesImportFromAnotherDocumentAndAFileAndExportToAFile() async throws {
        let environment = TestEnvironment()
        let documents = DocumentController(environment: environment.document)
        let other = documents.open(.memory(title: "Brand"), show: false)
        _ = await other.documentHandle.perform(CreateGraphicStyle(.defaults)).value
        let front = documents.open(.memory(title: "Poster"), show: false)
        defer {
            front.close()
            other.close()
        }
        let model = StyleTransferModel(documents: documents, teamLibraries: nil)
        let presented = TestBox<[String]>([])
        let sheets = SheetPresenter()
        sheets.present = { presented.value.append($0.identifier?.rawValue ?? "") }
        model.sheets = sheets
        model.blobCache = { nil }
        #expect(model.front?.id == front.documentHandle.id)
        #expect(model.sources.map(\.title) == ["Brand"])

        // The panel's Import… and Export… become live.
        let panels = PanelRegistry()
        _ = panels.registerIfAbsent(PanelDescriptor(id: "styles", title: "Styles", defaultGroup: "g", menuOrder: 1, optionsMenu: {
            [PanelMenuItem(title: "New") {}, PanelMenuItem(title: "Import…", isEnabled: false) {}, PanelMenuItem(title: "Export…", isEnabled: false) {}]
        }) { NSView() })
        model.install(panels: panels)
        let menu = try #require(panels.descriptor(for: PanelID("styles"))).optionsMenu()
        #expect(menu.map(\.isEnabled) == [true, true, true])
        menu[1].action()
        #expect(presented.value == [StyleTransferModel.importSheet])
        StyleImportSheet.chosen(nil, model)
        await model.choose(model.sources[0])
        let names = model.package?.names ?? []
        #expect(names.count == GraphicStyleFields.styles(in: other.documentHandle.state, GraphicStyleResolver(other.documentHandle.state)).count)
        #expect(!model.chosen.isEmpty && model.canImport)
        Render.view(StyleImportSheet(model: model))
        let before = GraphicStyleFields.styles(in: front.documentHandle.state, GraphicStyleResolver(front.documentHandle.state)).count
        let change = await model.confirmImport()?.value
        #expect(change?.label.hasPrefix("Import") == true)
        let after = GraphicStyleFields.styles(in: front.documentHandle.state, GraphicStyleResolver(front.documentHandle.state)).count
        #expect(after == before + names.count)

        // Export to a file and read it back as an import source.
        let url = FileManager.default.temporaryDirectory.appending(component: "styles-\(UUID().uuidString).wtstyles")
        model.chooseDestination = { _ in url }
        menu[2].action()
        #expect(presented.value.last == StyleTransferModel.exportSheet && !model.exportChosen.isEmpty)
        Render.view(StyleExportSheet(model: model))
        #expect(!model.canExportToTeamLibrary)
        model.exportToTeamLibrary()
        #expect(model.exportToFile() == url)
        let written = try StylePackage(fileData: Data(contentsOf: url))
        #expect(written.names.count == model.exportable.count)
        model.chooseFile = { url }
        await model.chooseStyleFile()
        #expect(model.source == .file(url) && model.package?.names == written.names && model.sources.last == .file(url))
        model.replacing = true
        _ = await model.confirmImport()?.value
        #expect(GraphicStyleFields.styles(in: front.documentHandle.state, GraphicStyleResolver(front.documentHandle.state)).count == after,
                "replacing: same names, no new styles")

        // A file that is not a style library; a cancelled chooser; nothing chosen.
        let bad = FileManager.default.temporaryDirectory.appending(component: "bad-\(UUID().uuidString).wtstyles")
        try Data("nope".utf8).write(to: bad)
        await model.choose(.file(bad))
        #expect(model.message == "The file is not a style library" && !model.canImport)
        model.chooseFile = { nil }
        await model.chooseStyleFile()
        model.chosen = []
        #expect(model.confirmImport() == nil)
        model.chooseDestination = { _ in nil }
        #expect(model.exportToFile() == nil)
        #expect(StyleTransferModel.Source.library(id: "l", name: "Web").title == "Web (team library)")
        #expect(StyleTransferModel.describe(CocoaError(.fileNoSuchFile)).hasPrefix("The styles could not be read"))
        model.cancelImport()
        model.cancelExport()
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: bad)
    }
}

/// IMG-028's app half: the Remove Background sheet with a stand-in segmenter, both results, the
/// refusals, and *Select Subject* seeding the Trace tool.
@Suite(.serialized) @MainActor struct RemoveBackgroundTests {
    /// Two subjects: the left and the right half of the image.
    struct Halves: SubjectSegmenter {
        func segment(_ image: CGImage) throws -> SubjectSegmentation? {
            let width = image.width, height = image.height
            var left = [UInt8](repeating: 0, count: width * height)
            var right = left
            for y in 0..<height {
                for x in 0..<width {
                    if x < width / 2 { left[y * width + x] = 255 } else if x >= width * 3 / 4 { right[y * width + x] = 255 }
                }
            }
            return SubjectSegmentation(width: width, height: height, instances: [1: SubjectMaskBuffer(width: width, height: height, values: left)!,
                                                                                2: SubjectMaskBuffer(width: width, height: height, values: right)!])
        }
    }

    struct Nothing: SubjectSegmenter {
        func segment(_ image: CGImage) throws -> SubjectSegmentation? { nil }
    }

    /// A 40 × 20 PNG in a scratch blob cache, placed in `window`'s document.
    static func placed(in window: DocumentWindowController, directory: URL) async throws -> (OpID, CGImage) {
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        let hash = try BlobCache(directory: directory).insert(data as Data)
        var pixels = Wiretuner_Doc_V1_PixelSource()
        pixels.blobSha256 = Data(stride(from: 0, to: hash.count, by: 2).map { offset in
            let start = hash.index(hash.startIndex, offsetBy: offset)
            return UInt8(hash[start..<hash.index(start, offsetBy: 2)], radix: 16)!
        })
        pixels.format = "public.png"
        pixels.pixelWidth = 40
        pixels.pixelHeight = 20
        pixels.mode = .rgb
        pixels.bitsPerChannel = 8
        let change = await window.documentHandle.perform(PlaceImage(pixels, name: "photo.png")).value
        return (try #require(change?.createdObjects.first), image)
    }

    @Test func theSheetMakesATransparentImageOrAClippingPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(component: "rb-\(UUID().uuidString)")
        let environment = TestEnvironment()
        let images = ImageFeatures(preferences: environment.preferences)
        images.blobDirectory = { directory }
        images.install(tools: environment.tools)
        let window = DocumentWindowController(document: .memory(title: "Photo"), environment: environment.document)
        defer { window.close() }
        let (node, _) = try await Self.placed(in: window, directory: directory)
        let original = window.documentHandle.state.props(node).image.pixels.blobSha256

        // Refusals: nothing selected; the image selected is fine; commands follow.
        let stored = TestBox<[Data]>([])
        let commands = RemoveBackgroundModel.commands(window: { window }, images: images) { data, _ in stored.value.append(data) }
        #expect(commands.map(\.title) == ["Remove Background…", "Select Subject"])
        #expect(commands[0].validation() == .disabled("Select an image"))
        window.selection.model.set(Selection([SelectionID(node)]))
        #expect(commands[0].validation() == .enabled)
        #expect(RemoveBackgroundModel.target(nil, isCached: { _ in true }) == .refused("No document is open"))

        let model = try #require(RemoveBackgroundModel.open(node, in: window, images: images) { data, _ in stored.value.append(data) })
        model.close()
        let sheet = RemoveBackgroundModel(window: window, node: node, image: model.image) { data, _ in stored.value.append(data) }
        let presented = TestBox<Int>(0)
        let sheets = SheetPresenter()
        sheets.present = { _ in presented.value += 1 }
        sheet.sheets = sheets
        sheet.segmenter = Halves()
        sheet.present()
        await sheet.start().value
        #expect(presented.value == 1 && sheet.chosen == [1, 2] && sheet.canRemove && sheet.name == "photo.png")
        Render.view(RemoveBackgroundSheet(model: sheet))
        #expect(sheet.preview(side: 20)?.width == 20)
        sheet.click(at: Point(x: 0.1, y: 0.5), adding: false)
        #expect(sheet.chosen == [1])
        sheet.click(at: Point(x: 0.9, y: 0.5), adding: true)
        #expect(sheet.chosen == [1, 2])
        sheet.click(at: Point(x: 0.9, y: 0.5), adding: true)
        sheet.click(at: Point(x: 0.6, y: 0.5), adding: false)
        #expect(sheet.chosen == [1], "a click on the background changes nothing")

        // *Transparent image*: the PNG is stored and replaces the pixels.
        let transparent = await sheet.remove()?.value
        #expect(transparent?.label == "Remove background from photo.png" && stored.value.count == 1)
        let image = window.documentHandle.state.props(node).image
        #expect(image.pixels.hasAlpha_p && image.pixels.blobSha256 == RemoveBackgroundModel.pixels(stored.value[0], width: 40, height: 20).blobSha256)
        #expect(image.pixels.pixelWidth == 40 && image.pixels.pixelHeight == 20, "the alpha PNG keeps the image's dimensions")
        let decoded = try #require(CGImageSourceCreateWithData(stored.value[0] as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(decoded.width == 40 && decoded.height == 20 && decoded.alphaInfo != .none)
        _ = await window.documentHandle.undo().value
        #expect(window.documentHandle.state.props(node).image.pixels.blobSha256 == original, "undo restores the original hash")
        _ = await window.documentHandle.redo().value

        // *Clipping path*: the image inside a path around the subject.
        sheet.result = .clippingPath
        let clipped = await sheet.remove()?.value
        #expect(clipped?.label == "Clip photo.png to subject")
        let group = try #require(Objects.parent(of: node, in: window.documentHandle.state))
        #expect(ClipGroups.clipPath(of: group, in: window.documentHandle.state) != nil)

        // No subject found; a deleted image.
        let empty = RemoveBackgroundModel(window: window, node: node, image: model.image) { _, _ in }
        empty.segmenter = Nothing()
        await empty.start().value
        #expect(empty.message == "No subject was found in this image" && !empty.canRemove && empty.remove() == nil)
        #expect(empty.preview(side: 10) != nil)
        _ = await window.documentHandle.perform(OpsCommand("Delete", ops: [Ops.setDeleted(node)])).value
        #expect(sheet.remove() == nil && sheet.message == "The image was deleted")
        for result in RemoveBackgroundModel.Result.allCases { #expect(!result.title.isEmpty) }
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func selectSubjectLeavesTheTraceToolWithTheSubjectSelected() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(component: "rb-\(UUID().uuidString)")
        let environment = TestEnvironment()
        let images = ImageFeatures(preferences: environment.preferences)
        images.blobDirectory = { directory }
        images.install(tools: environment.tools)
        let window = DocumentWindowController(document: .memory(title: "Photo"), environment: environment.document)
        defer { window.close() }
        let (node, _) = try await Self.placed(in: window, directory: directory)
        let selection = try #require(await RemoveBackgroundModel.selectSubject(node, in: window, images: images, segmenter: Halves()))
        #expect(window.toolManager.activeToolID == TraceTool.id)
        let tool = try #require(window.toolManager.activeTool as? TraceTool)
        #expect(tool.wand?.selection == selection && selection.count > 0)
        let width = selection.width
        let columns = (0..<width).filter { $0 < width / 2 || $0 >= width * 3 / 4 }.count
        #expect(selection.count == columns * selection.height)
        #expect(await RemoveBackgroundModel.selectSubject(node, in: window, images: images, segmenter: Nothing()) == nil)
        #expect(WandSelection(width: 2, height: 1, mask: [1]).isEmpty, "a mask of the wrong size selects nothing")
        try? FileManager.default.removeItem(at: directory)
    }
}
