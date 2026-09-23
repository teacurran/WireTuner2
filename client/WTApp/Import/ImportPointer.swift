import AppKit
import WTGeometry
import WTModel
import WTRender

/// What the import pointer decides (importing.adoc, "Importing with the Import command"; IMG-005):
/// the files still to place, the counter, and where a click or a drag puts the next one.  Pure;
/// `ImportPointerTool` feeds it events.
struct ImportPointer {
    /// A press that moves less than this many view points before release is a click.
    static let clickTolerance = 3.0

    let files: [URL]
    /// The index of the next file to place.
    private(set) var index = 0
    /// The pointer, pasteboard space; nil until it has moved over the canvas.
    var pointer: Point?
    /// The press of a drag in progress: pasteboard and view points.
    private(set) var press: (pasteboard: Point, view: Point)?
    var modifiers: KeyModifiers = []

    init(files: [URL]) {
        self.files = files
    }

    /// The file the next click or drag places; nil once every file is placed.
    var next: URL? { files.indices.contains(index) ? files[index] : nil }

    /// The files after the next one.
    var remaining: [URL] { Array(files.dropFirst(index)) }

    var isFinished: Bool { next == nil }

    /// "2 of 5" while several files are being placed; nil for one.
    var counter: String? {
        guard files.count > 1, !isFinished else { return nil }
        return "\(index + 1) of \(files.count)"
    }

    /// What the pointer shows beside it: the counter and the next file's name.
    var label: String {
        guard let next else { return "" }
        return [counter, next.lastPathComponent].compactMap { $0 }.joined(separator: "  ")
    }

    var isDragging: Bool { press != nil }

    mutating func begin(at pasteboard: Point, view: Point, modifiers: KeyModifiers) {
        press = (pasteboard, view)
        pointer = pasteboard
        self.modifiers = modifiers
    }

    /// The marquee, pasteboard space: from the press to the pointer, or with kbd:[Option] centred
    /// on the press.
    var marquee: Rect? {
        guard let press, let pointer else { return nil }
        return Self.marquee(from: press.pasteboard, to: pointer, fromCenter: modifiers.contains(.option))
    }

    static func marquee(from start: Point, to end: Point, fromCenter: Bool) -> Rect {
        let dx = abs(end.x - start.x), dy = abs(end.y - start.y)
        if fromCenter { return Rect(x: start.x - dx, y: start.y - dy, width: dx * 2, height: dy * 2) }
        return Rect(x: min(start.x, end.x), y: min(start.y, end.y), width: dx, height: dy)
    }

    /// The release at `pasteboard` (`view` in view points): where the next file goes -- its
    /// top-left corner at the press for a click, fitted to the marquee for a drag (kbd:[Shift]
    /// filling its width) -- and the file.  Nil when nothing is pressed or every file is placed.
    mutating func release(at pasteboard: Point, view: Point) -> (file: URL, placement: ImportPlacement)? {
        pointer = pasteboard
        defer { press = nil }
        guard let press, let next else { return nil }
        index += 1
        let moved = hypot(view.x - press.view.x, view.y - press.view.y)
        guard moved >= Self.clickTolerance, let marquee, marquee.width > 0, marquee.height > 0 else { return (next, .at(press.pasteboard)) }
        return (next, .fit(marquee, fillWidth: modifiers.contains(.shift)))
    }

    /// kbd:[Return]: every file left, to be stacked from the pointer (the caller's `fallback`
    /// when it has not been over the canvas).
    mutating func takeRemaining() -> [URL] {
        defer {
            index = files.count
            press = nil
        }
        return remaining
    }

    /// kbd:[Esc]: the files not placed are dropped.
    mutating func stop() {
        index = files.count
        press = nil
    }
}

/// The import pointer (importing.adoc; client.adoc, "Tools": a `Tool` pushed temporarily): a
/// corner bracket where the artwork's top-left corner lands, the counter and the next file's
/// name; click to place at natural size, drag a marquee to fit (kbd:[Shift] fills its width,
/// kbd:[Option] draws it from the centre), kbd:[Return] places every remaining file stacked from
/// the pointer, kbd:[Esc] stops.  It pops itself after the last file.
@MainActor
final class ImportPointerTool: Tool, PointerTracking {
    static let id: ToolID = "import"
    static let statusMessage = "Click to place at natural size, or drag to fit; Shift fills the width, Option draws from the centre; Return places the rest; Esc cancels"
    /// The bracket's arm length, view points.
    static let bracket = 12.0

