import AppKit
import OSLog
import SwiftUI
import SystemConfiguration
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTSync

/// Where an import's blobs go before the change that references them (importing.adoc, "Offline
/// behavior"; SYNC-008): through the document's sync session's blob queue when it has one (cached
/// and queued for upload), else into the blob cache and the store's `blobs_pending` directly (the
/// session picks them up when it starts), else -- a memory document -- into the cache alone.
@MainActor
struct BlobPlacement {
    /// The blob cache's directory.
    var directory: @Sendable () throws -> URL = { try BlobCache.defaultDirectory() }
    /// The document's session's blob queue, if it runs one.
    var queue: @MainActor (DocumentHandle) -> BlobQueue? = { _ in nil }

    /// Stores `blobs` in order (a poster before its animation) for `document`.
    func store(_ blobs: [ImportedBlob], for document: DocumentHandle) async throws {
        try await store(blobs.map { (data: $0.data, mediaType: $0.mediaType) }, for: document)
    }

    /// Stores encoded files with their media types, in order, for `document`.
    func store(_ blobs: [(data: Data, mediaType: String)], for document: DocumentHandle) async throws {
        if let queue = queue(document) {
            for blob in blobs { try await queue.add(blob.data, mediaType: blob.mediaType) }
            return
        }
        let cache = BlobCache(directory: try directory())
        let store = await document.openedModel()?.backend as? LocalStore
        for blob in blobs {
            let hash = try cache.insert(blob.data)
            try await store?.addPendingBlob(LocalStore.PendingBlob(hash: hash, path: cache.url(for: hash).path, size: Int64(blob.data.count),
                                                                   mediaType: blob.mediaType))
        }
    }

    /// The cached bytes of the blob `sha256`, nil when this Mac does not have it.
    func cached(_ sha256: Data) -> Data? {
        guard let directory = try? directory() else { return nil }
        return try? Data(contentsOf: BlobCache(directory: directory).url(for: ImportedBlob.hex(sha256)))
    }
}

/// The panels and alerts of importing and packages: sheets on a window, application-modal
/// without one.
@MainActor
enum ModalUI {
    /// `panel` run until it closes; whether the user confirmed it.
    static func run(_ panel: NSSavePanel, on window: NSWindow?) async -> Bool {
        guard let window = host(window) else { return panel.runModal() == .OK }
        return await panel.beginSheetModal(for: window) == .OK
    }

    /// The window a sheet goes on: `window`'s front sheet when one is open (a *Choose…* button on
    /// the Publish sheet), since a second sheet on the window itself waits, unseen, until the
    /// first closes.
    static func host(_ window: NSWindow?) -> NSWindow? {
        var host = window
        while let sheet = host?.attachedSheet { host = sheet }
        return host
    }

    /// The files chosen in `panel`, none when it was cancelled.
    static func urls(_ panel: NSOpenPanel, on window: NSWindow?) async -> [URL] {
        await run(panel, on: window) ? panel.urls : []
    }

    /// The location chosen in `panel`, nil when it was cancelled.
    static func url(_ panel: NSSavePanel, on window: NSWindow?) async -> URL? {
        await run(panel, on: window) ? panel.url : nil
    }

    /// An alert saying `message` with `detail` below it.
    static func alert(_ message: String, _ detail: String, on window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        guard let window = host(window) else {
            alert.runModal()
            return
        }
        alert.beginSheetModal(for: window)
    }
}

/// Reads dropped or pasted file URLs off a pasteboard.
enum FileDrop {
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

/// What one import did: the objects placed, the files refused with why, the converters' notes and
/// whether the current layer could not take the artwork.
struct ImportOutcome: Equatable {
    var placed: [OpID] = []
    var failures: [String] = []
    var notes: [String] = []
    /// The layer the artwork went onto instead of a locked or hidden current layer.
    var movedTo: OpID?
}

/// menu:File[Import…] and files dropped on the canvas (importing.adoc; IMG-005, IMG-008,
/// WEB-025): each file is converted off the main actor with its format's remembered options, its
/// blobs stored and queued (an animation's poster first), and placed by one change -- at its natural
/// size, its top-left corner at the drop point (or the whole centred in the view), several files
/// stacked by the *Keep both offset*.  The placed objects are selected; a locked or hidden current
/// layer hands over to the nearest editable one above, which becomes current and is named in the
/// status bar with the converters' notes; files that cannot be imported are named in one alert.
@MainActor
final class ImportController {
    static let logger = Logger(subsystem: "com.villagecompute.wiretuner", category: "import")

