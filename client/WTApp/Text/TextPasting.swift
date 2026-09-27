import AppKit
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender

/// Text on the pasteboard for the Text tool, Paste and drops (importing-text.adoc, "Pasting",
/// "Dragging text in"; TYPE-009): a WireTuner copy is `TextClip.pasteboardType` beside plain text;
/// reading prefers that clip (every attribute), then RTFD and RTF (through `TextImporter`, the import
/// table), then plain text.  Plain reading (kbd:[Option]-drop) takes the characters alone.
@MainActor
enum TextPasting {
    static let clipType = NSPasteboard.PasteboardType(TextClip.pasteboardType)
    /// What a text drop onto the canvas accepts.
    static let dropTypes: [NSPasteboard.PasteboardType] = [clipType, .rtfd, .rtf, .string]

    /// A copy of text: `string` as plain text and, from a block, `clip` with every attribute.
    static func write(_ string: String, clip: TextClip?, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        if let clip { pasteboard.setData(Data(clip.encoded()), forType: clipType) }
    }

    /// Whether `pasteboard` holds text to paste.
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(clipType) || types.contains(.rtfd) || types.contains(.rtf) { return true }
        return pasteboard.string(forType: .string)?.isEmpty == false
    }

    /// The text on `pasteboard`; with `plain`, its characters only.  Nil when it holds none.
    static func clip(from pasteboard: NSPasteboard, plain: Bool = false) -> TextClip? {
        // Plain: the characters of the richest text (AppKit's string derived from RTF ends in a newline).
        if plain, let rich = clip(from: pasteboard) { return TextClip(plain: rich.string) }
        if !plain {
            if let data = pasteboard.data(forType: clipType), let clip = TextClip(decoding: Array(data)), !clip.isEmpty { return clip }
            for (type, format) in [(NSPasteboard.PasteboardType.rtfd, TextFileFormat.rtfd), (.rtf, .rtf)] {
                if let data = pasteboard.data(forType: type), let file = try? TextImporter.read(data, format: format) {
                    let clip = TextClip(file)
                    if !clip.isEmpty { return clip }
                }
            }
        }
        if let string = pasteboard.string(forType: .string), !string.isEmpty { return TextClip(plain: string) }
        return nil
    }

    /// The text block under `point` (pasteboard) and the boundary nearest it: where dropped text
    /// goes.  Locked blocks are skipped.
    static func target(at point: Point, in document: DocumentHandle) -> (node: OpID, offset: Int)? {
        let state = document.state
        let candidates = document.scene.objects.values.filter { $0.kind == .text && !$0.isEffectivelyLocked }
            .sorted { $0.itemPath.lexicographicallyPrecedes($1.itemPath) }.reversed()
        for object in candidates {
            guard let layout = document.textLayout(for: object.id), let text = state.textNode(object.id),
                  let local = Objects.pasteboardTransform(of: object.id, in: state).inverted()?.apply(point),
                  TextFrames.frame(of: layout).contains(local) else { continue }
            let offset = text.length == 0 ? 0 : min(layout.offset(at: local, inContainer: 0) ?? text.length, text.length)
            return (object.id, offset)
        }
        return nil
    }
}

/// Text dragged onto the canvas from another application (importing-text.adoc, "Dragging text
/// in"): over a text block a caret follows the pointer at the boundary the drop would insert at;
/// dropped there the text is pasted into the block (`PasteText`), on empty space it becomes a new
/// auto-expanding block at the drop point (`PasteTextBlock`), selected.  kbd:[Option] drops plain
/// text.  One change.
@MainActor
final class CanvasTextDrop {
    weak var window: DocumentWindowController?
    /// Where the drop would insert, while a drag is over a block.
    private(set) var caret: (node: OpID, offset: Int)?

    init(window: DocumentWindowController) {
        self.window = window
    }

    /// Whether the drag carries text (and nothing the canvas takes first: files, objects).
    static func carriesText(_ pasteboard: NSPasteboard) -> Bool {
        FileDrop.urls(from: pasteboard).isEmpty && !ObjectDragging.carriesObjects(pasteboard) && TextPasting.canRead(pasteboard)
    }

    /// The drag moved: the caret follows.  False when it carries no text.
    func update(_ pasteboard: NSPasteboard, at viewPoint: Point, viewport: Viewport) -> Bool {
        guard Self.carriesText(pasteboard), let window else { return false }
        caret = TextPasting.target(at: viewport.toPasteboard(viewPoint), in: window.documentHandle)
        return true
    }

    func exit() {
        caret = nil
    }

    /// The drop; nil when the drag carries no text.
    @discardableResult
    func drop(_ pasteboard: NSPasteboard, at viewPoint: Point, viewport: Viewport, plain: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        defer { caret = nil }
        guard Self.carriesText(pasteboard), let window, let clip = TextPasting.clip(from: pasteboard, plain: plain) else { return nil }
        let point = viewport.toPasteboard(viewPoint)
        let document = window.documentHandle
        if let (node, offset) = TextPasting.target(at: point, in: document), let text = document.state.textNode(node) {
            let at = text.anchor(at: offset)
            return window.objectEditing.perform(PasteText(node: node, from: at, to: at, clip: clip))
        }
        let task = window.objectEditing.perform(PasteTextBlock(clip, at: point, layer: window.objectEditing.activeLayer))
        let model = window.selection.model
        return Task { @MainActor in
            let change = await task.value
            if let block = change?.createdObjects.first(where: { document.state.nodeKind($0) == .text }) {
                model.set(Selection([SelectionID(block)]))
            }
            return change
        }
    }

    /// The caret's ends in view points, while a drag is over a block.
    func caretLine(viewport: Viewport) -> (top: Point, bottom: Point)? {
        guard let caret, let window, let layout = window.documentHandle.textLayout(for: caret.node),
              let line = layout.caret(atOffset: caret.offset, upstream: false) else { return nil }
        let toView = Objects.pasteboardTransform(of: caret.node, in: window.documentHandle.state).concatenating(viewport.pasteboardToView)
        return (toView.apply(line.top), toView.apply(line.bottom))
    }

    /// Draws the following caret (an overlay extra).
    func draw(in ctx: CGContext, viewport: Viewport) {
        guard let line = caretLine(viewport: viewport) else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: line.top.x, y: line.top.y))
        ctx.addLine(to: CGPoint(x: line.bottom.x, y: line.bottom.y))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

extension EditFeatures {
    /// Paste of text with nothing being edited: a new auto-expanding block holding the
    /// pasteboard's text at the centre of the view, selected (TYPE-009).  False without text.
    @discardableResult
    func pasteTextBlock(on window: DocumentWindowController, from pasteboard: NSPasteboard) async -> Bool {
        guard let clip = TextPasting.clip(from: pasteboard) else { return false }
        let center = window.objectEditing.visibleCenter() ?? Point(x: 0, y: 0)
        let document = window.documentHandle
        guard let change = await window.objectEditing.perform(PasteTextBlock(clip, at: center, layer: window.objectEditing.activeLayer)).value,
              let block = change.createdObjects.first(where: { document.state.nodeKind($0) == .text }) else { return false }
        window.selection.model.set(Selection([SelectionID(block)]))
        return true
    }
}