    /// Places one file: the controller's single-file placement.
    typealias Place = @MainActor (URL, ImportPlacement) async -> Void
    /// Places several files stacked from a point (kbd:[Return]).
    typealias PlaceAll = @MainActor ([URL], Point) async -> Void

    private(set) var pointer: ImportPointer
    private let place: Place
    private let placeAll: PlaceAll
    /// Called once when the tool is done (the last file placed, kbd:[Return], kbd:[Esc]); the
    /// controller pops it.
    var onFinish: (@MainActor (ImportPointerTool) -> Void)?
    private var context: ToolContext?
    private var finished = false
    /// The placement in flight (tests await it).
    private(set) var placing: Task<Void, Never>?

    init(files: [URL], place: @escaping Place, placeAll: @escaping PlaceAll) {
        pointer = ImportPointer(files: files)
        self.place = place
        self.placeAll = placeAll
    }

    var cursor: NSCursor { .crosshair }
    var hasSomethingToCancel: Bool { !finished }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.statusMessage)
    }

    func deactivate() {
        context = nil
    }

    func pointerMoved(_ e: CanvasEvent) {
        pointer.pointer = e.pasteboardPoint
        pointer.modifiers = e.modifiers
        context?.host.setNeedsOverlayDisplay()
    }

    func mouseDown(_ e: CanvasEvent) {
        pointer.begin(at: e.pasteboardPoint, view: e.viewPoint, modifiers: e.modifiers)
    }

    func mouseDragged(_ e: CanvasEvent) {
        pointer.pointer = e.pasteboardPoint
        pointer.modifiers = e.modifiers
    }

    func mouseUp(_ e: CanvasEvent) {
        pointer.modifiers = e.modifiers
        guard let (file, placement) = pointer.release(at: e.pasteboardPoint, view: e.viewPoint) else { return }
        let previous = placing
        placing = Task { [place] in
            await previous?.value
            await place(file, placement)
        }
        if pointer.isFinished { finish() }
    }

    func flagsChanged(_ e: CanvasEvent) {
        pointer.modifiers = e.modifiers
    }

    /// kbd:[Return] (or kbd:[Enter]) places the rest; other keys go on to the shortcuts.
    func keyDown(_ e: NSEvent) -> Bool {
        guard e.keyCode == 36 || e.keyCode == 76 else { return false }
        placeRemaining()
        return true
    }

    /// Every remaining file at natural size, stacked from the pointer (the view's centre when the
    /// pointer has not been over the canvas).
    func placeRemaining() {
        let origin = pointer.pointer ?? context.map { $0.viewport.toPasteboard($0.viewport.viewCenter) } ?? .zero
        let files = pointer.takeRemaining()
        let previous = placing
        placing = Task { [placeAll] in
            await previous?.value
            await placeAll(files, origin)
        }
        finish()
    }

    /// kbd:[Esc]: the files not placed yet are dropped.
    func cancel() {
        pointer.stop()
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish?(self)
    }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        let color = NSColor.controlAccentColor.cgColor
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1)
        if let marquee = pointer.marquee {
            let corners = [Point(x: marquee.minX, y: marquee.minY), Point(x: marquee.maxX, y: marquee.minY),
                           Point(x: marquee.maxX, y: marquee.maxY), Point(x: marquee.minX, y: marquee.maxY)].map { viewport.toView($0).cgPoint }
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.addLines(between: corners + [corners[0]])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        guard let at = pointer.pointer.map(viewport.toView), !pointer.isFinished else { return }
        // The corner bracket: the top-left corner of where the artwork lands.
        ctx.move(to: CGPoint(x: at.x, y: at.y + Self.bracket))
        ctx.addLine(to: CGPoint(x: at.x, y: at.y))
        ctx.addLine(to: CGPoint(x: at.x + Self.bracket, y: at.y))
        ctx.strokePath()
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: at.x + Self.bracket + 4, y: at.y + Self.bracket + 10)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: pointer.label, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor,
        ])), ctx)
        ctx.restoreGState()
    }
}
