import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The selected paths and live shapes (a group's, too) a distortion drag reshapes, captured at the
/// press (path-effects.adoc; FX-032; a shape converts to a path in the same change, D-078):
/// each path's contours in pasteboard space, the preview the overlay draws, and the one change the
/// release writes -- a `RewritePath` per path, its points mapped back into the path's own space
/// (existing points keep their ids, so the change merges point by point).
@MainActor
struct DistortTargets {
    let targets: [PathSplitting.Target]

    init(_ context: ToolContext) {
        targets = PathSplitting.targets(Self.members(context.selection.selection, document: context.document), document: context.document)
    }

    /// `selection` with every group opened to the objects inside it, at any depth: a distortion
    /// reshapes a group's paths and live shapes as if each were selected (FreeHand's distort tools
    /// work on a selected group).  Anything else inside (text, images) is left alone.
    static func members(_ selection: Selection, document: DocumentHandle) -> Selection {
        let state = document.state
        func opened(_ node: OpID) -> [OpID] { state.nodeKind(node) == .group ? state.liveChildren(node).flatMap(opened) : [node] }
        return Selection(selection.ids.flatMap { id in state.nodeKind(id.opID) == .group ? opened(id.opID).map { SelectionID($0) } : [id] })
    }

    var isEmpty: Bool { targets.isEmpty }

    /// Every contour of `target` in pasteboard space.
    static func contours(_ target: PathSplitting.Target) -> [DistortContour] {
        target.contours.map { DistortContour(points: PathSplitting.map($0.drawn, target.transform), closed: $0.closed) }
    }

    /// All contours of every path (what a kernel's reference measures, the Bend's farthest point).
    var allContours: [DistortContour] { targets.flatMap(Self.contours) }

    /// The reshaped contours per path.
    func distorted(_ kernel: (DistortContour) -> DistortContour) -> [[DistortContour]] {
        targets.map { Self.contours($0).map(kernel) }
    }

    /// The change: each path's contours replaced by `kernel`'s, labelled `label`.
    func command(_ label: String, _ kernel: (DistortContour) -> DistortContour) -> any WTModel.Command {
        DistortTargetsCommand.command(targets, label: label, kernel)
    }

    /// Strokes `contours` (pasteboard space) in view points.
    static func draw(_ contours: [DistortContour], in ctx: CGContext, viewport: Viewport) {
        Keylines.add(contours, to: ctx, viewport: viewport)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }
}

/// What the three reshaping tools share: the press captures the selected paths, each drag event
/// redraws the preview, the release writes one change, kbd:[Esc] abandons.
@MainActor
class DistortDragTool {
    private(set) var context: ToolContext?
    private(set) var press: CanvasEvent?
    private(set) var current: CanvasEvent?
    private(set) var targets: DistortTargets?

    var cursor: NSCursor { .crosshair }
    var statusMessage: String { "" }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(statusMessage)
    }

    func deactivate() {
        cancel()
        context = nil
    }

    func mouseDown(_ e: CanvasEvent) {
        guard let context else { return }
        let targets = DistortTargets(context)
        guard !targets.isEmpty else { return }
        self.targets = targets
        press = e
        current = e
        didPress()
    }

    /// A subclass's per-press setup (Roughen's random seed).
    func didPress() {}

    func mouseDragged(_ e: CanvasEvent) {
        guard press != nil else { return }
        current = e
        context?.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { cancel() }
        guard let context, let command = command() else { return }
        context.commandSink.perform(command)
    }

    func flagsChanged(_ e: CanvasEvent) {
        guard let current else { return }
        self.current = current.with(modifiers: e.modifiers)
        context?.host.setNeedsOverlayDisplay()
    }

    func keyDown(_ e: NSEvent) -> Bool { false }

    /// The kernel the drag so far stands for; nil when the drag does nothing yet.
    func kernel() -> ((DistortContour) -> DistortContour)? { nil }

    var label: String { "" }

    func command() -> (any WTModel.Command)? {
        guard let targets, let kernel = kernel() else { return nil }
        return targets.command(label, kernel)
    }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let targets, let kernel = kernel() else { return }
        DistortTargets.draw(targets.distorted(kernel).flatMap { $0 }, in: ctx, viewport: viewport)
    }

    func cancel() {
        press = nil
        current = nil
        targets = nil
    }

    var hasSomethingToCancel: Bool { press != nil }

    /// The drag's length in pasteboard points.
    var dragDistance: Double {
        guard let press, let current else { return 0 }
        return press.pasteboardPoint.distance(to: current.pasteboardPoint)
    }
}

