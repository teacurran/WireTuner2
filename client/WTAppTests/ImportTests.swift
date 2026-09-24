import AppKit
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import WebKit
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// Files to import, written to a throwaway folder.
@MainActor
final class ImportFiles {
    let directory = FileManager.default.temporaryDirectory.appending(path: "WireTunerImport-\(UUID().uuidString)")
    let blobs = FileManager.default.temporaryDirectory.appending(path: "WireTunerImportBlobs-\(UUID().uuidString)")

    static let staticSVG = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50"><rect width="40" height="20" fill="red"/></svg>"#
    static let filteredSVG = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50"><filter id="f"><feGaussianBlur stdDeviation="2"/></filter><rect width="40" height="20" filter="url(#f)"/></svg>"#
    static let animatedSVG = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 40"><circle cx="10" cy="20" r="8" fill="blue"><animate attributeName="cx" from="10" to="70" dur="2s" repeatCount="indefinite"/></circle></svg>"#

    init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(_ name: String, _ data: Data) -> URL {
        let url = directory.appending(path: name)
        try? data.write(to: url)
        return url
    }

    func text(_ name: String, _ text: String) -> URL { write(name, Data(text.utf8)) }

    /// A 20 × 10 pixel PNG.
    func png(_ name: String = "photo.png") -> URL {
        let context = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        return write(name, PosterRenderer.png(context.makeImage()!)!)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: blobs)
    }
}

/// A document window over a memory document, with an import controller whose alerts and panels
/// are recorded.
@MainActor
final class ImportWorld {
    let environment = TestEnvironment()
    let files = ImportFiles()
    let documents: DocumentController
    let window: DocumentWindowController
    let imports: ImportController
    private(set) var alerts: [(String, String)] = []

    init(importFiles: Bool = false, pasteboard: NSPasteboard? = nil) {
        var documentEnvironment = environment.document
        let imports = ImportController(preferences: environment.preferences)
        if importFiles {
            documentEnvironment.importFiles = { window, urls, point in imports.drop(urls, on: window, at: point) }
        }
        if let pasteboard {
            documentEnvironment.pasteImport = PasteImport(canPaste: { imports.canPaste(from: pasteboard) },
                                                          paste: { window in Task { await imports.paste(from: pasteboard, on: window) } })
        }
        documents = DocumentController(environment: documentEnvironment)
        window = documents.newDocument(show: false)
        self.imports = imports
        let blobs = files.blobs
        imports.blobs.directory = { blobs }
        imports.posters.web = { _, _ in nil }
        imports.showAlert = { [weak self] message, detail, _ in self?.alerts.append((message, detail)) }
    }

    var document: DocumentHandle { window.documentHandle }
    var state: EngineState { document.state }

    /// The live objects on the document's layers, bottom first.
    var objects: [OpID] {
        let order = LayerOrder(state)
        return order.layers.flatMap { order.objects(on: $0.id, in: state) }
    }

    func layer(_ name: String) async -> OpID {
        _ = await document.perform(CreateLayer(name: name, above: LayerOrder(state).layers.last?.id)).value
        return LayerOrder(state).layers.last!.id
    }

    func close() {
        documents.close(document.id)
        files.remove()
        environment.suite.remove()
    }
}

/// A drag of files over the canvas.
@MainActor
final class FileDragging: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint

    init(_ urls: [URL], at location: NSPoint = NSPoint(x: 100, y: 100)) {
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("wiretuner.test.drop.\(UUID().uuidString)"))
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(urls.map { $0 as NSURL })
        draggingLocation = location
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// menu:File[Import…], its options sheet, drops on the canvas and blob placement (IMG-005,
/// IMG-008, WEB-025).
@Suite(.serialized) @MainActor struct ImportTests {
    @Test func optionsAreEditedInTheSheetAndRememberedPerFormatAcrossLaunches() throws {
        let world = ImportWorld()
        defer { world.close() }
        #expect(world.imports.optionsModel(for: .png) == nil, "bitmaps have no options")
        #expect(world.imports.optionsModel(for: .eps) == nil, "no importer reads EPS yet")
        let pdf = try #require(world.imports.optionsModel(for: .pdf))
        #expect(pdf.title == "PDF Options")
        let notes = try #require(pdf.schema.fields.first { $0.key == "importNotes" })
        let pages = try #require(pdf.schema.fields.first { $0.key == "pages" })
        #expect(pdf.bool(notes))
        pdf.binding(bool: notes).wrappedValue = false
        pdf.binding(string: pages).wrappedValue = "2-3"
        #expect(!pdf.bool(notes) && pdf.string(pages) == "2-3")
        #expect(!pdf.bool(pages) && pdf.string(notes) == "", "a field of another kind reads as empty")
        pdf.save()
        // A later launch reads them back from the same defaults.
        let relaunched = ImportController(preferences: PreferenceStore(defaults: world.environment.suite.defaults))
        let again = try #require(relaunched.optionsModel(for: .pdf))
        #expect(!again.bool(notes) && again.string(pages) == "2-3")
        again.resetToDefaults()
        #expect(again.bool(notes) && again.string(pages) == "All")
        #expect(try #require(relaunched.optionsModel(for: .svg)).values["animation"] == .string("automatic"))
    }

