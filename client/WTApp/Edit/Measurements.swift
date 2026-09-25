import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// Size matches while a transform handle resizes the selection (moving.adoc, "Smart guides", *Size
/// match*; OBJ-039): the gesture's `SmartGuideEngine` answers the width and height being made; a
/// match within the *Snap distance* snaps the scale so the size lands on it exactly, and a badge
/// beside the pointer shows the matched size in the document's unit.  Nothing here writes to the
/// document; the handle drag's one transformation carries the snapped size.
@MainActor
final class SizeGuideLink {
    static let shared = SizeGuideLink()

    struct Session {
        var engine: SmartGuideEngine
        var match: SmartGuideSizeMatch
        /// The pointer (pasteboard) the badge sits beside.
        var pointer: Point
    }

    /// Builds a document's engine for a gesture starting at a point (the smart guides' engine).
    var engine: @MainActor (String, Point) -> SmartGuideEngine? = { SmartGuideLink.shared.engine($0, start: $1) }
    private(set) var sessions: [String: Session] = [:]

    init() {}

    /// The selection is being resized to `size` from a drag that started at `start`: the match
    /// within `tolerance` (pasteboard units).  Starts the gesture's engine on the first call.
    @discardableResult
    /// `outset` is what painting adds to the geometric `size` (the engine knows painted sizes);
    /// the match is given back geometric.
    func resizing(_ document: String, size: Size, outset: Size = Size(width: 0, height: 0), pointer: Point, start: Point, tolerance: Double) -> SmartGuideSizeMatch? {
        guard var session = sessions[document] ?? engine(document, start).map({ Session(engine: $0, match: SmartGuideSizeMatch(), pointer: pointer) }) else { return nil }
        var match = session.engine.sizeGuides(width: size.width + outset.width, height: size.height + outset.height, tolerance: tolerance)
        match.width = match.width.map { $0 - outset.width }
        match.height = match.height.map { $0 - outset.height }
        session.match = match
        session.pointer = pointer
        sessions[document] = session
        return session.match
    }

    func end(_ document: String) {
        sessions[document] = nil
    }

