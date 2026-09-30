import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The settings the pen reads at each stroke (its sheet, freeform.adoc).
struct VariableStrokeSettings: Equatable, Sendable {
    var precision = PrecisionSetting(5)
    var dotted = false
    var removeOverlap = false
    var min = 2.0
    var max = 12.0
    var pressureCurve = 1.0

    init() {}

    @MainActor init(preferences: PreferenceStore) {
        typealias P = PathToolPreferences
        precision = PrecisionSetting(preferences[P.strokePrecision])
        dotted = preferences[P.strokeDotted]
        removeOverlap = preferences[P.strokeRemoveOverlap]
        min = preferences[P.strokeMin]
        max = preferences[P.strokeMax]
        pressureCurve = preferences[P.pressureCurve]
    }
}

/// The Variable Stroke Pen (freeform.adoc; DRAW-018, with DRAW-020's pen input): drag to draw a
/// closed, filled outline whose width follows pen pressure between *Min* and *Max*, or with a
/// mouse the width kbd:[{startsb}] and kbd:[{endsb}] set; kbd:[Option] draws a straight span.  The
/// stroke is one change "Variable Stroke"; with *Auto remove overlap* the self-overlap is removed
/// off the main thread afterwards and written in the same undo group.
@MainActor
final class VariableStrokePen: Tool, PointerTracking {
    static let id: ToolID = "variableStrokePen"
    static let statusMessage = "Drag to draw a variable stroke; [ and ] narrow and widen it; Option draws a straight segment"

    let settings: @MainActor () -> VariableStrokeSettings
    private var context: ToolContext?
    private(set) var capture: StrokeCapture?
    private(set) var samples: [VariableStrokeOutline.Sample] = []
    private(set) var width: StrokeWidthControl
    /// The overlap cleanup in flight (tests wait for it).
    private(set) var cleanup: Task<Void, Never>?

    init(settings: @escaping @MainActor () -> VariableStrokeSettings = { VariableStrokeSettings() }) {
        self.settings = settings
        let current = settings()
        width = StrokeWidthControl(min: current.min, max: current.max, curve: current.pressureCurve)
    }

    var cursor: NSCursor { .crosshair }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.statusMessage)
    }

    func deactivate() {
        cancel()
        context = nil
    }

    func pointerMoved(_ e: CanvasEvent) {}

    /// Re-reads *Min*, *Max* and the curve, keeping the key width inside them.
    private func refreshWidth() {
        let current = settings()
        width = StrokeWidthControl(min: current.min, max: current.max, curve: current.pressureCurve, keyWidth: width.keyWidth)
    }

    func mouseDown(_ e: CanvasEvent) {
        refreshWidth()
        capture = StrokeCapture(start: e.pasteboardPoint, straight: e.modifiers.contains(.option))
        samples = [VariableStrokeOutline.Sample(point: e.pasteboardPoint, width: width.width(for: e))]
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard capture != nil, let context else { return }
        let straight = e.modifiers.contains(.option)
        let constraint = e.modifiers.contains(.shift) ? context.drawing().constraint : nil
        capture?.add(e.pasteboardPoint, straight: straight, constraint: constraint)
        let sample = VariableStrokeOutline.Sample(point: capture?.last ?? e.pasteboardPoint, width: width.width(for: e))
        if straight, samples.count > 1, capture?.straightStart != nil { samples[samples.count - 1] = sample } else { samples.append(sample) }
        context.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { cancel() }
        guard let context, let command = command() else { return }
        let document = context.document
        let current = settings()
        if current.removeOverlap { document.beginGroup() }
        let task = context.commandSink.perform(command)
        let selection = context.selection
        let sink = context.commandSink
        cleanup = Task { @MainActor in
            let created = await task.value?.createdObjects.first
            if let created { selection.model.set(Selection([SelectionID(created)])) }
            if current.removeOverlap {
                if let created { _ = await Self.removeOverlap(created, document: document, sink: sink)?.value }
                await document.settle()
                document.endGroup()
            }
        }
    }

    /// The outline of the stroke so far as the pen draws it (pasteboard space).
    func outline() -> Contour? {
        guard let context, let capture else { return nil }
        let centerline = StrokeFit.points(capture.allSpans, precision: settings().precision, zoom: context.viewport.zoom)
        return VariableStrokeOutline.outline(centerline: centerline, samples: samples)
    }

    /// The stroke's change: a closed path with the new-object attributes.
    func command() -> (any WTModel.Command)? {
        guard let context, let outline = outline() else { return nil }
        let points = ContourPoints.points(outline)
        guard points.count >= 3 else { return nil }
        return CreatePath(label: "Variable Stroke", contours: [NewContour(closed: true, points: points)], appearance: context.newObjectAppearance(),
                          layer: context.objectEditing?.activeLayer)
    }

    /// The overlap cleanup of `node`, computed off the main thread: its contour replaced by the
    /// outline without self-overlap (every point new, so a concurrent point edit is *edit vs
    /// delete*); nil when the node is gone or nothing overlaps.
    static func removeOverlap(_ node: OpID, document: DocumentHandle, sink: any CommandSink) async -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard document.state.isLive(node), let path = document.object(for: SelectionID(node))?.path, let first = path.contours.first else { return nil }
        let local = Contour(segments: ContourPoints.segments(first.drawn, closed: true), closed: true)
        let cleaned = await Task.detached(priority: .userInitiated) { VariableStrokeOutline.removingOverlap(local) }.value
        guard document.state.isLive(node), !cleaned.isEmpty else { return nil }
        let contours = cleaned.map { ContourPoints.points($0) }.filter { $0.count >= 2 }
        guard let head = contours.first else { return nil }
        let command = RewritePath(node: node, edits: [.init(contour: first.id, points: head, closed: true)],
                                  added: contours.dropFirst().map { NewContour(closed: true, points: $0) }, label: "Remove Overlap")
        return sink.perform(command)
    }

    func flagsChanged(_ e: CanvasEvent) {}

    /// kbd:[{startsb}] and kbd:[{endsb}] step the width (ignored while a pen is in contact).
    func keyDown(_ e: NSEvent) -> Bool {
        guard let wider = StrokeWidthControl.bracket(e.charactersIgnoringModifiers) else { return false }
        width.bracket(wider: wider)
        return true
    }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let capture, capture.trail.count >= 2 else { return }
        let path = CGMutablePath()
        SelectionOverlay.add(DisplayPath(polygon: capture.trail, closed: false), transform: viewport.pasteboardToView, to: path)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(max(1, width.keyWidth * viewport.zoom))
        if settings().dotted { ctx.setLineDash(phase: 0, lengths: [1, 3]) }
        ctx.addPath(path)
        ctx.strokePath()
    }

    func cancel() {
        capture = nil
        samples = []
    }

    var hasSomethingToCancel: Bool { capture != nil }
}
