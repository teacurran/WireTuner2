import Foundation
import WTGeometry
import WTModel

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
}
