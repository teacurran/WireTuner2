import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Eraser's sheet: *Min* and *Max* width (preferences on this Mac).
enum EraserPreferences {
    static let min = PreferenceKey<Double>("tools.eraser.min", "Min", category: .object, default: 4, control: .stepper(range: 0...72, step: 1, unit: "pt"),
                                           help: "editing-paths")
    static let max = PreferenceKey<Double>("tools.eraser.max", "Max", category: .object, default: 12, control: .stepper(range: 0...72, step: 1, unit: "pt"),
                                           help: "editing-paths")
    static let sheet: [AnyPreferenceKey] = [min.erased, max.erased, PathToolPreferences.pressureCurve.erased]
}

struct EraserSettings: Equatable, Sendable {
    var min = 4.0
    var max = 12.0
    var pressureCurve = 1.0

    init(min: Double = 4, max: Double = 12) {
        self.min = min
        self.max = max
    }

    @MainActor init(preferences: PreferenceStore) {
        min = preferences[EraserPreferences.min]
        max = preferences[EraserPreferences.max]
        pressureCurve = preferences[PathToolPreferences.pressureCurve]
    }
}

/// The eraser strip (editing-paths.adoc, "Erasing"; DRAW-029): the two edges of a strip along the
/// drag whose width follows each sample's width, and the cut of a contour by it -- what the strip
/// covers is removed, what remains becomes pieces (the one holding the contour's start keeps it).
enum EraserStrip {
    /// The two edges of the strip along `samples` (each sample's width), with the ends extended by
    /// half a width so the strip reaches past the first and last samples.
    static func edges(_ samples: [VariableStrokeOutline.Sample]) -> (left: [Point], right: [Point]) {
        let points = samples.map(\.point)
        guard points.count >= 2 else { return (points, points) }
        var left: [Point] = [], right: [Point] = []
        for index in points.indices {
            let before = index > 0 ? points[index] - points[index - 1] : points[1] - points[0]
            let after = index + 1 < points.count ? points[index + 1] - points[index] : before
            var normal = (before.lengthSquared > 0 ? before.normalized : after.normalized) + (after.lengthSquared > 0 ? after.normalized : before.normalized)
            if normal.lengthSquared < 1e-12 { normal = before.normalized }
            let half = samples[index].width / 2
            let perpendicular = normal.normalized.perpendicular * half
            var point = points[index]
            if index == 0 { point = point - after.normalized * half }
            if index == points.count - 1 { point = point + before.normalized * half }
            left.append(point + perpendicular)
            right.append(point - perpendicular)
        }
        return (left, right)
    }

    /// The half width of the strip nearest `point`.
    static func halfWidth(near point: Point, samples: [VariableStrokeOutline.Sample]) -> Double {
        (samples.min { $0.point.distance(to: point) < $1.point.distance(to: point) }?.width ?? 0) / 2
    }

    /// The pieces of one contour (pasteboard space) after the strip, or nil when it misses.
    static func erase(_ points: [VectorPoint], closed: Bool, samples: [VariableStrokeOutline.Sample]) -> [PathCutting.Piece]? {
        let path = samples.map(\.point)
        guard path.count >= 2 else { return nil }
        let (left, right) = edges(samples)
        let cuts = PathCutting.crossings(points, closed: closed, cutter: left) + PathCutting.crossings(points, closed: closed, cutter: right)
        guard var pieces = PathCutting.split(points, closed: closed, at: cuts) else { return nil }
        pieces = pieces.filter { piece in
            let segments = ContourPoints.segments(piece.points, closed: false)
            let middle = segments[segments.count / 2].evaluate(0.5)
            return PathCutting.distance(middle, to: path) > halfWidth(near: middle, samples: samples) - 1e-6
        }
        if !pieces.contains(where: \.keepsStart), !pieces.isEmpty { pieces[0].keepsStart = true }
        return pieces
    }

    /// The erase of every selected path, one change "Erase"; nil when the strip touches none.
    @MainActor
    static func command(_ selection: Selection, document: DocumentHandle, samples: [VariableStrokeOutline.Sample]) -> (any WTModel.Command)? {
        var commands: [any WTModel.Command] = []
        for target in PathSplitting.targets(selection, document: document) {
            guard let inverse = target.transform.inverted() else { continue }
            let cut = target.contours.compactMap { contour -> (contour: OpID, pieces: [PathCutting.Piece])? in
                let drawn = PathSplitting.map(contour.drawn, target.transform)
                guard let pieces = erase(drawn, closed: contour.closed, samples: samples) else { return nil }
                return (contour.id, pieces.map {
                    PathCutting.Piece(points: PathSplitting.restored(PathSplitting.map($0.points, inverse), from: contour.drawn), closed: false, keepsStart: $0.keepsStart)
                })
            }
            if let command = PathCutting.command(node: target.node, cut: cut, label: "Erase") { commands.append(command) }
        }
        guard !commands.isEmpty else { return nil }
        return commands.count == 1 ? commands[0] : CompositeCommand("Erase", commands)
    }
}

/// The Eraser (editing-paths.adoc, "Erasing"; DRAW-029): drag across selected paths to remove what
/// the eraser covers.  Its width follows pen pressure between *Min* and *Max*, or with a mouse
/// the width kbd:[{startsb}] and kbd:[{endsb}] set; a pen in contact overrides the keys.  One
/// change "Erase" on release.
@MainActor
final class EraserTool: Tool, PointerTracking {
    static let id: ToolID = "eraser"
    static let statusMessage = "Drag across selected paths to erase them; [ and ] narrow and widen the eraser"

    let settings: @MainActor () -> EraserSettings
    private var context: ToolContext?
    private(set) var samples: [VariableStrokeOutline.Sample] = []
    private(set) var width: StrokeWidthControl
    private(set) var isErasing = false

    init(settings: @escaping @MainActor () -> EraserSettings = { EraserSettings() }) {
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

    func mouseDown(_ e: CanvasEvent) {
        let current = settings()
        width = StrokeWidthControl(min: current.min, max: current.max, curve: current.pressureCurve, keyWidth: width.keyWidth)
        isErasing = true
        samples = [VariableStrokeOutline.Sample(point: e.pasteboardPoint, width: width.width(for: e))]
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard isErasing else { return }
        samples.append(VariableStrokeOutline.Sample(point: e.pasteboardPoint, width: width.width(for: e)))
        context?.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { cancel() }
        guard let context, let command = command() else { return }
        context.commandSink.perform(command)
    }

    func command() -> (any WTModel.Command)? {
        guard let context, samples.count >= 2 else { return nil }
        return EraserStrip.command(context.selection.selection, document: context.document, samples: samples)
    }

    func flagsChanged(_ e: CanvasEvent) {}

    /// kbd:[{startsb}] and kbd:[{endsb}]: narrower or wider from the next sample.
    func keyDown(_ e: NSEvent) -> Bool {
        guard let wider = StrokeWidthControl.bracket(e.charactersIgnoringModifiers) else { return false }
        width.bracket(wider: wider)
        return true
    }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard samples.count >= 2 else { return }
        let (left, right) = EraserStrip.edges(samples)
        let path = CGMutablePath()
        SelectionOverlay.add(DisplayPath(polygon: left + right.reversed(), closed: true), transform: viewport.pasteboardToView, to: path)
        ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.25).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
    }

    func cancel() {
        samples = []
        isErasing = false
    }

    var hasSomethingToCancel: Bool { isErasing }
}
