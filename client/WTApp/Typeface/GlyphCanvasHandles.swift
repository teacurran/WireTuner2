import AppKit
import CoreText
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The handles of a glyph canvas (glyph-editing.adoc, "Side bearings and advance width",
/// "Components", "Anchors"; FONT-011, FONT-012, FONT-013), over the Pointer and Subselect tools:
///
/// * the advance-width line and the left side bearing line, taken within 6 view points when no
///   object is under the pointer: dragging the advance line sets the width (kbd:[Option] moves the
///   artwork with it, keeping the RSB); dragging the LSB line moves the artwork (kbd:[Option] keeps
///   the RSB); kbd:[Shift] steps by 10 units; a readout shows LSB, RSB and width;
/// * anchors, drawn as diamonds with their names, dragged like points (snapped, whole units);
/// * components, taken inside their outline when no object is hit, dragged as one object;
///   double-click opens the source glyph;
/// * with menu:View[Show Mark Attachment], the marks that attach to this glyph (or a base under a
///   mark) drawn faintly in place, following an anchor drag.
///
/// Each drag previews and writes its one change on release (D-076).
@MainActor
final class GlyphCanvasHandles: CanvasHandleLayer {
    /// How near a bearing line (view points) a press takes it.
    static let zone = 6.0
    /// How near an anchor's centre a press takes it.
    static let anchorRadius = 6.0
    static let anchorSize = 7.0
    static let attachmentOpacity = 0.3
    static let markAnchorColor = NSColor.systemPurple
    static let baseAnchorColor = NSColor.systemGreen

    enum Target: Equatable {
        case advance, left
        case anchor(OpID)
        case component(OpID)
    }

    /// A drag in progress: what was pressed and the glyph as it was.
    struct Drag {
        var target: Target
        var start: Point
        var now: Point
        var modifiers: KeyModifiers
        var glyph: Glyph
        var metrics: GlyphMetrics
    }

    /// What the canvas shows of the glyph as of one document change.
    struct Snapshot {
        let count: Int
        let index: GlyphIndex
        let glyph: Glyph
        let frame: GlyphCanvasFrame
        let metrics: GlyphMetrics
        let components: [PlacedComponent]
    }

    let glyph: OpID
    /// Opens a glyph in a tab (a component's source on double-click).
    var openGlyph: @MainActor (OpID) -> Void = { _ in }
    /// Whether menu:View[Show Mark Attachment] is on.
    var showsMarkAttachment: @MainActor () -> Bool = { false }
    private(set) var drag: Drag?
    /// The anchor or component last pressed (the Object panel's Anchor or Component section edits it); a press
    /// anywhere else clears it.
    var picked: Target? {
        didSet { if picked != oldValue { onPick() } }
    }
    /// Called when `picked` changes.
    var onPick: @MainActor () -> Void = {}
    private var edit: GestureEdit?
    private var cache: Snapshot?
    /// Flattened outlines for the mark attachment preview, as of `outlineCount`.
    private var outlines: [OpID: FilledPath] = [:]
    private var outlineCount = -1

    init(glyph: OpID) {
        self.glyph = glyph
    }

    var tools: Set<ToolID>? { CanvasHandleLayers.tools }

    // MARK: Reading

    /// The glyph as the document holds it now; nil once it is gone.
    func snapshot(_ document: DocumentHandle) -> Snapshot? {
        if let cache, cache.count == document.changeCount { return cache }
        let state = document.state
        let index = GlyphIndex(state)
        guard let read = index[glyph], let frame = GlyphCanvas.frame(for: glyph, in: state) else { return nil }
        let metrics = GlyphMetrics(advanceWidth: read.advanceWidth, bounds: GlyphOutlines.reachableOutline(of: glyph, in: state, index: index).bounds)
        let snapshot = Snapshot(count: document.changeCount, index: index, glyph: read, frame: frame, metrics: metrics,
                                components: GlyphOutlines.placedComponents(of: glyph, in: state, index: index))
        cache = snapshot
        return snapshot
    }

    /// The x of the vertical line at `x` (on the baseline) at canvas height `y`, slanted by the
    /// italic angle.
    static func lineX(_ x: Double, at y: Double, frame: GlyphCanvasFrame) -> Double {
        frame.italicAngle == 0 ? x : x + y * tan(frame.italicAngle * .pi / 180)
    }

    /// The bearing line under `e`, if any: the advance line first (it is the one usually dragged).
    static func bearingLine(at e: CanvasEvent, snapshot: Snapshot, viewport: Viewport) -> Target? {
        guard snapshot.frame.showSideBearings else { return nil }
        let y = e.pasteboardPoint.y
        func near(_ x: Double) -> Bool {
            viewport.toView(Point(x: lineX(x, at: y, frame: snapshot.frame), y: y)).distance(to: e.viewPoint) <= zone
        }
        if near(snapshot.glyph.advanceWidth) { return .advance }
        if snapshot.metrics.bounds != nil, near(0) { return .left }
        return nil
    }

    /// The component under `point` (glyph space): inside its outline, or its box when it has none;
    /// the topmost (last) first.
    static func component(at point: Point, in snapshot: Snapshot) -> PlacedComponent? {
        snapshot.components.last { $0.outline.isEmpty ? $0.bounds.contains(point) : $0.outline.contains(point) }
    }

    // MARK: Commands

    /// `delta` in whole units, or tens with kbd:[Shift].
    static func stepped(_ delta: Double, _ modifiers: KeyModifiers) -> Double {
        modifiers.contains(.shift) ? (delta / 10).rounded() * 10 : delta.rounded()
    }

    /// The horizontal move of a bearing drag so far.
    static func delta(_ drag: Drag) -> Double { stepped(drag.now.x - drag.start.x, drag.modifiers) }

    /// The command a drag writes so far; nil for a drag that changes nothing yet.
    func command(for drag: Drag, snapping: (Point) -> Point = { $0 }) -> (any WTModel.Command)? {
        let keepRSB = drag.modifiers.contains(.option)
        switch drag.target {
        case .advance:
            let delta = Self.delta(drag)
            guard delta != 0 else { return nil }
            if keepRSB, drag.metrics.bounds != nil {
                return SetGlyphBearings([glyph], .left(drag.metrics.leftSideBearing + delta, keepRSB: true))
            }
            return SetGlyphWidth([glyph], to: max(0, drag.glyph.advanceWidth + delta))
        case .left:
            // The line follows the pointer over the artwork: the artwork moves the other way.
            let delta = -Self.delta(drag)
            guard delta != 0 else { return nil }
            return SetGlyphBearings([glyph], .left(drag.metrics.leftSideBearing + delta, keepRSB: keepRSB))
        case .anchor(let id):
            guard let anchor = drag.glyph.anchors.first(where: { $0.id == id }) else { return nil }
            let position = Self.anchorPosition(drag, anchor: anchor, snapping: snapping)
            return position == anchor.position ? nil : EditAnchor(id, of: glyph, .move(position))
        case .component(let id):
            guard let component = drag.glyph.components.first(where: { $0.id == id }) else { return nil }
            var dx = (drag.now.x - drag.start.x).rounded(), dy = (drag.now.y - drag.start.y).rounded()
            // kbd:[Shift] keeps the move horizontal or vertical.
            if drag.modifiers.contains(.shift) {
                if abs(dx) >= abs(dy) { dy = 0 } else { dx = 0 }
            }
            guard dx != 0 || dy != 0 else { return nil }
            return SetComponentTransform(id, of: glyph, to: component.transform.concatenating(.translation(x: dx, y: dy)))
        }
    }

    /// Where a dragged anchor goes: its start position moved by the drag, snapped, whole units.
    static func anchorPosition(_ drag: Drag, anchor: GlyphAnchorValue, snapping: (Point) -> Point) -> Point {
        let moved = snapping(anchor.position + (drag.now - drag.start))
        return Point(x: moved.x.rounded(), y: moved.y.rounded())
    }

    /// The readout of a bearing drag: "LSB 40  RSB 60  Width 600" (font units).
    static func readout(_ drag: Drag) -> String? {
        let delta = delta(drag)
        let keepRSB = drag.modifiers.contains(.option)
        var lsb = drag.metrics.leftSideBearing, rsb = drag.metrics.rightSideBearing, width = drag.glyph.advanceWidth
        switch drag.target {
        case .advance:
            if keepRSB, drag.metrics.bounds != nil {
                lsb += delta
            } else {
                rsb += max(-width, delta)
            }
            width = max(0, width + delta)
        case .left:
            lsb -= delta
            if keepRSB { width -= delta } else { rsb += delta }
        case .anchor, .component:
            return nil
        }
        return "LSB \(FontUnits.format(lsb))  RSB \(FontUnits.format(rsb))  Width \(FontUnits.format(width))"
    }

    // MARK: CanvasHandleLayer

    func press(_ e: CanvasEvent, context: ToolContext) -> Bool {
        guard let snapshot = snapshot(context.document) else { return false }
        let viewport = context.viewport
        var target: Target?
        if let anchor = snapshot.glyph.anchors.last(where: { viewport.toView($0.position).distance(to: e.viewPoint) <= Self.anchorRadius }) {
            target = .anchor(anchor.id)
        } else if context.selection.pick(at: e.viewPoint, viewport: viewport, subselect: false) != nil {
            // Objects are drawn over the lines and components: they win.
            picked = nil
            return false
        } else if let line = Self.bearingLine(at: e, snapshot: snapshot, viewport: viewport) {
            target = line
        } else if let component = Self.component(at: e.pasteboardPoint, in: snapshot) {
            if e.clickCount >= 2 {
                if component.status == .resolved, let source = component.source { openGlyph(source) }
                return true
            }
            target = .component(component.id)
        }
        switch target {
        case .anchor?, .component?: picked = target
        default: picked = nil
        }
        guard let target else { return false }
        drag = Drag(target: target, start: e.pasteboardPoint, now: e.pasteboardPoint, modifiers: e.modifiers, glyph: snapshot.glyph, metrics: snapshot.metrics)
        edit = GestureEdit(document: context.document)
        return true
    }

    func drag(_ e: CanvasEvent, context: ToolContext) {
        guard var drag else { return }
        drag.now = e.pasteboardPoint
        drag.modifiers = e.modifiers
        self.drag = drag
        let viewport = context.viewport
        edit?.update(command(for: drag) { context.snapping.snap($0, viewport: viewport) })
    }

    func release(_ e: CanvasEvent, context: ToolContext) {
        drag(e, context: context)
        edit?.commit()
        drag = nil
        edit = nil
    }

    func cancel(context: ToolContext) {
        edit?.cancel()
        drag = nil
        edit = nil
    }

    // MARK: Drawing

    func draw(in ctx: CGContext, viewport: Viewport, context: ToolContext) {
        guard let snapshot = snapshot(context.document) else { return }
        let toView = viewport.pasteboardToView.cgAffineTransform
        var anchors = snapshot.glyph.anchors
        if let drag, case .anchor(let id) = drag.target, let at = anchors.firstIndex(where: { $0.id == id }) {
            anchors[at].position = Self.anchorPosition(drag, anchor: anchors[at]) { context.snapping.snap($0, viewport: viewport) }
        }
        if showsMarkAttachment() { drawAttachments(snapshot, anchors: anchors, state: context.document.state, count: context.document.changeCount, in: ctx, toView: toView) }
        ctx.saveGState()
        for anchor in anchors {
            Self.drawAnchor(anchor, at: viewport.toView(anchor.position), in: ctx)
            if picked == .anchor(anchor.id) { Self.drawPickedRing(at: viewport.toView(anchor.position), in: ctx) }
        }
        ctx.restoreGState()
        guard let drag else {
            if case .component(let id)? = picked, let component = snapshot.components.first(where: { $0.id == id }) {
                let outline = component.outline.isEmpty ? DisplayPath(rect: component.bounds) : DisplayPath(contours: component.outline.contours)
                ctx.saveGState()
                ctx.addPath(MetricsModel.cgPath(outline, transform: toView))
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokePath()
                ctx.restoreGState()
            }
            return
        }
        switch drag.target {
        case .advance, .left:
            let delta = Self.delta(drag)
            let x = drag.target == .advance ? drag.glyph.advanceWidth + delta : delta
            let frame = snapshot.frame
            let top = Point(x: Self.lineX(x, at: -frame.ascender, frame: frame), y: -frame.ascender)
            let bottom = Point(x: Self.lineX(x, at: -frame.descender, frame: frame), y: -frame.descender)
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemOrange.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeLineSegments(between: [viewport.toView(top).cgPoint, viewport.toView(bottom).cgPoint])
            ctx.restoreGState()
            if let text = Self.readout(drag) { Self.drawLabel(text, at: viewport.toView(drag.now) + Vector(dx: 12, dy: 16), in: ctx) }
        case .component(let id):
            guard let component = snapshot.components.first(where: { $0.id == id }),
                  let command = command(for: drag) as? SetComponentTransform else { return }
            // The drag only adds a translation, so the placed outline moves by it.
            let dx = command.transform.tx - component.transform.tx, dy = command.transform.ty - component.transform.ty
            let outline = component.outline.isEmpty
                ? DisplayPath(rect: component.bounds) : DisplayPath(contours: component.outline.contours)
            ctx.saveGState()
            ctx.addPath(MetricsModel.cgPath(outline, transform: CGAffineTransform(translationX: dx, y: dy).concatenating(toView)))
            ctx.setStrokeColor(NSColor.systemTeal.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            ctx.restoreGState()
        case .anchor:
            break
        }
    }

    /// An anchor: a diamond (green for a base anchor, purple for a mark anchor) and its name.
    static func drawAnchor(_ anchor: GlyphAnchorValue, at point: Point, in ctx: CGContext) {
        let half = anchorSize / 2 + 1
        let diamond = CGMutablePath()
        diamond.move(to: CGPoint(x: point.x, y: point.y - half))
        diamond.addLine(to: CGPoint(x: point.x + half, y: point.y))
        diamond.addLine(to: CGPoint(x: point.x, y: point.y + half))
        diamond.addLine(to: CGPoint(x: point.x - half, y: point.y))
        diamond.closeSubpath()
        let color = anchor.role == .mark ? markAnchorColor : baseAnchorColor
        ctx.addPath(diamond)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.addPath(diamond)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        drawText(anchor.isDuplicate ? "\(anchor.name) (duplicate)" : anchor.name, at: point + Vector(dx: half + 3, dy: 4), color: color, in: ctx)
    }

    /// The ring around the picked anchor.
    static func drawPickedRing(at point: Point, in ctx: CGContext) {
        let radius = anchorSize
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }

    static func drawText(_ text: String, at origin: Point, color: NSColor, in ctx: CGContext) {
        let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: color])
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = origin.cgPoint
        CTLineDraw(CTLineCreateWithAttributedString(string), ctx)
        ctx.restoreGState()
    }

    /// The drag readout: text on a small dark tag.
    static func drawLabel(_ text: String, at origin: Point, in ctx: CGContext) {
        let string = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)])
        let size = string.size()
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.fill(CGRect(x: origin.x - 4, y: origin.y - size.height, width: size.width + 8, height: size.height + 4))
        ctx.restoreGState()
        drawText(text, at: origin, color: .white, in: ctx)
    }

    /// The mark attachment preview at 30% opacity (flattened outlines, cached per change).
    private func drawAttachments(_ snapshot: Snapshot, anchors: [GlyphAnchorValue], state: EngineState, count: Int, in ctx: CGContext,
                                 toView: CGAffineTransform) {
        let placements = MarkAttachment.placements(on: glyph, anchors: anchors, in: snapshot.index)
        guard !placements.isEmpty else { return }
        if outlineCount != count {
            outlines = [:]
            outlineCount = count
        }
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(Self.attachmentOpacity).cgColor)
        for placement in placements {
            let outline = outlines[placement.glyph] ?? GlyphOutlines.reachableOutline(of: placement.glyph, in: state, index: snapshot.index).path
            outlines[placement.glyph] = outline
            guard !outline.isEmpty else { continue }
            let placed = CGAffineTransform(translationX: placement.offset.dx, y: placement.offset.dy).concatenating(toView)
            ctx.addPath(MetricsModel.cgPath(DisplayPath(contours: outline.contours), transform: placed))
        }
        ctx.fillPath()
        ctx.restoreGState()
    }
}
