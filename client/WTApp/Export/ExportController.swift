import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WTGeometry
import WTInterchange
import WTModel
import WTRender
import WTSync

/// menu:File[Export…] and menu:File[Export Again] (exporting.adoc; IO-014): the Export sheet --
/// a save panel with the accessory view and the format's options sheet over it -- the snapshot
/// taken the instant btn:[Export] is clicked, the background export with its progress bar and
/// Cancel, the export summary, the *After export* actions and the per-Mac memory of the last
/// export.
@MainActor
final class ExportController {
    var registry = ExportRegistry.standard
    let presets: ExportPresetStore
    let memory: ExportMemoryStore
    /// The blob cache (placed images' pixels, placed EPS programs, the embedded package's blobs).
    var blobs = BlobPlacement()
    /// The signed-in account's id and display name, for an embedded package's manifest.
    var account: @MainActor () -> (id: String, name: String) = { ("", "") }
    var appVersion = LaunchEnvironment.clientVersion(Bundle.main.infoDictionary)
    /// Sets up the builder the snapshot draws with (the document's text layout).
    var configureBuilder: @MainActor (inout DocumentDisplayListBuilder, DocumentHandle) -> Void = { _, _ in }
    /// The window's output area, once the Output Area tool makes one.
    var outputArea: @MainActor (DocumentWindowController) -> Rect? = { _ in nil }
    var runSavePanel: @MainActor (NSSavePanel, NSWindow?) async -> URL? = ModalUI.url
    var showAlert: @MainActor (String, String, NSWindow?) -> Void = ModalUI.alert
    /// Asks for a password at export time (a preset stores none); nil when cancelled.
    var askPassword: @MainActor (String, NSWindow?) async -> String? = PasswordPrompt.run
    /// *Open with*: opens the files in the application with this bundle id.
    var openFiles: @MainActor ([URL], String) -> Void = ExportController.open
    /// *Reveal in Finder*.
    var reveal: @MainActor ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    /// How long an export runs before its progress bar appears.
    var progressDelay: Duration = .seconds(1)
    /// The exports running, by document id.
    private(set) var activities: [String: ExportActivity] = [:]
    /// The sheet showing, for tests.
    private(set) var sheet: ExportSheetModel?

    init(defaults: UserDefaults) {
        presets = ExportPresetStore(defaults: defaults)
        memory = ExportMemoryStore(defaults: defaults)
    }

    // MARK: Commands

    /// menu:File[Export…]: the sheet, prefilled with this document's last export.
    @discardableResult
    func export(_ window: DocumentWindowController) async -> ExportOutcome? {
        let settings = memory.settings(for: window.documentHandle.id) ?? ExportSettings()
        return await present(settings, for: window)
    }

    /// menu:File[Export Again]: the last export repeated to the same file without the sheet;
    /// the sheet, prefilled, when the file has moved or this document was never exported here.
    @discardableResult
    func exportAgain(_ window: DocumentWindowController) async -> ExportOutcome? {
        let id = window.documentHandle.id
        guard let settings = memory.settings(for: id), let url = memory.file(for: id) else {
            return await export(window)
        }
        return await run(settings, to: url, from: window)
    }

    /// The sheet over `window`, then the export it sets up; nil when it was cancelled.
    func present(_ settings: ExportSettings, for window: DocumentWindowController) async -> ExportOutcome? {
        let model = ExportSheetModel(context: context(for: window), settings: settings, presets: presets, registry: registry)
        model.web = webPresets(for: window, sheet: model)
        let panel = makePanel(model)
        sheet = model
        defer { sheet = nil }
        guard let url = await runSavePanel(panel, window.window) else { return nil }
        return await run(model.settings, to: url, from: window)
    }

    /// The save panel with the accessory view: its type follows the format, btn:[Options…] opens
    /// the options sheet over it, and a refused setup keeps it open with the reason.
    func makePanel(_ model: ExportSheetModel) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "Export"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [model.settings.format.utType]
        panel.nameFieldStringValue = "\(model.context.title).\(model.settings.format.fileExtension)"
        panel.accessoryView = NSHostingView(rootView: ExportAccessory(model: model))
        let delegate = ExportPanelDelegate(model: model)
        panel.delegate = delegate
        objc_setAssociatedObject(panel, &ExportPanelDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        model.onFormatChange = { [weak panel] format in panel.map { Self.follow(format, in: $0) } }
        model.onShowOptions = { [weak panel] in panel.map { Self.showOptions(model, over: $0) } }
        return panel
    }

