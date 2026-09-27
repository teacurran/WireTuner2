// Wide-gamut output (CMS-015; docs/_includes/cms/color-profiles.adoc, "Client"): the rules the
// exporters share on top of CMS-011's output context -- how wide the document's colours reach
// (`widestSpaceUsed`), which RGB space an RGB export is written in (`rgbExportSpace`), the bundled
// Display P3 profile bytes for embedding, the CSS Color 4 serializer that pairs every wide value
// with its gamut-mapped sRGB fallback, and the sRGB pull-in for RGB output that carries no profile
// (every colour outside sRGB mapped by COLOR-024 before rendering, so the pixels are the same on
// every Mac) with its warning.  The PDF halves -- the shared `/ICCBased` Display P3 object, `/Lab`
// with the D50 white point, the Display P3 output intent and the PDF 1.7 gate -- are the PDF
// writer's (`PDFStreamWriter.setColor`, `PDFDocumentBuild.write`).

import CoreGraphics
import Foundation
import WTRender

extension WTColor.OutputContext {
    /// How far a document's colours reach.
    public enum GamutReach: Int, Comparable, Hashable, Sendable {
        /// Every colour lies inside sRGB.
        case sRGB
        /// Some colour lies outside sRGB, none outside Display P3.
        case displayP3
        /// Some colour lies outside Display P3.
        case beyondDisplayP3

        public static func < (lhs: GamutReach, rhs: GamutReach) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The reach of `colors`.
    public static func widestSpace(of colors: some Sequence<Color>) -> GamutReach {
        var widest = GamutReach.sRGB
        for color in colors where !WTColor.Gamut.contains(color, in: .sRGB) {
            if !WTColor.Gamut.contains(color, in: .displayP3) { return .beyondDisplayP3 }
            widest = .displayP3
        }
        return widest
    }

    /// The document gamut scan over every resolved colour the exported pages draw: fills,
    /// strokes, gradient stops and text (swatches and guides that draw nothing are the model's
    /// to add; the scan over one snapshot needs no cache).
    public static func widestSpaceUsed(in scene: ExportScene) -> GamutReach {
        var colors = Set<Color>()
        for page in scene.pages {
            for item in page.displayList.items { WideColorScan.collect(item, into: &colors) }
        }
        return widestSpace(of: colors)
    }

    /// The RGB space an RGB export is written in: Working RGB, or Display P3 when the artwork
    /// reaches beyond sRGB and Working RGB does not already hold Display P3.
    public func rgbExportSpace(widest: GamutReach) -> WTColor.ProfileRef {
        guard widest > .sRGB, !holdsDisplayP3(rgbProfile) else { return rgbProfile }
        return registry.displayP3
    }

