import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// What the gradient form reads and the commands it performs (gradients.adoc; ATTR-025): *Gradient
/// type*, *Behavior* and *Count* over every selected fill, and the ramp's stop gestures on one
/// object's fill.
@MainActor
struct GradientEditorModel {
    let context: AttributeEditorContext

    static let behaviors: [(Wiretuner_Doc_V1_GradientBehavior, String)] = [
        (.normal, "Normal"), (.repeat, "Repeat"), (.reflect, "Reflect"), (.autoSize, "Auto size"),
    ]

    var pairs: [(node: OpID, row: AppearanceRow)] { context.pairs }

    var type: Wiretuner_Doc_V1_GradientType? { context.shared { GradientReading.normalized($0.fill.settings.gradient).type } }
    var behavior: Wiretuner_Doc_V1_GradientBehavior? { context.shared { GradientReading.normalized($0.fill.settings.gradient).behavior } }
    /// Unset reads 1.
    var count: Double? { context.shared { Double(max($0.fill.settings.gradient.repeatCount, 1)) } }
    /// *Count* applies to Repeat and Reflect.
    var countApplies: Bool { behavior == .repeat || behavior == .reflect }

    func setType(_ type: Wiretuner_Doc_V1_GradientType) -> any WTModel.Command { EditGradient.type(pairs, type) }
    func setBehavior(_ behavior: Wiretuner_Doc_V1_GradientBehavior) -> any WTModel.Command { EditGradient.behavior(pairs, behavior) }
    func setCount(_ count: Double) -> any WTModel.Command { EditGradient.count(pairs, Int(count.rounded())) }

    // MARK: The ramp (one object)

    /// The fill the ramp edits: the one selected object's (the ramp edits one object at a time).
    var target: AttributeTarget? { context.item.targets.count == 1 ? context.item.targets[0] : nil }

    /// The stops in ramp order.
    var stops: [GradientRampStop] {
        guard target != nil, let entry = context.entries.first else { return [] }
        return GradientReading.ramp(entry.fill.settings.gradient)
    }

    /// Whether `stop` is one of the two ends (never removed, and dragged inward it leaves a copy).
    func isEnd(_ stop: OpID) -> Bool {
        let stops = stops
        return stops.first?.id == stop || stops.last?.id == stop
    }

    func move(_ stop: OpID, to offset: Double) -> (any WTModel.Command)? {
        target.map { MoveGradientStop(node: $0.node, row: $0.row, stop: stop, offset: Self.clamp(offset)) }
    }

    func copy(_ stop: OpID, to offset: Double) -> (any WTModel.Command)? {
        target.map { CopyGradientStop(node: $0.node, row: $0.row, stop: stop, offset: Self.clamp(offset)) }
    }

    /// Dragging a stop off the ramp; nil for an end stop or when two stops are left.
    func remove(_ stop: OpID) -> (any WTModel.Command)? {
        guard let target, !isEnd(stop), stops.count > 2 else { return nil }
        return RemoveGradientStop(node: target.node, row: target.row, stop: stop)
    }

    func add(at offset: Double, color: Wiretuner_Doc_V1_ColorRef) -> (any WTModel.Command)? {
        target.map { AddGradientStop(node: $0.node, row: $0.row, offset: Self.clamp(offset), color: color) }
    }

    func recolor(_ stop: OpID, _ color: Wiretuner_Doc_V1_ColorRef) -> (any WTModel.Command)? {
        target.map { RecolorGradientStop(node: $0.node, row: $0.row, stop: stop, color: color) }
    }

    static func clamp(_ offset: Double) -> Double { min(max(offset, 0), 1) }
}

/// The ramp's gestures on a bar `width` wide (gradients.adoc, "The ramp"): a click selects a
/// stop, a drag moves it (kbd:[Cmd]: a copy), a drag off the ramp removes it, a colour dropped
/// on a stop recolours it and anywhere else adds one.  The dragged stop is drawn where the pointer
/// is, whatever a remote change does to the others meanwhile.
@MainActor
final class GradientRampController {
    /// The bar's height and the thumbs' band below it, view points.
    static let barHeight = 18.0
    static let height = 36.0
    static let inset = 8.0
    static let thumbRadius = 7.0
    /// How far above or below the view a drag removes the stop.
    static let removeDistance = 16.0

    struct Drag: Equatable {
        var stop: OpID
        var copy: Bool
        var offset: Double
        var off: Bool
    }

    var model: GradientEditorModel?
    var width = 200.0
    private(set) var drag: Drag?
    private(set) var selected: OpID?
    /// Called when a click selects a stop (the form shows its colour).
    var onSelect: @MainActor (OpID?) -> Void = { _ in }

