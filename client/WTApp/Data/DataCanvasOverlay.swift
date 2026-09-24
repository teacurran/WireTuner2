import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The canvas marks of data merge (data-merge.adoc, "Text placeholders", "Binding an object";
/// DATA-016's WTApp half): a light tint over each placeholder (the *Highlight data fields*
/// preference), red over a placeholder whose field is missing, and a data badge at the corner of
/// each bound object -- red when its field is missing.  Drawn with the canvas furniture, over the
/// tiles and never into output.  What to mark is read once per document change; each draw only
/// maps it through the viewport.
@MainActor
final class DataCanvasOverlay {
    /// A placeholder span to tint, in its text node's container space.
    struct Span: Equatable {
        let node: OpID
        let range: Range<Int>
        let missing: Bool
    }

    /// A bound object's badge.
    struct Badge: Equatable {
        let node: OpID
        let missing: Bool
    }

    static let badgeRadius = 5.0
    static let tint = NSColor.systemTeal.withAlphaComponent(0.18)
    static let missingTint = NSColor.systemRed.withAlphaComponent(0.35)
    static let badgeColor = NSColor.systemTeal
    static let missingBadgeColor = NSColor.systemRed

    let document: DocumentHandle
    /// Whether placeholders are tinted (*Highlight data fields*); red ones always show.
    var highlights: @MainActor () -> Bool = { true }
    /// Whether the canvas shows a record (the tint then sits over values, so none is drawn).
    var previewing: @MainActor () -> Bool = { false }
    private(set) var spans: [Span] = []
    private(set) var badges: [Badge] = []
    private var readAt = -1

    init(document: DocumentHandle) {
        self.document = document
    }

    /// Re-reads the placeholders and bindings when the document changed since the last read.
    func refresh() {
        guard readAt != document.changeCount else { return }
        readAt = document.changeCount
        let state = document.state
        let model = DataModel(state)
        var spans: [Span] = []
        var badges: [Badge] = []
        for node in DataPreviewScene.dependentNodes(in: state).sorted() {
            if let binding = model.binding(of: node, in: state) { badges.append(Badge(node: node, missing: binding.isMissing)) }
            guard let text = TextNode(node, in: state) else { continue }
            spans += model.placeholders(in: text).map { Span(node: node, range: $0.range, missing: $0.resolved == nil) }
        }
        self.spans = spans
        self.badges = badges
    }

    /// Draws the marks for `viewport` (view space, y down as the furniture draws).
    func draw(in ctx: CGContext, viewport: Viewport) {
        refresh()
        let state = document.state
        let tints = highlights()
        if !previewing() {
            for span in spans where span.missing || tints {
                guard let layout = document.textLayout(for: span.node) else { continue }
                let transform = Objects.pasteboardTransform(of: span.node, in: state)
                ctx.setFillColor((span.missing ? Self.missingTint : Self.tint).cgColor)
                for quad in layout.selection(from: span.range.lowerBound, to: span.range.upperBound) {
                    let points = quad.corners.map { viewport.toView(transform.apply($0)) }.map { CGPoint(x: $0.x, y: $0.y) }
                    ctx.move(to: points[0])
                    for point in points.dropFirst() { ctx.addLine(to: point) }
                    ctx.closePath()
                }
                ctx.fillPath()
            }
        }
        for badge in badges {
            guard let bounds = document.object(for: SelectionID(badge.node))?.bounds else { continue }
            let corner = viewport.toView(Point(x: bounds.maxX, y: bounds.minY))
            let radius = Self.badgeRadius
            let rect = CGRect(x: corner.x - radius, y: corner.y - radius, width: radius * 2, height: radius * 2)
            ctx.setFillColor((badge.missing ? Self.missingBadgeColor : Self.badgeColor).cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: rect.insetBy(dx: 2, dy: 2))
        }
    }
}
