// A foreign file opened as a document (creating-opening.adoc, "Opening other file types"; IO-040,
// D-082): what an importer produces when menu:File[Open File…], the Finder or the Dock opens a file
// rather than placing it.  Where an `ImportedScene` is one piece of artwork for the current layer,
// an `ImportedDocument` keeps the file's structure: its pages (a PDF's pages, an Illustrator
// file's artboards) each with its own size, and on every page the artwork in page space with the
// file's layers still marked as `ImportedGroup.Role.layer` groups, which `WTModel` turns into
// document layers.  Coordinates are points, y down, each page's top-left corner at its origin.

import Foundation
import WTGeometry
import WTRender

/// One page of an opened file.
public struct ImportedPage: Hashable, Sendable {
    /// The page's name in the file (a PDF page label, an artboard name), when it has one.
    public var name: String?
    /// The page's size in points.
    public var size: Size
    /// The page's artwork, back to front, in page space; top-level `.layer` groups are the file's
    /// layers.
    public var nodes: [ImportedNode]
    /// Artwork for named document layers (a PDF's *Notes* and *URLs*), in page space.
    public var layers: [ImportedLayer]

    public init(name: String? = nil, size: Size, nodes: [ImportedNode], layers: [ImportedLayer] = []) {
        self.name = name
        self.size = size
        self.nodes = nodes
        self.layers = layers
    }
}

/// The result of opening a file as a document.
public struct ImportedDocument: Hashable, Sendable {
    /// The format the file was read as.
    public var format: ImportFormat
    /// The file name (`Poster.ai`).
    public var name: String
    /// The pages in file order; never empty.
    public var pages: [ImportedPage]
    /// What was approximated or left out, for the open report.
    public var notes: [String]

    public init(format: ImportFormat, name: String, pages: [ImportedPage], notes: [String] = []) {
        self.format = format
        self.name = name
        self.pages = pages
        self.notes = notes
    }

    /// A one-page document of `scene`: the page is the scene's bounds (at least one point on each
    /// side), its artwork the scene's nodes moved so the bounds' top-left corner is the page's --
    /// a vector scene's nodes as they are (no group named after the file: the document is the
    /// file), a bitmap or placed scene's single node named after the file.
    public init(scene: ImportedScene, format: ImportFormat) {
        let bounds = scene.bounds
        let shift = AffineTransform.translation(x: -bounds.minX, y: -bounds.minY)
        let nodes = scene.kind == .vector ? scene.nodes : [scene.subtree]
        let page = ImportedPage(size: Size(width: max(bounds.width, 1), height: max(bounds.height, 1)),
                                nodes: nodes.map { $0.applying(shift) },
                                layers: scene.layers.map { ImportedLayer(name: $0.name, nodes: $0.nodes.map { $0.applying(shift) }) })
        self.init(format: format, name: scene.name, pages: [page], notes: scene.notes)
    }

    /// The document's title: the file name without its extension (`Poster`).
    public var title: String {
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// Every blob the document references, once each, in first-use order.
    public var blobs: [ImportedBlob] {
        var seen = Set<Data>()
        var result: [ImportedBlob] = []
        for page in pages {
            let scene = ImportedScene(kind: .vector, name: name, bounds: .zero, nodes: page.nodes, layers: page.layers)
            for blob in scene.blobs where seen.insert(blob.sha256).inserted {
                result.append(blob)
            }
        }
        return result
    }

    /// The names of the file's layers in the order they first appear, bottom to top: the
    /// top-level `.layer` groups of every page, then the named layers.
    public var layerNames: [String] {
        var names: [String] = []
        for page in pages {
            for node in page.nodes {
                if case .group(let group) = node, group.role == .layer, let name = group.name, !names.contains(name) { names.append(name) }
            }
        }
        for page in pages {
            for layer in page.layers where !layer.nodes.isEmpty && !names.contains(layer.name) { names.append(layer.name) }
        }
        return names
    }

    /// Every object of the document, groups included and layer groups excluded (the report's
    /// object count).
    public var objectCount: Int {
        pages.reduce(0) { total, page in
            total + (page.nodes + page.layers.flatMap(\.nodes)).flatMap(\.descendants).filter { node in
                if case .group(let group) = node { return group.role != .layer }
                return true
            }.count
        }
    }
}

extension ImportedNode {
    /// The node with `transform` composed after its own (moved into another space).
    public func applying(_ transform: AffineTransform) -> ImportedNode {
        switch self {
        case .group(var group):
            group.transform = group.transform.concatenating(transform)
            return .group(group)
        case .path(var path):
            path.transform = path.transform.concatenating(transform)
            return .path(path)
        case .text(var text):
            text.transform = text.transform.concatenating(transform)
            return .text(text)
        case .image(var image):
            image.transform = image.transform.concatenating(transform)
            return .image(image)
        case .placed(var placed):
            placed.transform = placed.transform.concatenating(transform)
            return .placed(placed)
        }
    }
}
