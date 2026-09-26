import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// What the Eyedropper lifted (applying-color.adoc, "The Eyedropper tool"; COLOR-012): the colour as
/// the document holds it -- a swatch reference stays one, an unnamed colour keeps its space -- or,
/// where the paint is not a Basic colour (a gradient, a pattern, later a bitmap), the pixel drawn
/// there as an unnamed colour in the default colour space.
struct EyedropperSample: Equatable {
    var ref: Wiretuner_Doc_V1_ColorRef
    /// The colour it shows (the chip, the Mixer); nil for *None*.
    var color: RenderColor?
    /// The swatch's name ("" for an unnamed colour): the drop's label.
    var name: String
}

/// Where the Eyedropper samples: through the window's hit tester, the model's colour registers and,
/// for anything else, the rendered pixel.
@MainActor
enum EyedropperSampling {
    /// The sample under `e`: kbd:[Option] takes the stroke where both are under the pointer.
    static func sample(at e: CanvasEvent, context: ToolContext, defaultSpace: RenderColor.Space) -> EyedropperSample? {
        let document = context.document
        let hits = context.selection.hitTester(viewport: context.viewport, subselect: true).hitTest(viewPoint: e.viewPoint)
        guard let hit = hits.first(where: { document.selectionID(atItemPath: $0.itemPath) != nil }),
              let id = document.selectionID(atItemPath: hit.itemPath) else { return nil }
        let state = document.state
        let node = id.opID
        if hit.kind == .text, let text = state.textNode(node) {
            let ref = textFill(text.runs.map(\.values)) ?? ColorResolver.inline(.black)
            return sample(ref, in: state)
        }
        var target = CanvasColorDrop.paint(for: hit.kind, modifiers: [])
        if e.modifiers.contains(.option), !ApplyColor.rows([node], target: .stroke, in: state).isEmpty { target = .stroke }
        if let ref = basicColor(node, target: target, in: state) { return sample(ref, in: state) }
        let color = pixel(at: e.pasteboardPoint, in: document.displayList).converted(to: defaultSpace)
        return EyedropperSample(ref: ColorResolver.inline(color), color: color, name: "")
    }

    /// `ref` with the colour it resolves to and the swatch's name.
    static func sample(_ ref: Wiretuner_Doc_V1_ColorRef, in state: EngineState) -> EyedropperSample {
        let list = SwatchList(state)
        let name = ColorResolver.swatch(of: ref).flatMap { list[$0]?.name } ?? ""
        return EyedropperSample(ref: ref, color: list.resolver.color(ref), name: name)
    }

    /// The colour of the topmost Basic fill or stroke of `node`; nil when it has none.
    static func basicColor(_ node: OpID, target: ColorTarget, in state: EngineState) -> Wiretuner_Doc_V1_ColorRef? {
        ApplyColor.rows([node], target: target, in: state).first.flatMap { row in
            AppearanceEditing.entries(row.node, in: state).first { $0.row == row.row }.flatMap(AttributeFields.color)
        }
    }

    /// The first glyph fill of a text's runs.
    static func textFill(_ runs: [[Wiretuner_Doc_V1_TextMarkValue]]) -> Wiretuner_Doc_V1_ColorRef? {
        for values in runs {
            for value in values { if case .fill(let ref)? = value.value { return ref } }
        }
        return nil
    }

    /// The colour drawn at `point` (pasteboard space) -- over empty pasteboard, the pasteboard's -- in sRGB.
    static func pixel(at point: Point, in displayList: DisplayList) -> RenderColor {
        let viewport = Viewport(scrollOrigin: Point(x: point.x - 0.5, y: point.y - 0.5), size: Size(width: 1, height: 1))
        var bytes = [UInt8](repeating: 0, count: 4)
        if let image = CoreGraphicsRenderer().renderBitmap(displayList, viewport: viewport), let space = CGColorSpace(name: CGColorSpace.sRGB),
           let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let alpha = max(Double(bytes[3]), 1) / 255
        return RenderColor(red: Double(bytes[0]) / 255 / alpha, green: Double(bytes[1]) / 255 / alpha, blue: Double(bytes[2]) / 255 / alpha)
    }
}

