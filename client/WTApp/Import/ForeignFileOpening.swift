import AppKit
import OSLog
import UniformTypeIdentifiers
import WTInterchange
import WTModel
import WTSync

/// Opening a foreign file as a new document (creating-opening.adoc, "Opening other file types";
/// IO-040, D-082): menu:File[Open File…], menu:File[Open Recent], a double-click in the Finder and
/// a file dropped on the Dock icon open an Illustrator, PDF, SVG, EPS or DXF file -- any format
/// whose importer says it opens as a document (`ImportRegistry.documentFormats`) -- as a new
/// document in the Library named after the file.  The file is read, never written: the document is
/// a WireTuner document from then on (Save a Copy As… writes a `.wiretuner`, Export… writes the
/// file's format again).  The file is converted off the main actor with its format's remembered
/// options (every page), its blobs stored, and the document created with the file as its first
/// change (`DocumentCreation.Template.imported`), so the window, the Library and Open Recent
/// have it at once; what the converter approximated is listed in one alert on the new window.
/// menu:File[Import…] still places a file into the current document.
@MainActor
final class ForeignFileOpener {
    static let logger = Logger(subsystem: "com.villagecompute.wiretuner", category: "open")

    /// The import controller whose registry, remembered options, preferences and blob cache the
    /// opener shares.
    let imports: ImportController
    /// Records a Library document named `title` whose first change is `template` and opens it in
    /// a window (the Library's `createDocument(name:template:)`); nil when none could be made.
    var createDocument: @MainActor (_ title: String, _ template: DocumentCreation.Template) -> DocumentHandle? = { _, _ in nil }
    /// The window a document opened in, for the report.
    var window: @MainActor (DocumentHandle) -> NSWindow? = { _ in nil }
    var showAlert: @MainActor (String, String, NSWindow?) -> Void = ModalUI.alert

    /// The most notes the report lists before "and N more".
    static let reportLimit = 12

    init(imports: ImportController) {
        self.imports = imports
    }

    var registry: ImportRegistry { imports.registry }

    /// Whether `url` is a file of a format that opens as a document.
    func opens(_ url: URL) -> Bool {
        url.isFileURL && registry.opensAsDocument(named: url.lastPathComponent)
    }

    /// The content types of the formats that open as documents, for the Open File panel.
    static func openableTypes(_ registry: ImportRegistry = .standard) -> [UTType] {
        var seen = Set<String>()
        return registry.documentUTIs.filter { seen.insert($0).inserted }.compactMap { UTType($0) }
    }

    /// The options a file named `name` opens with: its format's remembered import options, with
    /// every page (Open is the whole file, whatever *Pages* the last import used).
    func options(for name: String) -> ImportOptionValues? {
        guard let format = ImportFormat(fileExtension: (name as NSString).pathExtension), let importer = registry.importer(for: format) else { return nil }
        var values = imports.options.options(for: format, schema: importer.optionsSchema(for: format))
        if values["pages"] != nil { values["pages"] = .string("All") }
        return values
    }

    /// Opens `url` as a new document; nil (after an alert naming the file) when it cannot be read.
    @discardableResult
    func open(_ url: URL) async -> DocumentHandle? {
        let name = url.lastPathComponent
        let registry = registry
        let options = options(for: name)
        let context = imports.context
        let document: ImportedDocument
        do {
            document = try await Task.detached(priority: .userInitiated) {
                try registry.document(contentsOf: url, options: options, context: context)
            }.value
        } catch {
            showAlert("“\(name)” could not be opened.", Self.reason(error, name: name, registry: registry), nil)
            return nil
        }
        return await open(document, from: url)
    }

    /// Makes the new document of `document`, read from `url`.
    func open(_ document: ImportedDocument, from url: URL) async -> DocumentHandle? {
        let name = url.lastPathComponent
        var poster: ImportedPoster?
        if case .placed(let placed)? = document.pages.first?.nodes.first, case .svgAnimation = placed.kind,
           let blob = await imports.posters.poster(svg: placed.blob.data, bounds: placed.bounds) {
            poster = ImportedPoster(blob: blob)
        }
        do {
            try imports.blobs.cache((poster.map { [$0.blob] } ?? []) + document.blobs)
        } catch {
            showAlert("“\(name)” could not be opened.", "Its images could not be stored: \(error.localizedDescription)", nil)
            return nil
        }
        var answered: EmbeddedProfilePolicy?
        let profiles = await imports.embeddedProfilePolicy(for: document.pages.flatMap { $0.nodes + $0.layers.flatMap(\.nodes) }, window: nil, answered: &answered)
        let source = DocumentImport(document, link: ImportLink(fileURL: url, device: imports.device), poster: poster, embeddedProfiles: profiles)
        guard let handle = createDocument(document.title, .imported(source)) else {
            showAlert("“\(name)” could not be opened.", "A new document could not be created for it.", nil)
            return nil
        }
        _ = await handle.openedModel()
        report(document, in: handle)
        return handle
    }

    /// The converter's notes in one alert on the new window: the first `reportLimit`, each once.
    func report(_ document: ImportedDocument, in handle: DocumentHandle) {
        var seen = Set<String>()
        let notes = document.notes.filter { seen.insert($0).inserted }
        guard !notes.isEmpty else { return }
        var lines = Array(notes.prefix(Self.reportLimit))
        if notes.count > Self.reportLimit { lines.append("…and \(notes.count - Self.reportLimit) more.") }
        showAlert("“\(document.name)” was opened with changes.", lines.joined(separator: "\n"), window(handle))
    }

    /// What the alert says about a file that could not be opened.
    static func reason(_ error: any Error, name: String, registry: ImportRegistry = .standard) -> String {
        if case .unsupportedFormat? = error as? ImportError {
            let names = registry.documentFormats.map(\.displayName)
            let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names.joined()
            return "WireTuner opens \(list) files as documents.  Use File > Import… to place other files in a document."
        }
        return ImportController.failure(error, name: name)
    }
}

extension BlobPlacement {
    /// Stores `blobs` in the blob cache alone -- a document that does not exist yet (a file being
    /// opened); `DocumentOpener.applyTemplate` queues them for upload once its store is open.
    func cache(_ blobs: [ImportedBlob]) throws {
        guard !blobs.isEmpty else { return }
        let cache = BlobCache(directory: try directory())
        for blob in blobs { _ = try cache.insert(blob.data) }
    }
}
