// Single-line labels for derived drawing: chart axes, legends and data numbers (DRAW-032), a
// barcode's human-readable line (DATA-018), a missing symbol's placeholder name (LIB-010).
// WTText depends on WTRender, so WTRender cannot call it; a derived element asks a
// `LabelTypesetter` instead.  `CoreTextLabels` shapes one line with Core Text -- the shaping
// engine WTText uses -- which is all a label needs; WTModel may pass a WTText-backed typesetter
// where document text attributes apply.

import CoreGraphics
import CoreText
import Foundation
import WTGeometry

/// Where a label sits relative to its anchor point.
public enum LabelAlignment: Hashable, Sendable {
    /// The anchor is the start of the baseline.
    case leading
    /// The anchor is the middle of the baseline.
    case center
    /// The anchor is the end of the baseline.
    case trailing
}

/// Lays out one line of text as display items.
public protocol LabelTypesetter: Sendable {
    /// `text` on one baseline, `anchor` (local space, y down) placed per `alignment`, in
    /// `color`; nil for empty text.
    func label(_ text: String, at anchor: Point, alignment: LabelAlignment, color: Color) -> [DisplayItem]
    /// The advance width of `text`.
    func width(of text: String) -> Double
    /// Ascent plus descent: the line's height.
    var lineHeight: Double { get }
    /// The distance from the top of the line to the baseline.
    var ascent: Double { get }
}

/// Labels shaped by Core Text in one font, cached by string.
public final class CoreTextLabels: LabelTypesetter, @unchecked Sendable {
    public let font: GlyphFont
    private let ctFont: CTFont
    private let lock = NSLock()
    private var runs: [String: (runs: [GlyphRun], width: Double)] = [:]

    /// Helvetica 9 pt: the default for chart labels.
    public init(font: GlyphFont = GlyphFont(postScriptName: "Helvetica", size: 9)) {
        self.font = font
        ctFont = font.ctFont
    }

    public var ascent: Double { Double(CTFontGetAscent(ctFont)) }
    public var lineHeight: Double { Double(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont)) }

    public func width(of text: String) -> Double {
        shaped(text).width
    }

    public func label(_ text: String, at anchor: Point, alignment: LabelAlignment, color: Color) -> [DisplayItem] {
        guard !text.isEmpty else {
            return []
        }
        let shaped = shaped(text)
        let dx: Double
        switch alignment {
        case .leading: dx = 0
        case .center: dx = -shaped.width / 2
        case .trailing: dx = -shaped.width
        }
        let placement = AffineTransform.translation(x: anchor.x + dx, y: anchor.y)
        return shaped.runs.map { run in
            .text(TextRunItem(text: text, glyphRun: run, origin: .zero, color: color, transform: placement))
        }
    }

    /// The line's glyph runs from a baseline origin at (0, 0), one per font Core Text chose.
    func shaped(_ text: String) -> (runs: [GlyphRun], width: Double) {
        if let cached = lock.withLock({ runs[text] }) {
            return cached
        }
        let attributed = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: ctFont])
        let line = CTLineCreateWithAttributedString(attributed)
        var result: [GlyphRun] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            // Core Text positions are y up from the baseline; the display list is y down.
            let placed = zip(glyphs, positions).map { PositionedGlyph(glyph: $0, position: Point(x: Double($1.x), y: -Double($1.y))) }
            result.append(GlyphRun(font: GlyphFont(runFont), glyphs: placed))
        }
        let shaped = (result, Double(CTLineGetTypographicBounds(line, nil, nil, nil)))
        lock.withLock { runs[text] = shaped }
        return shaped
    }
}