/// The Roughen tool's options (path-effects.adoc, "Roughening").
struct RoughenSettings: Equatable, Sendable {
    /// Points added per inch, 0...100.
    var amount = 20.0
    /// *Smooth* makes curve points; *Rough* corners.
    var smooth = false

    init(amount: Double = 20, smooth: Bool = false) {
        self.amount = amount
        self.smooth = smooth
    }

    @MainActor init(preferences: PreferenceStore) {
        amount = preferences[DistortPreferences.roughenAmount]
        smooth = preferences[DistortPreferences.roughenEdge] == "smooth"
    }
}

/// The Roughen tool (FX-032): press on the selection and drag; the farther from the press, the
/// rougher.  One change "Roughen".
@MainActor
final class RoughenTool: DistortDragTool, Tool {
    static let id: ToolID = "roughen"
    override var statusMessage: String { "Drag away from the path to roughen it" }
    override var label: String { "Roughen" }

    let settings: @MainActor () -> RoughenSettings
    /// The drag's random seed (fixed per press, so the preview and the result agree).
    private(set) var seed: UInt64 = 1

    init(settings: @escaping @MainActor () -> RoughenSettings) {
        self.settings = settings
    }

    override func didPress() {
        seed = UInt64.random(in: 1...UInt64.max)
    }

    override func kernel() -> ((DistortContour) -> DistortContour)? {
        let distance = dragDistance
        guard distance > 0 else { return nil }
        let current = settings()
        var random = SeededGenerator(seed: seed)
        return { DistortKernels.roughen($0, amount: current.amount, smooth: current.smooth, distance: distance, using: &random) }
    }
}

/// The Fisheye Lens tool (FX-032): the drag draws the lens -- the circle across the drag, or with
/// kbd:[Option] the circle about the press -- and the release looks through it.  One change
/// "Fisheye lens".
@MainActor
final class FisheyeLensTool: DistortDragTool, Tool {
    static let id: ToolID = "fisheyeLens"
    override var statusMessage: String { "Drag across the selection to draw the lens; Option draws from the centre" }
    override var label: String { "Fisheye lens" }

    let perspective: @MainActor () -> Double

    init(perspective: @escaping @MainActor () -> Double) {
        self.perspective = perspective
    }

    /// The lens: centre and radius, pasteboard space.
    var lens: (center: Point, radius: Double)? {
        guard let press, let current else { return nil }
        let a = press.pasteboardPoint, b = current.pasteboardPoint
        if current.modifiers.contains(.option) { return (a, a.distance(to: b)) }
        return (Point.lerp(a, b, 0.5), a.distance(to: b) / 2)
    }

    override func kernel() -> ((DistortContour) -> DistortContour)? {
        guard let lens, lens.radius > 0 else { return nil }
        let perspective = perspective()
        return { DistortKernels.fisheye($0, center: lens.center, radius: lens.radius, perspective: perspective) }
    }

    override func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        super.drawOverlay(in: ctx, viewport: viewport)
        guard let lens else { return }
        let center = viewport.toView(lens.center), radius = lens.radius * viewport.zoom
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ctx.setLineDash(phase: 0, lengths: [])
    }
}

/// The Bend tool (FX-032): press at the centre and drag up for a spike, down for a bloat; the
/// farther, the stronger.  The Bend effect's kernel with `size = ±distance × amount / 10`.  One
/// change "Bend".
@MainActor
final class BendTool: DistortDragTool, Tool {
    static let id: ToolID = "bend"
    override var statusMessage: String { "Press at the centre; drag up to spike, down to bloat" }
    override var label: String { "Bend" }

    let amount: @MainActor () -> Double

    init(amount: @escaping @MainActor () -> Double) {
        self.amount = amount
    }

    /// The Bend kernel's size for the drag so far.
    var size: Double {
        guard let press, let current else { return 0 }
        let dy = current.pasteboardPoint.y - press.pasteboardPoint.y
        return DistortKernels.bendSize(dragDistance: dy, up: dy < 0, amount: amount())
    }

    override func kernel() -> ((DistortContour) -> DistortContour)? {
        guard let press, let targets, size != 0 else { return nil }
        let center = press.pasteboardPoint
        let farthest = DistortKernels.farthest(targets.allContours, from: center)
        let size = size
        return { DistortKernels.bend($0, center: center, size: size, farthest: farthest) }
    }
}
