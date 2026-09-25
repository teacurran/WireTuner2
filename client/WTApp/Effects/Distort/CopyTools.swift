import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

extension PreferenceColor {
    /// The preference's sRGB colour as a document colour.
    var documentColor: RenderColor { RenderColor(red: red, green: green, blue: blue, alpha: alpha) }
}

/// The Smudge tool's options (path-effects.adoc, "Smudging").
struct SmudgeSettings: Equatable, Sendable {
    /// The colour the copies' fills and strokes fade toward; nil is *None*.
    var fill: RenderColor?
    var stroke: RenderColor?

    init(fill: RenderColor? = .white, stroke: RenderColor? = nil) {
        self.fill = fill
        self.stroke = stroke
    }

    @MainActor init(preferences: PreferenceStore) {
        typealias P = DistortPreferences
        fill = preferences[P.smudgeFillNone] ? nil : preferences[P.smudgeFill].documentColor
        stroke = preferences[P.smudgeStrokeNone] ? nil : preferences[P.smudgeStroke].documentColor
    }
}

/// The Shadow tool's options (path-effects.adoc, "Adding a drop shadow with the Shadow tool").
struct ShadowSettings: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case hard, soft, zoom }
    enum FillMode: String, CaseIterable, Sendable { case tint, shade, color }

    var kind = Kind.hard
    var fill = FillMode.shade
    /// *Tint* (0 white ... 100 the object's colour) or *Shade* (percent black added).
    var percent = 50.0
    var color = RenderColor(red: 0.5, green: 0.5, blue: 0.5)
    var fadeTo = RenderColor.white
    /// 0 (hard) ... 100 (soft throughout).
    var softEdge = 50.0
    var zoomStroke = RenderColor.white
    var zoomFill = RenderColor.white
    /// Percent of the object.
    var scale = 100.0
    var offset = Vector(dx: 6, dy: 6)

    init(kind: Kind = .hard, fill: FillMode = .shade, percent: Double = 50, color: RenderColor = RenderColor(red: 0.5, green: 0.5, blue: 0.5),
         fadeTo: RenderColor = .white, softEdge: Double = 50, zoomStroke: RenderColor = .white, zoomFill: RenderColor = .white, scale: Double = 100,
         offset: Vector = Vector(dx: 6, dy: 6)) {
        self.kind = kind
        self.fill = fill
        self.percent = percent
        self.color = color
        self.fadeTo = fadeTo
        self.softEdge = softEdge
        self.zoomStroke = zoomStroke
        self.zoomFill = zoomFill
        self.scale = scale
        self.offset = offset
    }

    @MainActor init(preferences: PreferenceStore) {
        typealias P = DistortPreferences
        kind = Self.kind(preferences[P.shadowType])
        fill = Self.fillMode(preferences[P.shadowFill])
        percent = preferences[P.shadowPercent]
        color = preferences[P.shadowColor].documentColor
        fadeTo = preferences[P.shadowFadeTo].documentColor
        softEdge = preferences[P.shadowSoftEdge]
        zoomStroke = preferences[P.shadowZoomStroke].documentColor
        zoomFill = preferences[P.shadowZoomFill].documentColor
        scale = preferences[P.shadowScale]
        offset = Vector(dx: preferences[P.shadowOffsetX], dy: preferences[P.shadowOffsetY])
    }

    /// A stored type; anything unknown reads as Hard Edge.
    static func kind(_ raw: String) -> Kind { Kind(rawValue: raw) ?? .hard }
    /// A stored fill; anything unknown reads as Shade.
    static func fillMode(_ raw: String) -> FillMode { FillMode(rawValue: raw) ?? .shade }

    /// The shadow's own paint (Hard and Soft Edge): a tint toward white, a shade toward black, or
    /// the chosen colour.
    var paint: CopiesBehind.Paint {
        let percent = min(max(percent, 0), 100) / 100
        switch fill {
        case .tint: return .toward(.white, amount: 1 - percent)
        case .shade: return .toward(.black, amount: percent)
        case .color: return .toward(color, amount: 1)
        }
    }
}

/// The copies the Smudge and Shadow tools make (path-effects.adoc, "Kernels").
enum CopyGeometry {
    /// Smudge refuses beyond this many new objects.
    static let smudgeCap = 1000
    static let smudgeRefusal = "Smudging would create more than 1,000 objects"
    static let shadowRefusal = "The Shadow tool does not apply to text, bitmaps or clipping paths"
    /// Zoom shadows are drawn in this many steps (the blend's default).
    static let zoomSteps = 25

