import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The text ruler (tabs-indents.adoc, "The text ruler"; TYPE-023): an `NSView` over the canvas
/// placed along the top of the Text tool's block and turned with it.  From the left: the tab well
/// with the five kinds, then the ruler with its point readout, the default ticks, the stops and the
/// indent markers.  Drags write one change at mouse-up.
@MainActor
final class TextRulerView: NSView {
    /// The well's width, view points: five slots.
    static let slot = 14.0
    static var wellWidth: Double { slot * Double(TextRulerModel.wellKinds.count) + 4 }

    /// What a drag holds.
    enum Grab: Equatable {
        case well(Wiretuner_Doc_V1_TabKind)
        case stop(Double)
        case indent(TextRulerModel.Indent)
    }

    var model: (any TextRulerSource)? {
        didSet { needsDisplay = true }
    }
    /// Where the commands go (the window's object editing).
    var perform: @MainActor (any WTModel.Command) -> Void = { _ in }
    /// Tracks the drag (the canvas draws the tracking line from it).
    var onTrack: @MainActor (Double?) -> Void = { _ in }
    /// A double-click on the ruler at a position (ruler points): the Edit Tab sheet (TYPE-024).
    var onDoubleClick: (@MainActor (Double) -> Void)?
    private(set) var grab: Grab?
    private var grabStart = NSPoint.zero
    /// The drag's current point, local.
    private(set) var dragPoint: NSPoint?

    override var isFlipped: Bool { false }

    /// Places the ruler along the block in `canvas` (its bounds origin is the ruler's zero, minus
    /// the well).
    func place(in canvas: NSView) {
        guard let model = model as? TextRulerModel else { return }
        let zero = model.origin
        let height = Double(canvas.bounds.height)
        // View points are y down; AppKit's y up.
        let angle = -model.angle
        let length = model.width * model.scale
        let wellWidth = Self.wellWidth
        let start = NSPoint(x: zero.x - wellWidth * cos(angle), y: height - zero.y - wellWidth * sin(angle))
        frameRotation = 0
        setFrameSize(NSSize(width: wellWidth + length + 8, height: TextRulerModel.height))
        setFrameOrigin(start)
        setBoundsOrigin(NSPoint(x: -wellWidth, y: 0))
        frameRotation = angle * 180 / .pi
        needsDisplay = true
    }

    // MARK: Hit testing

    /// What a press at `point` (local) grabs.
    func grab(at point: NSPoint) -> Grab? {
        guard let model else { return nil }
        let x = Double(point.x)
        if x < 0 {
            let index = Int((x + Self.wellWidth) / Self.slot)
            return TextRulerModel.wellKinds.indices.contains(index) ? .well(TextRulerModel.wellKinds[index]) : nil
        }
        let scale = model.scale
        let lower = Double(point.y) < TextRulerModel.height / 2
        if lower {
            if abs(x - model.leftIndent * scale) <= 5 { return Double(point.y) < 4 ? .indent(.both) : .indent(.left) }
            if abs(x - model.rightIndent * scale) <= 5 { return .indent(.right) }
        } else if abs(x - model.firstLine * scale) <= 5 {
            return .indent(.firstLine)
        }
        if let stop = model.stops.first(where: { abs(x - $0.stop.position * scale) <= 5 }) { return .stop(stop.stop.position) }
        return nil
    }

    // MARK: Gestures

    func begin(at point: NSPoint) {
        grab = grab(at: point)
        grabStart = point
        dragPoint = point
        track()
    }

    func drag(to point: NSPoint) {
        guard grab != nil else { return }
        dragPoint = point
        track()
        needsDisplay = true
    }

    /// Mouse-up at `point`: the gesture's command, performed.
    @discardableResult
    func end(at point: NSPoint, duplicate: Bool = false) -> (any WTModel.Command)? {
        defer {
            grab = nil
            dragPoint = nil
            onTrack(nil)
            needsDisplay = true
        }
        guard let model, let grab else { return nil }
        let x = model.position(Double(point.x))
        let off = abs(Double(point.y) - TextRulerModel.height / 2) > TextRulerModel.removeDistance
        let command: (any WTModel.Command)?
        switch grab {
        case .well(let kind): command = off ? nil : model.place(kind, at: x)
        case .stop(let position): command = model.dragStop(from: position, to: x, offRuler: off, duplicate: duplicate)
        case .indent(let indent): command = model.dragIndent(indent, by: model.position(Double(point.x - grabStart.x)))
        }
        if let command { perform(command) }
        return command
    }

    private func track() {
        guard let model, let dragPoint, grab != nil else { return onTrack(nil) }
        onTrack(model.position(Double(dragPoint.x)))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, doubleClick(at: point) { return }
        begin(at: point)
    }

