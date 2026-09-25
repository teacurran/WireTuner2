import Foundation
import WTCRDT
import WTGeometry
import WTRender

// Auto Kern and Guess Classes (kerning-metrics.adoc, "The Kerning Classes editor", "Automatic
// kerning"; FONT-021): the optical gap between two glyphs from their flattened outlines' edge
// profiles, the kern toward a target separation, and classes proposed from the glyphs' names.

/// The edge profiles of flattened glyph outlines.
public enum KerningProfiles {
    /// Heights sampled from the descender to the ascender.
    public static let samples = 32

    /// The sampled heights in glyph space (y down: the ascender at `-ascender`).
    public static func heights(ascender: Double, descender: Double, count: Int = samples) -> [Double] {
        let top = -ascender, bottom = -descender
        guard count > 1 else { return [top] }
        return (0..<count).map { top + (bottom - top) * Double($0) / Double(count - 1) }
    }

    /// The outline's leftmost and rightmost x at each height; nil where it has no ink.
    public static func edges(_ path: FilledPath, heights: [Double]) -> [(left: Double, right: Double)?] {
        var edges: [(Point, Point)] = []
        for contour in path.contours {
            for segment in contour.segments {
                var previous = segment.p0
                for step in 1...16 {
                    let point = segment.evaluate(Double(step) / 16)
                    edges.append((previous, point))
                    previous = point
                }
            }
        }
        return heights.map { y in
            var xs: [Double] = []
            for (a, b) in edges where (a.y <= y && b.y > y) || (b.y <= y && a.y > y) {
                xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
            }
            guard let low = xs.min(), let high = xs.max() else { return nil }
            return (low, high)
        }
    }

    /// The narrowest gap between `left` (advance `advance`) and `right` set after it, over the
    /// heights where both have ink; nil when they never share a height.
    public static func gap(left: FilledPath, advance: Double, right: FilledPath, heights: [Double]) -> Double? {
        let l = edges(left, heights: heights), r = edges(right, heights: heights)
        return zip(l, r).compactMap { a, b -> Double? in
            guard let a, let b else { return nil }
            return advance - a.right + b.left
        }.min()
    }
}

/// Auto Kern's settings and the values it proposes.
public struct AutoKern: Sendable {
    /// The gap aimed for, font units.
    public var separation: Double
    /// Below this magnitude nothing is written.
    public var minimum: Double

    public init(separation: Double, minimum: Double = 5) {
        self.separation = separation
        self.minimum = minimum
    }

    /// The flattened outline and advance of each glyph asked for.
    static func shapes(_ glyphs: Set<OpID>, in state: EngineState) -> [OpID: (FilledPath, Double)] {
        let index = GlyphIndex(state)
        var result: [OpID: (FilledPath, Double)] = [:]
        for glyph in glyphs {
            guard let read = index[glyph] else { continue }
            result[glyph] = (GlyphOutlines.outline(of: glyph, in: state).path, read.advanceWidth)
        }
        return result
    }

    static func heights(_ state: EngineState) -> [Double] {
        let metrics = FontInfo(state).metrics
        return KerningProfiles.heights(ascender: metrics.ascender, descender: metrics.descender)
    }

    /// The separation measured between two `n`s (a good starting value), nil without an `n`.
    public static func suggestedSeparation(in state: EngineState) -> Double? {
        guard let n = GlyphIndex(state).glyph(for: 0x6E)?.id, let shape = shapes([n], in: state)[n] else { return nil }
        return KerningProfiles.gap(left: shape.0, advance: shape.1, right: shape.0, heights: heights(state))
    }

    /// The kern of each pair (separation minus the gap, rounded), leaving out those under the
    /// minimum and pairs that never share a height.
    public func values(_ pairs: [(left: OpID, right: OpID)], in state: EngineState) -> [(left: OpID, right: OpID, value: Double)] {
        let shapes = Self.shapes(Set(pairs.flatMap { [$0.left, $0.right] }), in: state)
        let heights = Self.heights(state)
        return pairs.compactMap { pair in
            guard let left = shapes[pair.left], let right = shapes[pair.right],
                  let gap = KerningProfiles.gap(left: left.0, advance: left.1, right: right.0, heights: heights) else { return nil }
            let kern = (separation - gap).rounded()
            return abs(kern) < minimum ? nil : (pair.left, pair.right, kern)
        }
    }
}

/// Guess Classes: accented variants join their base letter (`a`, `agrave`, `aacute`, …).
public enum KerningGuesses {
    /// The base letter of a codepoint: its canonical decomposition's first scalar, when that differs.
    static func base(of codepoint: UInt32) -> UInt32? {
        guard let scalar = Unicode.Scalar(codepoint) else { return nil }
        let first = String(Character(scalar)).decomposedStringWithCanonicalMapping.unicodeScalars.first
        return first.map(\.value).flatMap { $0 == codepoint ? nil : $0 }
    }

    /// The proposed classes: for each base glyph with accented variants in the font, the base and
    /// its variants, named after the base.
    public static func classes(in index: GlyphIndex) -> [(name: String, members: [OpID])] {
        var groups: [OpID: [OpID]] = [:]
        var order: [OpID] = []
        for glyph in index.glyphs {
            guard let codepoint = glyph.codepoints.first, let base = base(of: codepoint), let baseGlyph = index.glyph(for: base) else { continue }
            if groups[baseGlyph.id] == nil {
                groups[baseGlyph.id] = [baseGlyph.id]
                order.append(baseGlyph.id)
            }
            groups[baseGlyph.id]?.append(glyph.id)
        }
        return order.compactMap { base in index[base].map { ($0.name, groups[base]!) } }
    }
}