    init() {}

    func offset(atX x: Double) -> Double {
        GradientEditorModel.clamp((x - Self.inset) / max(width - 2 * Self.inset, 1))
    }

    func x(of offset: Double) -> Double {
        Self.inset + offset * max(width - 2 * Self.inset, 1)
    }

    /// The stops as drawn: the dragged one where the pointer is.
    var shownStops: [GradientRampStop] {
        (model?.stops ?? []).map { stop in
            guard let drag, drag.stop == stop.id, !drag.copy else { return stop }
            var moved = stop
            moved.offset = drag.offset
            return moved
        }
    }

    /// The stop whose thumb is under `x` (the thumbs sit below the bar).
    func stop(atX x: Double, y: Double) -> GradientRampStop? {
        guard y >= Self.barHeight - Self.thumbRadius else { return nil }
        return shownStops.min { abs(self.x(of: $0.offset) - x) < abs(self.x(of: $1.offset) - x) }
            .flatMap { abs(self.x(of: $0.offset) - x) <= Self.thumbRadius ? $0 : nil }
    }

    /// A press: on a thumb it selects the stop and starts dragging it.
    @discardableResult
    func mouseDown(x: Double, y: Double, command: Bool) -> Bool {
        guard let stop = stop(atX: x, y: y) else { return false }
        selected = stop.id
        onSelect(stop.id)
        drag = Drag(stop: stop.id, copy: command, offset: stop.offset, off: false)
        return true
    }

    func mouseDragged(x: Double, y: Double) {
        guard var drag else { return }
        drag.offset = offset(atX: x)
        drag.off = y < -Self.removeDistance || y > Self.height + Self.removeDistance
        self.drag = drag
    }

    /// The release: the command the drag performs, or nil for a click or a refused removal.
    func mouseUp(x: Double, y: Double) -> (any WTModel.Command)? {
        mouseDragged(x: x, y: y)
        defer { drag = nil }
        guard let drag, let model, let original = model.stops.first(where: { $0.id == drag.stop }) else { return nil }
        if drag.off { return drag.copy ? nil : model.remove(drag.stop) }
        guard abs(drag.offset - original.offset) > 1e-9 else { return nil }
        return drag.copy ? model.copy(drag.stop, to: drag.offset) : model.move(drag.stop, to: drag.offset)
    }

    /// A colour dropped at `x`, `y`: onto a thumb it recolours that stop, elsewhere a stop is
    /// added there.
    func drop(_ color: Wiretuner_Doc_V1_ColorRef, x: Double, y: Double) -> (any WTModel.Command)? {
        if let stop = stop(atX: x, y: y) { return model?.recolor(stop.id, color) }
        return model?.add(at: offset(atX: x), color: color)
    }
}

/// The ramp: the bar drawn from the stops, a thumb per stop below it, and the drop target for
/// colours from the Swatches panel.
final class GradientRampView: NSView {
    let controller: GradientRampController
    /// Performs a command the ramp made.
    var perform: @MainActor (any WTModel.Command) -> Void = { _ in }
    /// Reads a dropped colour into a reference in the document (a swatch from another document is
    /// imported first).
    var readColor: @MainActor (NSPasteboard) -> Wiretuner_Doc_V1_ColorRef? = { _ in nil }

