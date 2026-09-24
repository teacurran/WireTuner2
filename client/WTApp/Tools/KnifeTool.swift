import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Knife's settings (editing-paths.adoc, "Splitting paths"): *Free* or *Straight*, the cut's
/// width, *Close cut paths*, *Tight fit*.
struct KnifeSettings: Equatable, Sendable {
    var straight = false
    var width = 0.0
    var close = false
    var tightFit = false

    init(straight: Bool = false, width: Double = 0, close: Bool = false, tightFit: Bool = false) {
        self.straight = straight
        self.width = width
        self.close = close
        self.tightFit = tightFit
    }

    @MainActor init(preferences: PreferenceStore) {
        typealias P = PathToolPreferences
        straight = preferences[P.knifeStraight] == "straight"
        width = preferences[P.knifeWidth]
        close = preferences[P.knifeClose]
        tightFit = preferences[P.knifeTightFit]
    }
}

/// The Knife and menu:Modify[Split] as changes over the selection (DRAW-028).
@MainActor
enum PathSplitting {
    /// The selected paths' drawn contours in pasteboard space, with how to map back.
    struct Target {
        var node: OpID
        var transform: WTGeometry.AffineTransform
        var contours: [VectorContour]
    }

    static func targets(_ selection: Selection, document: DocumentHandle) -> [Target] {
        let state = document.state
        return selection.ids.compactMap { id in
            guard state.nodeKind(id.opID) == .path, !Objects.isEffectivelyLocked(id.opID, in: state),
                  let path = document.object(for: id)?.path else { return nil }
            return Target(node: id.opID, transform: Objects.pasteboardTransform(of: id.opID, in: state), contours: path.contours)
        }
    }

    /// Points mapped through `transform` (anchors, and handles by its linear part).
    static func map(_ points: [VectorPoint], _ transform: WTGeometry.AffineTransform) -> [VectorPoint] {
        points.map { point in
            var copy = point
            copy.anchor = transform.apply(point.anchor)
            copy.inHandle = transform.apply(point.anchor + point.inHandle) - copy.anchor
            copy.outHandle = transform.apply(point.anchor + point.outHandle) - copy.anchor
            return copy
        }
    }

    /// `points` with the anchors and handles of surviving points put back to `original`'s where
    /// they differ by no more than rounding.
    static func restored(_ points: [VectorPoint], from original: [VectorPoint]) -> [VectorPoint] {
        let stored = Dictionary(original.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return points.map { point in
            guard point.id != .zero, let old = stored[point.id] else { return point }
            var copy = point
            if copy.anchor.isApproximatelyEqual(to: old.anchor, tolerance: 1e-6) { copy.anchor = old.anchor }
            if copy.inHandle.isApproximatelyEqual(to: old.inHandle, tolerance: 1e-6) { copy.inHandle = old.inHandle }
            if copy.outHandle.isApproximatelyEqual(to: old.outHandle, tolerance: 1e-6) { copy.outHandle = old.outHandle }
            return copy
        }
    }

    /// The Knife along `cutter` (pasteboard space) through every selected path: one change
    /// "Knife"; nil when it crosses nothing.
    static func knife(_ selection: Selection, document: DocumentHandle, cutter: [Point], settings: KnifeSettings) -> (any WTModel.Command)? {
        var commands: [any WTModel.Command] = []
        for target in targets(selection, document: document) {
            guard let inverse = target.transform.inverted() else { continue }
            let cut = target.contours.compactMap { contour -> (contour: OpID, pieces: [PathCutting.Piece])? in
                let drawn = map(contour.drawn, target.transform)
                guard let pieces = PathCutting.knife(drawn, closed: contour.closed, cutter: cutter, width: settings.width, close: settings.close) else { return nil }
                // Back into the path's space; the surviving points keep their ids, and what the
                // round trip only disturbed in the last digits stays as stored.
                return (contour.id, pieces.map {
                    PathCutting.Piece(points: restored(map($0.points, inverse), from: contour.drawn), closed: $0.closed, keepsStart: $0.keepsStart)
                })
            }
            if let command = PathCutting.command(node: target.node, cut: cut, label: "Knife") { commands.append(command) }
        }
        guard !commands.isEmpty else { return nil }
        return commands.count == 1 ? commands[0] : CompositeCommand("Knife", commands)
    }

    /// menu:Modify[Split] at the selected points: each becomes the end of one piece and the start
    /// of another; the piece holding a contour's start keeps the node.  Nil when no point that can
    /// split (an open contour's own ends cannot) is selected.
    static func split(_ selection: Selection, document: DocumentHandle) -> (any WTModel.Command)? {
        var commands: [any WTModel.Command] = []
        for target in targets(selection, document: document) {
            guard case .points(let references)? = selection.subSelection(of: SelectionID(target.node)) else { continue }
            let cut = target.contours.compactMap { contour -> (contour: OpID, pieces: [PathCutting.Piece])? in
                let drawn = contour.drawn
                let locations = references.filter { $0.contour == contour.id }.compactMap { reference in
                    drawn.firstIndex { $0.id == reference.point }.map { PathCutting.Location(segment: $0, t: 0) }
                }.filter { contour.closed || ($0.segment > 0 && $0.segment < drawn.count - 1) }
                guard !locations.isEmpty, let pieces = PathCutting.split(drawn, closed: contour.closed, at: locations) else { return nil }
                return (contour.id, pieces)
            }
            if let command = PathCutting.command(node: target.node, cut: cut, label: "Split") { commands.append(command) }
        }
        guard !commands.isEmpty else { return nil }
        return commands.count == 1 ? commands[0] : CompositeCommand("Split", commands)
    }

    /// Whether menu:Modify[Split] has points to split at.
    static func canSplit(_ selection: Selection, document: DocumentHandle) -> Bool {
        split(selection, document: document) != nil
    }
}

/// The Knife (editing-paths.adoc, "Splitting paths"; DRAW-028): drag across selected paths to cut
/// them wherever the drag crosses -- freehand, smoothed unless *Tight fit*, or *Straight* from
/// press to release; in *Free* mode kbd:[Option] cuts straight for part of the drag and
/// kbd:[Shift] constrains it.  A *Width* above zero removes the strip between two cuts.  One change
/// "Knife" on release.
@MainActor
final class KnifeTool: Tool {
    static let id: ToolID = "knife"
    static let statusMessage = "Drag across selected paths to cut them; Option cuts straight, Shift constrains"