    let registry: ImportRegistry
    let preferences: PreferenceStore
    /// Each format's remembered options (in the preferences' defaults, so they survive launches).
    let options: ImportOptionsStore
    var blobs = BlobPlacement()
    let posters = PosterRenderer()
    /// This Mac's name for link records.
    var device: String = SCDynamicStoreCopyComputerName(nil, nil).map { $0 as String } ?? ""
    /// Runs the Import panel; the chosen files (the test hook replaces it).
    var runPanel: @MainActor (NSOpenPanel, NSWindow?) async -> [URL] = ModalUI.urls
    /// Shows an alert with `message` and `detail` (the test hook records it).
    var showAlert: @MainActor (String, String, NSWindow?) -> Void = ModalUI.alert
    /// The *Embedded image profiles* preference's *Ask* sheet (CMS-012; `EmbeddedProfileChoice.swift`,
    /// the test hook replaces it): the profile's name in, the choice out.
    var askEmbeddedProfile: @MainActor (String, NSWindow?) async -> EmbeddedProfilePolicy = ModalUI.embeddedProfile
    /// The panel's accessory model while it is open.
    private(set) var accessory: ImportPanelAccessoryModel?

    init(preferences: PreferenceStore, registry: ImportRegistry = .standard) {
        self.preferences = preferences
        self.registry = registry
        options = ImportOptionsStore(storage: preferences.defaults)
    }

    /// The converters' preferences: *Downsample images larger than* and *Keep both offset*.
    var context: ImportContext {
        var context = ImportContext(downsampleMegapixels: preferences[PreferenceCatalog.Import.downsampleMegapixels])
        context.keepBothOffset = preferences[PreferenceCatalog.Sync.keepBothOffset]
        return context
    }

    /// The options sheet's model for `format`.
    func optionsModel(for format: ImportFormat) -> ImportOptionsModel? {
        let schema = registry.importer(for: format)?.optionsSchema(for: format) ?? ImportOptionsSchema(fields: [])
        return schema.isEmpty ? nil : ImportOptionsModel(format: format, schema: schema, store: options)
    }

    // MARK: The Import panel

    /// The Import panel: every importable type, several files at once, with the btn:[Options…]
    /// accessory for the selected file's format.
    func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Import"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = registry.acceptedTypes + [StyleTransferModel.libraryType, SymbolTransferFeatures.libraryType]
        let accessory = ImportPanelAccessoryModel(importer: self)
        accessory.window = { [weak panel] in panel }
        panel.delegate = accessory
        panel.accessoryView = NSHostingView(rootView: ImportPanelAccessory(model: accessory))
        panel.isAccessoryViewDisclosed = true
        self.accessory = accessory
        return panel
    }

    /// menu:File[Import…]: the chosen files wait under the import pointer (nil when the panel was
    /// cancelled).
    @discardableResult
    func runImport(on window: DocumentWindowController) async -> ImportPointerTool? {
        let urls = routingLibraryFiles(await runPanel(makePanel(), window.window))
        accessory = nil
        guard !urls.isEmpty else { return nil }
        return beginPlacing(urls, on: window)
    }

    /// Opens a style or symbol library file's import sheet instead of placing it (LIB-022, LIB-013;
    /// the app's `StyleTransferModel.opens` and `SymbolTransferFeatures.opens`).
    var openLibraryFile: @MainActor (URL) -> Bool = { _ in false }