    init(controller: GradientRampController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: GradientRampController.height))
        registerForDraggedTypes(ColorDrag.dropTypes.map { NSPasteboard.PasteboardType($0.identifier) })
        setAccessibilityIdentifier("fill.gradient.ramp")
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// A point in the view, y down.
    func local(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) { press(local(event), command: event.modifierFlags.contains(.command)) }
    override func mouseDragged(with event: NSEvent) { move(local(event)) }
    override func mouseUp(with event: NSEvent) { release(local(event)) }

    func press(_ point: CGPoint, command: Bool) {
        controller.width = bounds.width
        controller.mouseDown(x: point.x, y: point.y, command: command)
        needsDisplay = true
    }

    func move(_ point: CGPoint) {
        controller.mouseDragged(x: point.x, y: point.y)
        needsDisplay = true
    }

    func release(_ point: CGPoint) {
        if let command = controller.mouseUp(x: point.x, y: point.y) { perform(command) }
        needsDisplay = true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        drop(sender.draggingPasteboard, at: convert(sender.draggingLocation, from: nil))
    }

    /// A colour drop at `point`: false when the pasteboard holds no colour.
    @discardableResult
    func drop(_ pasteboard: NSPasteboard, at point: CGPoint) -> Bool {
        controller.width = bounds.width
        guard let color = readColor(pasteboard), let command = controller.drop(color, x: point.x, y: point.y) else { return false }
        perform(command)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        controller.width = bounds.width
        Self.draw(controller, in: ctx, width: bounds.width)
    }

    /// The bar and the thumbs.
    static func draw(_ controller: GradientRampController, in ctx: CGContext, width: Double) {
        let stops = controller.shownStops
        let bar = CGRect(x: GradientRampController.inset, y: 2, width: max(width - 2 * GradientRampController.inset, 1), height: GradientRampController.barHeight - 4)
        let colors = stops.map { ColorBridge.cgColor($0.color) ?? CGColor(gray: 1, alpha: 0) } as CFArray
        let locations = stops.map { CGFloat($0.offset) }
        if stops.count >= 2, let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations) {
            ctx.saveGState()
            ctx.clip(to: bar)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: bar.minX, y: 0), end: CGPoint(x: bar.maxX, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
        ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
        ctx.stroke(bar)
        let r = GradientRampController.thumbRadius
        for stop in stops {
            let x = controller.x(of: stop.offset)
            let thumb = CGRect(x: x - r, y: GradientRampController.barHeight, width: 2 * r, height: 2 * r)
            ctx.setFillColor(ColorBridge.cgColor(stop.color) ?? .white)
            ctx.fill(thumb)
            ctx.setStrokeColor(stop.id == controller.selected ? NSColor.controlAccentColor.cgColor : NSColor.labelColor.cgColor)
            ctx.setLineWidth(stop.id == controller.selected ? 2 : 1)
            ctx.stroke(thumb)
        }
    }
}

/// The ramp in SwiftUI.
struct GradientRamp: NSViewRepresentable {
    let model: GradientEditorModel
    let select: @MainActor (OpID?) -> Void

    func makeCoordinator() -> GradientRampController { GradientRampController() }

    func makeNSView(context: Context) -> GradientRampView {
        GradientRampView(controller: context.coordinator)
    }

    func updateNSView(_ view: GradientRampView, context: Context) {
        update(view)
    }

    /// Hands the view the current model and actions.
    func update(_ view: GradientRampView) {
        view.controller.model = model
        view.controller.onSelect = select
        let editing = model.context
        view.perform = { editing.perform($0) }
        view.readColor = { Self.color(from: $0, document: editing.document) }
        view.needsDisplay = true
    }

    /// A colour on the drag pasteboard as a reference usable in `document` (a swatch of another
    /// document is added to this one's swatches first, `ColorDrop`); nil without one.
    static func color(from pasteboard: NSPasteboard, document: DocumentHandle) -> Wiretuner_Doc_V1_ColorRef? {
        guard let payload = ColorDrag.read(from: pasteboard, defaultSpace: .displayP3), !ColorDrop.needsImport(payload, into: document.id) else { return nil }
        return payload.reference(in: document.state, document: document.id)
    }
}

/// The gradient form: *Gradient type*, *Behavior*, *Count*, the ramp and the selected stop's
/// colour.
struct GradientEditorView: View {
    let model: GradientEditorModel
    @State private var stop: OpID?

    init(model: GradientEditorModel, stop: OpID? = nil) {
        self.model = model
        _stop = State(initialValue: stop)
    }

    /// The selected stop's colour control's commit.
    static func recolor(_ stop: OpID, model: GradientEditorModel) -> (Wiretuner_Doc_V1_ColorRef) -> Void {
        { model.context.perform(model.recolor(stop, $0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AttributePicker(title: "Gradient type", value: model.type, choices: AttributeNames.gradientTypes, identifier: "fill.gradient.type",
                            commit: model.context.committing(model.setType))
            AttributePicker(title: "Behavior", value: model.behavior, choices: GradientEditorModel.behaviors, identifier: "fill.gradient.behavior",
                            commit: model.context.committing(model.setBehavior))
            CommitField(title: "Count", value: model.count, identifier: "fill.gradient.count", commit: model.context.committing(model.setCount))
                .disabled(!model.countApplies)
            if model.target == nil {
                Text("The ramp edits one object at a time.").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("fill.gradient.one")
            } else {
                GradientRamp(model: model) { stop = $0 }
                    .frame(height: GradientRampController.height)
                if let stop, let shown = model.stops.first(where: { $0.id == stop }) {
                    AttributeColorControl(title: "Stop color", color: shown.color, identifier: "fill.gradient.stop-color", document: model.context.document,
                                          commit: Self.recolor(stop, model: model))
                }
            }
        }
    }
}