    /// `matrix` applied about `center`.
    static func about(_ center: Point, _ matrix: WTGeometry.AffineTransform) -> WTGeometry.AffineTransform {
        WTGeometry.AffineTransform.translation(Vector(dx: -center.x, dy: -center.y)).concatenating(matrix).concatenating(.translation(Vector(dx: center.x, dy: center.y)))
    }

    /// Smudge: `n = distance / 2 pt` copies (at least one), the farthest at the bottom; each moved
    /// its share of the drag -- or with kbd:[Option] grown about `center` by its share -- and
    /// faded its share of the way to the smudge colours.
    static func smudge(drag: Vector, center: Point, size: Size, outward: Bool, settings: SmudgeSettings) -> [CopiesBehind.Copy] {
        let count = max(Int(drag.length / 2), 1)
        return (1...count).reversed().map { index in
            let t = Double(index) / Double(count)
            let matrix: WTGeometry.AffineTransform
            if outward {
                let grow = drag.length * t * 2
                let sx = size.width > 0 ? (size.width + grow) / size.width : 1, sy = size.height > 0 ? (size.height + grow) / size.height : 1
                matrix = about(center, .scale(x: sx, y: sy))
            } else {
                matrix = .translation(drag * t)
            }
            return CopiesBehind.Copy(matrix: matrix, fill: settings.fill.map { .toward($0, amount: t) } ?? CopiesBehind.Paint.none,
                                     stroke: settings.stroke.map { .toward($0, amount: t) } ?? CopiesBehind.Paint.none)
        }
    }

    /// Shadow copies of an object with pasteboard `bounds`, placed `offset` away: one copy (Hard);
    /// `soft_edge / 4 + 1` concentric insets fading from the shadow toward *Fade to* at the edge
    /// (Soft); or a series scaled and moved from the shadow back to the object, its colours blended
    /// from the zoom colours to the object's (Zoom).
    static func shadow(bounds: Rect, offset: Vector, settings: ShadowSettings) -> [CopiesBehind.Copy] {
        let center = bounds.center
        let scale = max(settings.scale, 1) / 100
        let placed = about(center, .scale(x: scale, y: scale)).concatenating(.translation(offset))
        switch settings.kind {
        case .hard:
            return [CopiesBehind.Copy(matrix: placed, fill: settings.paint, stroke: settings.paint)]
        case .soft:
            let steps = Int(min(max(settings.softEdge, 0), 100) / 4) + 1
            let width = bounds.width * scale, height = bounds.height * scale
            let depth = min(max(settings.softEdge, 0), 100) / 100 * min(width, height) / 2
            return (0..<steps).map { step in
                let inset = depth * Double(step) / Double(steps)
                let sx = width > 0 ? (width - 2 * inset) / width : 1, sy = height > 0 ? (height - 2 * inset) / height : 1
                let fade = steps == 1 ? 0 : 1 - Double(step + 1) / Double(steps)
                let paint = CopiesBehind.Paint.then(settings.paint, .toward(settings.fadeTo, amount: fade))
                let matrix = placed.concatenating(about(center + offset, .scale(x: sx, y: sy)))
                return CopiesBehind.Copy(matrix: matrix, fill: paint, stroke: paint)
            }
        case .zoom:
            return (0..<zoomSteps).map { step in
                let t = Double(step) / Double(zoomSteps)
                let factor = scale + (1 - scale) * t
                let matrix = about(center, .scale(x: factor, y: factor)).concatenating(.translation(offset * (1 - t)))
                return CopiesBehind.Copy(matrix: matrix, fill: .toward(settings.zoomFill, amount: 1 - t), stroke: .toward(settings.zoomStroke, amount: 1 - t))
            }
        }
    }

    /// Whether the Shadow tool applies to `node`: not text, bitmaps, placed files or clipping groups.
    static func shadowable(_ node: OpID, in state: EngineState) -> Bool {
        guard state.store.kind(node) != ImageKind.kind else { return false }
        switch state.nodeKind(node) {
        case .text?, .placedFile?, nil: return false
        case .group?: return !state.props(node).group.hasClipPath
        default: return true
        }
    }

    /// The Shadow tool's change on `nodes`, each placed `offset` away; nil when none is eligible.
    @MainActor
    static func shadowCommand(_ nodes: [OpID], offset: Vector, settings: ShadowSettings, document: DocumentHandle) -> (any WTModel.Command)? {
        let state = document.state
        let copies = nodes.filter { shadowable($0, in: state) }.compactMap { node -> (node: OpID, copies: [CopiesBehind.Copy])? in
            guard let bounds = Objects.bounds(of: node, in: state) else { return nil }
            return (node, shadow(bounds: bounds, offset: offset, settings: settings))
        }
        return copies.isEmpty ? nil : CopiesBehind("Add shadow", copies: copies)
    }
}

