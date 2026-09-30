// The Illustrator importer (import-formats.adoc, "Adobe Illustrator"; IMG-010): files saved with
// *Create PDF Compatible File* (every Illustrator since 9 by default) are read as PDFs -- their
// layers from the `/Layer` marks Illustrator writes around each layer's drawing (or, with *Create
// Acrobat Layers*, its optional content), hidden layers from the copies Illustrator keeps beside
// them, and for a file with neither its private data's layer table when that has one layer
// (D-085); live blends as the groups of blended shapes Illustrator writes, gradient meshes as 50%
// black -- and PostScript-based files (versions 1.1 through 8, Illustrator EPS) through the
// legacy operator reader, which places a file it cannot read as EPS rather than refusing it.

import CoreGraphics
import Foundation
import WTGeometry

public struct IllustratorImporter: Importer {
    public init() {}

    public var formats: [ImportFormat] { [.illustrator] }

    public func optionsSchema(for format: ImportFormat) -> ImportOptionsSchema { PDFImportOptions.schema }

    /// The PDF importer for PDF-compatible files: gradient meshes at 50% black, Illustrator's
    /// layer marks read.
    static let pdf = PDFImporter(meshBlack: 0.5, illustratorLayers: true)
    /// The same without Illustrator's layer marks: what a file whose layers cannot be matched to
    /// its drawing opens with (its optional content, if any, else one layer).
    static let plainPDF = PDFImporter(meshBlack: 0.5)

    /// Whether `data` carries a PDF (the PDF-compatible format) rather than only PostScript.
    static func isPDFCompatible(_ data: Data) -> Bool {
        data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
    }

    public func probe(_ data: Data, name: String, format: ImportFormat) throws -> ImportDescriptor {
        if IllustratorImporter.isPDFCompatible(data) {
            return try IllustratorImporter.pdf.probe(data, name: name, format: format)
        }
        let scene = try legacy(data, name: name, text: .editable)
        return ImportDescriptor(format: format, naturalSize: scene.bounds, placed: scene.kind == .placed)
    }

    public func convert(_ data: Data, name: String, format: ImportFormat, options: ImportOptionValues, context: ImportContext) throws -> ImportedScene {
        let typed = try PDFImportOptions(options, name: name)
        if IllustratorImporter.isPDFCompatible(data) {
            let document = try PDFImporter.document(data, name: name)
            var scene = try IllustratorImporter.pdf.convert(document, name: name, options: typed, context: context)
            if !scene.nodes.contains(where: \.isLayer), document.numberOfPages == 1, let layer = IllustratorImporter.onlyLayer(document), layer.state.visible, !scene.nodes.isEmpty {
                scene.nodes = [.group(ImportedGroup(children: scene.nodes, name: layer.name, role: .layer, layerState: layer.state))]
            }
            return scene
        }
        return try legacy(data, name: name, text: typed.text)
    }

    /// A PDF-compatible file opened with one page per artboard (Illustrator writes each artboard
    /// as a page of its PDF) and its layers as layer groups; a PostScript file as one page.
    public func document(_ data: Data, name: String, format: ImportFormat, options: ImportOptionValues, context: ImportContext) throws -> ImportedDocument {
        let typed = try PDFImportOptions(options, name: name)
        if IllustratorImporter.isPDFCompatible(data) {
            return try IllustratorImporter.document(try PDFImporter.document(data, name: name), name: name, format: format, options: typed)
        }
        var document = ImportedDocument(scene: try legacy(data, name: name, text: typed.text), format: format)
        document.layerSource = document.pages.contains { $0.nodes.contains(where: \.isLayer) } ? .postScript : ImportedLayerSource.none
        return document
    }

    /// The layers of a PDF-compatible file (D-085): Illustrator's layer marks or optional content
    /// when every page's drawing is inside them, each layer once per page and in one order on all
    /// pages; for a file without either, the private data's layer when it has exactly one; else
    /// the file as a plain PDF reads, with a note.
    static func document(_ pdf: CGPDFDocument, name: String, format: ImportFormat, options: PDFImportOptions) throws -> ImportedDocument {
        let (document, pages, sources) = try IllustratorImporter.pdf.pages(pdf, name: name, format: format, options: options)
        if sources.isEmpty {
            var result = document
            if let layer = onlyLayer(pdf) {
                for index in result.pages.indices {
                    result.pages[index].nodes = [.group(ImportedGroup(children: result.pages[index].nodes, name: layer.name, role: .layer, layerState: layer.state))]
                }
                result.layerSource = .privateData
            } else {
                result.layerSource = ImportedLayerSource.none
            }
            return result
        }
        if let problem = uncertainty(pages, sources: sources) {
            var fallback = try plainPDF.document(pdf, name: name, format: format, options: options)
            fallback.notes.append("Its layers could not be matched to its artwork with certainty (\(problem)), so it opens as its PDF reads.")
            fallback.layerSource = fallback.pages.contains { $0.nodes.contains(where: \.isLayer) } ? .optionalContent : ImportedLayerSource.none
            return fallback
        }
        var result = document
        let keys = pages.map(documentKeys)
        let names = uniqueNames(keys.flatMap { $0 })
        let native = sources == [.optionalContent] ? nativeLayers(pdf).filter { $0.depth == 0 } : []
        for (index, page) in pages.enumerated() {
            var run = 0
            result.pages[index].nodes = result.pages[index].nodes.map { node in
                guard case .group(var group) = node, group.role == .layer else { return node }
                let key = keys[index][run]
                let layer = page.layerRuns[run]
                run += 1
                group.name = names[key] ?? layer.name
                if let match = native.filter({ $0.name == layer.name }).onlyElement, Set(keys.flatMap { $0 }.filter { $0.name == layer.name }).count == 1 {
                    // Acrobat layers carry no lock, print or outline setting: the private data's do.
                    group.layerState = ImportedLayerState(visible: group.layerState.visible, locked: match.state.locked, printing: match.state.printing, outline: match.state.outline)
                }
                return .group(group)
            }
        }
        result.layerSource = sources == [.illustrator] ? .layerMarks : .optionalContent
        return result
    }

