// Inspect mode's measurements (COLLAB-035; docs/_includes/collaboration/inspect.adoc,
// "Measuring by hovering" and "Units and scale"): the hovered object's outline and size, the gaps
// between it and the selected object (the overlap when they intersect), its distances to the
// edges of its page (or, with Option, its group or the pasteboard's ruler origin), and a hovered
// point's coordinates -- all from axis-aligned pasteboard bounds of the transformed geometry,
// which the caller reads from the geometry kernel, so they agree with it exactly.  The overlay
// layer draws them; the Inspect panel formats values with the same `InspectFormat`.

import Foundation
import WTGeometry

/// A unit Inspect mode reads measurements in.
public enum InspectUnit: String, CaseIterable, Hashable, Sendable {
    case points, pixels, millimeters, centimeters, inches

    /// The suffix a value carries: "12 pt", "24 px".
    public var symbol: String {
        switch self {
        case .points: "pt"
        case .pixels: "px"
        case .millimeters: "mm"
        case .centimeters: "cm"
        case .inches: "in"
        }
    }

    /// Points in one unit (a pixel is a point before the scale).
    public var points: Double {
        switch self {
        case .points, .pixels: 1
        case .millimeters: 72 / 25.4
        case .centimeters: 72 / 2.54
        case .inches: 72
        }
    }
}

/// How measurements read: the unit and the scale, which applies to pixels only (a 100-point-wide
/// object at 2× reads `200 px`).
public struct InspectFormat: Hashable, Sendable {
    public var unit: InspectUnit
    /// The pixel scale: 1, 2, 3 or a custom factor (> 0).
    public var scale: Double
    /// Decimal places at most; trailing zeros are dropped.
    public var decimals: Int

    public init(unit: InspectUnit = .points, scale: Double = 1, decimals: Int = 2) {
        self.unit = unit
        self.scale = scale > 0 && scale.isFinite ? scale : 1
        self.decimals = max(0, decimals)
    }

    /// `points` in the unit (pixels scaled).
    public func value(_ points: Double) -> Double {
        let converted = points / unit.points
        return unit == .pixels ? converted * scale : converted
    }

    /// "12.5 px": the value rounded to `decimals`, trailing zeros dropped, and the unit's symbol.
    public func string(_ points: Double) -> String {
        "\(number(value(points))) \(unit.symbol)"
    }

    /// "120 × 48 pt".
    public func size(_ size: Size) -> String {
        "\(number(value(size.width))) × \(number(value(size.height))) \(unit.symbol)"
    }

    /// "x 12 pt, y 30 pt" of a point relative to `origin`.
    public func coordinates(_ point: Point, origin: Point = .zero) -> String {
        "x \(string(point.x - origin.x)), y \(string(point.y - origin.y))"
    }

    func number(_ value: Double) -> String {
        let factor = pow(10, Double(decimals))
        var rounded = (value * factor).rounded() / factor
        if rounded == 0 { rounded = 0 }   // no "-0"
        var text = String(format: "%.\(decimals)f", rounded)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }
}

/// One measurement line: from `start` to `end` (pasteboard), horizontal or vertical, labelled with
/// its length.
public struct InspectLine: Hashable, Sendable {
    public enum Axis: Hashable, Sendable {
        case horizontal, vertical
    }

    public var start: Point
    public var end: Point
    public var axis: Axis

    public init(from start: Point, to end: Point, axis: Axis) {
        self.start = start
        self.end = end
        self.axis = axis
    }

    /// The length in points.
    public var distance: Double {
        axis == .horizontal ? abs(end.x - start.x) : abs(end.y - start.y)
    }

    /// Where its label goes: the middle.
    public var middle: Point { Point(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2) }
}

/// What the overlay shows for one pointer position.
public struct InspectMeasurements: Hashable, Sendable {
    /// The hovered object's bounds (its outline and size label); nil when nothing is hovered.
    public var outline: Rect?
    /// Gap or edge-distance lines.
    public var lines: [InspectLine]
    /// The intersection of the hovered and selected bounds when they overlap.
    public var overlap: Rect?
    /// A hovered path point, with the origin its coordinates are read from.
    public var point: Point?
    public var origin: Point

    public init(outline: Rect? = nil, lines: [InspectLine] = [], overlap: Rect? = nil, point: Point? = nil, origin: Point = .zero) {
        self.outline = outline
        self.lines = lines
        self.overlap = overlap
        self.point = point
        self.origin = origin
    }

