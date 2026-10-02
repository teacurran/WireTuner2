import WTGeometry
import WTModel
import WTRender

/// One scroll bar's state: how much of the content is visible and where.
struct ScrollAxisState: Equatable, Sendable {
    /// Visible share of the content, 0...1 (`NSScroller.knobProportion`).
    let knobProportion: Double
    /// Position, 0 at the start (left or top) to 1 at the end (`NSScroller.doubleValue`).
    let value: Double

    var isScrollable: Bool { knobProportion < 1 }
}

/// The scrolling model that replaces `NSScrollView`: the canvas's scrollable extent in view
/// space, the clamp that keeps the view inside it, and the two scroll bars' states.  Works in the
/// rotated, scaled space (`R · S` applied to the extent, without the scroll translation), so it
/// clamps correctly at any canvas rotation (BASIC-034's rotated scroll extent).  The view's
/// covered edges (`insets`: the dock, rulers and scroll bars the canvas runs under, D-077) are
/// left out: the clamp keeps the *safe area* inside the extent, so every part of it can be
/// scrolled out from under the dock, and the scroll bars measure the safe area.
///
/// The extent is the document's pages with their margins and any artwork beyond them
/// (`CanvasExtent`, D-093), set by the canvas after each document change; the clamp also holds
/// the zoom at or above the magnification at which the whole extent fits the safe area, so the
/// pages can never be scrolled or zoomed out of reach.
struct CanvasScrollerModel: Sendable {
    /// The scrollable extent, pasteboard coordinates.
    var extent: Rect
    /// The covered edges of the view.
    var insets = CanvasInsets.zero

    init(extent: Rect = Pasteboard.newDocumentExtent) {
        self.extent = extent
    }

    /// A model that never moves the view (a tool's own arithmetic, offscreen renders): the
    /// canvas clamps what it is given.
    static let unbounded = CanvasScrollerModel(extent: Rect(x: -1e12, y: -1e12, width: 2e12, height: 2e12))

    /// The lowest zoom for `viewport`: the whole extent fits its safe area (never below the View
    /// menu's 6%, never above 100%).
    func minimumZoom(of viewport: Viewport) -> Double {
        let safe = insets.safeRect(in: viewport.size)
        return CanvasExtent.minimumZoom(
            for: extent, rotationDegrees: viewport.rotationDegrees, in: Size(width: safe.width, height: safe.height),
            range: Viewport.zoomRange.lowerBound...1
        )
    }

    /// The extent's bounding box in unscrolled view space.
    func contentBounds(of viewport: Viewport) -> Rect {
        extent.applying(viewport.rotationAndScale)
    }

    /// Where the view's top-left corner sits in unscrolled view space.
    func visibleOrigin(of viewport: Viewport) -> Point {
        viewport.rotationAndScale.apply(viewport.scrollOrigin)
    }

    /// Where the safe area's top-left corner sits in unscrolled view space, and its size.
    func safeArea(of viewport: Viewport) -> (origin: Point, size: Size) {
        let origin = visibleOrigin(of: viewport)
        let safe = insets.safeRect(in: viewport.size)
        return (Point(x: origin.x + safe.minX, y: origin.y + safe.minY), Size(width: safe.width, height: safe.height))
    }

    /// The viewport zoomed in (about the safe area's centre) to at least `minimumZoom`, then moved
    /// as little as it takes so the safe area stays inside the extent; along an axis where the
    /// extent is smaller than the safe area, so the whole extent stays inside the safe area (it
    /// may sit anywhere there, so a document change that grows the extent never moves the view).
    func clamped(_ viewport: Viewport) -> Viewport {
        var viewport = viewport
        let floor = minimumZoom(of: viewport)
        if viewport.zoom < floor {
            viewport = viewport.zoomed(to: floor, aboutViewPoint: insets.safeRect(in: viewport.size).center)
        }
        let content = contentBounds(of: viewport)
        let safe = safeArea(of: viewport)
        let x = Self.clamp(safe.origin.x, length: safe.size.width, contentMin: content.minX, contentMax: content.maxX)
        let y = Self.clamp(safe.origin.y, length: safe.size.height, contentMin: content.minY, contentMax: content.maxY)
        guard x != safe.origin.x || y != safe.origin.y else { return viewport }
        return viewport.scrolled(byViewDelta: Vector(dx: x - safe.origin.x, dy: y - safe.origin.y))
    }

    static func clamp(_ start: Double, length: Double, contentMin: Double, contentMax: Double) -> Double {
        let extent = contentMax - contentMin
        if extent <= length { return min(max(start, contentMax - length), contentMin) }
        return min(max(start, contentMin), contentMax - length)
    }

    func horizontal(_ viewport: Viewport) -> ScrollAxisState {
        let content = contentBounds(of: viewport)
        let safe = safeArea(of: viewport)
        return Self.axis(start: safe.origin.x, length: safe.size.width, contentMin: content.minX, contentMax: content.maxX)
    }

    func vertical(_ viewport: Viewport) -> ScrollAxisState {
        let content = contentBounds(of: viewport)
        let safe = safeArea(of: viewport)
        return Self.axis(start: safe.origin.y, length: safe.size.height, contentMin: content.minY, contentMax: content.maxY)
    }

    static func axis(start: Double, length: Double, contentMin: Double, contentMax: Double) -> ScrollAxisState {
        let extent = contentMax - contentMin
        guard extent > length, length > 0 else { return ScrollAxisState(knobProportion: 1, value: 0) }
        let value = (start - contentMin) / (extent - length)
        return ScrollAxisState(knobProportion: length / extent, value: min(max(value, 0), 1))
    }

    /// The viewport with the horizontal scroll bar at `value` (0...1).
    func scrolled(_ viewport: Viewport, horizontalValue value: Double) -> Viewport {
        let content = contentBounds(of: viewport)
        let safe = safeArea(of: viewport)
        let target = content.minX + min(max(value, 0), 1) * max(content.width - safe.size.width, 0)
        let delta = target - safe.origin.x
        return clamped(viewport.scrolled(byViewDelta: Vector(dx: delta, dy: 0)))
    }

    /// The viewport with the vertical scroll bar at `value` (0...1).
    func scrolled(_ viewport: Viewport, verticalValue value: Double) -> Viewport {
        let content = contentBounds(of: viewport)
        let safe = safeArea(of: viewport)
        let target = content.minY + min(max(value, 0), 1) * max(content.height - safe.size.height, 0)
        let delta = target - safe.origin.y
        return clamped(viewport.scrolled(byViewDelta: Vector(dx: 0, dy: delta)))
    }
}
