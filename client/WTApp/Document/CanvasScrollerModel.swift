import WTGeometry
import WTRender

/// One scroll bar's state: how much of the content is visible and where.
struct ScrollAxisState: Equatable, Sendable {
    /// Visible share of the content, 0...1 (`NSScroller.knobProportion`).
    let knobProportion: Double
    /// Position, 0 at the start (left or top) to 1 at the end (`NSScroller.doubleValue`).
    let value: Double

    var isScrollable: Bool { knobProportion < 1 }
}

/// The scrolling model that replaces `NSScrollView`: the pasteboard's extent in view space,
/// the clamp that keeps the view inside it, and the two scroll bars' states.  Works in the
/// rotated, scaled space (`R · S` applied to the pasteboard, without the scroll translation),
/// so it clamps correctly at any canvas rotation (BASIC-034's rotated scroll extent).  The view's
/// covered edges (`insets`: the dock, rulers and scroll bars the canvas runs under, D-077) are
/// left out: the clamp keeps the *safe area* inside the pasteboard, so every part of the
/// pasteboard can be scrolled out from under the dock, and the scroll bars measure the safe area.
struct CanvasScrollerModel: Sendable {
    /// The pasteboard: 222 × 222 inches.
    let pasteboard: Rect
    /// The covered edges of the view.
    var insets = CanvasInsets.zero

    init(pasteboard: Rect = Pasteboard.bounds) {
        self.pasteboard = pasteboard
    }

    /// The pasteboard's bounding box in unscrolled view space.
    func contentBounds(of viewport: Viewport) -> Rect {
        pasteboard.applying(viewport.rotationAndScale)
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

    /// The viewport moved so the safe area stays inside the pasteboard; along an axis where the
    /// pasteboard is smaller than the safe area, the pasteboard is centred in it.
    func clamped(_ viewport: Viewport) -> Viewport {
        let content = contentBounds(of: viewport)
        let safe = safeArea(of: viewport)
        let x = Self.clamp(safe.origin.x, length: safe.size.width, contentMin: content.minX, contentMax: content.maxX)
        let y = Self.clamp(safe.origin.y, length: safe.size.height, contentMin: content.minY, contentMax: content.maxY)
        guard x != safe.origin.x || y != safe.origin.y else { return viewport }
        return viewport.scrolled(byViewDelta: Vector(dx: x - safe.origin.x, dy: y - safe.origin.y))
    }

    static func clamp(_ start: Double, length: Double, contentMin: Double, contentMax: Double) -> Double {
        let extent = contentMax - contentMin
        if extent <= length { return contentMin - (length - extent) / 2 }
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
