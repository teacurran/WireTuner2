import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The 3D Rotation tool's settings (path-effects.adoc, "3D rotation"; OBJ-035).
struct Rotation3DSettings: Equatable, Sendable {
    enum Place: String, CaseIterable, Sendable { case click, center, gravity, origin, point }

    var expert = false
    var rotateFrom = Place.center
    /// The eye's distance from the page, points: smaller exaggerates the perspective.
    var distance = 500.0
    var projectFrom = Place.center
    /// *X/Y coordinates* of the projection point.
    var projectX = 0.0
    var projectY = 0.0

    init(expert: Bool = false, rotateFrom: Place = .center, distance: Double = 500, projectFrom: Place = .center, projectX: Double = 0, projectY: Double = 0) {
        self.expert = expert
        self.rotateFrom = rotateFrom
        self.distance = distance
        self.projectFrom = projectFrom
        self.projectX = projectX
        self.projectY = projectY
    }

    /// A stored place; anything unknown reads as the centre of the selection.
    static func place(_ raw: String) -> Place {
        Place(rawValue: raw) ?? .center
    }

    @MainActor init(preferences: PreferenceStore) {
        typealias P = PathToolPreferences
        expert = preferences[P.rotationExpert]
        rotateFrom = Self.place(preferences[P.rotationFrom])
        distance = preferences[P.rotationDistance]
        projectFrom = Self.place(preferences[P.projectFrom])
        projectX = preferences[P.projectX]
        projectY = preferences[P.projectY]
    }
}

/// The projection of a 3D rotation (path-effects.adoc, "Client": "rotate the outline about the
/// chosen origin in 3D by the drag vector (trackball), project with a perspective of focal length
/// `distance` from the projection point; Easy mode fixes projection at the rotation origin").
/// Pasteboard space, y down, z toward the viewer.
struct Rotation3D: Equatable, Sendable {
    /// Radians about the page's vertical axis (a horizontal drag) and its horizontal axis (a
    /// vertical drag).
    var yaw: Double
    var pitch: Double

    /// Half a degree per view point dragged; kbd:[Shift] snaps each angle to 45° steps.
    static let radiansPerPoint = 0.5 * .pi / 180

    init(yaw: Double, pitch: Double) {
        self.yaw = yaw
        self.pitch = pitch
    }

    init(drag: Vector, constrained: Bool) {
        var yaw = drag.dx * Self.radiansPerPoint, pitch = drag.dy * Self.radiansPerPoint
        if constrained {
            yaw = (yaw / (.pi / 4)).rounded() * (.pi / 4)
            pitch = (pitch / (.pi / 4)).rounded() * (.pi / 4)
        }
        self.init(yaw: yaw, pitch: pitch)
    }

    /// The rotation matrix `R = Ry(yaw) · Rx(pitch)` (rows).
    var matrix: [[Double]] {
        let (cy, sy, cx, sx) = (cos(yaw), sin(yaw), cos(pitch), sin(pitch))
        return [[cy, sy * sx, sy * cx], [0, cx, -sx], [-sy, cy * sx, cy * cx]]
    }

    /// `point` turned about `origin` and projected from the eye `distance` above `eye`.
    func project(_ point: Point, origin: Point, eye: Point, distance: Double) -> Point {
        let r = matrix
        let (x, y) = (point.x - origin.x, point.y - origin.y)
        let rx = r[0][0] * x + r[0][1] * y, ry = r[1][0] * x + r[1][1] * y, rz = r[2][0] * x + r[2][1] * y
        let world = Point(x: origin.x + rx, y: origin.y + ry)
        let depth = max(distance - rz, 1e-6)
        let factor = distance / depth
        return Point(x: eye.x + (world.x - eye.x) * factor, y: eye.y + (world.y - eye.y) * factor)
    }

    /// Easy mode: the projection seen from above the origin, to first order there -- the skew and
    /// scale matrix `[r00 r01; r10 r11]` about the origin (the perspective term vanishes at it).
    var affine: WTGeometry.AffineTransform {
        let r = matrix
        return WTGeometry.AffineTransform(a: r[0][0], b: r[1][0], c: r[0][1], d: r[1][1], tx: 0, ty: 0)
    }
}

/// The 3D Rotation tool (OBJ-035; FX-036): press on the selection and drag; the drag's direction
/// tilts it (kbd:[Shift]: 45° steps) about the rotation point.  In *Easy* mode the result is the
/// skew-and-scale transformation of the projection seen from the rotation point, one
/// `TransformObjects`; in *Expert* mode paths are projected point by point from the projection
/// point at the *Distance* (other objects take the Easy transformation).  One change "3D rotate".
@MainActor
final class Rotation3DTool: Tool, PointerTracking {
    static let id: ToolID = "rotation3D"
    static let statusMessage = "Drag to rotate the selection in 3D; Shift constrains to 45° steps"

    let settings: @MainActor () -> Rotation3DSettings
    private var context: ToolContext?
    private(set) var press: Point?
    private(set) var current: CanvasEvent?
    /// The last pointer position (the Expert X/Y projection point's default).
    private(set) var lastPointer: Point?

