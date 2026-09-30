// FONT-011's render half (glyph-editing.adoc, "Client"): the metric lines -- baseline, x-height,
// cap height, ascender, descender, extra lines -- the side bearing lines at the origin and the
// advance width, and the em box, drawn as a canvas decoration below the artwork (like page
// rectangles) in glyph-canvas space: stored y = -font y, hairlines one device pixel wide at every
// zoom, the vertical lines slanted by the italic angle.  Labels are drawn by the canvas in screen
// space from `lines`; the same lines are snap targets (*Snap to metric lines*).

import Foundation
import WTGeometry

/// A named horizontal metric line.
public struct GlyphMetricLine: Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        case baseline, xHeight, capHeight, ascender, descender, extra
    }

    public var role: Role
    public var label: String
    /// Font units, y up (a font value, not a canvas coordinate).
    public var y: Double

    public init(role: Role, label: String, y: Double) {
        self.role = role
        self.label = label
        self.y = y
    }

    /// The line's y on the glyph canvas (stored, y down).
    public var canvasY: Double { y == 0 ? 0 : -y }
}

/// Everything the decoration of one glyph canvas depends on.
public struct GlyphCanvasFrame: Hashable, Sendable {
    public var advanceWidth: Double
    public var unitsPerEm: Double
    /// Font units, y up.
    public var ascender: Double
    public var descender: Double
    public var xHeight: Double
    public var capHeight: Double
    /// Degrees, negative leaning right.
    public var italicAngle: Double
    public var extraLines: [GlyphMetricLine]
    public var showBaseline = true
    public var showXHeight = true
    public var showCapHeight = true
    public var showAscender = true
    public var showDescender = true
    public var showSideBearings = true
    public var showEmBox = true
    public var baselineColor = Color(red: 0.2, green: 0.45, blue: 0.95)
    public var metricColor = Color(red: 0.55, green: 0.7, blue: 1)
    public var bearingColor = Color(red: 0.95, green: 0.45, blue: 0.2)

    public init(advanceWidth: Double, unitsPerEm: Double = 1_000, ascender: Double = 800, descender: Double = -200, xHeight: Double = 500,
                capHeight: Double = 700, italicAngle: Double = 0, extraLines: [GlyphMetricLine] = []) {
        self.advanceWidth = advanceWidth
        self.unitsPerEm = unitsPerEm
        self.ascender = ascender
        self.descender = descender
        self.xHeight = xHeight
        self.capHeight = capHeight
        self.italicAngle = italicAngle
        self.extraLines = extraLines
    }

    /// The horizontal extent lines are drawn over: one em either side of the glyph.
    public var extent: (minX: Double, maxX: Double) {
        (-unitsPerEm, max(advanceWidth, 0) + unitsPerEm)
    }
}

/// Builds the glyph canvas decoration.
public enum GlyphCanvasRendering {
    /// The shown horizontal lines, bottom to top by font y.
    public static func lines(_ frame: GlyphCanvasFrame) -> [GlyphMetricLine] {
        var lines: [GlyphMetricLine] = []
        if frame.showDescender { lines.append(GlyphMetricLine(role: .descender, label: "Descender", y: frame.descender)) }
        if frame.showBaseline { lines.append(GlyphMetricLine(role: .baseline, label: "Baseline", y: 0)) }
        if frame.showXHeight { lines.append(GlyphMetricLine(role: .xHeight, label: "x-height", y: frame.xHeight)) }
        if frame.showCapHeight { lines.append(GlyphMetricLine(role: .capHeight, label: "Cap height", y: frame.capHeight)) }
        if frame.showAscender { lines.append(GlyphMetricLine(role: .ascender, label: "Ascender", y: frame.ascender)) }
        lines += frame.extraLines.filter { $0.y.isFinite && abs($0.y) <= 32_767 }
        return lines.sorted { $0.y < $1.y }
    }

    /// The x offset the italic angle gives at canvas height `y` (0 on the baseline).
    static func slant(_ frame: GlyphCanvasFrame, at y: Double) -> Double {
        guard frame.italicAngle != 0 else { return 0 }
        return y * tan(frame.italicAngle * .pi / 180)
    }

    /// A vertical line at `x` from the descender to the ascender, slanted by the italic angle.
    static func vertical(_ frame: GlyphCanvasFrame, x: Double) -> DisplayPath {
        let top = -frame.ascender, bottom = -frame.descender
        return DisplayPath(elements: [.move(to: Point(x: x + slant(frame, at: top), y: top)), .line(to: Point(x: x + slant(frame, at: bottom), y: bottom))])
    }

