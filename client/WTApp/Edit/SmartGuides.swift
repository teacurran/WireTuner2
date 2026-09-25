import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// Smart guides during a Pointer move (moving.adoc, "Smart guides"; OBJ-039 over OBJ-038's
/// `SmartGuideEngine`): the engine of the gesture, built from the window's display list when the
/// move starts, answers the moving bounds at every drag event; its match goes into the window's
/// `SnapSources.smartGuides` for the snap and is drawn in the *Smart guide color* until the gesture
/// ends.  Nothing here writes to the document.
@MainActor
final class SmartGuideLink {
    static let shared = SmartGuideLink()

    /// One move gesture's state.
    struct Session {
        var engine: SmartGuideEngine
        /// The selection's bounds when the move began.
        var bounds: Rect
        var match: SmartGuideMatch
        /// The gesture's snapping point before snapping.
        var point: Point
    }

    /// Builds a document's engine for a gesture starting at a pasteboard point (the front window's
    /// canvas); registered per document by the window.
    private var engines: [String: @MainActor (Point) -> SmartGuideEngine?] = [:]
    private(set) var sessions: [String: Session] = [:]
    /// The guide colour (*Smart guide color*).
    var color: @MainActor () -> CGColor = { NSColor.systemPink.cgColor }

    init() {}

    func register(_ document: String, engine: @escaping @MainActor (Point) -> SmartGuideEngine?) {
        engines[document] = engine
    }

    /// A gesture engine for `document` starting at `start` (the size badges build theirs here).
    func engine(_ document: String, start: Point) -> SmartGuideEngine? {
        engines[document]?(start)
    }

    func unregister(_ document: String) {
        engines[document] = nil
        sessions[document] = nil
    }

    /// The selection with bounds `bounds` is being dragged by `delta` from `point`: the match for
    /// the moved bounds within `tolerance` (pasteboard units).  Starts the gesture's engine on the
    /// first call.
    @discardableResult
    func moving(_ document: String, bounds: Rect, delta: Vector, from point: Point, tolerance: Double) -> SmartGuideMatch? {
        var session = sessions[document]
        if session == nil {
            guard let engine = engines[document]?(point) else { return nil }
            session = Session(engine: engine, bounds: bounds, match: SmartGuideMatch(), point: point)
        }
        guard var current = session else { return nil }
        current.match = current.engine.guides(moving: current.bounds.offset(by: delta), tolerance: tolerance)
        current.point = Point(x: point.x + delta.dx, y: point.y + delta.dy)
        sessions[document] = current
        return current.match
    }

    /// The gesture ended or was abandoned.
    func end(_ document: String) {
        sessions[document] = nil
    }

    /// The snap lines the window's snapping adds for `document` (none outside a move).
    func snapGuides(_ document: String) -> [SnapGuide] {
        guard let session = sessions[document] else { return [] }
        return session.match.snapGuides(for: session.point)
    }

    /// The guides of the move in progress, drawn in view space: edge and centre lines across their
    /// span, spacing gaps as short bars with the gap's length.
    func draw(_ document: String, in ctx: CGContext, viewport: Viewport) {
        guard let session = sessions[document], !session.match.guides.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(color())
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [])
        for guide in session.match.guides {
            for (from, to) in Self.segments(guide) {
                let a = viewport.toView(from), b = viewport.toView(to)
                ctx.move(to: CGPoint(x: a.x, y: a.y))
                ctx.addLine(to: CGPoint(x: b.x, y: b.y))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The line segments (pasteboard) a guide draws.
    static func segments(_ guide: SmartGuide) -> [(Point, Point)] {
        func line(_ along: ClosedRange<Double>, at position: Double) -> (Point, Point) {
            guide.axis == .vertical
                ? (Point(x: position, y: along.lowerBound), Point(x: position, y: along.upperBound))
                : (Point(x: along.lowerBound, y: position), Point(x: along.upperBound, y: position))
        }
        switch guide.kind {
        case .edge, .center:
            return [line(guide.span, at: guide.position)]
        case .spacing:
            // Each equal gap as a bar across the band the row sits in.
            let middle = (guide.span.lowerBound + guide.span.upperBound) / 2
            return guide.gaps.map { gap in
                guide.axis == .vertical
                    ? (Point(x: gap.lowerBound, y: middle), Point(x: gap.upperBound, y: middle))
                    : (Point(x: middle, y: gap.lowerBound), Point(x: middle, y: gap.upperBound))
            }
        case .size:
            return []
        }
    }
}

extension DocumentWindowController {
    /// The smart guides of the move in progress, for `SnapSources.smartGuides`.
    var smartGuideSnaps: [SnapGuide] { SmartGuideLink.shared.snapGuides(documentHandle.id) }

    /// The engine of a gesture on this window starting at `start`: the objects in view, the
    /// selection (what moves) left out, and the pages.
    func smartGuideEngine(start: Point) -> SmartGuideEngine {
        let document = documentHandle
        let list = document.displayList
        let tester = selection.hitTester(viewport: viewport, subselect: false)
        let excluded = Set(selection.model.ids.compactMap { list.index(of: $0.node) })
        return SmartGuideEngine(displayList: list, index: tester.index, viewport: viewport.visiblePasteboardBounds, excludedItems: excluded,
                                pages: document.pageList.pages.map(\.rect), start: start)
    }
}

extension PointerTool {
    /// The Pointer's move feeds the window's smart guides (called from `moveDelta`): the selected
    /// objects' bounds moved by `delta`, within the *Snap distance* at the view's zoom.
    static func trackSmartGuides(_ context: ToolContext, start: Point, delta: Vector) {
        guard context.snapping.smartGuidesEnabled(), !context.snapping.suspended(),
              let bounds = TransformHandles.bounds(of: context.selection.selection, document: context.document) else {
            SmartGuideLink.shared.end(context.document.id)
            return
        }
        let tolerance = context.snapping.snapDistance() / max(context.viewport.zoom, 1e-9)
        SmartGuideLink.shared.moving(context.document.id, bounds: bounds, delta: delta, from: start, tolerance: tolerance)
    }
}
