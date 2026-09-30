// Opening a FreeHand file as a document (IO-040's `Importer.document`, D-082; IO-041, D-083).
// FreeHand's objects belong to the pasteboard, not to a page: each top-level object of every
// layer goes to the page its bounds' centre lies on (the nearest page when it lies on none), in
// that page's space, and the layers stay `.layer` groups so they become document layers -- hidden
// layers too, with their artwork, which an import leaves out (D-085).
//
// The symbols of `ImportedScene.symbols` have no place on `ImportedDocument` yet, so an opened
// file's symbol instances open as their expanded groups (import-formats.adoc, "FreeHand").

import Foundation
import WTGeometry
import WTRender

extension FreeHandImporter {
    public func document(_ data: Data, name: String, format: ImportFormat, options: ImportOptionValues, context: ImportContext) throws -> ImportedDocument {
        let (pages, scene) = try self.pages(data, name: name, context: context, keepHidden: true)
        guard !scene.nodes.isEmpty else { throw ImportError.empty(name: name) }
        var perPage: [[ImportedNode]] = Array(repeating: [], count: pages.count)
        for layer in scene.nodes {
            guard case .group(let group) = layer else { continue }
            var children: [[ImportedNode]] = Array(repeating: [], count: pages.count)
            for child in group.children {
                children[FreeHandImporter.page(of: child, among: pages)].append(child)
            }
            for (index, members) in children.enumerated() where !members.isEmpty {
                let shift = AffineTransform.translation(x: -pages[index].minX, y: -pages[index].minY)
                var moved = group
                moved.children = members.map { $0.applying(shift) }
                perPage[index].append(.group(moved))
            }
        }
        let documentPages = zip(pages, perPage).map { rect, nodes in
            ImportedPage(size: Size(width: max(rect.width, 1), height: max(rect.height, 1)), nodes: nodes)
        }
        return ImportedDocument(format: .freehand, name: name, pages: documentPages, notes: scene.notes)
    }

    /// The page `node` belongs to: the one holding its bounds' centre, else the nearest.
    static func page(of node: ImportedNode, among pages: [Rect]) -> Int {
        let bounds = node.controlBounds()
        guard !bounds.isNull, pages.count > 1 else { return 0 }
        let center = bounds.center
        if let holding = pages.firstIndex(where: { $0.contains(center) }) { return holding }
        func distance(_ rect: Rect) -> Double {
            let dx = max(rect.minX - center.x, 0, center.x - rect.maxX)
            let dy = max(rect.minY - center.y, 0, center.y - rect.maxY)
            return dx * dx + dy * dy
        }
        return pages.indices.min { distance(pages[$0]) < distance(pages[$1]) }!
    }
}
