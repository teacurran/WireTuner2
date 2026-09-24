import AppKit
import UniformTypeIdentifiers
import WTInterchange
import WTModel

/// A PDF or EPS file exported with *Embed {product} document* opens as the original document
/// (export-pdf.adoc, IO-028): menu:File[Open Package…] and a Finder double-click look for the
/// embedded package first (`EmbeddedPackage.open`) and fall through to the importer when there is
/// none.
extension PackageController {
    /// The extensions of files that may carry a package.
    static let embeddingExtensions: Set<String> = ["pdf", "eps", "epsf", "ai"]

    /// What Open Package… offers: packages, PDF and EPS files.
    static var openableTypes: [UTType] {
        [contentType, .pdf, ExportFormat.eps.utType]
    }

    /// Whether the app opens `url` as a document (a package, or a PDF or EPS file).
    static func opens(_ url: URL) -> Bool {
        url.isFileURL && (url.pathExtension.lowercased() == fileExtension || embeddingExtensions.contains(url.pathExtension.lowercased()))
    }

    /// Opens `url` as a new document: a package as itself, a PDF or EPS file as the package it
    /// embeds or, without one, through the importer.
    @discardableResult
    func openFile(_ url: URL) async -> DocumentHandle? {
        guard Self.embeddingExtensions.contains(url.pathExtension.lowercased()) else { return await open(url) }
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
