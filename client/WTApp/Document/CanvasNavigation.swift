import Foundation
import WTGeometry
import WTRender

/// The zoom and scroll arithmetic behind the View menu, the magnification field, pinch,
/// Option-scroll and the Hand and Zoom tools.  Pure: every function maps a viewport to a
/// viewport, clamped to the pasteboard by `CanvasScrollerModel`.
struct CanvasNavigation: Sendable {
    /// Margin, in view points, a Fit command leaves around the fitted rectangle.
    static let fitMargin = 20.0

    var scroller = CanvasScrollerModel()

    func clamped(_ viewport: Viewport) -> Viewport { scroller.clamped(viewport) }

    /// Zoom In: the next ladder preset above the current zoom, keeping the window centre.
    func zoomIn(_ viewport: Viewport) -> Viewport {
        zoom(viewport, to: ZoomLadder.zoomIn(from: viewport.zoom))
    }

    /// Zoom Out: the next ladder preset below, keeping the window centre.
    func zoomOut(_ viewport: Viewport) -> Viewport {
        zoom(viewport, to: ZoomLadder.zoomOut(from: viewport.zoom))
    }

    /// Magnification `zoom` about `viewPoint` (default: the window centre).
    func zoom(_ viewport: Viewport, to zoom: Double, about viewPoint: Point? = nil) -> Viewport {
        clamped(viewport.zoomed(to: zoom, aboutViewPoint: viewPoint))
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

    /// The largest zoom at which `rect` (pasteboard) fits the view with the margin, clamped
    /// to the zoom range.  The rectangle's extent is measured in the view's rotated axes.
    func fittingZoom(for rect: Rect, in viewport: Viewport) -> Double {
        let turned = rect.applying(WTGeometry.AffineTransform.rotation(degrees: -viewport.rotationDegrees))
        let width = max(viewport.size.width - 2 * Self.fitMargin, 1)
        let height = max(viewport.size.height - 2 * Self.fitMargin, 1)
        guard turned.width > 0 || turned.height > 0 else { return viewport.zoom }
        let zoomX = turned.width > 0 ? width / turned.width : .infinity
        let zoomY = turned.height > 0 ? height / turned.height : .infinity
        return Viewport.clampedZoom(min(zoomX, zoomY))
    }

    /// Fits `rect` in the window and centres it (Fit Selection, Fit to Page, Fit All, a Zoom
    /// tool drag).
    func fit(_ viewport: Viewport, rect: Rect) -> Viewport {
        guard !rect.isNull else { return viewport }
        var result = viewport
        result.zoom = fittingZoom(for: rect, in: viewport)
        return clamped(centring(result, on: rect.center))
    }

    /// The viewport scrolled so `point` (pasteboard) shows at the window centre.
    func centring(_ viewport: Viewport, on point: Point) -> Viewport {
        let shown = viewport.toView(point)
        return viewport.scrolled(byViewDelta: shown - viewport.viewCenter)
    }

    /// The union of `rects`, or nil when there are none.
    static func union(_ rects: [Rect]) -> Rect? {
        guard var result = rects.first else { return nil }
        for rect in rects.dropFirst() { result = result.union(rect) }
        return result
    }
}
