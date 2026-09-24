import AppKit
import OSLog
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTSync

/// menu:File[Export a Package…] and menu:File[Open Package…] (saving.adoc, "Packages: a document
/// as a file"; IO-005, IO-006), and a package double-clicked in the Finder.  Exporting writes the
/// merged state as this Mac has it -- unsynced changes included and counted -- with every
/// referenced blob in the cache; the ones that are not are named in a warning.  Opening validates
/// the package before anything is created, then makes a new document, stores the package's blobs
/// (queued for upload) and re-issues the state into it as fresh changes, one undo step.
@MainActor
final class PackageController {
    static let fileExtension = "wiretuner"
    static let typeIdentifier = "com.villagecompute.wiretuner.package"
    static let logger = Logger(subsystem: "com.villagecompute.wiretuner", category: "package")

    /// The package type the app declares (`UTExportedTypeDeclarations`).
    static var contentType: UTType {
        UTType(exportedAs: typeIdentifier, conformingTo: .zip)
    }

    var blobs = BlobPlacement()
    /// The signed-in account's id and display name for the manifest.
    var account: @MainActor () -> (id: String, name: String) = { ("", "") }
    /// "<version>/<build>".
    var appVersion = LaunchEnvironment.clientVersion(Bundle.main.infoDictionary)
    /// Makes the new document an opened package becomes, named `title` (the library's pending
    /// creation, opened in a window).
    var createDocument: @MainActor (String) -> DocumentHandle? = { _ in nil }
    /// Opens a PDF or EPS file that carries no package as a new document through the importer
    /// (IO-028: the file falls through to the PDF or EPS importer).
    var importAsDocument: @MainActor (URL) async -> DocumentHandle? = { _ in nil }
    var runSavePanel: @MainActor (NSSavePanel, NSWindow?) async -> URL? = ModalUI.url
    var runOpenPanel: @MainActor (NSOpenPanel, NSWindow?) async -> [URL] = ModalUI.urls
    var showAlert: @MainActor (String, String, NSWindow?) -> Void = ModalUI.alert

    // MARK: Export

    /// menu:File[Export a Package…] for the window's document.
    @discardableResult
    func exportPackage(of window: DocumentWindowController) async -> PackageSummary? {
        let panel = NSSavePanel()
        panel.title = "Export a Package"
        panel.prompt = "Export"
        panel.allowedContentTypes = [Self.contentType]
        panel.nameFieldStringValue = "\(window.documentHandle.title).\(Self.fileExtension)"
        guard let url = await runSavePanel(panel, window.window) else { return nil }
        do {
            let summary = try await export(window.documentHandle, to: url)
            let missing = summary.manifest.missingBlobs.map { $0.name.isEmpty ? $0.hex : $0.name }
            let warnings = (missing.isEmpty ? [] : ["Not on this Mac, so not included: " + missing.joined(separator: ", ") + "."]) + summary.notes
            if !warnings.isEmpty {
                showAlert("The package was exported with warnings.", warnings.joined(separator: "\n"), window.window)
            }
            return summary
        } catch {
            showAlert("The package could not be exported.", String(describing: error), window.window)
            return nil
        }
    }

    /// Writes `document`'s package to `url`.
    func export(_ document: DocumentHandle, to url: URL) async throws -> PackageSummary {
        guard let model = await document.openedModel() else { throw PackageError.nothingToExport }
        await document.settle()
        var head: UInt64 = 0
        var unsynced = 0
        if let store = model.backend as? LocalStore {
            head = await store.lastServerSeq
            unsynced = try await store.outboxCount()
        }
        let account = account()
        let info = DocumentPackage.Info(documentID: document.id, title: document.title, exportedBy: account.id, exportedByName: account.name,
                                        appVersion: appVersion, headServerSeq: head, unsyncedChanges: UInt32(clamping: unsynced))
        let contents = DocumentPackage.contents(of: model.state, info: info, page: document.pages.first ?? Pasteboard.letterPage, cached: blobs.cached)
        return try await Task.detached(priority: .userInitiated) { try PackageWriter().write(contents, to: url) }.value
    }

    // MARK: Open

    /// menu:File[Open Package…].
    @discardableResult
    func openPackage() async -> DocumentHandle? {
        let panel = NSOpenPanel()
        panel.title = "Open Package"
        panel.prompt = "Open"
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.openableTypes
        guard let url = await runOpenPanel(panel, nil).first else { return nil }
        return await openFile(url)
    }

    /// Opens the package at `url` as a new document; nil (after an alert) when it is refused.
    @discardableResult
    func open(_ url: URL) async -> DocumentHandle? {
        let opened: OpenedPackage
        do {
            opened = try await Task.detached(priority: .userInitiated) { try DocumentPackage.reader.open(contentsOf: url) }.value
        } catch {
            showAlert("“\(url.lastPathComponent)” could not be opened.", String(describing: error), nil)
            return nil
        }
        return await open(opened, from: url)
    }

    /// Opens `opened` -- read from `url`, a package or the package a PDF or EPS file embeds -- as
    /// a new document; nil (after an alert) when it is refused.
    func open(_ opened: OpenedPackage, from url: URL) async -> DocumentHandle? {
        let state: EngineState
        do {
            state = try DocumentPackage.state(of: opened)
        } catch {
            showAlert("“\(url.lastPathComponent)” could not be opened.", String(describing: error), nil)
            return nil
        }
        let title = opened.manifest.title.isEmpty ? url.deletingPathExtension().lastPathComponent : opened.manifest.title
        guard let document = createDocument(title), let model = await document.openedModel() else {
            showAlert("“\(url.lastPathComponent)” could not be opened.", "A new document could not be created for it.", nil)
            return nil
        }
        do {
            let blobs = opened.manifest.blobs.compactMap { listed in opened.data(for: listed).map { (data: $0, mediaType: listed.mediaType) } }
            try await self.blobs.store(blobs, for: document)
            let plan = try PackageReissue(state, missing: opened.manifest.missingBlobs.map(PackageBlobReference.init))
            model.beginGroup()
            defer { model.endGroup() }
            while !plan.isFinished {
                guard try await model.perform(plan.nextChunk()) != nil else { break }
            }
        } catch {
            showAlert("“\(url.lastPathComponent)” was only partly opened.", String(describing: error), nil)
        }
        return document
    }
}