    let settings: @MainActor () -> KnifeSettings
    private var context: ToolContext?
    private(set) var capture: StrokeCapture?
    private(set) var press: Point?
    private(set) var current: Point?

    init(settings: @escaping @MainActor () -> KnifeSettings = { KnifeSettings() }) {
        self.settings = settings
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

    func mouseDown(_ e: CanvasEvent) {
        press = e.pasteboardPoint
        current = e.pasteboardPoint
        capture = StrokeCapture(start: e.pasteboardPoint, straight: e.modifiers.contains(.option))
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard capture != nil, let context, let press else { return }
        let constraint = e.modifiers.contains(.shift) ? context.drawing().constraint : nil
        current = settings().straight ? (constraint.map { $0.constrain(e.pasteboardPoint, from: press) } ?? e.pasteboardPoint) : e.pasteboardPoint
        capture?.add(e.pasteboardPoint, straight: e.modifiers.contains(.option), constraint: constraint)
        context.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { cancel() }
        guard let context, let command = command() else { return }
        context.commandSink.perform(command)
    }

    /// The cutting line so far (pasteboard space).
    func cutter() -> [Point] {
        guard let capture, let press else { return [] }
        let current = settings()
        if current.straight { return [press, self.current ?? press] }
        let trail = capture.trail
        guard !current.tightFit, trail.count > 2 else { return trail }
        return Polyline.smoothed(trail, sigma: 1)
    }

    func command() -> (any WTModel.Command)? {
        guard let context else { return nil }
        let line = cutter()
        guard line.count >= 2, Polyline.length(line) > 0 else { return nil }
        return PathSplitting.knife(context.selection.selection, document: context.document, cutter: line, settings: settings())
    }

    func flagsChanged(_ e: CanvasEvent) {}

    func keyDown(_ e: NSEvent) -> Bool { false }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        let line = cutter()
        guard line.count >= 2 else { return }
        let path = CGMutablePath()
        SelectionOverlay.add(DisplayPath(polygon: line, closed: false), transform: viewport.pasteboardToView, to: path)
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(max(1, settings().width * viewport.zoom))
        ctx.addPath(path)
        ctx.strokePath()
    }

    func cancel() {
        capture = nil
        press = nil
        current = nil
    }

    var hasSomethingToCancel: Bool { capture != nil }
}
