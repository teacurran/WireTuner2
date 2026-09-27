import Foundation
import WTGeometry
import WTModel
import WTCRDT
import WTProto
import WTRender

/// Font units on a glyph canvas (typeface-documents.adoc, "Font units"; FONT-004): the rulers count
/// in units from the glyph's origin, x to the right and y upward, and the Object panel shows font
/// y (the negated stored y, which runs down the canvas): typing y = 700 stores −700.  One unit is
/// one stored point, so arrow-key nudges move by whole units.
@MainActor
enum GlyphCanvasUnits {
    /// Whether `document` draws a glyph canvas.
    static func isGlyphCanvas(_ document: DocumentHandle) -> Bool { document.glyphCanvasNode != nil }

    /// The y a field shows for stored `y`.
    static func shown(y: Double, in document: DocumentHandle) -> Double {
        isGlyphCanvas(document) ? -y : y
    }

    /// The stored y for a typed `y`.
    static func stored(y: Double, in document: DocumentHandle) -> Double {
        isGlyphCanvas(document) ? -y : y
    }

    /// The rulers' units and zero on a glyph canvas: points (one per unit) from the origin; nil
    /// on the pasteboard.
    static func rulerReference(of document: DocumentHandle) -> (units: Units, zero: Point)? {
        isGlyphCanvas(document) ? (Units(documentUnit: .points), .zero) : nil
    }

    /// The grid the canvas draws and snaps to: on a glyph canvas 10 units from the glyph's origin
    /// (unless the document set a size), else the document's grid from the active page's zero.
    static func grid(of document: DocumentHandle) -> GridSpec {
        isGlyphCanvas(document) ? document.pageList.glyphGrid : document.pageList.grid(on: document.activePage)
    }

    /// What a paste writes on this canvas: on a glyph canvas text blocks arrive as paths
    /// (`GlyphPaste`; objects already arrive one unit per point), else `payload` as copied.
    static func pasted(_ payload: ClipboardPayload, in document: DocumentHandle) -> ClipboardPayload {
        guard isGlyphCanvas(document), payload.nodes.contains(where: { $0.flattened.contains { $0.props.kind.map(\.isText) ?? false } }),
              let (state, roots) = try? GlyphPaste.scratch(payload) else { return payload }
        var conversions: [OpID: TextConversion] = [:]
        for node in GlyphPaste.textNodes(roots, in: state) {
            conversions[node] = try? TextToPaths.conversion(node, in: state, engine: document.textEngine)
        }
        return GlyphPaste.outlined(payload, scratch: state, roots: roots, conversions: conversions)
    }
}

extension Wiretuner_Doc_V1_NodeProps.OneOf_Kind {
    /// Whether the props are a text block's.
    var isText: Bool {
        if case .text = self { return true }
        return false
    }
}