    /// A double-click at `point` (local) past the tab well; answers whether it was taken.
    @discardableResult
    func doubleClick(at point: NSPoint) -> Bool {
        guard let model, let onDoubleClick, point.x >= 0 else { return false }
        onDoubleClick(model.position(Double(point.x)))
        return true
    }
    override func mouseDragged(with event: NSEvent) { drag(to: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        end(at: convert(event.locationInWindow, from: nil), duplicate: event.modifierFlags.contains(.option))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let scale = model.scale
        let height = TextRulerModel.height
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        // The well.
        for (index, kind) in TextRulerModel.wellKinds.enumerated() {
            let x = -Self.wellWidth + Double(index) * Self.slot + 2
            Self.stopGlyph(kind, at: NSPoint(x: x + Self.slot / 2, y: height / 2)).fill()
        }
        // Point readout and default ticks.
        let label = NSAttributedString(string: "\(Int(model.width.rounded())) pt", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.secondaryLabelColor])
        label.draw(at: NSPoint(x: model.width * scale - label.size().width - 2, y: height - 10))
        NSColor.tertiaryLabelColor.setFill()
        for tick in model.defaultTicks { NSRect(x: tick * scale, y: height - 4, width: 1, height: 3).fill() }
        // Stops (the one being dragged at the pointer).
        NSColor.labelColor.setFill()
        for stop in model.stops {
            var x = stop.stop.position * scale
            if case .stop(let grabbed)? = grab, abs(grabbed - stop.stop.position) < TextTabs.tolerance, let dragPoint { x = Double(dragPoint.x) }
            Self.stopGlyph(stop.stop.kind, at: NSPoint(x: x, y: height / 2)).fill()
        }
        // Indent markers.
        NSColor.controlAccentColor.setFill()
        Self.triangle(at: model.firstLine * scale, pointingDown: true, height: height).fill()
        Self.triangle(at: model.leftIndent * scale, pointingDown: false, height: height).fill()
        NSRect(x: model.leftIndent * scale - 3, y: 0, width: 6, height: 3).fill()
        Self.triangle(at: model.rightIndent * scale, pointingDown: false, height: height).fill()
    }

    /// A tab kind's glyph: an L for left, a mirrored L for right, a T for centre, a T with a dot
    /// for decimal and a bar for wrapping.
    static func stopGlyph(_ kind: Wiretuner_Doc_V1_TabKind, at point: NSPoint) -> NSBezierPath {
        let path = NSBezierPath()
        let x = point.x, y = point.y
        switch kind {
        case .right:
            path.appendRect(NSRect(x: x - 1, y: y - 4, width: 2, height: 8))
            path.appendRect(NSRect(x: x - 5, y: y - 4, width: 5, height: 2))
        case .center:
            path.appendRect(NSRect(x: x - 1, y: y - 4, width: 2, height: 8))
            path.appendRect(NSRect(x: x - 4, y: y - 4, width: 8, height: 2))
        case .decimal:
            path.appendRect(NSRect(x: x - 1, y: y - 4, width: 2, height: 8))
            path.appendRect(NSRect(x: x - 4, y: y - 4, width: 8, height: 2))
            path.appendOval(in: NSRect(x: x + 2, y: y, width: 2, height: 2))
        case .wrapping:
            path.appendRect(NSRect(x: x - 1, y: y - 5, width: 2, height: 10))
            path.appendRect(NSRect(x: x - 4, y: y + 3, width: 8, height: 2))
        default:
            path.appendRect(NSRect(x: x - 1, y: y - 4, width: 2, height: 8))
            path.appendRect(NSRect(x: x, y: y - 4, width: 5, height: 2))
        }
        return path
    }

    static func triangle(at x: Double, pointingDown: Bool, height: Double) -> NSBezierPath {
        let path = NSBezierPath()
        if pointingDown {
            path.move(to: NSPoint(x: x - 4, y: height))
            path.line(to: NSPoint(x: x + 4, y: height))
            path.line(to: NSPoint(x: x, y: height - 6))
        } else {
            path.move(to: NSPoint(x: x - 4, y: 3))
            path.line(to: NSPoint(x: x + 4, y: 3))
            path.line(to: NSPoint(x: x, y: 9))
        }
        path.close()
        return path
    }
}

/// One window's text ruler: shown above the Text tool's block while menu:View[Text Rulers] is on,
/// kept in place on every overlay draw, and the tracking line drawn while a stop is dragged (with
/// *Track tab movement with vertical line*).
@MainActor
final class TextRulers {
    static let shownKey = "WTTextRulersShown"

    /// Weak: the ruler can outlive a closed window by a queued overlay update.
    weak var window: DocumentWindowController?
    let view = TextRulerView()
    let defaults: UserDefaults
    /// *Track tab movement with vertical line*.
    var tracksLine: @MainActor () -> Bool = { true }
    private(set) var tracking: Double?

    init(window: DocumentWindowController, defaults: UserDefaults) {
        self.window = window
        self.defaults = defaults
        view.isHidden = true
        view.setAccessibilityIdentifier("textRuler")
        view.perform = { [weak window] command in _ = window?.objectEditing.perform(command) }
        view.onTrack = { [weak self] position in
            self?.tracking = position
            self?.window?.canvas.setNeedsOverlayDisplay()
        }
    }

    /// menu:View[Text Rulers].
    var isShown: Bool {
        get { defaults.object(forKey: Self.shownKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.shownKey) }
    }

    /// Shows, hides and places the ruler for the Text tool's session.
    func update() {
        guard isShown, let window, let session = window.objectEditing.textSession, session.node != nil, session.isLive, window.canvas.toolManager?.textInput != nil else {
            view.isHidden = true
            view.model = nil
            return
        }
        if view.superview !== window.canvas { window.canvas.addSubview(view) }
        view.model = TextRulerModel(session: session, viewport: window.viewport)
        view.place(in: window.canvas)
        view.isHidden = false
    }

    /// The tracking line down the block (canvas overlay, view points).
    func drawTracking(in ctx: CGContext, viewport: Viewport) {
        guard let position = tracking, tracksLine(), let model = view.model as? TextRulerModel, let session = window?.objectEditing.textSession else { return }
        let x = position + model.inset.left
        let toView = session.toPasteboard.concatenating(viewport.pasteboardToView)
        let top = toView.apply(Point(x: x, y: 0))
        let bottom = toView.apply(Point(x: x, y: session.localFrame.height))
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.move(to: top.cgPoint)
        ctx.addLine(to: bottom.cgPoint)
        ctx.strokePath()
        ctx.restoreGState()
    }
}