    /// The badge's text: the matched width and height in `units` ("W 50 pt", "H 30 pt").
    static func badge(_ match: SmartGuideSizeMatch, units: Units) -> String? {
        let parts = [match.width.map { "W \(units.format($0, suffix: true))" }, match.height.map { "H \(units.format($0, suffix: true))" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    /// Draws the badge of the resize in progress beside the pointer (view space).
    func draw(_ document: String, units: Units, in ctx: CGContext, viewport: Viewport, color: CGColor) {
        guard let session = sessions[document], let text = Self.badge(session.match, units: units) else { return }
        let at = viewport.toView(session.pointer)
        MeasurementLink.label(text, at: CGPoint(x: at.x + 12, y: at.y + 12), color: color, in: ctx)
    }

    /// The scale of a corner or edge handle drag with the size snapped to `match`: each matched
    /// dimension's factor makes that dimension exactly (its sign kept); others are unchanged.
    static func snapped(_ matrix: WTGeometry.AffineTransform, anchor: HandleAnchor, bounds: Rect, match: SmartGuideSizeMatch) -> WTGeometry.AffineTransform {
        var sx = matrix.a, sy = matrix.d
        if let width = match.width, anchor.unit.x != 0.5, bounds.width > 1e-9 { sx = width / bounds.width * (sx < 0 ? -1 : 1) }
        if let height = match.height, anchor.unit.y != 0.5, bounds.height > 1e-9 { sy = height / bounds.height * (sy < 0 ? -1 : 1) }
        return .scale(x: sx, y: sy)
    }
}

extension PointerTool {
    /// The handle drag's matrix with size matching: a scale zone without kbd:[Shift] (a
    /// proportional drag keeps its proportions) snaps to a matched width or height while smart
    /// guides are on and snapping is not suspended; any other zone passes through.
    static func trackSizeGuides(_ context: ToolContext, zone: TransformHandles.Zone, handles: TransformHandles, matrix: WTGeometry.AffineTransform?,
                                start: Point, end: CanvasEvent) -> WTGeometry.AffineTransform? {
        let document = context.document.id
        guard case .scale(let anchor) = zone, let matrix, !end.modifiers.contains(.shift),
              context.snapping.smartGuidesEnabled(), !context.snapping.suspended() else {
            SizeGuideLink.shared.end(document)
            return matrix
        }
        // The engine knows painted sizes (strokes included): the selection's is its geometric size
        // scaled plus the outset its painting adds, and a match is made geometric again.
        let outset = paintedOutset(context, bounds: handles.bounds)
        let size = Size(width: handles.bounds.width * abs(matrix.a), height: handles.bounds.height * abs(matrix.d))
        let tolerance = context.snapping.snapDistance() / max(context.viewport.zoom, 1e-9)
        guard let match = SizeGuideLink.shared.resizing(document, size: size, outset: outset, pointer: end.pasteboardPoint, start: start,
                                                        tolerance: tolerance) else { return matrix }
        return SizeGuideLink.snapped(matrix, anchor: anchor, bounds: handles.bounds, match: match)
    }

    /// How much wider and taller the selected objects paint than their geometric `bounds` (their
    /// strokes); zero for a point selection.
    static func paintedOutset(_ context: ToolContext, bounds: Rect) -> Size {
        let selection = context.selection.selection
        let list = context.document.displayList
        let painted = selection.ids.compactMap { id -> Rect? in
            if case .points? = selection.subSelection(of: id) { return nil }
            return list.index(of: id.node).flatMap { list.itemBounds[$0] }
        }
        guard let first = painted.first else { return Size(width: 0, height: 0) }
        let union = painted.dropFirst().reduce(first) { $0.union($1) }
        return Size(width: max(union.width - bounds.width, 0), height: max(union.height - bounds.height, 0))
    }

    /// The Pointer's extra overlay: the size badge of a resize and the kbd:[Option] measurements.
    static func drawMeasurements(_ context: ToolContext, in ctx: CGContext, viewport: Viewport) {
        let color = SmartGuideLink.shared.color()
        let units = context.document.unitConverter
        SizeGuideLink.shared.draw(context.document.id, units: units, in: ctx, viewport: viewport, color: color)
        MeasurementLink.shared.draw(context.document.id, units: units, in: ctx, viewport: viewport, color: color)
    }

    /// Ends the gesture's size matching and clears the measurements (a press, the end of a drag).
    static func endMeasurements(_ context: ToolContext) {
        SizeGuideLink.shared.end(context.document.id)
        MeasurementLink.shared.clear(context.document.id)
    }
}

/// The kbd:[Option]-hover measurements (moving.adoc, "Measuring distances"; OBJ-039): with
/// kbd:[Option] down and no button pressed, dimension lines from the selection's bounds to the
/// hovered object on each side that faces it, or to the four edges of the page under the pointer
/// when no object is hovered, labelled in the document's unit.  kbd:[Option] up or a press clears
/// them; nothing is written.
@MainActor
final class MeasurementLink {
    static let shared = MeasurementLink()

    /// One dimension line, pasteboard space, and its length.
    struct Line: Equatable {
        var from: Point
        var to: Point
        var length: Double { from.distance(to: to) }
    }

    /// *Show measurements while holding Option*.
    var enabled: @MainActor () -> Bool = { true }
    private(set) var lines: [String: [Line]] = [:]
    /// The last hover event per document.
    private(set) var pointers: [String: CanvasEvent] = [:]

    init() {}

    /// The dimension lines between `selection` and `target` on each side that faces it; where
    /// the two overlap on an axis the lines join their matching edges instead.
    static func lines(from selection: Rect, to target: Rect) -> [Line] {
        var result: [Line] = []
        let y = overlapMiddle(selection.minY...selection.maxY, target.minY...target.maxY) ?? selection.midY
        let x = overlapMiddle(selection.minX...selection.maxX, target.minX...target.maxX) ?? selection.midX
        if target.minX >= selection.maxX {
            result.append(Line(from: Point(x: selection.maxX, y: y), to: Point(x: target.minX, y: y)))
        } else if target.maxX <= selection.minX {
            result.append(Line(from: Point(x: target.maxX, y: y), to: Point(x: selection.minX, y: y)))
        } else {
            result += [Line(from: Point(x: selection.minX, y: y), to: Point(x: target.minX, y: y)),
                       Line(from: Point(x: selection.maxX, y: y), to: Point(x: target.maxX, y: y))]
        }
        if target.minY >= selection.maxY {
            result.append(Line(from: Point(x: x, y: selection.maxY), to: Point(x: x, y: target.minY)))
        } else if target.maxY <= selection.minY {
            result.append(Line(from: Point(x: x, y: target.maxY), to: Point(x: x, y: selection.minY)))
        } else {
            result += [Line(from: Point(x: x, y: selection.minY), to: Point(x: x, y: target.minY)),
                       Line(from: Point(x: x, y: selection.maxY), to: Point(x: x, y: target.maxY))]
        }
        return result.filter { $0.length > 1e-9 }
    }

    /// The four distances from `selection` to the edges of `page`.
    static func lines(from selection: Rect, toEdgesOf page: Rect) -> [Line] {
        [
            Line(from: Point(x: page.minX, y: selection.midY), to: Point(x: selection.minX, y: selection.midY)),
            Line(from: Point(x: selection.maxX, y: selection.midY), to: Point(x: page.maxX, y: selection.midY)),
            Line(from: Point(x: selection.midX, y: page.minY), to: Point(x: selection.midX, y: selection.minY)),
            Line(from: Point(x: selection.midX, y: selection.maxY), to: Point(x: selection.midX, y: page.maxY)),
        ]
    }

    static func overlapMiddle(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Double? {
        let low = max(a.lowerBound, b.lowerBound), high = min(a.upperBound, b.upperBound)
        return low <= high ? (low + high) / 2 : nil
    }

    /// The pointer moved or a modifier changed with no button down: the measurements for `e`,
    /// or none without kbd:[Option] (or with the preference off, or nothing selected).
    func hover(_ e: CanvasEvent, context: ToolContext) {
        let document = context.document.id
        pointers[document] = e
        let previous = lines[document] ?? []
        lines[document] = measure(e, context: context)
        if (lines[document] ?? []) != previous { context.host.setNeedsOverlayDisplay() }
    }

    /// A modifier changed with no button down: the measurements at the last hover point with the
    /// new modifiers (the modifier event carries no location).
    func modifiersChanged(_ modifiers: KeyModifiers, context: ToolContext) {
        guard let last = pointers[context.document.id] else { return }
        hover(last.with(modifiers: modifiers, timestamp: last.timestamp), context: context)
    }

    func measure(_ e: CanvasEvent, context: ToolContext) -> [Line] {
        guard e.modifiers.contains(.option), enabled(),
              let selection = TransformHandles.bounds(of: context.selection.selection, document: context.document) else { return [] }
        if let hit = context.selection.pick(at: e.viewPoint, viewport: context.viewport, subselect: false), !context.selection.selection.contains(hit.id),
           let target = Objects.bounds(of: hit.id.opID, in: context.document.state) {
            return Self.lines(from: selection, to: target)
        }
        guard let page = context.document.pageList.pages.first(where: { $0.rect.contains(e.pasteboardPoint) }) else { return [] }
        return Self.lines(from: selection, toEdgesOf: page.rect)
    }

    func clear(_ document: String) {
        lines[document] = nil
    }

    /// Dimension lines with end ticks and their lengths (view space).
    func draw(_ document: String, units: Units, in ctx: CGContext, viewport: Viewport, color: CGColor) {
        guard let lines = lines[document], !lines.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [])
        for line in lines {
            let a = viewport.toView(line.from), b = viewport.toView(line.to)
            ctx.move(to: CGPoint(x: a.x, y: a.y))
            ctx.addLine(to: CGPoint(x: b.x, y: b.y))
            let dx = b.x - a.x, dy = b.y - a.y, length = max(hypot(dx, dy), 1e-9)
            let nx = -dy / length * 4, ny = dx / length * 4
            for end in [a, b] {
                ctx.move(to: CGPoint(x: end.x - nx, y: end.y - ny))
                ctx.addLine(to: CGPoint(x: end.x + nx, y: end.y + ny))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
        for line in lines {
            let a = viewport.toView(line.from), b = viewport.toView(line.to)
            Self.label(units.format(line.length, suffix: true), at: CGPoint(x: (a.x + b.x) / 2 + 4, y: (a.y + b.y) / 2 + 4), color: color, in: ctx)
        }
    }

    /// A small filled capsule with white text at `origin` (view space).
    static func label(_ text: String, at origin: CGPoint, color: CGColor, in ctx: CGContext) {
        WindowImages.label(in: ctx, text, at: origin, fill: color)
    }
}