    /// The library files of `urls` handed to their import sheets; the rest, to place.
    func routingLibraryFiles(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            guard Self.libraryExtensions.contains(url.pathExtension.lowercased()) else { return true }
            return !openLibraryFile(url)
        }
    }

    /// Style and symbol library files.
    static let libraryExtensions: Set<String> = [StylePackage.fileExtension, SymbolPackage.fileExtension]

    /// Pushes the import pointer for `urls` on `window`'s canvas (importing.adoc, "Importing with
    /// the Import command"): each click or drag places the next file; it pops after the last one,
    /// after kbd:[Return] or kbd:[Esc].
    @discardableResult
    func beginPlacing(_ urls: [URL], on window: DocumentWindowController) -> ImportPointerTool {
        let tool = ImportPointerTool(files: urls, place: { [weak self, weak window] url, placement in
            guard let self, let window else { return }
            await self.place(url, on: window, placement: placement)
        }, placeAll: { [weak self, weak window] urls, point in
            guard let self, let window else { return }
            await self.place(urls, on: window, at: point)
        })
        tool.onFinish = { [weak window] tool in window?.toolManager.pop(tool) }
        window.toolManager.push(tool)
        return tool
    }

    // MARK: Drops

    /// Files dropped on the canvas at `point` (pasteboard space): true when any can be imported;
    /// placing them runs after the drop returns.
    @discardableResult
    func drop(_ urls: [URL], on window: DocumentWindowController, at point: Point) -> Bool {
        let libraries = urls.filter { Self.libraryExtensions.contains($0.pathExtension.lowercased()) }
        let rest = routingLibraryFiles(urls)
        guard rest.contains(where: { ImportFormat(fileExtension: $0.pathExtension) != nil }) else { return !libraries.isEmpty && rest.count < urls.count }
        Task { await place(rest, on: window, at: point) }
        return true
    }

    // MARK: Placing

    /// Imports `urls` in order into `window`'s document: the first at `point` (its top-left
    /// corner), or centred in the view when nil; each next one down and right by the *Keep both
    /// offset*.
    @discardableResult
    func place(_ urls: [URL], on window: DocumentWindowController, at point: Point?) async -> ImportOutcome {
        let step = context.keepBothOffset
        return await place(urls, on: window) { index, scene in
            let offset = Double(index) * step
            return .at(point.map { Point(x: $0.x + offset, y: $0.y + offset) }
                ?? Self.centred(scene.bounds, in: window.objectEditing.visibleCenter() ?? Point(x: 0, y: 0), offset: offset))
        }
    }

    /// Imports `url` into `window`'s document at `placement` (the import pointer's click or
    /// marquee).
    @discardableResult
    func place(_ url: URL, on window: DocumentWindowController, placement: ImportPlacement) async -> ImportOutcome {
        await place([url], on: window) { _, _ in placement }
    }

    /// Imports `urls` in order, each where `placement` says for its index and scene.
    private func place(_ urls: [URL], on window: DocumentWindowController, placement: (Int, ImportedScene) -> ImportPlacement) async -> ImportOutcome {
        var outcome = ImportOutcome()
        let context = context
        // One answer to *Ask* covers every image of the import.
        var profiles: EmbeddedProfilePolicy?
        for (index, url) in urls.enumerated() {
            do {
                let scene = try await convert(url, context: context)
                let policy = await embeddedProfilePolicy(for: scene, window: window.window, answered: &profiles)
                await place(scene, named: url.lastPathComponent, link: ImportLink(fileURL: url, device: device), on: window,
                            placement: placement(index, scene), profiles: policy, into: &outcome)
            } catch {
                outcome.failures.append(Self.failure(error, name: url.lastPathComponent))
            }
        }
        report(outcome, in: window)
        return outcome
    }

    /// Stores `scene`'s blobs and places it by one change, recording the result in `outcome`.
    private func place(_ scene: ImportedScene, named name: String, link: ImportLink?, on window: DocumentWindowController,
                       placement: ImportPlacement, profiles: EmbeddedProfilePolicy = .useEmbedded, into outcome: inout ImportOutcome) async {
        let document = window.documentHandle
        do {
            let poster = try await storeBlobs(of: scene, for: document)
            let command = PlaceImportedScene(scene, placement: placement, layer: window.objectEditing.activeLayer, link: link, poster: poster,
                                             embeddedProfiles: profiles)
            let target = ImportTarget.resolve(preferred: window.objectEditing.activeLayer, in: document.state)
            guard let change = await window.objectEditing.perform(command).value,
                  let root = PlaceImportedScene.placedRoot(of: change, in: document.state) else {
                outcome.failures.append("“\(name)” could not be placed.")
                return
            }
            outcome.placed.append(root)
            outcome.notes += scene.notes.map { "\(name): \($0)" }
            if target.fellBack { outcome.movedTo = LayerOrder(document.state).layer(of: root, in: document.state) }
        } catch {
            outcome.failures.append(Self.failure(error, name: name))
        }
    }

    /// What the alert says about a file that could not be imported.
    static func failure(_ error: any Error, name: String) -> String {
        (error as? ImportError)?.description ?? "“\(name)” could not be imported: \(error.localizedDescription)"
    }

    // MARK: Pasting

    /// The name pasted artwork gets (importing.adoc, "Pasting").
    static let pastedName = "Pasted"

    /// Whether `pasteboard` holds something to import (menu:Edit[Paste] when it holds no
    /// WireTuner objects): importable files, PDF data, or image data.
    func canPaste(from pasteboard: NSPasteboard) -> Bool {
        if FileDrop.urls(from: pasteboard).contains(where: { ImportFormat(fileExtension: $0.pathExtension) != nil }) { return true }
        return (pasteboard.types ?? []).contains { Self.isPastable($0.rawValue) }
    }

    /// Whether a pasteboard type is one the paste reader looks at: PDF or any image.
    static func isPastable(_ type: String) -> Bool {
        type == UTType.pdf.identifier || (UTType(type)?.conforms(to: .image) ?? false)
    }

    /// menu:Edit[Paste] of files, PDF data or image data (importing.adoc, "Pasting"): files are
    /// placed as a drop would place them; PDF (preferred) or image data is converted with the
    /// format's remembered options and placed centred in the view, or at `point`, named "Pasted"
    /// with no link record.
    @discardableResult
    func paste(from pasteboard: NSPasteboard, on window: DocumentWindowController, at point: Point? = nil) async -> ImportOutcome {
        let files = FileDrop.urls(from: pasteboard).filter { ImportFormat(fileExtension: $0.pathExtension) != nil }
        if !files.isEmpty { return await place(files, on: window, at: point) }
        let representations = (pasteboard.types ?? []).filter { Self.isPastable($0.rawValue) }.compactMap { type in
            pasteboard.data(forType: type).map { (type: type.rawValue, data: $0) }
        }
        var outcome = ImportOutcome()
        guard let (format, data) = ImportPasteboard.choose(representations), let importer = registry.importer(for: format) else { return outcome }
        let values = options.options(for: format, schema: importer.optionsSchema(for: format))
        let context = context
        let name = Self.pastedName
        do {
            let scene = try await Task.detached(priority: .userInitiated) {
                try importer.convert(data, name: name, format: format, options: values, context: context)
            }.value
            let origin = point ?? Self.centred(scene.bounds, in: window.objectEditing.visibleCenter() ?? Point(x: 0, y: 0), offset: 0)
            await place(scene, named: Self.pastedName, link: nil, on: window, placement: .at(origin), into: &outcome)
        } catch {
            outcome.failures.append(Self.failure(error, name: Self.pastedName))
        }
        report(outcome, in: window)
        return outcome
    }

    /// The top-left corner that centres `bounds` on `center`, moved by `offset` down and right.
    static func centred(_ bounds: Rect, in center: Point, offset: Double) -> Point {
        Point(x: center.x - bounds.width / 2 + offset, y: center.y - bounds.height / 2 + offset)
    }

    /// `url` converted with its format's remembered options, off the main actor.
    func convert(_ url: URL, context: ImportContext) async throws -> ImportedScene {
        let registry = registry
        let name = url.lastPathComponent
        let (data, format) = try await Task.detached(priority: .userInitiated) { () throws -> (Data, ImportFormat?) in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= context.maximumFileSize else {
                throw ImportError.tooLarge(name: name, bytes: size, limit: context.maximumFileSize)
            }
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                return (data, registry.format(of: data, name: name))
            } catch {
                throw ImportError.unreadable(name: name, reason: error.localizedDescription)
            }
        }.value
        guard let format, let importer = registry.importer(for: format) else { throw ImportError.unsupportedFormat(name: name) }
        let values = options.options(for: format, schema: importer.optionsSchema(for: format))
        return try await Task.detached(priority: .userInitiated) {
            try registry.convert(data, name: name, options: values, context: context)
        }.value
    }

    /// Stores the scene's blobs (an animation's poster first); returns the poster.
    func storeBlobs(of scene: ImportedScene, for document: DocumentHandle) async throws -> ImportedPoster? {
        var poster: ImportedPoster?
        if case .placed(let placed)? = scene.nodes.first, case .svgAnimation = placed.kind,
           let blob = await posters.poster(svg: placed.blob.data, bounds: placed.bounds) {
            poster = ImportedPoster(blob: blob)
        }
        try await blobs.store((poster.map { [$0.blob] } ?? []) + scene.blobs, for: document)
        return poster
    }

    /// Selects what was placed, makes the fallback layer current, shows the notes and the layer
    /// in the status bar, and names the refused files in one alert.
    func report(_ outcome: ImportOutcome, in window: DocumentWindowController) {
        if !outcome.placed.isEmpty {
            window.selection.model.set(Selection(outcome.placed.map { SelectionID($0) }))
        }
        var messages: [String] = []
        if let layer = outcome.movedTo {
            window.objectEditing.activeLayer = layer
            // The layer the artwork was just placed on.
            let name = LayerOrder(window.documentHandle.state).layer(layer)!.name
            messages.append("The current layer is locked or hidden, so the artwork was placed on “\(name)”.")
        }
        messages += outcome.notes
        if !messages.isEmpty { window.statusBar.show(message: messages.joined(separator: "  ")) }
        if !outcome.failures.isEmpty {
            let message = outcome.failures.count == 1 ? "A file could not be imported." : "\(outcome.failures.count) files could not be imported."
            showAlert(message, outcome.failures.joined(separator: "\n"), window.window)
        }
    }
}

