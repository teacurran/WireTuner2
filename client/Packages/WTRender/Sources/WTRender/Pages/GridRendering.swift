// The document grid (DOC-016; docs/_includes/document/grid-guides.adoc, "The grid" and
// "Client"): dots at the intersections of lines `size` points apart from the grid origin, drawn
// above the page backgrounds and below the pages' content.  Dots closer than 4 px on screen are
// thinned -- every k-th line is kept so the visible lattice is at least 8 px -- using the view
// scale only, never the canvas angle; the dots are pasteboard geometry, so a rotated canvas
// rotates them with the pages.  A dot is one device pixel square at every zoom.

import WTGeometry

/// The grid as drawn and snapped to: `SettingsProps.grid` with its origin.
public struct GridSpec: Hashable, Sendable {
    /// Points between grid lines.
    public var size: Double
    /// Where a pair of lines crosses (the active page's zero point).
    public var origin: Point
    /// *Relative grid*: snap keeps the offset within a cell rather than landing on an
    /// intersection.
    public var relative: Bool

    public init(size: Double, origin: Point = .zero, relative: Bool = false) {
        self.size = size
        self.origin = origin
        self.relative = relative
    }

    /// Whether the grid has a usable spacing.
    public var isValid: Bool { size > 0 && size.isFinite && origin.isFinite }

    /// The absolute lattice as a snap target.
    public var snapGrid: SnapGrid {
        SnapGrid(origin: origin, size: size)
    }
}

/// Builds the grid's dots for an area of the pasteboard at a zoom.
public enum GridRendering {
    /// Dots closer than this on screen are thinned.
    public static let minimumSpacing = 4.0
    /// The thinned lattice is at least this far apart on screen.
    public static let thinnedSpacing = 8.0
    /// The most dots one call draws; an area that would hold more (a huge tile) is left empty
    /// rather than stalling a frame.
    public static let maximumDots = 250_000

    /// Every how many grid lines a dot is drawn at `zoom` (view pixels per point): 1 while the
    /// dots are at least 4 px apart, else the smallest k that puts them 8 px or more apart.  Nil
    /// for an unusable grid or zoom.
    public static func stride(size: Double, zoom: Double) -> Int? {
        guard size > 0, size.isFinite, zoom > 0, zoom.isFinite else { return nil }
        let spacing = size * zoom
        if spacing >= minimumSpacing { return 1 }
        let k = (thinnedSpacing / spacing).rounded(.up)
        return k.isFinite && k < Double(Int32.max) ? Int(k) : nil
    }

    /// The dots of `grid` inside `area` (pasteboard) at `zoom`, as one fill of `color`: each dot a
    /// square one device pixel wide centred on an intersection.  Nil when there is nothing to draw.
    public static func item(_ grid: GridSpec, in area: Rect, zoom: Double, color: Color = Color(white: 0.75)) -> DisplayItem? {
        guard grid.isValid, !area.isNull, area.width > 0, area.height > 0, let k = stride(size: grid.size, zoom: zoom) else { return nil }
        let step = grid.size * Double(k)
        let first = (x: ((area.minX - grid.origin.x) / step).rounded(.up), y: ((area.minY - grid.origin.y) / step).rounded(.up))
        let last = (x: ((area.maxX - grid.origin.x) / step).rounded(.down), y: ((area.maxY - grid.origin.y) / step).rounded(.down))
        let columns = last.x - first.x + 1
        let rows = last.y - first.y + 1
        guard columns >= 1, rows >= 1, columns * rows <= Double(maximumDots) else { return nil }
        let half = 0.5 / zoom
        var elements: [DisplayPath.Element] = []
        elements.reserveCapacity(Int(columns * rows) * 5)
        var j = first.y
        while j <= last.y {
            let y = grid.origin.y + j * step
            var i = first.x
            while i <= last.x {
                let x = grid.origin.x + i * step
                elements.append(.move(to: Point(x: x - half, y: y - half)))
                elements.append(.line(to: Point(x: x + half, y: y - half)))
                elements.append(.line(to: Point(x: x + half, y: y + half)))
                elements.append(.line(to: Point(x: x - half, y: y + half)))
                elements.append(.close)
                i += 1
            }
            j += 1
        }
        return .fill(FillItem(path: DisplayPath(elements: elements), paint: .solid(color)))
    }

    /// The number of dots `item` would draw (for budgets and tests); 0 when it draws none.
    public static func dotCount(_ grid: GridSpec, in area: Rect, zoom: Double) -> Int {
        guard grid.isValid, !area.isNull, let k = stride(size: grid.size, zoom: zoom) else { return 0 }
        let step = grid.size * Double(k)
        let columns = ((area.maxX - grid.origin.x) / step).rounded(.down) - ((area.minX - grid.origin.x) / step).rounded(.up) + 1
        let rows = ((area.maxY - grid.origin.y) / step).rounded(.down) - ((area.minY - grid.origin.y) / step).rounded(.up) + 1
        guard columns >= 1, rows >= 1, columns * rows <= Double(maximumDots) else { return 0 }
        return Int(columns * rows)
    }
}
