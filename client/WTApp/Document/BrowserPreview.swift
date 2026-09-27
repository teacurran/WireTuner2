import AppKit

/// Writes a document as web pages for Preview in Browser.  The IO epic's SVG/HTML exporter
/// (WEB-029) conforms; until it exists no exporter is installed and the command is disabled.
@MainActor
protocol BrowserPreviewExporter: AnyObject {
    /// Exports the page at `pageIndex` -- or the whole document when it has interactions -- into
    /// `directory` and returns the file to open.
    func exportPreview(of document: DocumentHandle, pageIndex: Int, into directory: URL) throws -> URL
    /// menu:View[Preview All Pages in Browser] (WEB-029): every page, opening the one at `pageIndex`
    /// -- or, with `allPages` false, as `exportPreview(of:pageIndex:into:)`.
    func exportPreview(of document: DocumentHandle, pageIndex: Int, allPages: Bool, into directory: URL) throws -> URL
    /// What the last export would list in the Publish sheet's output warnings, and the placed files
    /// it drew as placeholders because they are not downloaded yet (WEB-029).
    var warnings: [String] { get }
}

extension BrowserPreviewExporter {
    func exportPreview(of document: DocumentHandle, pageIndex: Int, allPages: Bool, into directory: URL) throws -> URL {
        try exportPreview(of: document, pageIndex: pageIndex, into: directory)
    }

    var warnings: [String] { [] }
}

/// menu:View[Preview in Browser] (document-view.adoc, "Preview in Browser"; BASIC-017): a local
/// export into `NSTemporaryDirectory()/WireTuner/Preview/<document>/`, opened with the default
/// browser (or the *Preview browser* preference's application); the folder is removed at quit.
/// Needs no network.
@MainActor
final class BrowserPreview {
    static let unavailableReason = "Preview in Browser needs the SVG and HTML exporter, which is not in this build yet"

    var exporter: (any BrowserPreviewExporter)?
    let root: URL
    /// Opens `url`, with the application at the second URL when one is chosen; replaceable in
    /// tests.
    var open: @MainActor (URL, URL?) -> Void = { url, application in
        if let application {
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    init(exporter: (any BrowserPreviewExporter)? = nil, root: URL = BrowserPreview.defaultRoot) {
        self.exporter = exporter
        self.root = root
    }

    static var defaultRoot: URL {
        FileManager.default.temporaryDirectory.appending(path: "WireTuner").appending(path: "Preview")
    }

    /// Enabled with an exporter and a document; otherwise disabled with the reason as the
    /// menu item's tooltip.
    func validation(hasDocument: Bool) -> CommandValidation {
        guard exporter != nil else { return .disabled(Self.unavailableReason) }
        return hasDocument ? .enabled : .disabled(ViewCommands.noDocument)
    }

    /// Exports and opens; returns the file opened.
    @discardableResult
    func preview(_ document: DocumentHandle, pageIndex: Int, allPages: Bool = false, browser: URL? = nil) throws -> URL? {
        guard let exporter else { return nil }
        let directory = root.appending(path: document.id)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = try exporter.exportPreview(of: document, pageIndex: pageIndex, allPages: allPages, into: directory)
        open(file, browser)
        return file
    }

    /// At quit: the temporary exports go.
    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

extension StandardCommands.ID {
    /// menu:View[Preview All Pages in Browser] (kbd:[Cmd+Shift+Return]; WEB-029).
    static let previewAllInBrowser: CommandID = "view.previewAllInBrowser"
}
