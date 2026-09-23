// Positioned glyph runs: text in the display list as `WTText` lays it out (TXT-001;
// docs/spec/client.adoc, "The display list": text as positioned glyph runs from `WTText`).
//
// A run names its font by value (PostScript name, size, variation axes, horizontal scale) so
// the display list stays a Sendable value; `GlyphFont.ctFont` rebuilds the Core Text font
// through one cache.  Both renderers draw glyphs as filled outlines from
// `CTFontCreatePathForGlyph` (the spec's path route), which keeps the Metal renderer's glyphs
// identical to Core Graphics' for the parity test.

import WTGeometry
import CoreGraphics
import CoreText
import Foundation

/// The font a glyph run is drawn in.
public struct GlyphFont: Hashable, Sendable, CustomStringConvertible {
    /// The face's PostScript name.
    public var postScriptName: String
    /// Points.
    public var size: Double
    /// Variation axis values by four-character tag (as a big-endian integer), for variable
    /// fonts; empty for the named instance.
    public var variations: [UInt32: Double]
    /// Horizontal scale, 1 = normal (`horizontal_scale` / 100): a per-glyph transform, since
    /// Core Text has no scale attribute (type-specifications, "Layout").
    public var horizontalScale: Double
    /// The slant of a synthesized oblique (type-specifications: Italic applied to a family
    /// without an italic face is synthesized): x += obliqueness × height, 0 for none.
    public var obliqueness: Double

    public init(postScriptName: String, size: Double, variations: [UInt32: Double] = [:], horizontalScale: Double = 1, obliqueness: Double = 0) {
        self.postScriptName = postScriptName
        self.size = size
        self.variations = variations
        self.horizontalScale = horizontalScale
        self.obliqueness = obliqueness
    }

    /// The font as it was used: its PostScript name, size and variation (a horizontal scale
    /// and a synthesized slant are carried separately, as the font matrix of the font Core
    /// Text shaped with).
    public init(_ font: CTFont, horizontalScale: Double = 1, obliqueness: Double = 0) {
        var variations: [UInt32: Double] = [:]
        if let variation = CTFontCopyVariation(font) as? [NSNumber: NSNumber] {
            for (tag, value) in variation {
                variations[tag.uint32Value] = value.doubleValue
            }
        }
        self.init(
            postScriptName: CTFontCopyPostScriptName(font) as String,
            size: Double(CTFontGetSize(font)),
            variations: variations,
            horizontalScale: horizontalScale,
            obliqueness: obliqueness
        )
    }

    /// The Core Text font, from the shared cache.
    public var ctFont: CTFont {
        FontCache.shared.font(for: self)
    }

    public var description: String {
        "\(postScriptName) \(size)pt"
    }
}

/// One glyph at its place.
public struct PositionedGlyph: Hashable, Sendable {
    public var glyph: CGGlyph
    /// The glyph origin on the baseline, in the run's local space (y down).
    public var position: Point
    /// When set, maps glyph space (points, y down, origin at the glyph origin) to local space
    /// and replaces `position`: text on a path, skewed and vertical glyphs.
    public var transform: AffineTransform?

    public init(glyph: CGGlyph, position: Point, transform: AffineTransform? = nil) {
        self.glyph = glyph
        self.position = position
        self.transform = transform
    }

    /// Glyph space → local space.
    public var placement: AffineTransform {
        transform ?? .translation(x: position.x, y: position.y)
    }
}

/// Glyphs of one font, drawn in one colour.
public struct GlyphRun: Hashable, Sendable {
    public var font: GlyphFont
    public var glyphs: [PositionedGlyph]

    public init(font: GlyphFont, glyphs: [PositionedGlyph]) {
        self.font = font
        self.glyphs = glyphs
    }

    /// Every glyph's outline placed in local space, as one path filled non-zero.
    public var outline: DisplayPath {
        let table = GlyphOutlines.shared.table(for: font)
        var elements: [DisplayPath.Element] = []
        for glyph in glyphs {
            guard let shape = table.entry(glyph.glyph).path else {
                continue
            }
            if let transform = glyph.transform {
                elements.append(contentsOf: shape.elements.map { $0.applying(transform) })
            } else {
                let offset = AffineTransform.translation(x: glyph.position.x, y: glyph.position.y)
                elements.append(contentsOf: shape.elements.map { $0.applying(offset) })
            }
        }
        return DisplayPath(elements: elements)
    }

    /// The union of the glyphs' outline bounds in local space; nil when no glyph has ink.
    public var inkBounds: Rect? {
        let table = GlyphOutlines.shared.table(for: font)
        var result: Rect?
        for glyph in glyphs {
            guard let bounds = table.entry(glyph.glyph).bounds else {
                continue
            }
            let placed: Rect
            if let transform = glyph.transform {
                placed = bounds.applying(transform)
            } else {
                placed = Rect(x: bounds.minX + glyph.position.x, y: bounds.minY + glyph.position.y, width: bounds.width, height: bounds.height)
            }
            result = result.map { $0.union(placed) } ?? placed
        }
        return result
    }
}

