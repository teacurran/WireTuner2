import AppKit
import Observation
import SwiftUI
import WTModel
import WTRender

/// The 64 built-in 8 × 8 patterns (stroke-attributes.adoc, "Pattern strokes"): application
/// resources, not document data -- a stroke or fill copies the one clicked into its own
/// `bitmap`.  Each is eight hex bytes, one per row, the most significant bit the left pixel.
enum PatternPresets {
    static let count = 64

    /// The presets from the bundle's `PatternPresets.json`.
    static let all: [[UInt8]] = load(Bundle.main.url(forResource: "PatternPresets", withExtension: "json"))

    /// The presets in the file at `url`; a checkerboard when it is missing or malformed, so the
    /// palette is never empty.
    static func load(_ url: URL?) -> [[UInt8]] {
        guard let url, let data = try? Data(contentsOf: url), let strings = try? JSONDecoder().decode([String].self, from: data) else {
            return [PatternBitmap.checker.rows]
        }
        let bitmaps = strings.compactMap(bitmap)
        return bitmaps.isEmpty ? [PatternBitmap.checker.rows] : bitmaps
    }

    /// Sixteen hex digits as eight rows.
    static func bitmap(_ hex: String) -> [UInt8]? {
        let digits = Array(hex)
        guard digits.count == 16 else { return nil }
        let rows = stride(from: 0, to: 16, by: 2).compactMap { UInt8(String(digits[$0...$0 + 1]), radix: 16) }
        return rows.count == 8 ? rows : nil
    }
}

/// The shared pattern editor's state and edits (ATTR-013): the 8 × 8 grid, a drag that paints
/// every pixel it crosses with the value the first one toggled to, btn:[Clear], btn:[Invert] and
/// the preset palette.  During a drag the grid shows the drag's own picture; a remote change of the
/// bitmap lands underneath and the grid shows the document again at mouse-up, when the drag's
/// picture is written as one change (the later whole bitmap wins, stroke-attributes.adoc).
@MainActor
@Observable
final class PatternEditorState {
    /// The picture being dragged, nil when no drag is in progress.
    private(set) var drawing: [UInt8]?
    private var paintValue = true
    /// The first preset the palette shows (the slider).
    var paletteOffset = 0

    init() {}

    /// Eight painted-or-clear rows, row 0 at the top.
    static func isPainted(_ rows: [UInt8], x: Int, y: Int) -> Bool {
        rows.indices.contains(y) && rows[y] & (0x80 >> UInt8(x)) != 0
    }

    static func setting(_ rows: [UInt8], x: Int, y: Int, to painted: Bool) -> [UInt8] {
        var rows = normalized(rows)
        let bit: UInt8 = 0x80 >> UInt8(x)
        rows[y] = painted ? rows[y] | bit : rows[y] & ~bit
        return rows
    }

    /// Eight rows, padding or truncating what a register held.
    static func normalized(_ rows: [UInt8]) -> [UInt8] {
        Array((rows + Array(repeating: 0, count: 8)).prefix(8))
    }

    static func cleared() -> [UInt8] { Array(repeating: 0, count: 8) }

    static func inverted(_ rows: [UInt8]) -> [UInt8] { normalized(rows).map { ~$0 } }

    /// What the grid shows: the drag's picture, else the document's.
    func shown(_ document: [UInt8]) -> [UInt8] {
        drawing ?? Self.normalized(document)
    }

    /// Mouse-down on pixel (`x`, `y`): toggles it and starts a drag painting that value.
    func press(x: Int, y: Int, document: [UInt8]) {
        let rows = Self.normalized(document)
        paintValue = !Self.isPainted(rows, x: x, y: y)
        drawing = Self.setting(rows, x: x, y: y, to: paintValue)
    }

    /// The drag crossed pixel (`x`, `y`).
    func drag(x: Int, y: Int) {
        guard let drawing, (0..<8).contains(x), (0..<8).contains(y) else { return }
        self.drawing = Self.setting(drawing, x: x, y: y, to: paintValue)
    }

    /// Mouse-up: the picture to write, and the grid goes back to showing the document.
    func release() -> [UInt8]? {
        defer { drawing = nil }
        return drawing
    }

    /// The palette page: eight presets from `paletteOffset`.
    func page(_ presets: [[UInt8]]) -> [(index: Int, rows: [UInt8])] {
        let start = min(max(paletteOffset, 0), max(presets.count - 8, 0))
        return presets.indices.dropFirst(start).prefix(8).map { ($0, presets[$0]) }
    }
}