/// What the Smudge and Shadow tools share: the press on the selection, the drag, the keylines.
@MainActor
class CopyDragTool {
    private(set) var context: ToolContext?
    private(set) var press: CanvasEvent?
    private(set) var current: CanvasEvent?
    private(set) var nodes: [OpID] = []

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

    /// The selected objects the tool applies to.
    func eligible(_ nodes: [OpID], in state: EngineState) -> [OpID] { nodes }

    /// Why nothing happened (the HUD) when no selected object is eligible.
    var refusal: String? { nil }

    func mouseDown(_ e: CanvasEvent) {
        guard let context else { return }
        let selected = eligible(context.selection.selection.ids.map(\.opID), in: context.document.state)
        guard !selected.isEmpty else {
            if let refusal, !context.selection.selection.isEmpty { context.host.showHUD(refusal) }
            return
        }
        nodes = selected
        press = e
        current = e
    }

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

    func command() -> (any WTModel.Command)? { nil }

    /// The drag, pasteboard space.
    var drag: Vector {
        guard let press, let current else { return Vector(dx: 0, dy: 0) }
        return current.pasteboardPoint - press.pasteboardPoint
    }

    /// Each copy's bounds as keylines, and a line from the press to the pointer.
    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let context, let press, let current, let command = command() as? CopiesBehind else { return }
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.strokeLineSegments(between: [viewport.toView(press.pasteboardPoint).cgPoint, viewport.toView(current.pasteboardPoint).cgPoint])
        // Every copied object has bounds (the command skips those without).
        for (node, copies) in command.copies {
            for b in [Objects.bounds(of: node, in: context.document.state)].compactMap({ $0 }) {
                let corners = [Point(x: b.minX, y: b.minY), Point(x: b.maxX, y: b.minY), Point(x: b.maxX, y: b.maxY), Point(x: b.minX, y: b.maxY)]
                for copy in copies {
                    let points = corners.map { viewport.toView(copy.matrix.apply($0)).cgPoint }
                    ctx.addLines(between: points + [points[0]])
                }
            }
        }
        ctx.strokePath()
    }

    func cancel() {
        press = nil
        current = nil
        nodes = []
    }

    var hasSomethingToCancel: Bool { press != nil }
}

/// The Smudge tool (FX-033): press on the selection and drag outward; trailing copies fading to the
/// smudge colours are grouped with each object, one change "Smudge".  kbd:[Option] smudges outward
/// from the centre in every direction.  More than 1,000 new objects is refused, with the reason.
@MainActor
final class SmudgeTool: CopyDragTool, Tool {
    static let id: ToolID = "smudge"
    override var statusMessage: String { "Drag from the selection to smudge it; Option smudges outward from the centre" }

    let settings: @MainActor () -> SmudgeSettings

    init(settings: @escaping @MainActor () -> SmudgeSettings) {
        self.settings = settings
    }

    override func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        if let context, press != nil, exceedsCap() {
            context.host.showHUD(CopyGeometry.smudgeRefusal)
            cancel()
            return
        }
        super.mouseUp(e)
    }

    /// Whether the smudge would create more than the cap.
    func exceedsCap() -> Bool {
        guard let context, let command = command() as? CopiesBehind else { return false }
        let state = context.document.state
        return command.copies.map { CopiesBehind.objectCount($0.node, copies: $0.copies.count, in: state) }.reduce(0, +) > CopyGeometry.smudgeCap
    }

    override func command() -> (any WTModel.Command)? {
        guard let context, let current, drag.lengthSquared > 0 else { return nil }
        let state = context.document.state
        let settings = settings()
        let outward = current.modifiers.contains(.option)
        let copies = nodes.compactMap { node -> (node: OpID, copies: [CopiesBehind.Copy])? in
            guard let bounds = Objects.bounds(of: node, in: state) else { return nil }
            return (node, CopyGeometry.smudge(drag: drag, center: bounds.center, size: bounds.size, outward: outward, settings: settings))
        }
        return copies.isEmpty ? nil : CopiesBehind("Smudge", copies: copies)
    }
}

/// The Shadow tool (FX-033): a click places a shadow of each eligible selected object at the
/// options' offset, a drag places it where the drag ends; each is grouped behind its object, one
/// change "Add shadow".  Text, bitmaps and clipping paths are refused.
@MainActor
final class ShadowTool: CopyDragTool, Tool {
    static let id: ToolID = "shadow"
    override var statusMessage: String { "Click to add a shadow at the options' offset, or drag to place it" }