/// The Eyedropper tool (COLOR-012): press on a colour to lift it -- the cursor shows its chip --
/// then drag to an object and release to colour it (the canvas drop's kbd:[Shift] / kbd:[Cmd] /
/// kbd:[Option] rules, one change); a click without a drag makes it the current colour and loads it
/// into the Color Mixer.  Sampling writes nothing.
@MainActor
final class EyedropperTool: Tool {
    static let id: ToolID = "eyedropper"
    static let statusMessage = "Click to pick up a color; drag it onto an object to apply it"
    /// View points a press moves before it is a drag.
    static let dragThreshold = 3.0

    /// A click's pick: the current colour and the Mixer.
    let pick: @MainActor (EyedropperSample) -> Void
    let defaultSpace: @MainActor () -> RenderColor.Space
    private var context: ToolContext?
    private(set) var sample: EyedropperSample?
    private(set) var press: CanvasEvent?
    private(set) var current: CanvasEvent?
    private(set) var dropTarget: CanvasColorDrop.Target?

    init(defaultSpace: @escaping @MainActor () -> RenderColor.Space, pick: @escaping @MainActor (EyedropperSample) -> Void) {
        self.defaultSpace = defaultSpace
        self.pick = pick
    }

    var cursor: NSCursor { Self.cursor(for: sample?.color) }

    /// The chip cursor: the eyedropper with a swatch of the lifted colour.
    static func cursor(for color: RenderColor?) -> NSCursor {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)?.draw(in: NSRect(x: 0, y: 8, width: 16, height: 16))
            let chip = NSRect(x: rect.maxX - 10, y: 0, width: 10, height: 10)
            (color.map { NSColor(cgColor: $0.cgColor) ?? .clear } ?? .clear).setFill()
            chip.fill()
            NSColor.black.setStroke()
            NSBezierPath(rect: chip).stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 1, y: 23))
    }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.statusMessage)
    }

    func deactivate() {
        cancel()
        context = nil
    }

    func mouseDown(_ e: CanvasEvent) {
        guard let context else { return }
        // Text attributes (TYPE-031): a click picks them up, an Option-click applies them.
        if TextEyedropper.press(e, context: context) { return }
        sample = EyedropperSampling.sample(at: e, context: context, defaultSpace: defaultSpace())
        guard sample != nil else { return }
        press = e
        current = e
        context.host.toolCursorDidChange()
    }

    /// Whether the press has moved far enough to be a drag.
    var isDragging: Bool {
        guard let press, let current else { return false }
        return press.viewPoint.distance(to: current.viewPoint) >= Self.dragThreshold
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard let context, press != nil else { return }
        current = e
        dropTarget = isDragging ? CanvasColorDrop(document: context.document, selection: context.selection).target(at: e.viewPoint, viewport: context.viewport, modifiers: e.modifiers) : nil
        context.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { cancel() }
        guard let context, let sample else { return }
        guard isDragging else {
            pick(sample)
            return
        }
        guard let target = dropTarget else { return }
        context.commandSink.perform(ApplyColor([target.node], target: target.target, color: sample.ref, name: sample.name))
    }

    func flagsChanged(_ e: CanvasEvent) {
        guard let current else { return }
        mouseDragged(current.with(modifiers: e.modifiers))
    }

    func keyDown(_ e: NSEvent) -> Bool { false }

    /// The drop target's outline (solid for a fill, dashed for a stroke) and the chip at the pointer.
    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let current, isDragging else { return }
        if let target = dropTarget {
            let b = target.bounds
            let corners = [Point(x: b.minX, y: b.minY), Point(x: b.maxX, y: b.minY), Point(x: b.maxX, y: b.maxY), Point(x: b.minX, y: b.maxY)]
                .map { viewport.toView($0).cgPoint }
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(2)
            if target.target == .stroke { ctx.setLineDash(phase: 0, lengths: [5, 3]) }
            ctx.addLines(between: corners + [corners[0]])
            ctx.strokePath()
            ctx.restoreGState()
        }
        let at = viewport.toView(current.pasteboardPoint)
        let chip = CGRect(x: at.x + 8, y: at.y + 8, width: 12, height: 12)
        ctx.setFillColor(sample?.color?.cgColor ?? NSColor.clear.cgColor)
        ctx.fill(chip)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.stroke(chip)
    }

    func cancel() {
        let had = sample != nil
        press = nil
        current = nil
        dropTarget = nil
        sample = nil
        if had { context?.host.toolCursorDidChange() }
    }

    var hasSomethingToCancel: Bool { press != nil }
}
