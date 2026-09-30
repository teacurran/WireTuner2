import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Mirror tool's settings (path-effects.adoc, "Mirror"; transforming.adoc "Other
/// transformation tools"; OBJ-035).
struct MirrorSettings: Equatable, Sendable {
    enum Axis: String, CaseIterable, Sendable { case horizontal, vertical, both, multiple }

    var axis = Axis.vertical
    /// Multiple: the number of axes (and so of copies), 1...100.
    var axes = 6
    /// Multiple: copies turned about the centre instead of reflected.
    var rotate = false
    var closePaths = false

    init(axis: Axis = .vertical, axes: Int = 6, rotate: Bool = false, closePaths: Bool = false) {
        self.axis = axis
        self.axes = axes
        self.rotate = rotate
        self.closePaths = closePaths
    }

    /// A stored axis; anything unknown reads as vertical.
    static func axis(_ raw: String) -> Axis { Axis(rawValue: raw) ?? .vertical }

    @MainActor init(preferences: PreferenceStore) {
        typealias P = PathToolPreferences
        axis = Self.axis(preferences[P.mirrorAxis])
        axes = preferences[P.mirrorAxes]
        rotate = preferences[P.mirrorRotate]
        closePaths = preferences[P.mirrorClosePaths]
    }
}

/// Mirror's copies as matrices about the centre (pasteboard space, y down; the axis angle turns
/// every axis): a horizontal axis flips top to bottom, a vertical one left to right, both makes
/// the three reflections of a quadrant, and *Multiple* makes one copy per axis -- reflected across
/// axes spaced 180°/N apart, or turned by 360°/(N+1) steps.
enum MirrorGeometry {
    /// The reflection across the line through the origin at `angle` radians (counter-clockwise on
    /// screen).
    static func reflection(_ angle: Double) -> WTGeometry.AffineTransform {
        let phi = -angle
        return WTGeometry.AffineTransform(a: cos(2 * phi), b: sin(2 * phi), c: sin(2 * phi), d: -cos(2 * phi), tx: 0, ty: 0)
    }

    static func matrices(_ settings: MirrorSettings, angle: Double = 0) -> [WTGeometry.AffineTransform] {
        switch settings.axis {
        case .horizontal: return [reflection(angle)]
        case .vertical: return [reflection(angle + .pi / 2)]
        case .both: return [reflection(angle), reflection(angle + .pi / 2), reflection(angle).concatenating(reflection(angle + .pi / 2))]
        case .multiple:
            let count = min(max(settings.axes, 1), 100)
            if settings.rotate {
                return (1...count).map { .rotation(radians: -2 * .pi * Double($0) / Double(count + 1)) }
            }
            return (0..<count).map { reflection(angle + .pi * Double($0) / Double(count)) }
        }
    }
}

/// The Mirror tool (OBJ-035; FX-035's keys): drag to set the centre of the reflection -- the
/// halfway point between the objects and their copies -- and release to make the copies of the
/// selected objects (whole objects, whatever points are selected) in one change "Mirror".  While
/// dragging kbd:[Option] turns the axes toward the pointer (kbd:[Option+Shift] in 45° steps),
/// kbd:[Up]/kbd:[Down] switch *Multiple* between reflect and rotate and kbd:[Right]/kbd:[Left] add
/// or remove an axis.  *Close paths* with one axis joins an open path whose ends touch the axis
/// with its reflection into one closed path.
@MainActor
final class MirrorTool: Tool {
    static let id: ToolID = "mirror"
    static let statusMessage = "Drag to place the mirror's centre; Option turns the axes, arrows change the axes"

    let settings: @MainActor () -> MirrorSettings
    private var context: ToolContext?
    private(set) var press: Point?
    private(set) var current: Point?
    private(set) var angle = 0.0
    /// The drag's own changes to the settings (arrow keys).
    private(set) var adjusted: MirrorSettings?

