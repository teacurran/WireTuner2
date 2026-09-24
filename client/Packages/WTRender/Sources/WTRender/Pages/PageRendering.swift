// Page furniture (DOC-009; docs/_includes/document/pages.adoc, "Client", and
// document-panel.adoc, "Derived, never stored"): the pasteboard in the *Pasteboard color*, each
// page rectangle filled white with a hairline, the bleed rectangle as a dotted hairline, the
// active page's outline emphasized, and a dot in each collaborator's presence colour at the
// top-left corner of the page they are on.  The items sit in the display list below the layers
// (`DocumentDisplayListBuilder`'s background) and carry no node id.  For print and export only
// the page background is drawn -- the outline, the bleed line, the dots and the pasteboard do
// not print.

import WTGeometry

/// One page as drawn: its rectangle on the pasteboard, its bleed, whether it is the active page
/// and the presence colours of the collaborators viewing it.
public struct PageFrame: Hashable, Sendable {
    public var rect: Rect
    /// Points beyond every edge.
    public var bleed: Double
    public var isActive: Bool
    public var presence: [Color]

    public init(rect: Rect, bleed: Double = 0, isActive: Bool = false, presence: [Color] = []) {
        self.rect = rect
        self.bleed = bleed
        self.isActive = isActive
        self.presence = presence
    }

    /// The page rectangle grown by the bleed on every side.
    public var bleedRect: Rect {
        rect.insetBy(dx: -max(bleed, 0), dy: -max(bleed, 0))
    }
}

/// Colours and sizes of the page furniture: the preferences (*Pasteboard color*) and the fixed
/// look.  Lines are hairlines -- one device pixel at every zoom -- and the bleed line's dots are
/// device pixels too, so pages look the same at every magnification.
public struct PageStyle: Hashable, Sendable {
    /// The *Pasteboard color* preference.
    public var pasteboardColor: Color
    /// The pasteboard's extent (222 × 222 in by default); nil draws no pasteboard fill.
    public var pasteboard: Rect?
    /// The page background: white on screen and in print.
    public var pageColor: Color
    public var outlineColor: Color
    /// The active page's outline.
    public var activeOutlineColor: Color
    public var bleedColor: Color
    /// The bleed line's dash and gap, in device pixels.
    public var bleedDash: [Double]
    /// A presence dot's diameter in device pixels.
    public var presenceDotDiameter: Double
    /// Pasteboard points per device pixel at the zoom the dots are laid out for (1 / zoom).  Only
    /// the presence dots depend on it; the page rectangles and lines do not.
    public var pixelSize: Double

    /// The pasteboard of every document: 222 × 222 inches from the origin (workspace.adoc).
    public static let standardPasteboard = Rect(x: 0, y: 0, width: 15_984, height: 15_984)

    public init(
        pasteboardColor: Color = Color(white: 0.87),
        pasteboard: Rect? = PageStyle.standardPasteboard,
        pageColor: Color = .white,
        outlineColor: Color = Color(white: 0.45),
        activeOutlineColor: Color = Color(red: 0.1, green: 0.4, blue: 0.95),
        bleedColor: Color = Color(white: 0.5),
        bleedDash: [Double] = [2, 2],
        presenceDotDiameter: Double = 7,
        pixelSize: Double = 1
    ) {
        self.pasteboardColor = pasteboardColor
        self.pasteboard = pasteboard
        self.pageColor = pageColor
        self.outlineColor = outlineColor
        self.activeOutlineColor = activeOutlineColor
        self.bleedColor = bleedColor
        self.bleedDash = bleedDash
        self.presenceDotDiameter = presenceDotDiameter
        self.pixelSize = pixelSize.isFinite && pixelSize > 0 ? pixelSize : 1
    }
}

/// Builds the page furniture's display items.
public enum PageRendering {
    /// Where the furniture is going.
    public enum Output: Hashable, Sendable {
        /// The canvas: pasteboard, page backgrounds, bleed lines, outlines and presence dots.
        case screen
        /// Print and export: the page backgrounds alone.
        case print
    }

    /// The pasteboard and the page backgrounds: what draws below the grid (grid-guides.adoc,
    /// "Client": the grid is above the page background and below the pages' content).
    public static func backgroundItems(_ pages: [PageFrame], style: PageStyle = PageStyle(), output: Output = .screen) -> [DisplayItem] {
        var items: [DisplayItem] = []
        if output == .screen, let pasteboard = style.pasteboard, !pasteboard.isEmpty {
            items.append(.fill(FillItem(path: DisplayPath(rect: pasteboard), paint: .solid(style.pasteboardColor))))
        }
        for page in pages where page.rect.width > 0 && page.rect.height > 0 {
            items.append(.fill(FillItem(path: DisplayPath(rect: page.rect), paint: .solid(style.pageColor))))
        }
        return items
    }

    /// The bleed lines, outlines and presence dots: what draws above the grid.  Nothing for print.
    public static func frameItems(_ pages: [PageFrame], style: PageStyle = PageStyle(), output: Output = .screen) -> [DisplayItem] {
        guard output == .screen else { return [] }
        var items: [DisplayItem] = []
        let dotted = StrokeStyle(width: 0, dash: style.bleedDash, dashInDevicePixels: true)
        for page in pages where page.rect.width > 0 && page.rect.height > 0 {
            if page.bleed > 0 {
                items.append(.stroke(StrokeItem(path: DisplayPath(rect: page.bleedRect), style: dotted, paint: .solid(style.bleedColor))))
            }
        }
        // Inactive outlines first so the active page's emphasis is never covered by a neighbour.
        for page in pages.sorted(by: { !$0.isActive && $1.isActive }) where page.rect.width > 0 && page.rect.height > 0 {
            let color = page.isActive ? style.activeOutlineColor : style.outlineColor
            items.append(.stroke(StrokeItem(path: DisplayPath(rect: page.rect), style: StrokeStyle(width: 0), paint: .solid(color))))
            items += presenceDots(page, style: style)
        }
        return items
    }

    /// One group of the whole furniture, `grid` (the canvas's grid layer, if shown) between the
    /// page backgrounds and the outlines: the background item of a canvas's display list.
    public static func item(_ pages: [PageFrame], style: PageStyle = PageStyle(), output: Output = .screen, grid: [DisplayItem] = []) -> DisplayItem {
        .group(GroupItem(children: backgroundItems(pages, style: style, output: output) + (output == .screen ? grid : [])
            + frameItems(pages, style: style, output: output)))
    }

    /// The presence dots of `page`: one per colour, left to right from the top-left corner,
    /// inside the page.
    static func presenceDots(_ page: PageFrame, style: PageStyle) -> [DisplayItem] {
        let diameter = style.presenceDotDiameter * style.pixelSize
        guard diameter > 0 else { return [] }
        let inset = diameter / 2
        return page.presence.enumerated().map { index, color in
            let x = page.rect.minX + inset + Double(index) * diameter * 1.4
            let rect = Rect(x: x, y: page.rect.minY + inset, width: diameter, height: diameter)
            return .fill(FillItem(path: DisplayPath(ellipseIn: rect), paint: .solid(color)))
        }
    }
}