    init(settings: @escaping @MainActor () -> Rotation3DSettings = { Rotation3DSettings() }) {
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

    func pointerMoved(_ e: CanvasEvent) {
        lastPointer = e.pasteboardPoint
    }

    /// A place over the selection (pasteboard): the press, the bounds' centre, the paths' point
    /// centroid, the lower-left corner, or the typed X/Y (the last pointer position when unset).
    func place(_ place: Rotation3DSettings.Place) -> Point? {
        guard let context else { return nil }
        let state = context.document.state
        let ids = context.selection.selection.ids.map(\.opID)
        let bounds = ids.compactMap { Objects.bounds(of: $0, in: state) }
        guard let first = bounds.first else { return nil }
        let box = bounds.dropFirst().reduce(first) { $0.union($1) }
        switch place {
        case .click: return press ?? box.center
        case .center: return box.center
        case .origin: return Point(x: box.minX, y: box.maxY)
        case .gravity:
            let anchors = PathSplitting.targets(context.selection.selection, document: context.document).flatMap { target in
                target.contours.flatMap { $0.drawn.map { target.transform.apply($0.anchor) } }
            }
            guard !anchors.isEmpty else { return box.center }
            return Point(x: anchors.map(\.x).reduce(0, +) / Double(anchors.count), y: anchors.map(\.y).reduce(0, +) / Double(anchors.count))
        case .point:
            let current = settings()
            if current.projectX == 0, current.projectY == 0, let lastPointer { return lastPointer }
            return Point(x: current.projectX, y: current.projectY)
        }
    }

    func mouseDown(_ e: CanvasEvent) {
        press = e.pasteboardPoint
        current = e
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard press != nil else { return }
        current = e
        lastPointer = e.pasteboardPoint
        context?.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { cancel() }
        guard let context, let command = command() else { return }
        context.commandSink.perform(command)
    }

    /// The rotation the drag so far stands for (view points, so the feel is the same at any zoom).
    var rotation: Rotation3D? {
        guard let press, let current, let context else { return nil }
        let drag = context.viewport.toView(current.pasteboardPoint) - context.viewport.toView(press)
        return Rotation3D(drag: drag, constrained: current.modifiers.contains(.shift))
    }

    func command() -> (any WTModel.Command)? {
        guard let context, let rotation, let origin = place(settings().rotateFrom) else { return nil }
        guard rotation.yaw != 0 || rotation.pitch != 0 else { return nil }
        let current = settings()
        let nodes = context.selection.selection.ids.map(\.opID)
        guard current.expert, let eye = place(current.projectFrom) else {
            return CompositeCommand("3D rotate", [TransformObjects(nodes, matrix: rotation.affine, about: origin, kind: .skew)])
        }
        var commands: [any WTModel.Command] = []
        let targets = PathSplitting.targets(context.selection.selection, document: context.document)
        for target in targets {
            guard let inverse = target.transform.inverted() else { continue }
            let edits = target.contours.map { contour -> RewritePath.ContourEdit in
                let projected = PathSplitting.map(contour.drawn, target.transform).map { point -> VectorPoint in
                    var copy = point
                    copy.anchor = rotation.project(point.anchor, origin: origin, eye: eye, distance: current.distance)
                    copy.inHandle = rotation.project(point.anchor + point.inHandle, origin: origin, eye: eye, distance: current.distance) - copy.anchor
                    copy.outHandle = rotation.project(point.anchor + point.outHandle, origin: origin, eye: eye, distance: current.distance) - copy.anchor
                    return copy
                }
                return .init(contour: contour.id, points: PathSplitting.map(projected, inverse), closed: contour.closed)
            }
            commands.append(RewritePath(node: target.node, edits: edits, label: "3D rotate"))
        }
        let others = nodes.filter { node in !targets.contains { $0.node == node } }
        if !others.isEmpty { commands.append(TransformObjects(others, matrix: rotation.affine, about: origin, kind: .skew)) }
        return CompositeCommand("3D rotate", commands)
    }

    func flagsChanged(_ e: CanvasEvent) {
        guard let current else { return }
        self.current = current.with(modifiers: e.modifiers)
    }

    func keyDown(_ e: NSEvent) -> Bool { false }

    /// The selection's bounds as they would project.
    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let context, let rotation, let origin = place(settings().rotateFrom) else { return }
        let current = settings()
        let eye = (current.expert ? place(current.projectFrom) : nil) ?? origin
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        for id in context.selection.selection.ids {
            guard let bounds = Objects.bounds(of: id.opID, in: context.document.state) else { continue }
            let corners = [Point(x: bounds.minX, y: bounds.minY), Point(x: bounds.maxX, y: bounds.minY), Point(x: bounds.maxX, y: bounds.maxY),
                           Point(x: bounds.minX, y: bounds.maxY)]
                .map { viewport.toView(rotation.project($0, origin: origin, eye: eye, distance: current.distance)) }
            ctx.addLines(between: corners.map(\.cgPoint) + [corners[0].cgPoint])
        }
        ctx.strokePath()
    }

    func cancel() {
        press = nil
        current = nil
    }

    var hasSomethingToCancel: Bool { press != nil }
}
