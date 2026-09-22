// The view transform (docs/_includes/basics/document-view.adoc, "Client"):
//
//     pasteboardToView = T(scroll) · R(rotation) · S(zoom)
//
// applied right to left to a pasteboard point.  Rotation is view state, never document data;
// every tool, ruler, overlay and hit test goes through `pasteboardToView`/`viewToPasteboard`
// so rotation is invisible to feature code.

import WTGeometry
import Foundation

/// Where the window looks at the pasteboard: scroll position, canvas rotation and
/// magnification, plus the view's size in points.  Both spaces are y-down.
public struct Viewport: Hashable, Sendable {
    /// Magnification limits from the View menu: 6% to 25,600%.
    public static let zoomRange: ClosedRange<Double> = 0.06...256

    /// The pasteboard point shown at the view's origin (its top-left corner), as
    /// `ViewState.scroll_origin` stores it.
    public var scrollOrigin: Point

    /// Canvas rotation in degrees, counter-clockwise on screen, normalized to (-180, 180].
    public var rotationDegrees: Double {
        didSet { rotationDegrees = Viewport.normalizedDegrees(rotationDegrees) }
    }

    /// View points per pasteboard unit (1 = 100%), clamped to `zoomRange`.
    public var zoom: Double {
        didSet { zoom = Viewport.clampedZoom(zoom) }
    }

    /// The view's size in points.
    public var size: Size

    public init(scrollOrigin: Point = .zero, rotationDegrees: Double = 0, zoom: Double = 1, size: Size) {
        self.scrollOrigin = scrollOrigin
        self.rotationDegrees = Viewport.normalizedDegrees(rotationDegrees)
        self.zoom = Viewport.clampedZoom(zoom)
        self.size = size
    }

    /// `degrees` folded into (-180, 180].
    public static func normalizedDegrees(_ degrees: Double) -> Double {
        var result = degrees.truncatingRemainder(dividingBy: 360)
        if result <= -180 {
            result += 360
        } else if result > 180 {
            result -= 360
        }
        return result == 0 ? 0 : result  // fold -0 into 0 so keys hash alike
    }

    public static func clampedZoom(_ zoom: Double) -> Double {
        guard zoom.isFinite else {
            return 1
        }
        return min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
    }

    public var rotationRadians: Double { rotationDegrees * .pi / 180 }

    /// The view rectangle in view points.
    public var viewBounds: Rect { Rect(x: 0, y: 0, width: size.width, height: size.height) }

    /// The view's centre in view points, the pivot for menu rotation and zoom commands.
    public var viewCenter: Point { viewBounds.center }

    /// `R(rotation) · S(zoom)`: the linear part of the view transform, shared with tile space.
    /// Counter-clockwise on a y-down screen is a negative mathematical angle.
    public var rotationAndScale: AffineTransform {
        Viewport.rotationAndScale(rotationDegrees: rotationDegrees, scale: zoom)
    }

    static func rotationAndScale(rotationDegrees: Double, scale: Double) -> AffineTransform {
        AffineTransform.scale(scale).concatenating(.rotation(degrees: -rotationDegrees))
    }

    /// `T(scroll)`: the translation that puts `scrollOrigin` at the view origin.
    public var translation: Vector {
        let rotatedScroll = rotationAndScale.apply(scrollOrigin)
        return Vector(dx: -rotatedScroll.x, dy: -rotatedScroll.y)
    }

    /// Pasteboard → view points.
    public var pasteboardToView: AffineTransform {
        rotationAndScale.concatenating(.translation(translation))
    }

    /// View points → pasteboard.
    public var viewToPasteboard: AffineTransform {
        pasteboardToView.invertedOrIdentity
    }

    public func toView(_ pasteboardPoint: Point) -> Point {
        pasteboardToView.apply(pasteboardPoint)
    }

    public func toPasteboard(_ viewPoint: Point) -> Point {
        viewToPasteboard.apply(viewPoint)
    }

    /// The pasteboard-space bounding box of what the view shows (a rotated view covers a
    /// larger axis-aligned pasteboard rectangle).
    public var visiblePasteboardBounds: Rect {
        viewBounds.applying(viewToPasteboard)
    }

    /// The viewport with a different `scrollOrigin` such that `viewPoint` keeps showing the
    /// pasteboard point it shows now.
    private func keeping(_ viewPoint: Point, at pasteboardPoint: Point) -> Viewport {
        // Solve pasteboardToView(pasteboardPoint) == viewPoint for the scroll origin:
        // R·S(pasteboardPoint) - R·S(scrollOrigin) == viewPoint  ⇒  scrollOrigin = (R·S)⁻¹(R·S(p) - v).
        var result = self
        let linear = result.rotationAndScale
        let mapped = linear.apply(pasteboardPoint)
        result.scrollOrigin = Point.zero + linear.invertedOrIdentity.apply(mapped - viewPoint)
        return result
    }

    /// The viewport turned to `degrees` about `viewPoint` (default: the view centre).
    public func rotated(toDegrees degrees: Double, aboutViewPoint viewPoint: Point? = nil) -> Viewport {
        let pivot = viewPoint ?? viewCenter
        let anchored = toPasteboard(pivot)
        var result = self
        result.rotationDegrees = degrees
        return result.keeping(pivot, at: anchored)
    }

    /// The viewport turned by `delta` degrees about `viewPoint` (default: the view centre).
    public func rotated(byDegrees delta: Double, aboutViewPoint viewPoint: Point? = nil) -> Viewport {
        rotated(toDegrees: rotationDegrees + delta, aboutViewPoint: viewPoint)
    }

    /// The viewport at magnification `zoom` with `viewPoint` (default: the view centre) fixed.
    public func zoomed(to zoom: Double, aboutViewPoint viewPoint: Point? = nil) -> Viewport {
        let pivot = viewPoint ?? viewCenter
        let anchored = toPasteboard(pivot)
        var result = self
        result.zoom = zoom
        return result.keeping(pivot, at: anchored)
    }

    /// The viewport scrolled by `viewDelta` view points (content moves by -delta).
    public func scrolled(byViewDelta viewDelta: Vector) -> Viewport {
        let pasteboardDelta = rotationAndScale.invertedOrIdentity.apply(viewDelta)
        var result = self
        result.scrollOrigin = scrollOrigin + pasteboardDelta
        return result
    }
}
