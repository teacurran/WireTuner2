// The canvas's scrollable extent (D-093; docs/_includes/basics/workspace.adoc, "The pasteboard",
// and document-view.adoc, "Client"): how far the window may scroll and zoom out.  A view
// property derived from the document every time it is needed -- never stored, never synced.

import WTGeometry
import WTRender

/// The rectangle a document window can scroll over: the bounding box of every page, grown on
/// each side by half the pages' width (left and right) and half their height (top and bottom),
/// each margin at least an A4 side (210 mm across, 297 mm down), so a full portrait A4 sheet
/// always fits beside, above and below the pages.  Artwork lying beyond that (an old document,
/// an import, a drop past the edge) widens the extent to its bounds plus the same A4 margins,
/// so nothing is ever out of reach and an object at the edge can still be brought to the middle
/// of the window.  Pure and platform-neutral: the window recomputes it once per
/// document change, never per frame.
public enum CanvasExtent {
    /// A4's width and height in points (portrait).
    public static let a4 = Size(width: 210 * 72 / 25.4, height: 297 * 72 / 25.4)
    /// Room left around artwork that lies outside the pages' margins: an A4 sheet's width
    /// across and its height down.
    public static let artworkMargin = a4

    /// The margin beyond the pages on the left and right, and on the top and bottom.
    public static func margins(of pages: Rect) -> (horizontal: Double, vertical: Double) {
        (max(pages.width / 2, a4.width), max(pages.height / 2, a4.height))
    }

    /// The extent for pages whose union is `pages`, with drawn artwork bounded by `artwork`
    /// (nil, null or non-finite: none).  Without pages the extent surrounds the artwork alone
    /// (an A4 sheet's margins about it), or an A4 sheet at the origin when there is nothing.
    public static func extent(pages: Rect?, artwork: Rect? = nil) -> Rect {
        let art = artwork.flatMap(usable).map { $0.insetBy(dx: -artworkMargin.width, dy: -artworkMargin.height) }
        guard let pages = pages.flatMap(usable) ?? artwork.flatMap(usable) else {
            return around(Rect(x: 0, y: 0, width: a4.width, height: a4.height))
        }
        let framed = around(pages)
        return art.map { framed.union($0) } ?? framed
    }

    /// `rect` grown by its margins.
    static func around(_ rect: Rect) -> Rect {
        let margin = margins(of: rect)
        return rect.insetBy(dx: -margin.horizontal, dy: -margin.vertical)
    }

    /// `rect` when it is a real, finite rectangle.
    static func usable(_ rect: Rect) -> Rect? {
        guard !rect.isNull, rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else { return nil }
        return rect
    }

    /// The union of the drawn objects' bounds in `list`: the items built from a document node
    /// (background furniture -- the page area's fill and the pages -- carries none).  One pass
    /// over the bounds the list computed when it was built.
    public static func artworkBounds(of list: DisplayList) -> Rect? {
        guard !list.nodeIDs.isEmpty else { return nil }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for (index, node) in list.nodeIDs.enumerated() where node != nil {
            guard let bounds = list.itemBounds[index], usable(bounds) != nil else { continue }
            minX = min(minX, bounds.minX)
            minY = min(minY, bounds.minY)
            maxX = max(maxX, bounds.maxX)
            maxY = max(maxY, bounds.maxY)
        }
        return minX <= maxX && minY <= maxY ? Rect(minX: minX, minY: minY, maxX: maxX, maxY: maxY) : nil
    }

    /// The lowest magnification at which `extent`, turned by `rotationDegrees` (the canvas
    /// rotation, counter-clockwise), fits an area of `size` view points, held within `range`:
    /// zooming out stops once the whole extent shows.
    public static func minimumZoom(for extent: Rect, rotationDegrees: Double = 0, in size: Size, range: ClosedRange<Double>) -> Double {
        let turned = extent.applying(WTGeometry.AffineTransform.rotation(degrees: -rotationDegrees))
        guard turned.width > 0, turned.height > 0, size.width > 0, size.height > 0 else { return range.lowerBound }
        let fit = min(size.width / turned.width, size.height / turned.height)
        guard fit.isFinite else { return range.lowerBound }
        return min(max(fit, range.lowerBound), range.upperBound)
    }
}
