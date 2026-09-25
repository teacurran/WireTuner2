import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Calligraphic Pen's outline (freeform.adoc, "Calligraphic Pen"; DRAW-019): each sample's
/// width is `base · |sin(θ_stroke − θ_nib)|`, at least half a point, where `base` is the fixed
/// width or the pressure- or bracket-set width; the fitted centreline is offset by half of it on
/// each side and the ends are cut flat.
enum CalligraphicOutline {
    /// The narrowest a stroke gets, points.
    static let minimumWidth = 0.5

    /// The width of a stroke moving along `direction` with a nib at `nibAngle` (degrees) and full
    /// width `base`.
    static func width(base: Double, direction: Vector, nibAngle: Double) -> Double {
        guard direction.lengthSquared > 0 else { return max(base, minimumWidth) }
        // Pasteboard y runs down; the nib angle is measured counter-clockwise on the page.
        let stroke = atan2(-direction.dy, direction.dx)
        let nib = nibAngle * .pi / 180
        return max(base * abs(sin(stroke - nib)), minimumWidth)
    }

    /// The samples with their widths from each one's direction of travel.
    static func samples(_ points: [Point], bases: [Double], nibAngle: Double) -> [VariableStrokeOutline.Sample] {
        points.indices.map { index in
            let from = points[max(index - 1, 0)], to = points[min(index + 1, points.count - 1)]
            return VariableStrokeOutline.Sample(point: points[index], width: width(base: bases[min(index, bases.count - 1)], direction: to - from, nibAngle: nibAngle))
        }
    }

    /// The outline of `centerline` with the widths of `samples`, flat at both ends; nil for a
    /// stroke too short to draw.
    static func outline(centerline: [VectorPoint], samples: [VariableStrokeOutline.Sample]) -> Contour? {
        let segments = ContourPoints.segments(centerline, closed: false)
        guard !segments.isEmpty else { return nil }
        let lengths = segments.map { $0.length(tolerance: 1e-4) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return nil }
        var left: [Point] = [], right: [Point] = []
        var travelled = 0.0
        var last = Vector(dx: 1, dy: 0)
        for (segment, length) in zip(segments, lengths) where length > 0 {
            let steps = max(8, Int((length / 1.5).rounded(.up)))
            for step in 0...steps where step > 0 || left.isEmpty {
                let t = Double(step) / Double(steps)
                let direction = VariableStrokeOutline.direction(segment.tangent(t), otherwise: last)
                last = direction
                let arc = travelled + segment.length(from: 0, to: t, tolerance: 1e-4)
                let half = VariableStrokeOutline.width(at: arc / total, samples: samples) / 2
                let point = segment.evaluate(t)
                left.append(point + direction.perpendicular * half)
                right.append(point - direction.perpendicular * half)
            }
            travelled += length
        }
        let ring = left + right.reversed()
        return CurveFitter(maxError: VariableStrokeOutline.tolerance, cornerAngle: 1.2).fitContour(ring + [ring[0]], closed: true)
    }
}

/// The pen's sheet (preferences on this Mac, never in the document).
enum CalligraphicPreferences {
    static let precision = PreferenceKey<Int>("tools.calligraphic.precision", "Precision", category: .object, default: 5,
                                              control: .stepper(range: 1...10, step: 1, unit: ""), help: "freeform")
    static let dotted = PreferenceKey<Bool>("tools.calligraphic.dotted", "Draw dotted line", category: .object, default: false, control: .toggle, help: "freeform")
    static let removeOverlap = PreferenceKey<Bool>("tools.calligraphic.removeOverlap", "Auto remove overlap", category: .object, default: false,
                                                   control: .toggle, help: "freeform")
    static let widthMode = PreferenceKey<String>("tools.calligraphic.widthMode", "Width", category: .object, default: "fixed",
                                                 control: .popup([PreferenceOption(.string("fixed"), "Fixed"), PreferenceOption(.string("variable"), "Variable")]),
                                                 help: "freeform")
    static let fixedWidth = PreferenceKey<Double>("tools.calligraphic.fixed", "Fixed width", category: .object, default: 8,
                                                  control: .stepper(range: 1...72, step: 1, unit: "pt"), help: "freeform")
    static let min = PreferenceKey<Double>("tools.calligraphic.min", "Min", category: .object, default: 2, control: .stepper(range: 1...72, step: 1, unit: "pt"), help: "freeform")
    static let max = PreferenceKey<Double>("tools.calligraphic.max", "Max", category: .object, default: 12, control: .stepper(range: 1...72, step: 1, unit: "pt"), help: "freeform")
    static let angle = PreferenceKey<Double>("tools.calligraphic.angle", "Angle", category: .object, default: 45,
                                             control: .stepper(range: 0...359, step: 1, unit: "°"), help: "freeform")

    static let sheet: [AnyPreferenceKey] = [precision.erased, dotted.erased, removeOverlap.erased, widthMode.erased, fixedWidth.erased, min.erased, max.erased,
                                            angle.erased, PathToolPreferences.pressureCurve.erased]
}

