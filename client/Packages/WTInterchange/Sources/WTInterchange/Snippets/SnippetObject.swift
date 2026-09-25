// The snippet library's input and settings (collaboration/inspect.adoc, "Copying as code",
// "Copying as PNG", "Units and scale" and "Client"; COLLAB-036).  A snippet is generated from the
// same display item the renderer draws, plus the facts the display list does not keep: the
// object's kind (so a rectangle becomes `Rectangle()` rather than a path), its name, the swatch
// names of its colours, its paragraph leading and tracking, and what the caller already knows no
// snippet can express (a blend, an extrude).  Everything else -- fills, the stroke, shadows, text
// runs -- is read from the item.

import CoreText
import Foundation
import WTGeometry
import WTRender

/// The notation colours are written in.
public enum SnippetNotation: String, CaseIterable, Hashable, Sendable {
    /// `#E63946` (sRGB; `#E6394680` with alpha).
    case hex
    /// `rgb(230 57 70)` (sRGB).
    case rgb
    /// `color(display-p3 0.8431 0.2745 0.2941)`.
    case displayP3
    /// `oklch(62.753% 0.20694 22.914)`.
    case oklch
    /// `device-cmyk(0% 75% 70% 10%)` through the document's CMYK profile.
    case cmyk
}

/// The unit lengths are written in.
public enum SnippetUnit: String, CaseIterable, Hashable, Sendable {
    case points
    case pixels
    case millimeters
    case centimeters
    case inches

    /// The CSS unit.
    public var css: String {
        switch self {
        case .points: "pt"
        case .pixels: "px"
        case .millimeters: "mm"
        case .centimeters: "cm"
        case .inches: "in"
        }
    }

    /// `points` in this unit; pixels are points × `scale`.
    public func value(_ points: Double, scale: Double) -> Double {
        switch self {
        case .points: points
        case .pixels: points * scale
        case .millimeters: points * 25.4 / 72
        case .centimeters: points * 2.54 / 72
        case .inches: points / 72
        }
    }

    /// `points` with the unit, at most two decimals (`"200px"`, `"4.23mm"`).
    public func format(_ points: Double, scale: Double) -> String {
        Numbers.format(value(points, scale: scale), places: 2) + css
    }
}

/// How snippets read: colour notation, unit and scale (the Inspect panel's popups).
public struct SnippetOptions: Sendable {
    public var notation: SnippetNotation
    public var unit: SnippetUnit
    /// *Scale*: pixel lengths and PNG output, 1× ... any positive factor.
    public var scale: Double
    /// The document's CMYK conversion, for the CMYK notation.
    public var cmyk: any CMYKConverter

    public init(notation: SnippetNotation = .hex, unit: SnippetUnit = .pixels, scale: Double = 1, cmyk: any CMYKConverter = ProfileCMYKConverter()) {
        self.notation = notation
        self.unit = unit
        self.scale = scale > 0 && scale.isFinite ? scale : 1
        self.cmyk = cmyk
    }
}

/// One object to write as a snippet.
public struct SnippetObject: Sendable {
    /// What kind of object it is, as the document says.
    public enum Shape: Hashable, Sendable {
        case rectangle
        case roundedRectangle(radius: Double)
        case ellipse
        /// Any other path.
        case path
        case text
        /// A group, image or anything else: SVG, PNG and the fallback only.
        case other
    }

    public var name: String?
    public var node: NodeID?
    public var shape: Shape
    /// The object as the renderer draws it, in pasteboard coordinates.
    public var item: DisplayItem
    /// Images the item draws, by asset id.
    public var assets: [String: ExportAsset]
    /// The object's opacity, 0 ... 1.
    public var opacity: Double
    /// Text: the leading in points; nil for automatic.
    public var leading: Double?
    /// Text: tracking in thousandths of an em.
    public var tracking: Double
    /// Swatch names of the colours the object uses.
    public var swatchNames: [Color: String]
    /// What the caller knows no snippet can express ("a blend", "an extrusion").
    public var cannotExpress: [String]

    public init(name: String? = nil, node: NodeID? = nil, shape: Shape, item: DisplayItem, assets: [String: ExportAsset] = [:], opacity: Double = 1,
                leading: Double? = nil, tracking: Double = 0, swatchNames: [Color: String] = [:], cannotExpress: [String] = []) {
        self.name = name
        self.node = node
        self.shape = shape
        self.item = item
        self.assets = assets
        self.opacity = opacity
        self.leading = leading
        self.tracking = tracking
        self.swatchNames = swatchNames
        self.cannotExpress = cannotExpress
    }

    // MARK: What the item says

    /// The geometry's bounds in pasteboard points: the path's (strokes and effects left out) or
    /// the text's ink; the item's bounds otherwise.
    public var bounds: Rect {
        switch item {
        case .path(let path):
            return path.path.applying(path.transform).controlBounds ?? .zero
        default:
            return item.bounds ?? .zero
        }
    }