/// The grid: an `NSView` with per-pixel hit testing (stroke-attributes.adoc, "Object panel
/// editors").  Clicking toggles a pixel; dragging paints; the edit is written at mouse-up.
final class PatternGridView: NSView {
    var rows: [UInt8] = PatternEditorState.cleared() { didSet { needsDisplay = true } }
    var onPress: (Int, Int) -> Void = { _, _ in }
    var onDrag: (Int, Int) -> Void = { _, _ in }
    var onRelease: () -> Void = {}

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The pixel under `point` (view coordinates), or nil outside the grid.
    func pixel(at point: NSPoint) -> (x: Int, y: Int)? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let x = Int(floor(point.x / bounds.width * 8)), y = Int(floor(point.y / bounds.height * 8))
        return (0..<8).contains(x) && (0..<8).contains(y) ? (x, y) : nil
    }

    override func mouseDown(with event: NSEvent) {
        if let pixel = pixel(at: convert(event.locationInWindow, from: nil)) { onPress(pixel.x, pixel.y) }
    }

    override func mouseDragged(with event: NSEvent) {
        if let pixel = pixel(at: convert(event.locationInWindow, from: nil)) { onDrag(pixel.x, pixel.y) }
    }

    override func mouseUp(with event: NSEvent) {
        onRelease()
    }

    override func draw(_ dirtyRect: NSRect) {
        let cell = NSSize(width: bounds.width / 8, height: bounds.height / 8)
        NSColor.white.setFill()
        bounds.fill()
        NSColor.black.setFill()
        for y in 0..<8 {
            for x in 0..<8 where PatternEditorState.isPainted(rows, x: x, y: y) {
                NSRect(x: CGFloat(x) * cell.width, y: CGFloat(y) * cell.height, width: cell.width, height: cell.height).fill()
            }
        }
        NSColor.separatorColor.setStroke()
        for index in 0...8 {
            NSBezierPath.strokeLine(from: NSPoint(x: CGFloat(index) * cell.width, y: 0), to: NSPoint(x: CGFloat(index) * cell.width, y: bounds.height))
            NSBezierPath.strokeLine(from: NSPoint(x: 0, y: CGFloat(index) * cell.height), to: NSPoint(x: bounds.width, y: CGFloat(index) * cell.height))
        }
    }
}

/// Hosts `PatternGridView` in SwiftUI.
struct PatternGrid: NSViewRepresentable {
    let rows: [UInt8]
    let state: PatternEditorState
    let document: [UInt8]
    let commit: ([UInt8]) -> Void

    func makeNSView(context: Context) -> PatternGridView {
        let view = PatternGridView()
        view.setAccessibilityIdentifier("pattern.grid")
        view.setAccessibilityRole(.image)
        Self.wire(view, state: state, document: document, commit: commit)
        return view
    }

    func updateNSView(_ view: PatternGridView, context: Context) {
        Self.wire(view, state: state, document: document, commit: commit)
        view.rows = rows
    }

    /// Connects the view's gestures to the editor state.
    static func wire(_ view: PatternGridView, state: PatternEditorState, document: [UInt8], commit: @escaping ([UInt8]) -> Void) {
        view.onPress = { [weak view] x, y in
            state.press(x: x, y: y, document: document)
            view?.rows = state.shown(document)
        }
        view.onDrag = { [weak view] x, y in
            state.drag(x: x, y: y)
            view?.rows = state.shown(document)
        }
        view.onRelease = {
            if let rows = state.release() { commit(rows) }
        }
    }
}

/// The pattern editor shared by the Pattern stroke and Pattern fill editors: the grid, a live
/// preview in the attribute's colour, btn:[Clear], btn:[Invert] and the scrolling palette.
struct PatternEditorView: View {
    /// The document's bitmap (the first target's when they differ).
    let bitmap: [UInt8]
    let color: RenderColor
    let state: PatternEditorState
    var presets: [[UInt8]] = PatternPresets.all
    let commit: ([UInt8]) -> Void

    static func preview(_ rows: [UInt8], color: RenderColor) -> CGImage? {
        AttributePreview.fill(FillPaint(paint: .pattern(PatternPaint(bitmap: PatternBitmap(rows: rows), color: color))), size: Size(width: 64, height: 64))
    }

    static func offset(_ state: PatternEditorState, count: Int) -> Binding<Double> {
        Binding(get: { Double(state.paletteOffset) }, set: { state.paletteOffset = min(max(Int($0.rounded()), 0), max(count - 8, 0)) })
    }

    var body: some View {
        let shown = state.shown(bitmap)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                PatternGrid(rows: shown, state: state, document: bitmap, commit: commit)
                    .frame(width: 96, height: 96)
                AttributePreviewImage(image: Self.preview(shown, color: color), size: Size(width: 64, height: 64), identifier: "pattern.preview")
                VStack {
                    Button("Clear") { commit(PatternEditorState.cleared()) }.accessibilityIdentifier("pattern.clear")
                    Button("Invert") { commit(PatternEditorState.inverted(bitmap)) }.accessibilityIdentifier("pattern.invert")
                }
            }
            HStack(spacing: 2) {
                ForEach(state.page(presets), id: \.index) { preset in
                    Button { commit(preset.rows) } label: {
                        AttributePreviewImage(image: Self.preview(preset.rows, color: .black), size: Size(width: 20, height: 20),
                                              identifier: "pattern.preset.\(preset.index)")
                    }
                    .buttonStyle(.plain)
                }
            }
            Slider(value: Self.offset(state, count: presets.count), in: 0...Double(max(presets.count - 8, 1)), step: 1) { Text("Patterns") }
                .accessibilityIdentifier("pattern.palette")
        }
    }
}