    /// The panel's type and the name's extension follow the format.
    static func follow(_ format: ExportFormat, in panel: NSSavePanel) {
        panel.allowedContentTypes = [format.utType]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "." + format.fileExtension
    }

    /// btn:[Options…]: the format's options as a sheet over the panel.
    static func showOptions(_ model: ExportSheetModel, over panel: NSWindow) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: ExportOptionsSheet(model: model)))
        window.title = "\(model.settings.format.displayName) Options"
        model.onCloseOptions = { [weak panel, weak window] in window.map { panel?.endSheet($0) } }
        panel.beginSheet(window)
    }

    /// What the sheet knows about `window`.
    func context(for window: DocumentWindowController) -> ExportContext {
        let document = window.documentHandle
        let selection = window.selection.selection
        let selectionBounds = selection.isEmpty ? nil : window.selection.selectedBounds
        var missing: [String] = []
        for blob in DocumentPackage.referencedBlobs(in: document.state) where blobs.cached(blob.sha256) == nil && !missing.contains(blob.name) {
            missing.append(blob.name)
        }
        return ExportContext(title: document.title, pages: document.pages, currentPage: document.currentPageIndex, snapshotPages: document.pageList.exportPages,
                             selectionBounds: selectionBounds, outputArea: outputArea(window),
                             syncNote: ExportContext.syncNote(window.syncStatus.state, lastSynced: window.syncStatus.details.lastSynced), missing: missing)
    }

    // MARK: Exporting

    /// Exports `window`'s document with `settings` to `url`: the snapshot now, the file later.
    /// Failures and the summary's notes are shown; the outcome is returned.
    @discardableResult
    func run(_ settings: ExportSettings, to url: URL, from window: DocumentWindowController) async -> ExportOutcome {
        let outcome = await perform(settings, to: url, from: window)
        switch outcome {
        case .exported(let summary):
            summary.files.first.map { memory.remember(window.documentHandle.id, url: url, written: $0, settings: settings) }
            if !summary.notes.isEmpty {
                showAlert("The export is done, with notes.", summary.notes.map { "• " + $0 }.joined(separator: "\n"), window.window)
            }
            if let application = settings.openWith { openFiles(summary.files, application) }
            if settings.revealInFinder { reveal(summary.files) }
        case .failed(let message):
            showAlert("The export could not be completed.", message, window.window)
        case .cancelled:
            break
        }
        return outcome
    }

    /// The export without its alerts and *After export* actions.
    func perform(_ settings: ExportSettings, to url: URL, from window: DocumentWindowController) async -> ExportOutcome {
        let model = ExportSheetModel(context: context(for: window), settings: settings, presets: presets, registry: registry)
        if let problem = model.problem { return .failed(problem) }
        var settings = settings
        guard await askPasswords(&settings, window: window.window) else { return .cancelled }
        let exporter: any Exporter
        do {
            exporter = try registry.exporter(for: settings.format)
        } catch {
            return .failed(String(describing: error))
        }
        let snapshot = capture(settings, model: model, from: window)
        guard !snapshot.scene.pages.isEmpty else { return .failed(String(describing: ExportError.nothingToExport)) }
        let destination = ExportDestination(url: url, namePattern: model.fileCount > 1 ? FileNamePattern(settings.namePattern) : nil)
        let activity = ExportActivity(title: "Exporting “\(url.deletingPathExtension().lastPathComponent)”", reportsProgress: exporter is AnimationExporter)
        let id = window.documentHandle.id
        activities[id] = activity
        let bar = Task { [progressDelay] in
            try await Task.sleep(for: progressDelay)
            ExportProgressBar.attach(activity, to: window.window)
        }
        defer {
            bar.cancel()
            ExportProgressBar.detach(from: window.window)
            activities[id] = nil
        }
        do {
            let summary = try await ExportPipeline.run(snapshot, exporter: exporter, options: settings.options.options(for: settings.format), to: destination,
                                                       progress: activity.progress)
            return .exported(ExportSummary(files: summary.files, notes: notes(for: snapshot, settings: settings) + summary.notes))
        } catch ExportError.cancelled {
            return .cancelled
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Cancels `document`'s running export.
    func cancel(_ document: String) {
        activities[document]?.cancel()
    }

    /// The snapshot of the document as it is now.
    func capture(_ settings: ExportSettings, model: ExportSheetModel, from window: DocumentWindowController) -> ExportSnapshot {
        let document = window.documentHandle
        let context = model.context
        var scope = ExportSnapshot.Scope.pages(model.pages)
        if settings.what == .selection { scope = .selection(Set(window.selection.selection.ids.map(\.node))) }
        if settings.what == .outputArea, let area = context.outputArea { scope = .area(area) }
        let account = account()
        let package = settings.options.embedsPackage(settings.format)
            ? DocumentPackage.Info(documentID: document.id, title: document.title, exportedBy: account.id, exportedByName: account.name, appVersion: appVersion)
            : nil
        let request = ExportSnapshot.Request(
            name: document.title, pages: context.snapshotPages.isEmpty ? context.pages.map { ExportSnapshot.Page(bounds: $0) } : context.snapshotPages, scope: scope,
            includePageBoundary: settings.includePageBoundary, pageColor: .white, animation: settings.format.family == .animation,
            text: settings.format.family == .text, package: package
        )
        var builder = DocumentDisplayListBuilder(canvas: CanvasID("export-\(document.id)"))
        configureBuilder(&builder, document)
        let blobs = blobs
        return ExportSnapshot.capture(document.state, request: request, builder: builder, blob: { blobs.cached($0) })
    }

    /// Notes the snapshot adds to the summary.
    func notes(for snapshot: ExportSnapshot, settings: ExportSettings) -> [String] {
        snapshot.missing.isEmpty ? [] : ["Not yet downloaded, exported as placeholders: " + snapshot.missing.joined(separator: ", ") + "."]
    }

    /// Asks for the PDF passwords a preset flagged (presets store none); false when cancelled.
    func askPasswords(_ settings: inout ExportSettings, window: NSWindow?) async -> Bool {
        guard settings.format == .pdf else { return true }
        if settings.asksOpenPassword && settings.options.pdf.openPassword.isEmpty {
            guard let password = await askPassword("Type the password needed to open the PDF.", window) else { return false }
            settings.options.pdf.openPassword = password
        }
        if settings.asksPermissionsPassword && settings.options.pdf.permissionsPassword.isEmpty {
            guard let password = await askPassword("Type the password that restricts printing, copying and editing.", window) else { return false }
            settings.options.pdf.permissionsPassword = password
        }
        return true
    }

    /// Opens `files` in the application `bundleID`.
    static func open(_ files: [URL], in bundleID: String) {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.open(files, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Keeps the save panel open while the setup is refused, saying why.
final class ExportPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    nonisolated(unsafe) static var key = 0
    let model: ExportSheetModel

    init(model: ExportSheetModel) {
        self.model = model
    }

    func panel(_ sender: Any, validate url: URL) throws {
        try MainActor.assumeIsolated {
            if let problem = model.problem {
                throw NSError(domain: "WireTuner.Export", code: 1, userInfo: [NSLocalizedDescriptionKey: problem])
            }
        }
    }
}

/// The password asked at export time.
@MainActor
enum PasswordPrompt {
    /// The alert: the message, a secure field, Export and Cancel.
    static func alert(_ message: String) -> (NSAlert, NSSecureTextField) {
        let alert = NSAlert()
        alert.messageText = "Password"
        alert.informativeText = message
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        return (alert, field)
    }

    /// The typed password when btn:[Export] was clicked.
    static func answer(_ response: NSApplication.ModalResponse, _ field: NSSecureTextField) -> String? {
        response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func run(_ message: String, on window: NSWindow?) async -> String? {
        let (alert, field) = alert(message)
        let response = if let window { await alert.beginSheetModal(for: window) } else { alert.runModal() }
        return answer(response, field)
    }
}