/// Core Text fonts by value.  Font creation is not free and runs repeat fonts constantly.
final class FontCache: @unchecked Sendable {
    static let shared = FontCache()

    private let lock = NSLock()
    private var fonts: [GlyphFont: CTFont] = [:]

    func font(for key: GlyphFont) -> CTFont {
        lock.lock()
        defer { lock.unlock() }
        if let font = fonts[key] {
            return font
        }
        var matrix = CGAffineTransform(a: CGFloat(key.horizontalScale), b: 0, c: CGFloat(key.obliqueness), d: 1, tx: 0, ty: 0)
        var font = CTFontCreateWithName(key.postScriptName as CFString, CGFloat(key.size), &matrix)
        if !key.variations.isEmpty {
            let variation = Dictionary(uniqueKeysWithValues: key.variations.map { (NSNumber(value: $0.key), NSNumber(value: $0.value)) })
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: variation] as CFDictionary)
            font = CTFontCreateCopyWithAttributes(font, CGFloat(key.size), &matrix, descriptor)
        }
        fonts[key] = font
        return font
    }
}

/// Glyph outlines in points, y down, by font and glyph, with their control bounds: one table
/// per font, so a run looks its font up once and its glyphs by id.
final class GlyphOutlines: @unchecked Sendable {
    static let shared = GlyphOutlines()

    /// One glyph's outline (nil for a glyph without one: a space, a bitmap-only glyph) and its
    /// bounds.
    struct Entry {
        let path: DisplayPath?
        let bounds: Rect?
    }

    /// The outlines of one font.
    final class FontTable: @unchecked Sendable {
        let font: CTFont
        private struct RoundKey: Hashable {
            let glyph: CGGlyph
            let width: Double
            let tolerance: Double
        }

        private let lock = NSLock()
        private var entries: [CGGlyph: Entry] = [:]
        private var rounds: [RoundKey: DisplayPath] = [:]

        /// The region a round-capped, round-joined stroke `width` wide along the glyph's outline
        /// paints, cached: GEO-003's `Offset.checkedStrokeOutline`, or the `RoundOutline` region
        /// where the stroker cannot resolve the outline.
        func roundOutline(_ glyph: CGGlyph, width: Double, tolerance: Double) -> DisplayPath {
            let key = RoundKey(glyph: glyph, width: width, tolerance: tolerance)
            lock.lock()
            if let cached = rounds[key] {
                lock.unlock()
                return cached
            }
            lock.unlock()
            let region = entry(glyph).path.map { FontTable.strokeRegion(of: $0, width: width, tolerance: tolerance) } ?? DisplayPath()
            lock.lock()
            rounds[key] = region
            lock.unlock()
            return region
        }

        init(font: CTFont) {
            self.font = font
        }

        /// The round stroke region of `outline`: the checked GEO-003 stroke outline, falling
        /// back to `RoundOutline` when it throws.  `stroke` is the stroker (replaced in tests).
        static func strokeRegion(
            of outline: DisplayPath, width: Double, tolerance: Double,
            stroke: ([Contour], WTGeometry.StrokeStyle, Double) throws -> FilledPath = { try Offset.checkedStrokeOutline($0, style: $1, tolerance: $2) }
        ) -> DisplayPath {
            guard width > 0, width.isFinite, tolerance > 0 else {
                return DisplayPath()
            }
            do {
                return DisplayPath(contours: try stroke(outline.contours, WTGeometry.StrokeStyle(width: width, cap: .round, join: .round), tolerance).contours)
            } catch {
                return RoundOutline.region(of: outline, width: width, tolerance: tolerance)
            }
        }

        func entry(_ glyph: CGGlyph) -> Entry {
            lock.lock()
            if let cached = entries[glyph] {
                lock.unlock()
                return cached
            }
            lock.unlock()
            var flip = CGAffineTransform(scaleX: 1, y: -1)
            let shape = CTFontCreatePathForGlyph(font, glyph, &flip).map(DisplayPath.init(cgPath:))
            let entry = Entry(path: shape, bounds: shape?.controlBounds)
            lock.lock()
            entries[glyph] = entry
            lock.unlock()
            return entry
        }
    }

    private let lock = NSLock()
    private var tables: [GlyphFont: FontTable] = [:]

    func table(for font: GlyphFont) -> FontTable {
        lock.lock()
        defer { lock.unlock() }
        if let table = tables[font] {
            return table
        }
        let table = FontTable(font: font.ctFont)
        tables[font] = table
        return table
    }

    /// Nil for a glyph without an outline (a space, a bitmap-only glyph).
    func outline(of glyph: CGGlyph, in font: GlyphFont) -> DisplayPath? {
        table(for: font).entry(glyph).path
    }
}