    init(settings: @escaping @MainActor () -> MirrorSettings = { MirrorSettings() }) {
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

    /// The settings the drag uses (the sheet's, with the arrow keys' changes).
    var effective: MirrorSettings { adjusted ?? settings() }

    func mouseDown(_ e: CanvasEvent) {
        press = e.pasteboardPoint
        current = e.pasteboardPoint
        angle = 0
        adjusted = nil
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard let press else { return }
        current = e.pasteboardPoint
        if e.modifiers.contains(.option) {
            let delta = e.pasteboardPoint - press
            if delta.lengthSquared > 0 {
                var turn = atan2(-delta.dy, delta.dx)
                if e.modifiers.contains(.shift) { turn = (turn / (.pi / 4)).rounded() * (.pi / 4) }
                angle = turn
            }
        }
        context?.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { cancel() }
        guard let context, let command = command() else { return }
        context.commandSink.perform(command)
    }

    /// The centre: where the drag is (with kbd:[Option], where it began: the axes turn about it).
    var center: Point? { angle != 0 ? press : current }

    /// The change: one copy per matrix of every selected object, or the joined closed path.
    func command() -> (any WTModel.Command)? {
        guard let context, let center else { return nil }
        let nodes = context.selection.selection.ids.map(\.opID)
        guard !nodes.isEmpty else { return nil }
        let settings = effective
        let matrices = MirrorGeometry.matrices(settings, angle: angle)
        if settings.closePaths, matrices.count == 1, let joined = Self.join(nodes, matrix: matrices[0], center: center, context: context) {
            return joined
        }
        let options = context.transformOptions()
        let copies = matrices.map {
            TransformObjects(nodes, matrix: $0, about: center, kind: settings.rotate && settings.axis == .multiple ? .rotate : .reflect, options: options, copies: 1)
        }
        return CompositeCommand("Mirror", copies)
    }

    /// *Close paths*: each selected open path whose two ends lie within the snap distance of the
    /// axis becomes one closed path, itself followed by its reflection; nil when none does.
    static func join(_ nodes: [OpID], matrix: WTGeometry.AffineTransform, center: Point, context: ToolContext) -> (any WTModel.Command)? {
        let reach = context.snapping.snapDistance() / context.viewport.zoom
        let about = WTGeometry.AffineTransform.translation(Vector(dx: -center.x, dy: -center.y)).concatenating(matrix)
            .concatenating(.translation(Vector(dx: center.x, dy: center.y)))
        var edits: [any WTModel.Command] = []
        for target in PathSplitting.targets(Selection(nodes.map { SelectionID($0) }), document: context.document) {
            guard let inverse = target.transform.inverted(), let contour = target.contours.first(where: { !$0.closed && $0.drawn.count >= 2 }) else { continue }
            let drawn = PathSplitting.map(contour.drawn, target.transform)
            let ends = [drawn.first!.anchor, drawn.last!.anchor]
            guard ends.allSatisfy({ $0.distance(to: about.apply($0)) / 2 <= reach }) else { continue }
            // The reflection read backwards, without its two end points (they meet the originals).
            let mirrored = PathSplitting.map(drawn, about).reversed().map { point -> VectorPoint in
                var copy = point
                copy.id = .zero
                (copy.inHandle, copy.outHandle) = (point.outHandle, point.inHandle)
                return copy
            }
            let inner = Array(mirrored.dropFirst().dropLast())
            var points = drawn
            points[points.count - 1].outHandle = mirrored.first?.outHandle ?? .zero
            points[0].inHandle = mirrored.last?.inHandle ?? .zero
            let local = PathSplitting.restored(PathSplitting.map(points + inner, inverse), from: contour.drawn)
            edits.append(RewritePath(node: target.node, edits: [.init(contour: contour.id, points: local, closed: true)], label: "Mirror"))
        }
        guard !edits.isEmpty else { return nil }
        return CompositeCommand("Mirror", edits)
    }

    func flagsChanged(_ e: CanvasEvent) {}

    /// The arrow keys during a drag: kbd:[Up]/kbd:[Down] toggle reflect/rotate, kbd:[Right]/
    /// kbd:[Left] add or remove an axis (*Multiple*).
    func keyDown(_ e: NSEvent) -> Bool {
        guard press != nil else { return false }
        var settings = effective
        switch e.keyCode {
        case 126, 125: settings.rotate.toggle()
        case 124: settings.axes = min(settings.axes + 1, 100)
        case 123: settings.axes = max(settings.axes - 1, 1)
        default: return false
        }
        adjusted = settings
        context?.host.setNeedsOverlayDisplay()
        return true
    }

    /// Keylines of every copy: each selected object's outline (every path of a group) reflected.
    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let context, let center else { return }
        let settings = effective
        let outlines = Keylines.contours(context.selection.selection.ids.map(\.opID), document: context.document)
        for matrix in MirrorGeometry.matrices(settings, angle: angle) {
            let about = WTGeometry.AffineTransform.translation(Vector(dx: -center.x, dy: -center.y)).concatenating(matrix)
                .concatenating(.translation(Vector(dx: center.x, dy: center.y)))
            Keylines.add(outlines.map { DistortKernels.mapped($0, about.apply) }, to: ctx, viewport: viewport)
        }
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    func cancel() {
        press = nil
        current = nil
        angle = 0
        adjusted = nil
    }

    var hasSomethingToCancel: Bool { press != nil }
}