/// The settings the pen reads at each stroke.
struct CalligraphicSettings: Equatable, Sendable {
    var precision = PrecisionSetting(5)
    var dotted = false
    var removeOverlap = false
    /// *Variable*: the width follows pressure or the bracket keys.
    var variable = false
    var fixedWidth = 8.0
    var min = 2.0
    var max = 12.0
    var angle = 45.0
    var pressureCurve = 1.0

    init() {}

    @MainActor init(preferences: PreferenceStore) {
        typealias P = CalligraphicPreferences
        precision = PrecisionSetting(preferences[P.precision])
        dotted = preferences[P.dotted]
        removeOverlap = preferences[P.removeOverlap]
        variable = preferences[P.widthMode] == "variable"
        fixedWidth = preferences[P.fixedWidth]
        min = preferences[P.min]
        max = preferences[P.max]
        angle = preferences[P.angle]
        pressureCurve = preferences[PathToolPreferences.pressureCurve]
    }
}

/// The Calligraphic Pen (freeform.adoc; DRAW-019): drag to draw a closed, filled outline like a
/// flat nib at a fixed angle -- wide across the nib, thin along it.  In *Variable* width the
/// nib's width follows pen pressure between *Min* and *Max*, or kbd:[{startsb}] and kbd:[{endsb}];
/// in *Fixed* width the keys do nothing.  kbd:[Option] draws a straight span.  One change
/// "Calligraphic Stroke" (with *Auto remove overlap*, the cleanup in the same undo group).
@MainActor
final class CalligraphicPen: Tool, PointerTracking {
    static let id: ToolID = "calligraphicPen"
    static let statusMessage = "Drag to draw with a flat nib; [ and ] narrow and widen a variable nib; Option draws a straight segment"

    let settings: @MainActor () -> CalligraphicSettings
    private var context: ToolContext?
    private(set) var capture: StrokeCapture?
    /// Each sample's nib width before the angle (the base).
    private(set) var bases: [Double] = []
    private(set) var points: [Point] = []
    private(set) var width: StrokeWidthControl
    private(set) var cleanup: Task<Void, Never>?

    init(settings: @escaping @MainActor () -> CalligraphicSettings = { CalligraphicSettings() }) {
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

    private func base(for e: CanvasEvent) -> Double {
        let current = settings()
        return current.variable ? width.width(for: e) : current.fixedWidth
    }

    func mouseDown(_ e: CanvasEvent) {
        let current = settings()
        width = StrokeWidthControl(min: current.min, max: current.max, curve: current.pressureCurve, keyWidth: width.keyWidth)
        capture = StrokeCapture(start: e.pasteboardPoint, straight: e.modifiers.contains(.option))
        points = [e.pasteboardPoint]
        bases = [base(for: e)]
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard capture != nil, let context else { return }
        let straight = e.modifiers.contains(.option)
        let constraint = e.modifiers.contains(.shift) ? context.drawing().constraint : nil
        capture?.add(e.pasteboardPoint, straight: straight, constraint: constraint)
        let point = capture?.last ?? e.pasteboardPoint
        if straight, points.count > 1, capture?.straightStart != nil {
            points[points.count - 1] = point
            bases[bases.count - 1] = base(for: e)
        } else {
            points.append(point)
            bases.append(base(for: e))
        }
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
                if let created { _ = await VariableStrokePen.removeOverlap(created, document: document, sink: sink)?.value }
                await document.settle()
                document.endGroup()
            }
        }
    }

    /// The outline of the stroke so far (pasteboard space).
    func outline() -> Contour? {
        guard let context, let capture else { return nil }
        let current = settings()
        let centerline = StrokeFit.points(capture.allSpans, precision: current.precision, zoom: context.viewport.zoom)
        return CalligraphicOutline.outline(centerline: centerline, samples: CalligraphicOutline.samples(points, bases: bases, nibAngle: current.angle))
    }

    func command() -> (any WTModel.Command)? {
        guard let context, let outline = outline() else { return nil }
        let points = ContourPoints.points(outline)
        guard points.count >= 3 else { return nil }
        return CreatePath(label: "Calligraphic Stroke", contours: [NewContour(closed: true, points: points)], appearance: context.newObjectAppearance(),
                          layer: context.objectEditing?.activeLayer)
    }

    func flagsChanged(_ e: CanvasEvent) {}

    /// kbd:[{startsb}] and kbd:[{endsb}] step a *Variable* nib; a *Fixed* nib ignores them.
    func keyDown(_ e: NSEvent) -> Bool {
        guard let wider = StrokeWidthControl.bracket(e.charactersIgnoringModifiers), settings().variable else { return false }
        width.bracket(wider: wider)
        return true
    }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let capture, capture.trail.count >= 2 else { return }
        let path = CGMutablePath()
        SelectionOverlay.add(DisplayPath(polygon: capture.trail, closed: false), transform: viewport.pasteboardToView, to: path)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(max(1, (settings().variable ? width.keyWidth : settings().fixedWidth) * viewport.zoom / 2))
        if settings().dotted { ctx.setLineDash(phase: 0, lengths: [1, 3]) }
        ctx.addPath(path)
        ctx.strokePath()
    }

    func cancel() {
        capture = nil
        points = []
        bases = []
    }

    var hasSomethingToCancel: Bool { capture != nil }
}