    let settings: @MainActor () -> ShadowSettings

    init(settings: @escaping @MainActor () -> ShadowSettings) {
        self.settings = settings
    }

    override func eligible(_ nodes: [OpID], in state: EngineState) -> [OpID] {
        nodes.filter { CopyGeometry.shadowable($0, in: state) }
    }

    override var refusal: String? { CopyGeometry.shadowRefusal }

    /// A click (no drag) uses the options' offset; a drag its own.
    var offset: Vector { drag.lengthSquared > 0 ? drag : settings().offset }

    override func command() -> (any WTModel.Command)? {
        guard let context, press != nil else { return nil }
        return CopyGeometry.shadowCommand(nodes, offset: offset, settings: settings(), document: context.document)
    }
}

/// The Shadow options sheet's btn:[Apply]: the shadow on the front window's selection as a preview
/// -- applying again replaces it, btn:[Cancel] takes it away, btn:[OK] keeps it.
@MainActor
final class ShadowPreview {
    typealias Target = @MainActor () -> ObjectEditing?

    let target: Target
    let settings: @MainActor () -> ShadowSettings
    /// The document the preview was performed in, while one stands.
    private(set) var previewed: DocumentHandle?

    init(target: @escaping Target, settings: @escaping @MainActor () -> ShadowSettings) {
        self.target = target
        self.settings = settings
    }

    /// btn:[Apply].
    @discardableResult
    func apply() -> Task<Void, Never> {
        let target = target, settings = settings()
        let previous = previewed
        return Task { @MainActor in
            if let previous { _ = await previous.undo().value }
            guard let editing = target(),
                  let command = CopyGeometry.shadowCommand(editing.selectedNodes, offset: settings.offset, settings: settings, document: editing.document) else {
                self.previewed = nil
                return
            }
            _ = await editing.document.perform(command).value
            self.previewed = editing.document
        }
    }

    /// btn:[Cancel]: the preview is undone.
    @discardableResult
    func cancel() -> Task<Void, Never>? {
        guard let previous = previewed else { return nil }
        previewed = nil
        return Task { @MainActor in _ = await previous.undo().value }
    }

    /// btn:[OK]: the preview stays.
    func keep() {
        previewed = nil
    }
}

/// The Shadow tool's options: its preference rows with btn:[Apply], btn:[Cancel] and btn:[OK].
struct ShadowOptionsSheet: View {
    let store: PreferenceStore
    let preview: ShadowPreview
    let dismiss: @MainActor () -> Void

    static func cancelling(_ preview: ShadowPreview, dismiss: @escaping @MainActor () -> Void) -> () -> Void {
        {
            preview.cancel()
            dismiss()
        }
    }

    /// The sheet's preference rows.
    static var rows: [PreferenceFormRow] {
        [DistortPreferences.shadowType, DistortPreferences.shadowFill].map { PreferenceFormRow(key: $0.erased) }
            + [DistortPreferences.shadowPercent, DistortPreferences.shadowSoftEdge, DistortPreferences.shadowScale, DistortPreferences.shadowOffsetX,
               DistortPreferences.shadowOffsetY].map { PreferenceFormRow(key: $0.erased) }
            + [DistortPreferences.shadowColor, DistortPreferences.shadowFadeTo, DistortPreferences.shadowZoomStroke, DistortPreferences.shadowZoomFill]
            .map { PreferenceFormRow(key: $0.erased) }
    }

    static func applying(_ preview: ShadowPreview) -> () -> Void {
        { preview.apply() }
    }

    static func confirming(_ preview: ShadowPreview, dismiss: @escaping @MainActor () -> Void) -> () -> Void {
        {
            preview.keep()
            dismiss()
        }
    }

    var body: some View {
        let bindings = PreferenceBindings(store: store)
        VStack(alignment: .leading, spacing: 12) {
            Text("Shadow Options").font(.headline)
            Form {
                ForEach(Self.rows) { row in
                    PreferenceRowView(row: row, bindings: bindings)
                }
            }
            HStack {
                Button("Apply", action: Self.applying(preview)).accessibilityIdentifier("shadow-options.apply")
                Spacer()
                Button("Cancel", action: Self.cancelling(preview, dismiss: dismiss)).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.confirming(preview, dismiss: dismiss)).keyboardShortcut(.defaultAction).accessibilityIdentifier("shadow-options.ok")
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
