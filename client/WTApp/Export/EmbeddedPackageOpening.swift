import AppKit
import UniformTypeIdentifiers
import WTInterchange
import WTModel

/// A PDF or EPS file exported with *Embed {product} document* opens as the original document
/// (export-pdf.adoc, IO-028): menu:File[Open File…] and a Finder double-click look for the
/// embedded package first (`EmbeddedPackage.open`) and fall through to opening the file as a new
/// document (IO-040, `ForeignFileOpener`) when there is none, as every other foreign file does.
extension PackageController {
    /// The extensions of files that may carry a package.
    static let embeddingExtensions: Set<String> = ["pdf", "eps", "epsf", "ai"]

    /// What Open File… offers: packages and every format that opens as a document (PDF and EPS,
    /// which may embed a package, among them).
    static var openableTypes: [UTType] {
        var types = [contentType, .pdf, ExportFormat.eps.utType]
        for type in ForeignFileOpener.openableTypes() where !types.contains(type) { types.append(type) }
        return types
    }

    /// Whether the app opens `url` as a document: a package, a PDF or EPS file, or any file that
    /// opens as a document.
    static func opens(_ url: URL, registry: ImportRegistry = .standard) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return url.isFileURL && (fileExtension == self.fileExtension || embeddingExtensions.contains(fileExtension)
            || registry.opensAsDocument(named: url.lastPathComponent))
    }

    /// Opens `url` as a new document: a package as itself, a PDF or EPS file as the package it
    /// embeds or, without one, as any foreign file is opened (`importAsDocument`).
    @discardableResult
    func openFile(_ url: URL) async -> DocumentHandle? {
        let fileExtension = url.pathExtension.lowercased()
        if fileExtension == Self.fileExtension { return await open(url) }
        guard Self.embeddingExtensions.contains(fileExtension) else { return await importAsDocument(url) }
        let opened: OpenedPackage?
        do {
            let data = try Data(contentsOf: url)
            opened = try EmbeddedPackage.open(data, reader: DocumentPackage.reader)
        } catch {
            showAlert("“\(url.lastPathComponent)” could not be opened.", String(describing: error), nil)
            return nil
        }
        guard let opened else { return await importAsDocument(url) }
        return await open(opened, from: url)
    }
}
