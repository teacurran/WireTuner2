import Foundation
import WTGeometry
import WTRender

/// The parts of the canvas covered by the window's chrome, in view points from each edge (D-077:
/// the canvas runs under the docked panels, the rulers and the scroll bars).  What is left is the
/// canvas's safe area: Fit, zoom-to-fit, centring, the scroll bars and auto-scroll use it, so
/// nothing is placed under the dock.
struct CanvasInsets: Equatable, Sendable {
    var top = 0.0
    var left = 0.0
    var bottom = 0.0
    var right = 0.0

    static let zero = CanvasInsets()

    /// The unobscured rectangle of a view of `size` (view points, y down); never narrower or
    /// shorter than one point.
    func safeRect(in size: Size) -> Rect {
        let width = max(size.width - left - right, 1)
        let height = max(size.height - top - bottom, 1)
        return Rect(x: min(left, max(size.width - 1, 0)), y: min(top, max(size.height - 1, 0)), width: width, height: height)
    }
}

/// The zoom and scroll arithmetic behind the View menu, the magnification field, pinch,
/// Option-scroll and the Hand and Zoom tools.  Pure: every function maps a viewport to a
/// viewport, clamped to the canvas's extent by `CanvasScrollerModel` (D-093).  Fits and centring use the
/// safe area (`insets`), not the whole view.
struct CanvasNavigation: Sendable {
    /// Margin, in view points, a Fit command leaves around the fitted rectangle.
    static let fitMargin = 20.0

    var scroller = CanvasScrollerModel()

    /// Navigation that never clamps (a tool's own arithmetic, offscreen renders): the canvas's
    /// `setViewport` clamps the result to its extent.
    static let unbounded = CanvasNavigation(scroller: .unbounded)

    /// The view's covered edges (the dock, rulers, scroll bars): kept in the scroller model, whose
    /// clamp and scroll bars use the same safe area.
    var insets: CanvasInsets {
        get { scroller.insets }
        set { scroller.insets = newValue }
    }

    /// The unobscured part of `viewport`'s view, view points.
    func safeRect(_ viewport: Viewport) -> Rect { insets.safeRect(in: viewport.size) }

    /// The centre of the unobscured part of the view, view points.
    func safeCenter(_ viewport: Viewport) -> Point { safeRect(viewport).center }

    func clamped(_ viewport: Viewport) -> Viewport { scroller.clamped(viewport) }

    /// Zoom In: the next ladder preset above the current zoom, keeping the window centre.
    func zoomIn(_ viewport: Viewport) -> Viewport {
        zoom(viewport, to: ZoomLadder.zoomIn(from: viewport.zoom))
    }

    /// Zoom Out: the next ladder preset below, keeping the window centre.
    func zoomOut(_ viewport: Viewport) -> Viewport {
        zoom(viewport, to: ZoomLadder.zoomOut(from: viewport.zoom))
    }

    /// Magnification `zoom` about `viewPoint` (default: the centre of the safe area).
    func zoom(_ viewport: Viewport, to zoom: Double, about viewPoint: Point? = nil) -> Viewport {
        clamped(viewport.zoomed(to: zoom, aboutViewPoint: viewPoint ?? safeCenter(viewport)))
    }

    /// Continuous zoom (pinch, Option-scroll): multiplies the zoom by `factor` about the pointer.
    func magnify(_ viewport: Viewport, by factor: Double, about viewPoint: Point) -> Viewport {
        guard factor.isFinite, factor > 0 else { return viewport }
        return zoom(viewport, to: viewport.zoom * factor, about: viewPoint)
    }

    /// Scrolls by `delta` view points (content moves by -delta).
    func scroll(_ viewport: Viewport, by delta: Vector) -> Viewport {
        clamped(viewport.scrolled(byViewDelta: delta))
    }

    /// The largest zoom at which `rect` (pasteboard) fits the safe area with the margin, clamped
    /// to the zoom range.  The rectangle's extent is measured in the view's rotated axes.
    func fittingZoom(for rect: Rect, in viewport: Viewport) -> Double {
        let turned = rect.applying(WTGeometry.AffineTransform.rotation(degrees: -viewport.rotationDegrees))
        let safe = safeRect(viewport)
        let width = max(safe.width - 2 * Self.fitMargin, 1)
        let height = max(safe.height - 2 * Self.fitMargin, 1)
        guard turned.width > 0 || turned.height > 0 else { return viewport.zoom }
        let zoomX = turned.width > 0 ? width / turned.width : .infinity
        let zoomY = turned.height > 0 ? height / turned.height : .infinity
        return Viewport.clampedZoom(min(zoomX, zoomY))
    }

    /// Fits `rect` in the safe area and centres it there (Fit Selection, Fit to Page, Fit All, a Zoom
    /// tool drag).
    func fit(_ viewport: Viewport, rect: Rect) -> Viewport {
        guard !rect.isNull else { return viewport }
        var result = viewport
        result.zoom = fittingZoom(for: rect, in: viewport)
        return clamped(centring(result, on: rect.center))
    }

    /// The viewport scrolled so `point` (pasteboard) shows at the centre of the safe area.
    func centring(_ viewport: Viewport, on point: Point) -> Viewport {
        let shown = viewport.toView(point)
        return viewport.scrolled(byViewDelta: shown - safeCenter(viewport))
    }

    /// The union of `rects`, or nil when there are none.
    static func union(_ rects: [Rect]) -> Rect? {
        guard var result = rects.first else { return nil }
        for rect in rects.dropFirst() { result = result.union(rect) }
        return result
    }
}
