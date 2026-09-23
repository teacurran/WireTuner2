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

    public init(postScriptName: String, size: Double, variations: [UInt32: Double] = [:], horizontalScale: Double = 1) {
        self.postScriptName = postScriptName
        self.size = size
        self.variations = variations
        self.horizontalScale = horizontalScale
    }

    /// The font as it was used: its PostScript name, size and variation (a horizontal scale
    /// is carried separately, as the font matrix of the font Core Text shaped with).
    public init(_ font: CTFont, horizontalScale: Double = 1) {
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
            horizontalScale: horizontalScale
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
        var elements: [DisplayPath.Element] = []
        for glyph in glyphs {
            guard let shape = GlyphOutlines.shared.outline(of: glyph.glyph, in: font), !shape.isEmpty else {
                continue
            }
            let placement = glyph.placement
            elements.append(contentsOf: shape.elements.map { $0.applying(placement) })
        }
        return DisplayPath(elements: elements)
    }

    /// The union of the glyphs' outline bounds in local space; nil when no glyph has ink.
    public var inkBounds: Rect? {
        var result: Rect?
        for glyph in glyphs {
            guard let bounds = GlyphOutlines.shared.outline(of: glyph.glyph, in: font)?.controlBounds else {
                continue
            }
            let placed = bounds.applying(glyph.placement)
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
        var matrix = CGAffineTransform(scaleX: CGFloat(key.horizontalScale), y: 1)
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

/// Glyph outlines in points, y down, by font and glyph.
final class GlyphOutlines: @unchecked Sendable {
    static let shared = GlyphOutlines()

    private struct Key: Hashable {
        let font: GlyphFont
        let glyph: CGGlyph
    }

    private let lock = NSLock()
    private var outlines: [Key: DisplayPath?] = [:]

    /// Nil for a glyph without an outline (a space, a bitmap-only glyph).
    func outline(of glyph: CGGlyph, in font: GlyphFont) -> DisplayPath? {
        let key = Key(font: font, glyph: glyph)
        lock.lock()
        if let cached = outlines[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        var flip = CGAffineTransform(scaleX: 1, y: -1)
        let shape = CTFontCreatePathForGlyph(font.ctFont, glyph, &flip).map(DisplayPath.init(cgPath:))
        lock.lock()
        outlines[key] = .some(shape)
        lock.unlock()
        return shape
    }
}