    /// Nothing to draw.
    public static let empty = InspectMeasurements()

    public var isEmpty: Bool { outline == nil && lines.isEmpty && overlap == nil && point == nil }

    /// The measurements for a pointer over `hovered` (nil: over nothing): with `selected`, the
    /// gaps between the two (the overlap when they intersect); without, the distances to
    /// `container` (the page the object is on, or with Option its group or the pasteboard's ruler
    /// area).  `point` is a hovered path point, read from `origin` (the page's ruler origin).
    public static func measure(hovered: Rect?, selected: Rect? = nil, container: Rect? = nil, point: Point? = nil,
                               origin: Point = .zero) -> InspectMeasurements {
        var result = InspectMeasurements(point: point, origin: origin)
        guard let hovered, !hovered.isNull else { return result }
        result.outline = hovered
        if let selected, !selected.isNull, selected != hovered {
            let (lines, overlap) = gaps(from: selected, to: hovered)
            result.lines = lines
            result.overlap = overlap
        } else if selected == nil, let container, !container.isNull {
            result.lines = edges(of: hovered, in: container)
        }
        return result
    }

    /// The horizontal and vertical gaps between `a` and `b`, or their intersection when they
    /// overlap.  A gap line runs through the middle of the span the two share on the other axis,
    /// or through `b`'s middle when they share none.
    public static func gaps(from a: Rect, to b: Rect) -> (lines: [InspectLine], overlap: Rect?) {
        let overlapsX = a.minX < b.maxX && b.minX < a.maxX
        let overlapsY = a.minY < b.maxY && b.minY < a.maxY
        if overlapsX && overlapsY {
            return ([], a.intersection(b))
        }
        var lines: [InspectLine] = []
        let y = overlapsY ? (max(a.minY, b.minY) + min(a.maxY, b.maxY)) / 2 : b.midY
        let x = overlapsX ? (max(a.minX, b.minX) + min(a.maxX, b.maxX)) / 2 : b.midX
        if b.minX >= a.maxX {
            lines.append(InspectLine(from: Point(x: a.maxX, y: y), to: Point(x: b.minX, y: y), axis: .horizontal))
        } else if a.minX >= b.maxX {
            lines.append(InspectLine(from: Point(x: b.maxX, y: y), to: Point(x: a.minX, y: y), axis: .horizontal))
        }
        if b.minY >= a.maxY {
            lines.append(InspectLine(from: Point(x: x, y: a.maxY), to: Point(x: x, y: b.minY), axis: .vertical))
        } else if a.minY >= b.maxY {
            lines.append(InspectLine(from: Point(x: x, y: b.maxY), to: Point(x: x, y: a.minY), axis: .vertical))
        }
        return (lines, nil)
    }

    /// The distances from `rect` to the four edges of `container`: left, right, top, bottom,
    /// each through `rect`'s middle.
    public static func edges(of rect: Rect, in container: Rect) -> [InspectLine] {
        [
            InspectLine(from: Point(x: container.minX, y: rect.midY), to: Point(x: rect.minX, y: rect.midY), axis: .horizontal),
            InspectLine(from: Point(x: rect.maxX, y: rect.midY), to: Point(x: container.maxX, y: rect.midY), axis: .horizontal),
            InspectLine(from: Point(x: rect.midX, y: container.minY), to: Point(x: rect.midX, y: rect.minY), axis: .vertical),
            InspectLine(from: Point(x: rect.midX, y: rect.maxY), to: Point(x: rect.midX, y: container.maxY), axis: .vertical),
        ]
    }
}

/// The overlay's state across pointer moves: holding kbd:[Shift] freezes what is shown so the
/// pointer can move to read it.
public struct InspectOverlayState: Hashable, Sendable {
    public private(set) var shown = InspectMeasurements.empty
    public var frozen = false

    public init() {}

    /// Shows `measurements` unless frozen; returns whether what is shown changed (the layer
    /// redraws only then).
    @discardableResult
    public mutating func update(_ measurements: InspectMeasurements) -> Bool {
        guard !frozen, measurements != shown else { return false }
        shown = measurements
        return true
    }

    /// Clears what is shown (the pointer left the canvas), frozen or not.
    public mutating func clear() {
        shown = .empty
        frozen = false
    }
}