    /// The decoration's display items: the em box (dotted), the horizontal lines, the side
    /// bearing lines -- hairlines, no node ids.
    public static func items(_ frame: GlyphCanvasFrame) -> [DisplayItem] {
        var items: [DisplayItem] = []
        let hairline = StrokeStyle(width: 0)
        if frame.showEmBox, frame.advanceWidth > 0 {
            let box = Rect(x: 0, y: -frame.ascender, width: frame.advanceWidth, height: frame.ascender - frame.descender)
            items.append(.stroke(StrokeItem(path: DisplayPath(rect: box), style: StrokeStyle(width: 0, dash: [2, 3], dashInDevicePixels: true),
                                            paint: .solid(frame.metricColor))))
        }
        let (minX, maxX) = frame.extent
        for line in lines(frame) {
            let path = DisplayPath(elements: [.move(to: Point(x: minX, y: line.canvasY)), .line(to: Point(x: maxX, y: line.canvasY))])
            let color = line.role == .baseline ? frame.baselineColor : frame.metricColor
            items.append(.stroke(StrokeItem(path: path, style: hairline, paint: .solid(color))))
        }
        if frame.showSideBearings {
            for x in [0, frame.advanceWidth] {
                items.append(.stroke(StrokeItem(path: vertical(frame, x: x), style: hairline, paint: .solid(frame.bearingColor))))
            }
        }
        return items
    }

    /// The decoration as one group: the background item of a glyph canvas's display list.
    public static func item(_ frame: GlyphCanvasFrame) -> DisplayItem {
        .group(GroupItem(children: items(frame)))
    }

    // MARK: Components (glyph-editing.adoc, "Components"; FONT-012)

    /// The colour components are drawn in: their outline, and a faint tint of it inside.
    public static let componentColor = Color(red: 0.1, green: 0.55, blue: 0.75)

    /// A component as the canvas draws it: the source's outline placed in glyph space, or a
    /// hatched placeholder over `bounds` (a removed source's cached outline, a cut loop).
    public struct Component: Hashable, Sendable {
        public var outline: FilledPath
        public var bounds: Rect
        public var isPlaceholder: Bool

        public init(outline: FilledPath, bounds: Rect, isPlaceholder: Bool) {
            self.outline = outline
            self.bounds = bounds
            self.isPlaceholder = isPlaceholder
        }
    }

    /// The display items of `components`: each outline tinted and outlined with a hairline in
    /// `componentColor` (so it reads as a reference, not artwork), each placeholder a dashed
    /// box with diagonal hatching and its remembered outline dashed inside.
    public static func componentItems(_ components: [Component], color: Color = componentColor) -> [DisplayItem] {
        var items: [DisplayItem] = []
        let hairline = StrokeStyle(width: 0)
        let dashed = StrokeStyle(width: 0, dash: [3, 3], dashInDevicePixels: true)
        for component in components {
            let display = DisplayPath(contours: component.outline.contours)
            if !component.isPlaceholder {
                items.append(.fill(FillItem(path: display, paint: .solid(color.withAlpha(multipliedBy: 0.25)))))
                items.append(.stroke(StrokeItem(path: display, style: hairline, paint: .solid(color))))
                continue
            }
            let box = component.bounds
            items.append(.stroke(StrokeItem(path: DisplayPath(rect: box), style: dashed, paint: .solid(color))))
            items.append(.stroke(StrokeItem(path: hatching(box), style: hairline, paint: .solid(color.withAlpha(multipliedBy: 0.5)))))
            if !component.outline.isEmpty { items.append(.stroke(StrokeItem(path: display, style: dashed, paint: .solid(color)))) }
        }
        return items
    }

    /// Diagonal lines across `box` every tenth of its larger side: the lines u + v = k, with u
    /// running right from the left edge and v up from the bottom edge.
    static func hatching(_ box: Rect) -> DisplayPath {
        let step = max(max(box.width, box.height) / 10, 1)
        var elements: [DisplayPath.Element] = []
        var k = step
        while k < box.width + box.height {
            let u0 = max(0, k - box.height), u1 = min(k, box.width)
            elements.append(.move(to: Point(x: box.minX + u0, y: box.maxY - (k - u0))))
            elements.append(.line(to: Point(x: box.minX + u1, y: box.maxY - (k - u1))))
            k += step
        }
        return DisplayPath(elements: elements)
    }

    /// The metric lines and side bearings as snap targets in glyph-canvas space.
    public static func snapGuides(_ frame: GlyphCanvasFrame) -> [SnapGuide] {
        var guides = lines(frame).map { SnapGuide.horizontal(y: $0.canvasY) }
        guard frame.showSideBearings else { return guides }
        for x in [0, frame.advanceWidth] {
            if frame.italicAngle == 0 {
                guides.append(.vertical(x: x))
            } else {
                let angle = frame.italicAngle * .pi / 180
                guides.append(.angled(through: Point(x: x, y: 0), direction: Vector(dx: -sin(angle), dy: -cos(angle))))
            }
        }
        return guides
    }
}