/// The Import panel's accessory (importing.adoc, "Importing with the Import command"): the selected
/// file's format and btn:[Options…] when the format has options.
@MainActor @Observable
final class ImportPanelAccessoryModel: NSObject, NSOpenSavePanelDelegate {
    @ObservationIgnored weak var importer: ImportController?
    /// The panel the options sheet goes on.
    @ObservationIgnored var window: @MainActor () -> NSWindow? = { nil }
    private(set) var format: ImportFormat?
    private(set) var hasOptions = false
    private(set) var sheet: NSWindow?

    init(importer: ImportController) {
        self.importer = importer
    }

    /// The panel's selection changed to `url`.
    func select(_ url: URL?) {
        format = url.flatMap { ImportFormat(fileExtension: $0.pathExtension) }
        hasOptions = format.flatMap { importer?.optionsModel(for: $0) } != nil
    }

    func panelSelectionDidChange(_ sender: Any?) {
        select((sender as? NSOpenPanel)?.url)
    }

    /// btn:[Options…]: the selected format's options sheet on the panel.
    func showOptions() {
        guard let format, let model = importer?.optionsModel(for: format), let window = window() else { return }
        sheet = ImportOptionsSheet.present(model, on: window) { [weak self] _ in self?.sheet = nil }
    }

    var summary: String { format.map { $0.displayName } ?? "No file selected" }
}

/// The accessory's view.
struct ImportPanelAccessory: View {
    let model: ImportPanelAccessoryModel

    var body: some View {
        HStack {
            Text(model.summary).accessibilityIdentifier("import.format")
            Spacer()
            Button("Options…", action: model.showOptions)
                .disabled(!model.hasOptions)
                .accessibilityIdentifier("import.options")
        }
        .padding(8)
        .frame(width: 420)
    }
}