    /// Why the pages' layers cannot be trusted to hold their artwork, or nil when they can: both
    /// kinds of layer in one file, artwork outside every layer, a layer in two separate places on
    /// a page, or layers in different orders on different pages.
    static func uncertainty(_ pages: [PDFImporter.PDFConvertedPage], sources: Set<PDFImportLayer.Source>) -> String? {
        if sources.count > 1 {
            return "it has both Illustrator layers and Acrobat layers"
        }
        var order: [DocumentKey] = []
        for page in pages {
            if page.looseCount > 0 {
                return "some artwork is outside every layer"
            }
            var local: [LayerKey] = []
            for layer in page.layerRuns where local.last != key(layer) {
                if local.contains(key(layer)) {
                    return "a layer is drawn in two places"
                }
                local.append(key(layer))
            }
            var sequence: [DocumentKey] = []
            for key in documentKeys(page) where sequence.last != key {
                sequence.append(key)
            }
            for layer in sequence where !order.contains(layer) {
                order.append(layer)
            }
            let positions = sequence.map { order.firstIndex(of: $0)! }
            if positions != positions.sorted() {
                return "the pages stack their layers in different orders"
            }
        }
        return nil
    }

    /// What identifies one layer on a page: its properties dictionary, or its name when the
    /// properties are inline.
    enum LayerKey: Hashable {
        case identity(UnsafeRawPointer)
        case name(String)
    }

    static func key(_ layer: PDFImportLayer) -> LayerKey {
        layer.identity.map(LayerKey.identity) ?? .name(layer.name)
    }

    /// What identifies one layer across pages, whose properties are each page's own: its name
    /// and which of the page's layers with that name it is (0 for the first).
    struct DocumentKey: Hashable {
        var name: String
        var ordinal: Int
    }

    /// The document key of each of the page's layer runs.
    static func documentKeys(_ page: PDFImporter.PDFConvertedPage) -> [DocumentKey] {
        var seen: [String: [LayerKey]] = [:]
        return page.layerRuns.map { layer in
            var keys = seen[layer.name] ?? []
            if !keys.contains(key(layer)) { keys.append(key(layer)) }
            seen[layer.name] = keys
            return DocumentKey(name: layer.name, ordinal: keys.firstIndex(of: key(layer))!)
        }
    }

    /// A document name for each layer: its own, or with " 2", " 3" … when an earlier layer of
    /// the file has the same name (document layers are matched by name).
    static func uniqueNames(_ keys: [DocumentKey]) -> [DocumentKey: String] {
        var names: [DocumentKey: String] = [:]
        var taken = Set<String>()
        for key in keys where names[key] == nil {
            let base = key.name.isEmpty ? "Layer" : key.name
            var name = base
            var suffix = 2
            while taken.contains(name) {
                name = "\(base) \(suffix)"
                suffix += 1
            }
            taken.insert(name)
            names[key] = name
        }
        return names
    }

    /// The layer records of the file's private data (page 1's), or none.
    static func nativeLayers(_ pdf: CGPDFDocument) -> [IllustratorNativeLayer] {
        guard let page = pdf.page(at: 1)?.dictionary, let data = IllustratorPrivateData.data(page: PDFImportDict(ref: page)) else {
            return []
        }
        return IllustratorPrivateData.layers(data)
    }

    /// The file's only top-level layer, when its private data has exactly one.
    static func onlyLayer(_ pdf: CGPDFDocument) -> IllustratorNativeLayer? {
        nativeLayers(pdf).filter { $0.depth == 0 }.onlyElement
    }

    /// A PostScript Illustrator file through the legacy reader; anything else is refused.
    func legacy(_ data: Data, name: String, text: ImportTextHandling) throws -> ImportedScene {
        guard String(decoding: data.prefix(64), as: UTF8.self).hasPrefix("%!PS-Adobe") else {
            throw ImportError.unreadable(name: name, reason: "it is neither a PDF-compatible nor a PostScript Illustrator file.")
        }
        return AILegacyReader(data: data, name: name, text: text).read()
    }
}

extension ImportedNode {
    /// Whether the node is a layer group.
    var isLayer: Bool {
        if case .group(let group) = self { return group.role == .layer }
        return false
    }
}

extension Array {
    /// The array's element when it has exactly one.
    var onlyElement: Element? { count == 1 ? self[0] : nil }
}