    @Test func theOptionsSheetSavesOnOKAndEndsOnItsParent() throws {
        let world = ImportWorld()
        defer { world.close() }
        for format in [ImportFormat.pdf, .svg, .dxf] {
            let hosting = NSHostingView(rootView: ImportOptionsForm(model: try #require(world.imports.optionsModel(for: format))) { _ in })
            hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.height > 0)
        }
        let model = try #require(world.imports.optionsModel(for: .dxf))
        let units = try #require(model.schema.fields.first { $0.key == "units" })
        var finished: [Bool] = []
        let sheet = ImportOptionsSheet.window(model) { finished.append($0) }
        #expect(sheet.identifier == ImportOptionsSheet.identifier && sheet.title == "AutoCAD DXF Options")
        let form = try #require(sheet.contentViewController as? NSHostingController<ImportOptionsForm>)
        model.set(units, .string("points"))
        form.rootView.finish(false)
        #expect(try #require(world.imports.optionsModel(for: .dxf)).string(units) == "inches", "Cancel keeps the remembered values")
        form.rootView.finish(true)
        #expect(try #require(world.imports.optionsModel(for: .dxf)).string(units) == "points")
        #expect(finished == [false, true])

        // The sheet's own buttons.
        var pressed: [Bool] = []
        let buttons = ImportOptionsForm(model: model) { pressed.append($0) }
        buttons.cancel()
        buttons.confirm()
        #expect(pressed == [false, true])

        let parent = TestWindow.make(NSRect(x: 0, y: 0, width: 400, height: 300))
        let presented = ImportOptionsSheet.present(model, on: parent)
        #expect(parent.attachedSheet === presented || parent.sheets.contains(presented))
        try #require(presented.contentViewController as? NSHostingController<ImportOptionsForm>).rootView.finish(true)
        #expect(parent.attachedSheet == nil)
    }

    @Test func theImportPanelOffersEveryTypeAndTheSelectedFormatsOptions() throws {
        let world = ImportWorld()
        defer { world.close() }
        let panel = world.imports.makePanel()
        #expect(panel.allowsMultipleSelection && !panel.canChooseDirectories)
        #expect(panel.allowedContentTypes.contains(.png) && panel.allowedContentTypes.contains(.pdf))
        let accessory = try #require(world.imports.accessory)
        #expect(panel.delegate === accessory && accessory.window() === panel)
        #expect(accessory.summary == "No file selected" && !accessory.hasOptions)
        accessory.select(world.files.directory.appending(path: "a.pdf"))
        #expect(accessory.format == .pdf && accessory.hasOptions && accessory.summary == "PDF")
        accessory.select(world.files.directory.appending(path: "a.png"))
        #expect(!accessory.hasOptions)
        accessory.showOptions()
        #expect(accessory.sheet == nil, "a format without options opens nothing")
        accessory.panelSelectionDidChange(panel)
        #expect(accessory.format == nil)
        let hosting = NSHostingView(rootView: ImportPanelAccessory(model: accessory))
        hosting.layoutSubtreeIfNeeded()
        // Options… for an SVG goes on the window the accessory names.
        accessory.select(world.files.directory.appending(path: "a.svg"))
        let parent = TestWindow.make(NSRect(x: 0, y: 0, width: 400, height: 300))
        accessory.window = { parent }
        accessory.showOptions()
        let sheet = try #require(accessory.sheet)
        try #require(sheet.contentViewController as? NSHostingController<ImportOptionsForm>).rootView.finish(false)
        #expect(accessory.sheet == nil)
    }

    @Test func importPlacesTheChosenFilesCentredAndStackedAndSelectsThem() async throws {
        let world = ImportWorld()
        defer { world.close() }
        _ = world.environment.preferences.set(12, for: PreferenceCatalog.Sync.keepBothOffset)
        world.window.objectEditing.visibleCenter = { Point(x: 500, y: 400) }
        let png = world.files.png()
        let svg = world.files.text("shape.svg", ImportFiles.staticSVG)
        var panels: [NSOpenPanel] = []
        world.imports.runPanel = { panel, _ in
            panels.append(panel)
            return [png, svg]
        }
        // The panel's files wait under the import pointer (ImportPointerTests); placed at once
        // they are centred and stacked.
        let pointer = await world.imports.runImport(on: world.window)
        #expect(panels.count == 1 && world.imports.accessory == nil && pointer?.pointer.files == [png, svg])
        pointer?.cancel()
        let outcome = await world.imports.place([png, svg], on: world.window, at: nil)
        #expect(outcome.placed.count == 2 && outcome.failures.isEmpty)
        #expect(world.window.selection.selection.ids.map(\.opID) == outcome.placed)
        let image = world.state.props(outcome.placed[0]).image
        #expect(image.common.name == "photo.png" && image.pixels.pixelWidth == 20)
        // 20 × 10 px at 72 ppi centred on (500, 400).
        #expect(image.common.transform.tx == 490 && image.common.transform.ty == 395)
        // The SVG's 100 × 50 view box reads at 96 px/in: 75 × 37.5 pt.
        let expected: Double = 500 - 37.5 + 12
        #expect(world.state.props(outcome.placed[1]).group.common.transform.tx == expected)
        #expect(world.document.undoTitle == "Undo Import shape.svg")
        // The image's blob is in the cache; its link record names the file.
        let hash = ImportedBlob.hex(image.pixels.blobSha256)
        #expect(BlobCache(directory: world.files.blobs).contains(hash))
        #expect(world.state.props(OpID(image.source.id)).asset.link.path == png.path)

        world.imports.runPanel = { _, _ in [] }
        #expect(await world.imports.runImport(on: world.window) == nil)
        // Without a visible area the file is centred on the pasteboard's origin.
        world.window.objectEditing.visibleCenter = { nil }
        let centred = await world.imports.place([png], on: world.window, at: nil)
        #expect(world.state.props(centred.placed[0]).image.common.transform.tx == -10)
    }

    @Test func refusedFilesAreNamedInOneAlert() async throws {
        let world = ImportWorld()
        defer { world.close() }
        let unknown = world.files.text("notes.xyz", "hello")
        let broken = world.files.text("broken.png", "not a png")
        let missing = world.files.directory.appending(path: "gone.svg")
        let outcome = await world.imports.place([unknown, broken, missing], on: world.window, at: Point(x: 0, y: 0))
        #expect(outcome.placed.isEmpty && outcome.failures.count == 3)
        #expect(world.alerts.count == 1 && world.alerts[0].0 == "3 files could not be imported.")
        #expect(world.alerts[0].1.contains("notes.xyz") && world.alerts[0].1.contains("broken.png") && world.alerts[0].1.contains("gone.svg"))
        _ = await world.imports.place([unknown], on: world.window, at: Point(x: 0, y: 0))
        #expect(world.alerts.last?.0 == "A file could not be imported.")
        var small = ImportContext()
        small.maximumFileSize = 4
        await #expect(throws: ImportError.self) { try await world.imports.convert(world.files.png(), context: small) }
        #expect(world.imports.context.keepBothOffset == 10 && world.imports.context.downsampleLimit == 50_000_000)
    }

    @Test func aLockedCurrentLayerHandsTheImportToTheNearestEditableLayerAbove() async throws {
        let world = ImportWorld()
        defer { world.close() }
        let locked = await world.layer("Locked")
        let open = await world.layer("Open")
        _ = await world.document.perform(SetLayerFlag([locked], .locked, true)).value
        world.window.objectEditing.activeLayer = locked
        let svg = world.files.text("blurred.svg", ImportFiles.filteredSVG)
        let outcome = await world.imports.place([svg], on: world.window, at: Point(x: 20, y: 30))
        #expect(outcome.movedTo == open)
        #expect(world.window.objectEditing.activeLayer == open)
        #expect(LayerOrder(world.state).layer(of: outcome.placed[0], in: world.state) == open)
        let status = world.window.statusBar.message.stringValue
        #expect(status.contains("“Open”") && status.contains("blurred.svg:"))
        #expect(world.state.props(outcome.placed[0]).group.common.transform.tx == 20)
    }

    @Test func dropsOnTheCanvasPlaceAtThePointer() async throws {
        let world = ImportWorld(importFiles: true)
        defer { world.close() }
        let canvas = world.window.canvas
        let png = world.files.png()
        let unknown = world.files.text("readme.xyz", "x")
        #expect(canvas.draggingEntered(FileDragging([png])) == .copy)
        #expect(canvas.draggingEntered(FileDragging([])) == [])
        #expect(!canvas.performDragOperation(FileDragging([])))
        #expect(!canvas.performDragOperation(FileDragging([unknown])), "nothing importable")
        let location = NSPoint(x: 40, y: 60)
        #expect(canvas.performDragOperation(FileDragging([png, png], at: location)))
        #expect(await eventually { world.objects.count == 2 })
        let origin = canvas.viewport.toPasteboard(canvas.viewPoint(fromAppKit: canvas.convert(location, from: nil)))
        let first = world.state.props(world.objects[0]).image.common.transform
        #expect(abs(first.tx - origin.x) < 0.001 && abs(first.ty - origin.y) < 0.001)
        #expect(world.state.props(world.objects[1]).image.common.transform.tx - first.tx == 10)
        #expect(FileDrop.urls(from: FileDragging([png]).draggingPasteboard) == [png])

        let refusing = ImportWorld()
        defer { refusing.close() }
        #expect(refusing.window.canvas.onFileDrop == nil)
        #expect(refusing.window.canvas.draggingEntered(FileDragging([png])) == [])
        #expect(!refusing.window.canvas.performDragOperation(FileDragging([png])))
    }

    @Test func anAnimatedSVGIsPlacedWithItsPosterStoredFirst() async throws {
        let world = ImportWorld()
        defer { world.close() }
        let svg = world.files.text("wave.svg", ImportFiles.animatedSVG)
        let outcome = await world.imports.place([svg], on: world.window, at: Point(x: 0, y: 0))
        let props = world.state.props(try #require(outcome.placed.first)).svgAnimation
        #expect(props.kinds.smil && props.naturalSize.width == 60, "an 80-unit view box at 96 px/in")
        let poster = world.state.props(OpID(props.poster.id)).asset
        #expect(poster.mediaType == "image/png" && BlobCache(directory: world.files.blobs).contains(ImportedBlob.hex(poster.sha256)))
        #expect(world.document.undoTitle == "Undo Place wave.svg")
    }

    @Test func postersComeFromWebKitOrTheStaticDrawing() async throws {
        let svg = Data(ImportFiles.animatedSVG.utf8)
        let bounds = Rect(x: 0, y: 0, width: 80, height: 40)
        let renderer = PosterRenderer()
        renderer.timeout = .seconds(20)
        let web = try #require(await renderer.poster(svg: svg, bounds: bounds))
        #expect(web.uti == UTType.png.identifier)
        // A WebKit that never answers: the static drawing after the timeout.
        renderer.web = { _, _ in
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
        renderer.timeout = .milliseconds(50)
        let fallback = try #require(await renderer.poster(svg: svg, bounds: bounds))
        let image = try #require(NSImage(data: fallback.data)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(image.width == 160 && image.height == 80)
        renderer.web = { _, _ in nil }
        #expect(await renderer.poster(svg: Data("nonsense".utf8), bounds: bounds) == nil)
        #expect(PosterRenderer.pixelSize(Rect(x: 0, y: 0, width: 5_000, height: 100)) == Size(width: 4_096, height: 82))
        #expect(PosterRenderer.pixelSize(Rect(x: 0, y: 0, width: 0, height: 0)) == Size(width: 2, height: 2))
        let delegate = WebPosterSnapshot()
        delegate.webView(WKWebView(), didFail: nil, withError: CancellationError())
        delegate.webView(WKWebView(), didFailProvisionalNavigation: nil, withError: CancellationError())
    }

    @Test func blobsGoThroughTheSessionQueueOrStraightIntoTheStore() async throws {
        let files = ImportFiles()
        defer { files.remove() }
        let blob = ImportedBlob(data: Data([1, 2, 3, 4]), uti: UTType.png.identifier)
        let stores = TestStores.directory()
        let stored = TestStores.handle(in: stores)
        let directory = files.blobs
        var placement = BlobPlacement()
        placement.directory = { directory }
        try await placement.store([blob], for: stored)
        let store = try #require(await stored.openedModel()?.backend as? LocalStore)
        #expect(try await store.pendingBlobs().map(\.hash) == [blob.hex])
        #expect(placement.cached(blob.sha256) == blob.data)
        #expect(placement.cached(Data(repeating: 0, count: 32)) == nil)
        // A session's queue caches and queues in one step.
        let queueCache = files.blobs.appending(path: "queue")
        let queue = BlobQueue(store: store, cache: BlobCache(directory: queueCache), transport: FakeSyncTransport(server: FakeSyncServer()), tokens: StaticTokens())
        placement.queue = { _ in queue }
        let other = ImportedBlob(data: Data([9, 9]), uti: UTType.png.identifier)
        try await placement.store([other], for: stored)
        #expect(BlobCache(directory: queueCache).contains(other.hex))
        #expect(try await store.pendingBlobs().map(\.hash).contains(other.hex))
        var failing = BlobPlacement()
        failing.directory = { throw CocoaError(.fileNoSuchFile) }
        #expect(failing.cached(blob.sha256) == nil)
        #expect(BlobPlacement().cached(Data(repeating: 0xAB, count: 32)) == nil, "the app's own cache")
        stored.close()
    }

    @Test func panelsRunAsSheetsOnTheWindow() async {
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 600, height: 400))
        let open = NSOpenPanel()
        let chosen = Task { await ModalUI.urls(open, on: window) }
        #expect(await eventually { window.attachedSheet != nil })
        open.cancel(nil)
        #expect(await chosen.value == [])
        let save = NSSavePanel()
        let location = Task { await ModalUI.url(save, on: window) }
        #expect(await eventually { window.attachedSheet != nil })
        save.cancel(nil)
        #expect(await location.value == nil)
    }

    @Test func alertsGoOnTheWindowAsSheets() {
        let environment = TestEnvironment()
        defer { environment.suite.remove() }
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 400, height: 300))
        ImportController(preferences: environment.preferences).showAlert("Message", "Detail", window)
        #expect(window.attachedSheet != nil)
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        PackageController().showAlert("Message", "Detail", window)
        #expect(window.attachedSheet != nil)
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
    }

    @Test func theCommandsActOnTheFrontWindow() async throws {
        let world = ImportWorld()
        defer { world.close() }
        final class Front {
            var window: DocumentWindowController?
            var calls: [String] = []
        }
        let front = Front()
        let hooks = ImportCommands.Hooks(
            window: { front.window },
            importFiles: { _ in front.calls.append("import") },
            openPackage: { front.calls.append("open") },
            exportPackage: { _ in front.calls.append("export") }
        )
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        ImportCommands.install(into: registry, hooks: hooks)
        let importCommand = try #require(registry.command(ImportCommands.ID.importFile))
        #expect(importCommand.defaultKey == KeyEquivalent("r", .command) && importCommand.title == "Import…")
        #expect(importCommand.validation() == .disabled(ImportCommands.noDocument))
        #expect(registry.command(ImportCommands.ID.exportPackage)?.validation() == .disabled(ImportCommands.noDocument))
        #expect(registry.perform(ImportCommands.ID.openPackage))
        front.window = world.window
        #expect(importCommand.validation() == .enabled)
        #expect(registry.perform(ImportCommands.ID.importFile) && registry.perform(ImportCommands.ID.exportPackage))
        front.window = nil
        if case .perform(let run) = importCommand.action { run() }
        if case .perform(let run) = try #require(registry.command(ImportCommands.ID.exportPackage)).action { run() }
        #expect(front.calls == ["open", "import", "export"])

        // The app's hooks start the panels.
        let packages = PackageController()
        var saved = 0
        var opened = 0
        packages.runSavePanel = { _, _ in saved += 1; return nil }
        packages.runOpenPanel = { _, _ in opened += 1; return [] }
        world.imports.runPanel = { _, _ in [] }
        let appHooks = ImportCommands.hooks(imports: world.imports, packages: packages) { world.window }
        appHooks.importFiles(world.window)
        appHooks.openPackage()
        appHooks.exportPackage(world.window)
        #expect(await eventually { saved == 1 && opened == 1 })
    }
}