    /// Whether `profile` holds Display P3's gamut: its primaries survive a round trip through it
    /// within 0.03 (ProPhoto's round trip moves P3 red by 0.017 through the white-point adaptation;
    /// a narrower space such as Adobe RGB moves it by more than 0.2).
    func holdsDisplayP3(_ profile: WTColor.ProfileRef) -> Bool {
        if profile == registry.displayP3 { return true }
        if profile == registry.sRGB { return false }
        guard let space = registry.colorSpace(for: profile) else { return false }
        let p3 = WTColor.Spaces.displayP3
        let corners: [[CGFloat]] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1]]
        return corners.allSatisfy { components in
            guard let there = CGColor(colorSpace: p3, components: components)?.converted(to: space, intent: .relativeColorimetric, options: nil),
                  let back = there.converted(to: p3, intent: .relativeColorimetric, options: nil)?.components else { return false }
            return zip(back, components).allSatisfy { abs($0 - $1) <= 0.03 }
        }
    }

    /// The bundled Display P3 profile's ICC bytes, for embedding.
    public var displayP3ICC: Data {
        // Display P3 is a bundled profile, always registered.
        registry.iccData(for: registry.displayP3)!
    }

    /// The export warning for RGB output without a profile that pulled `count` colours into
    /// sRGB; nil for none.
    public static func clippedWarning(_ count: Int) -> String? {
        count > 0 ? "\(count) color\(count == 1 ? "" : "s") outside sRGB \(count == 1 ? "was" : "were") clipped" : nil
    }

    /// `list` with every colour outside sRGB mapped into sRGB by COLOR-024's gamut mapping (fills,
    /// strokes, gradient stops, text), so a file without a profile renders the same on every Mac.
    public static func mappedIntoSRGB(_ list: DisplayList) -> DisplayList {
        DisplayList(canvas: list.canvas, items: list.items.map(mappedIntoSRGB), nodeIDs: list.nodeIDs, layers: list.layers)
    }

    static func mappedIntoSRGB(_ item: DisplayItem) -> DisplayItem {
        switch item {
        case .fill(var fill):
            fill.paint = mapped(fill.paint)
            return .fill(fill)
        case .stroke(var stroke):
            stroke.paint = mapped(stroke.paint)
            return .stroke(stroke)
        case .path(var path):
            path.appearance.items = path.appearance.items.map { element in
                switch element {
                case .fill(var fill):
                    fill.paint = mapped(fill.paint)
                    return .fill(fill)
                case .stroke(var stroke):
                    stroke.paint = mapped(stroke.paint)
                    return .stroke(stroke)
                }
            }
            return .path(path)
        case .text(var text):
            text.color = mapped(text.color)
            return .text(text)
        case .group(var group):
            group.children = group.children.map(mappedIntoSRGB)
            return .group(group)
        case .image:
            return item
        }
    }

    static func mapped(_ paint: Paint) -> Paint {
        switch paint {
        case .solid(let color):
            return .solid(mapped(color))
        case .gradient(var gradient):
            gradient.stops = gradient.stops.map { Gradient.Stop(offset: $0.offset, color: mapped($0.color)) }
            return .gradient(gradient)
        default:
            return paint
        }
    }

    static func mapped(_ color: Color) -> Color {
        guard color.space != .cmyk, color.spot == nil, !WTColor.Gamut.contains(color, in: .sRGB) else { return color }
        return WTColor.Gamut.map(color, into: .sRGB)
    }
}

extension WTColor {
    /// CSS Color 4 serialization with an sRGB fallback (CMS-015): every colour as `#rrggbb` --
    /// gamut-mapped into sRGB by COLOR-024 -- and, when it lies outside sRGB, the value itself in
    /// the form its space reads best in: `color(display-p3 r g b)` for Display P3 and extended
    /// sRGB, `oklch(l c h)` for OKLab, `lab(l a b)` for CIELAB.  Writers emit the fallback first
    /// and the wide value after it, so a viewer without CSS Color 4 keeps the fallback.
    public enum CSS {
        /// The fallback and, for a colour outside sRGB, the wide value.  Alpha below 1 is written
        /// in the wide value (` / a`) and left to the caller's opacity property for the fallback.
        public static func serialize(_ color: Color) -> (fallback: String, wide: String?) {
            let fallback = ColorMath.hex(color)
            guard color.space != .cmyk, !Gamut.contains(color, in: .sRGB) else { return (fallback, nil) }
            let alpha = color.alpha < 1 ? " / " + number(max(color.alpha, 0), places: 4) : ""
            let c = color.components
            switch color.space {
            case .lab:
                return (fallback, "lab(\(number(c.x, places: 4)) \(number(c.y, places: 4)) \(number(c.z, places: 4))\(alpha))")
            case .oklab:
                let lch = Math.oklch(fromOKLab: SIMD3(c.x, c.y, c.z))
                return (fallback, "oklch(\(number(lch.x, places: 5)) \(number(lch.y, places: 5)) \(number(lch.z, places: 3))\(alpha))")
            case .sRGB, .displayP3, .cmyk:
                let p3 = ColorMath.displayP3(color)
                return (fallback, "color(display-p3 \(number(p3.x, places: 4)) \(number(p3.y, places: 4)) \(number(p3.z, places: 4))\(alpha))")
            }
        }

        /// The declarations of `property` for `color`: the fallback, then the wide value.
        public static func declarations(_ property: String, _ color: Color) -> [String] {
            let value = serialize(color)
            return ["\(property):\(value.fallback)"] + (value.wide.map { ["\(property):\($0)"] } ?? [])
        }

        /// CSS's shortest form of a number: at most `places` decimals, trailing zeros dropped,
        /// no negative zero.
        static func number(_ value: Double, places: Int) -> String {
            Numbers.format(value, places: places)
        }
    }
}
