// menu:View[Show Links] (WEB-004; web/urls.adoc, "Client"): a tint over every linked object and an
// underline under every linked text line, drawn by the window in an overlay layer over the tiles
// -- never in the display list, so toggling it rebuilds nothing and it cannot reach print or an
// export -- with the URL under the pointer for the hover tooltip.  The marks are in pasteboard
// space; WTModel's `LinkOverlayReading` builds them from the scene and the link index.

import CoreGraphics
import WTGeometry

/// One linked thing on the canvas.
public struct LinkMark: Hashable, Sendable {
    public enum Shape: Hashable, Sendable {
        /// A linked object: its painted bounds, tinted.
        case object(Rect)
        /// One line of a linked text range: the line's box, underlined along its bottom edge.
        case textLine(Rect)
    }

    public var url: String
    /// The node carrying the link (the object, or the text block holding the range).
    public var node: NodeID
    public var shape: Shape

    public init(url: String, node: NodeID, shape: Shape) {
        self.url = url
        self.node = node
        self.shape = shape
    }

    /// The pasteboard area the mark paints.
    public var rect: Rect {
        switch shape {
        case .object(let rect), .textLine(let rect): rect
        }
    }
}

/// The marks of one window's Show Links overlay, bottom first.
public struct LinkOverlay: Hashable, Sendable {
    public struct Style: Hashable, Sendable {
        public var tint: Color
        public var underline: Color
        /// The underline's thickness in view points (it does not scale with zoom).
        public var underlineWidth: Double

        public init(tint: Color, underline: Color, underlineWidth: Double) {
            self.tint = tint
            self.underline = underline
            self.underlineWidth = underlineWidth
        }

        /// A light blue tint and a blue 2 pt underline.
        public static let standard = Style(tint: Color(red: 0.2, green: 0.45, blue: 1, alpha: 0.18), underline: Color(red: 0.1, green: 0.35, blue: 0.95),
                                           underlineWidth: 2)
    }

    public var marks: [LinkMark]

    public init(marks: [LinkMark] = []) {
        self.marks = marks
    }

    public var isEmpty: Bool { marks.isEmpty }

    /// The URL under `point` (pasteboard space) for the hover tooltip: the topmost mark whose
    /// rect, grown by `tolerance`, holds it; text lines win over the object tint beneath them.
    public func url(at point: Point, tolerance: Double = 0) -> String? {
        func hit(_ mark: LinkMark) -> Bool {
            let rect = mark.rect
            return point.x >= rect.minX - tolerance && point.x <= rect.maxX + tolerance
                && point.y >= rect.minY - tolerance && point.y <= rect.maxY + tolerance
        }
        let lines = marks.reversed().filter { if case .textLine = $0.shape { true } else { false } }
        return (lines.first(where: hit) ?? marks.reversed().first(where: hit))?.url
    }

    /// The pasteboard area each node's marks paint.
    public var bounds: [NodeID: Rect] {
        var result: [NodeID: Rect] = [:]
        for mark in marks {
            result[mark.node] = result[mark.node].map { $0.union(mark.rect) } ?? mark.rect
        }
        return result
    }

    /// What must repaint going from `old` to `new`: the areas of the nodes whose marks changed
    /// (a remote link change repaints only that object's area).
    public static func dirtyRects(from old: LinkOverlay, to new: LinkOverlay) -> [Rect] {
        let before = Dictionary(grouping: old.marks, by: \.node)
        let after = Dictionary(grouping: new.marks, by: \.node)
        let oldBounds = old.bounds, newBounds = new.bounds
        var rects: [Rect] = []
        for node in Set(before.keys).union(after.keys).sorted() where before[node] != after[node] {
            rects += [oldBounds[node], newBounds[node]].compactMap { $0 }
        }
        return rects
    }

    /// Draws the marks into `context` (view space, y down, as the canvas overlays are) through
    /// `viewport`: the tint over each object, then each underline along its line's bottom edge.
    public func draw(in context: CGContext, viewport: Viewport, style: Style = .standard) {
        context.saveGState()
        defer { context.restoreGState() }
        for mark in marks {
            let rect = viewRect(mark.rect, viewport: viewport)
            switch mark.shape {
            case .object:
                context.setFillColor(style.tint.cgColor)
                context.fill(rect)
            case .textLine:
                context.setFillColor(style.underline.cgColor)
                context.fill(CGRect(x: rect.minX, y: rect.maxY - style.underlineWidth, width: rect.width, height: style.underlineWidth))
            }
        }
    }

    /// `rect` (pasteboard) in view space.
    func viewRect(_ rect: Rect, viewport: Viewport) -> CGRect {
        let a = viewport.toView(Point(x: rect.minX, y: rect.minY))
        let b = viewport.toView(Point(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
