import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The link badge (interactivity.adoc, "Going to a page on click"; WEB-021): while menu:View[Show
/// Links] is on, an object with a page link shows a small badge at the lower right of its bounding
/// box, 12 × 12 pt whatever the zoom, and hovering it names the target page.  Drawn with the Show
/// Links overlay, never in the display list.
@MainActor
enum LinkBadges {
    static let size = 12.0

    struct Badge: Equatable {
        var node: OpID
        /// The object's bounds (pasteboard); the badge sits at their lower-right corner.
        var bounds: Rect
        /// The target page's name ("Page 3" when it has none).
        var page: String
    }

    /// Every drawn object with a live page link, in node order.
    static func badges(_ document: DocumentHandle) -> [Badge] {
        let state = document.state
        let pages = PageList(state)
        return document.scene.objects.values.compactMap { object -> Badge? in
            guard let bounds = object.bounds, let target = NavigationInfo(object.id, in: state).goToPage, let page = pages[target] else { return nil }
            return Badge(node: object.id, bounds: bounds, page: page.name.isEmpty ? "Page \(page.number)" : page.name)
        }
        .sorted { $0.node < $1.node }
    }

    /// The badge's square in view points.
    static func rect(_ badge: Badge, viewport: Viewport) -> Rect {
        let corner = viewport.toView(Point(x: badge.bounds.maxX, y: badge.bounds.maxY))
        return Rect(x: corner.x - size, y: corner.y - size, width: size, height: size)
    }

    /// The target page named by the badge under `point` (pasteboard), for the tooltip.
    static func page(at point: Point, document: DocumentHandle, viewport: Viewport) -> String? {
        let view = viewport.toView(point)
        return badges(document).last { rect($0, viewport: viewport).contains(view) }.map { "Go to \($0.page)" }
    }

    /// Draws the badges: a blue rounded square with an arrow pointing out of it.
    static func draw(_ document: DocumentHandle, in ctx: CGContext, viewport: Viewport) {
        let badges = badges(document)
        guard !badges.isEmpty else { return }
        ctx.saveGState()
        for badge in badges {
            let r = rect(badge, viewport: viewport).cgRect
            ctx.setFillColor(NSColor.systemBlue.cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.fillPath()
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeLineSegments(between: [CGPoint(x: r.minX + 3, y: r.maxY - 3), CGPoint(x: r.maxX - 3, y: r.minY + 3),
                                             CGPoint(x: r.maxX - 3, y: r.minY + 3), CGPoint(x: r.maxX - 7, y: r.minY + 3),
                                             CGPoint(x: r.maxX - 3, y: r.minY + 3), CGPoint(x: r.maxX - 3, y: r.minY + 7)])
        }
        ctx.restoreGState()
    }
}