    /// The item's fills, bottom to top.
    var fills: [FillPaint] {
        if case .path(let path) = item { return path.appearance.fills.filter { !$0.paint.isNone } }
        return []
    }

    /// The topmost fill: what a snippet paints with.
    var fill: Paint? { fills.last?.paint }

    /// The topmost basic stroke.
    var stroke: StrokePaint? {
        if case .path(let path) = item { return path.appearance.strokes.last { !$0.paint.isNone } }
        return nil
    }

    /// A shadow as CSS and SwiftUI describe one: offset (y down), blur radius, colour with the
    /// effect's opacity; `inset` for inner shadows and glows.
    struct Shadow: Hashable {
        var dx: Double
        var dy: Double
        var blur: Double
        var spread: Double
        var color: Color
        var inset: Bool
    }

    var effects: [LiveEffect] {
        if case .path(let path) = item { return path.appearance.effects.filter { !$0.hidden }.map(\.effect) }
        return []
    }

    var shadows: [Shadow] {
        effects.compactMap { effect -> Shadow? in
            guard case .shadow(let shadow) = effect else { return nil }
            let color = shadow.color.withAlpha(multipliedBy: shadow.effectiveOpacity / 100)
            let radians = shadow.angle * .pi / 180
            switch shadow.style {
            case .dropShadow, .innerShadow:
                let distance = shadow.effectiveOffset
                return Shadow(dx: distance * cos(radians), dy: -distance * sin(radians), blur: shadow.effectiveSoftness, spread: 0, color: color,
                              inset: shadow.style == .innerShadow)
            case .glow, .innerGlow:
                return Shadow(dx: 0, dy: 0, blur: shadow.effectiveSoftness, spread: shadow.effectiveOffset, color: color, inset: shadow.style == .innerGlow)
            }
        }
    }

    /// The text runs the item draws, in order.
    var runs: [TextRunItem] {
        func collect(_ item: DisplayItem) -> [TextRunItem] {
            switch item {
            case .text(let run): return [run]
            case .group(let group): return group.children.flatMap(collect)
            default: return []
            }
        }
        return collect(item)
    }

    /// Everything no snippet can express, the caller's reasons first: paints other than solid,
    /// linear and radial, effects other than shadows, several fills.
    var unexpressible: [String] {
        var reasons = cannotExpress
        let paints = fills.map(\.paint) + (stroke.map { [$0.paint] } ?? [])
        for paint in paints {
            switch paint {
            case .none, .solid: break
            case .gradient(let gradient):
                if gradient.kind != .linear && gradient.kind != .radial { reasons.append("a \(gradient.kind) gradient") }
            case .pattern: reasons.append("a pattern fill")
            case .custom: reasons.append("a custom fill")
            case .textured: reasons.append("a textured fill")
            case .tiled: reasons.append("a tiled fill")
            case .lens: reasons.append("a lens fill")
            }
        }
        if fills.count > 1 { reasons.append("several fills") }
        for effect in effects {
            if case .shadow = effect { continue }
            reasons.append("the \(String(describing: effect).split(separator: "(")[0]) effect")
        }
        var seen = Set<String>()
        return reasons.filter { seen.insert($0).inserted }
    }

    /// Every colour the object uses, in first-use order: fills, gradient stops, the stroke,
    /// shadows, text.
    var colors: [Color] {
        var result: [Color] = []
        func add(_ paint: Paint?) {
            switch paint {
            case .solid(let color): result.append(color)
            case .gradient(let gradient): result += gradient.sortedStops.map(\.color)
            default: break
            }
        }
        add(fill)
        add(stroke?.paint)
        result += shadows.map(\.color) + runs.map(\.color)
        var seen = Set<Color>()
        return result.filter { seen.insert($0).inserted }
    }

    /// The object alone as an export page tight around its drawing.
    var page: ExportPage {
        let area = item.bounds ?? bounds
        return ExportPage(name: name, bounds: area.width > 0 && area.height > 0 ? area : Rect(x: area.minX, y: area.minY, width: max(area.width, 1), height: max(area.height, 1)),
                          displayList: DisplayList(canvas: "snippet", items: [item], nodeIDs: [node]))
    }

    /// The scene of `page`, with the name as the node's.
    var scene: ExportScene {
        var nodes: [NodeID: ExportNodeInfo] = [:]
        if let node { nodes[node] = ExportNodeInfo(name: name) }
        return ExportScene(name: name ?? "Snippet", pages: [page], nodes: nodes, assets: assets)
    }

    /// The font facts of a run.
    static func facts(_ run: TextRunItem) -> (family: String, postScriptName: String, weight: Int, italic: Bool, size: Double)? {
        guard let glyphs = run.glyphRun else { return nil }
        let facts = FontFacts(glyphs.font.ctFont)
        return (facts.familyName, facts.postScriptName, facts.cssWeight, facts.italic, glyphs.font.size)
    }
}
