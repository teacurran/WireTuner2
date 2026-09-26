import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Text tool's preferences, read at each use (preferences.adoc, "Text").
struct TextToolSettings: Equatable, Sendable {
    /// *New text containers auto-expand*: a click makes an auto-expanding block; off, a
    /// fixed-size block of `defaultSize`.
    var autoExpand = true
    /// *Text tool reverts to Pointer*.
    var revertsToPointer = true
    /// *Always use Text Editor*: a click into a block opens the Text Editor (TYPE-011).
    var alwaysUseEditor = false

    /// The fixed-size block a click makes with auto-expanding off.
    static let defaultSize = Size(width: 144, height: 72)

    init(autoExpand: Bool = true, revertsToPointer: Bool = true) {
        self.autoExpand = autoExpand
        self.revertsToPointer = revertsToPointer
    }

    @MainActor init(preferences: PreferenceStore) {
        autoExpand = preferences[PreferenceCatalog.Text.autoExpand]
        revertsToPointer = preferences[PreferenceCatalog.Text.toolRevertsToPointer]
        alwaysUseEditor = preferences[PreferenceCatalog.Text.alwaysUseEditor]
    }
}

/// What the canvas's `NSTextInputClient` forwards to the tool that is editing text: committed
/// strings, the input method's marked text, and the key-binding selectors `interpretKeyEvents`
/// produces (creating-text, "Client": dictation, marked text and the Character Viewer work
/// because the canvas is a text input client).
@MainActor
protocol TextInputHandling: AnyObject {
    /// Whether keys go to text: the tool has a block (or a new block's place) to type into.
    var isEditingText: Bool { get }
    func insertText(_ string: String, replacementRange: NSRange?)
    func setMarkedText(_ string: String, selectedRange: NSRange)
    func unmarkText()
    var hasMarkedText: Bool { get }
    var markedRange: NSRange { get }
    var selectedRange: NSRange { get }
    func attributedSubstring(_ range: NSRange) -> (string: NSAttributedString, range: NSRange)?
    /// The insertion point in pasteboard space, for the input method's candidate window.
    var caretRect: Rect? { get }
    /// A key-binding selector (`moveLeft:`); returns whether it was handled.
    @discardableResult
    func doCommand(_ selector: String) -> Bool
}

/// The Text tool (creating-text.adoc, editing-text.adoc; TYPE-003, TYPE-010): a click makes a
/// place for an auto-expanding block, a drag a fixed-size one (kbd:[Shift] square, kbd:[Option]
/// from the centre); a click in a block places the insertion point, a drag selects, a double
/// click selects a word and a triple click a paragraph (dragging after them extends by words or
/// paragraphs), kbd:[Shift]-click extends.  Keys arrive through the canvas's text input client
/// (`TextInputHandling`); the editing itself is `TextEditingSession`.  A click away from the block
/// ends editing -- and with *Text tool reverts to Pointer* hands over to the Pointer -- and kbd:[Esc]
/// ends it and returns to the Pointer with the block selected.  A block is created by its first
/// character, so a block abandoned empty never reaches the document.
@MainActor
final class TextTool: Tool, TextInputHandling {
    static let id: ToolID = "text"
    /// A drag shorter than this (view points) is a click.
    static let dragThreshold = 3.0
    /// How far outside its rectangle a click still lands in the edited block (view points).
    static let hitSlop = 4.0
    static let statusMessage = "Click to type, drag to make a fixed-size text block; click in text to edit it"
    static let editingMessage = "Type to edit; Esc or a click outside the block finishes"

    static var descriptor: ToolDescriptor {
        ToolCatalog.all.first { $0.id == id }!.delivering { TextTool() }
    }

    private enum Gesture {
        /// Dragging out a new block.
        case create
        /// Selecting in the edited block.
        case select
    }

    private var context: ToolContext?
    private(set) var session: TextEditingSession?
    private(set) var start: CanvasEvent?
    private(set) var current: CanvasEvent?
    private var gesture: Gesture?
    private var observation: DocumentHandle.ObservationToken?

    init() {}

    var cursor: NSCursor { .iBeam }
    var isEditingText: Bool { session != nil }
    var hasSomethingToCancel: Bool { session != nil || start != nil }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.statusMessage)
        observation = context.document.observe { [weak self] _ in self?.documentDidChange() }
    }

    func deactivate() {
        endEditing(revert: false)
        if let observation { context?.document.stopObserving(observation) }
        observation = nil
        start = nil
        current = nil
        gesture = nil
        context = nil
    }

    // MARK: Sessions

    /// Starts editing: a new block's place, or `node` with the insertion point at `point`.
    private func begin(_ target: TextEditingSession.Target, at point: Point = .zero, granularity: TextGranularity = .character, context: ToolContext) {
        let session = TextEditingSession(document: context.document, sink: context.commandSink, target: target, layer: context.objectEditing?.activeLayer)
        session.onChange = { [weak self] in self?.sessionDidChange() }
        session.onCreate = { [weak self] node in self?.context?.selection.model.set(Selection([SelectionID(node)])) }
        self.session = session
        context.objectEditing?.textSession = session
        if case .node(let node) = target {
            context.selection.model.set(Selection([SelectionID(node)]))
            session.click(at: point, granularity: granularity, extend: false)
        } else if case .override(let instance, _) = target {
            context.selection.model.set(Selection([SelectionID(instance)]))
            session.click(at: point, granularity: granularity, extend: false)
        } else {
            context.selection.model.clear()
        }
        context.host.showStatusMessage(Self.editingMessage)
        sessionDidChange()
    }

    /// The Pointer's double-click on a text block, or a click in one: editing starts with the
    /// insertion point at `point` (pasteboard).
    func edit(_ node: OpID, at point: Point, granularity: TextGranularity = .character) {
        edit(.node(node), at: point, granularity: granularity)
    }

    /// `edit(_:at:granularity:)` for a block or a text block inside an instance.
    func edit(_ target: TextEditingSession.Target, at point: Point, granularity: TextGranularity = .character) {
        guard let context else { return }
        endEditing(revert: false)
        begin(target, at: point, granularity: granularity, context: context)
    }

    /// Ends editing: the block stays selected (an emptied one is deleted); with `revert` the
    /// Pointer takes over.
    func endEditing(revert: Bool) {
        guard let session, let context else { return }
        self.session = nil
        if context.objectEditing?.textSession === session { context.objectEditing?.textSession = nil }
        let node = session.end()
        context.textCaretChanged(nil)
        context.selection.model.set(node.map { Selection([SelectionID($0)]) } ?? .empty)
        context.host.showStatusMessage(Self.statusMessage)
        context.host.setNeedsOverlayDisplay()
        if revert { context.selectTool(.pointer) }
    }

    private func sessionDidChange() {
        context?.textCaretChanged(session?.presenceCaret)
        context?.host.setNeedsOverlayDisplay()
    }

    private func documentDidChange() {
        guard let session else { return }
        session.documentDidChange()
        // The block was deleted (remotely, or its creation undone): editing ends.
        if !session.isLive { endEditing(revert: false) }
    }

    /// The text block a click at `e` edits: the topmost unlocked block whose rectangle (its laid
    /// out size, grown by the hit slop) holds the point -- so a click between lines or in a
    /// fixed-size block's empty part lands in it too.
    private func textBlock(at e: CanvasEvent, context: ToolContext) -> OpID? {
        if case .node(let node)? = textTarget(at: e, context: context) { return node }
        return nil
    }

    /// What a click at `e` edits: `textBlock(at:context:)`'s rule over the blocks and over the text
    /// blocks inside unlocked instances (library.adoc, "Text tool inside an instance": the resolved
    /// artwork's text blocks through the instance's transform, the topmost block of the topmost
    /// instance winning).
    func textTarget(at e: CanvasEvent, context: ToolContext) -> TextEditingSession.Target? {
        let document = context.document
        let state = document.state
        let slop = Self.hitSlop / max(context.viewport.zoom, 0.0001)
        let point = e.pasteboardPoint
        var hits: [(path: [Int], target: TextEditingSession.Target)] = []
        for object in document.scene.objects.values where !object.isEffectivelyLocked {
            if object.kind == .text {
                guard let layout = document.textLayout(for: object.id),
                      let local = Objects.pasteboardTransform(of: object.id, in: state).inverted()?.apply(point),
                      TextFrames.frame(of: layout).expanded(by: slop).contains(local) else { continue }
                hits.append((object.itemPath, .node(object.id)))
            } else if object.kind == .instance, object.bounds?.expanded(by: slop).contains(point) == true,
                      let artwork = Symbols.resolvedArtwork(of: object.id, in: state) {
                for (index, master) in artwork.textBlocks.enumerated() {
                    guard let text = Symbols.textNode(master, in: object.id, state: state),
                          let local = Symbols.pasteboardTransform(ofMaster: master, in: object.id, state: state)?.inverted()?.apply(point),
                          TextFrames.frame(of: TextEditingSession.layout(text, document: document)).expanded(by: slop).contains(local) else { continue }
                    hits.append((object.itemPath + [index], .override(instance: object.id, master: master)))
                }
            }
        }
        return hits.max { $0.path.lexicographicallyPrecedes($1.path) }?.target
    }

    // MARK: Pointer

    func mouseDown(_ e: CanvasEvent) {
        guard let context else { return }
        if session == nil, let open = context.openTextEditor, e.modifiers.contains(.option) || context.text().alwaysUseEditor {
            // kbd:[Option]-click (or any click with *Always use Text Editor*) opens the Text Editor.
            let node = textBlock(at: e, context: context)
            if node != nil || e.modifiers.contains(.option) {
                open(node, e.pasteboardPoint)
                return
            }
        }
        start = e
        current = e
        gesture = nil
        let slop = Self.hitSlop / max(context.viewport.zoom, 0.0001)
        if let session {
            if session.contains(e.pasteboardPoint, tolerance: slop) {
                gesture = .select
                session.click(at: e.pasteboardPoint, granularity: TextGranularity(clickCount: e.clickCount), extend: e.modifiers.contains(.shift))
                return
            }
            // A click in another block edits it; a click away finishes, and by default the
            // Pointer takes over and the click does nothing more.
            if let target = textTarget(at: e, context: context) {
                edit(target, at: e.pasteboardPoint, granularity: TextGranularity(clickCount: e.clickCount))
                gesture = .select
                return
            }
            let reverts = context.text().revertsToPointer
            endEditing(revert: reverts)
            if reverts {
                start = nil
                return
            }
        }
        if let target = textTarget(at: e, context: context) {
            gesture = .select
            begin(target, at: e.pasteboardPoint, granularity: TextGranularity(clickCount: e.clickCount), context: context)
            return
        }
        gesture = .create
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard start != nil else { return }
        current = e
        if gesture == .select { session?.drag(to: e.pasteboardPoint) }
    }

    func mouseUp(_ e: CanvasEvent) {
        defer {
            start = nil
            current = nil
            gesture = nil
        }
        guard let context, let start, gesture == .create else { return }
        current = e
        if let rect = dragRect(start: start, end: e) {
            begin(.pending(.area(rect)), context: context)
        } else if context.text().autoExpand {
            begin(.pending(.point(start.pasteboardPoint)), context: context)
        } else {
            let size = TextToolSettings.defaultSize
            begin(.pending(.area(Rect(x: start.pasteboardPoint.x, y: start.pasteboardPoint.y, width: size.width, height: size.height))), context: context)
        }
    }

    /// The fixed-size block a drag from `start` to `end` makes (pasteboard): kbd:[Shift] squares
    /// it, kbd:[Option] draws it from its centre; nil for a click.
    func dragRect(start: CanvasEvent, end: CanvasEvent) -> Rect? {
        guard end.viewPoint.distance(to: start.viewPoint) >= Self.dragThreshold else { return nil }
        var dx = end.pasteboardPoint.x - start.pasteboardPoint.x
        var dy = end.pasteboardPoint.y - start.pasteboardPoint.y
        if end.modifiers.contains(.shift) {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        let origin = start.pasteboardPoint
        let rect = end.modifiers.contains(.option)
            ? Rect(x: origin.x - abs(dx), y: origin.y - abs(dy), width: 2 * abs(dx), height: 2 * abs(dy))
            : Rect(origin, Point(x: origin.x + dx, y: origin.y + dy))
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    func flagsChanged(_ e: CanvasEvent) {
        if current != nil { current = current?.with(modifiers: e.modifiers) }
    }

    // MARK: Keys

    func keyDown(_ e: NSEvent) -> Bool {
        guard let session, let context else { return false }
        let flags = e.modifierFlags.intersection([.shift, .control, .option, .command])
        // kbd:[Shift+Return]: an end of line, not a new paragraph (creating-text, "Typing").
        if e.keyCode == TextKeys.returnKeyCode, flags == .shift {
            session.insert("\u{2028}")
            return true
        }
        // Kerning, baseline shift and size nudges (TYPE-019).
        if let nudge = TypeNudge(event: e), let editing = context.objectEditing, TypeNudger.nudger(for: editing).nudge(nudge) { return true }
        if context.host.interpretKeys(e) { return true }
        // Without an input method, kbd:[Esc] drops a composition.
        if e.keyCode == CanvasEventTranslator.escapeKeyCode, session.marked != nil {
            session.setMarkedText("", selected: NSRange(location: 0, length: 0))
            return true
        }
        if let selector = TextKeys.selector(for: e) { return doCommand(selector) }
        guard flags.isDisjoint(with: [.command, .control]), let characters = e.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
        session.insert(characters)
        return true
    }

    func cancel() {
        start = nil
        current = nil
        gesture = nil
        // kbd:[Esc] ends editing and returns to the Pointer with the block selected.
        if session != nil { endEditing(revert: true) }
    }

    // MARK: TextInputHandling

    func insertText(_ string: String, replacementRange: NSRange?) {
        session?.insertCommitted(string, replacing: replacementRange)
    }

    func setMarkedText(_ string: String, selectedRange: NSRange) {
        session?.setMarkedText(string, selected: selectedRange)
    }

    func unmarkText() {
        session?.unmarkText()
    }

    var hasMarkedText: Bool { session?.marked != nil }
    var markedRange: NSRange { session?.markedUTF16Range ?? NSRange(location: NSNotFound, length: 0) }
    var selectedRange: NSRange { session?.selectedUTF16Range ?? NSRange(location: NSNotFound, length: 0) }

    func attributedSubstring(_ range: NSRange) -> (string: NSAttributedString, range: NSRange)? {
        session?.substring(range).map { (NSAttributedString(string: $0.string), $0.range) }
    }

    var caretRect: Rect? {
        guard let session else { return nil }
        if let caret = session.caret { return Rect(caret.top, caret.bottom) }
        return session.selectionQuads.first.map { quad in quad.dropFirst().reduce(Rect(quad[0], quad[0])) { $0.union(Rect($1, $1)) } }
    }

    @discardableResult
    func doCommand(_ selector: String) -> Bool {
        guard let session else { return false }
        if let (move, extend) = TextKeys.moves[selector] {
            session.move(move, extend: extend)
            return true
        }
        switch selector {
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertParagraphSeparator:": session.insert("\n")
        case "insertLineBreak:": session.insert("\u{2028}")
        case "insertTab:", "insertTabIgnoringFieldEditor:": session.insert("\t")
        case "deleteBackward:", "deleteBackwardByDecomposingPreviousCharacter:": session.delete(.backspace)
        case "deleteForward:": session.delete(.forwardDelete)
        case "deleteWordBackward:": session.delete(.deleteWordBackward)
        case "deleteWordForward:": session.delete(.deleteWordForward)
        case "deleteToBeginningOfLine:", "deleteToBeginningOfParagraph:": session.deleteToLineEdge(end: false)
        case "deleteToEndOfLine:", "deleteToEndOfParagraph:": session.deleteToLineEdge(end: true)
        case "selectAll:": session.selectAll()
        case "cancelOperation:": cancel()
        default: return false
        }
        return true
    }

    // MARK: Overlay

    /// The edited block's outline, the selection, the insertion point and the composition; the
    /// rectangle while a new block is dragged out.
    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let toView = viewport.pasteboardToView
        if gesture == .create, let start, let current, let rect = dragRect(start: start, end: current) {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.addPath(Self.polygon([Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY), Point(x: rect.maxX, y: rect.maxY),
                                      Point(x: rect.minX, y: rect.maxY)].map { toView.apply($0) }))
            ctx.strokePath()
        }
        guard let session else { return }
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(0.5)
        ctx.setLineDash(phase: 0, lengths: [2, 2])
        ctx.addPath(Self.polygon(session.frameCorners.map { toView.apply($0) }))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.6).cgColor)
        for quad in session.marked == nil ? session.selectionQuads : [] {
            ctx.addPath(Self.polygon(quad.map { toView.apply($0) }))
            ctx.fillPath()
        }
        if let marked = session.marked, let baseline = session.caretBaseline {
            Self.drawMarked(marked.text, at: toView.apply(baseline), zoom: viewport.zoom, in: ctx)
        } else if let caret = session.caret {
            ctx.setStrokeColor(NSColor.textColor.cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: toView.apply(caret.top).cgPoint)
            ctx.addLine(to: toView.apply(caret.bottom).cgPoint)
            ctx.strokePath()
        }
    }

    static func polygon(_ points: [Point]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map(\.cgPoint))
        path.closeSubpath()
        return path
    }

    /// The composition, underlined, at the insertion point (view space, y down).
    static func drawMarked(_ text: String, at baseline: Point, zoom: Double, in ctx: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 12 * zoom, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor]))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = baseline.cgPoint
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.setStrokeColor(NSColor.textColor.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: baseline.x, y: baseline.y + 2))
        ctx.addLine(to: CGPoint(x: baseline.x + width, y: baseline.y + 2))
        ctx.strokePath()
    }
}

/// The key bindings the tool falls back to when the host has no input context (the text system
/// normally turns keys into these selectors through `interpretKeyEvents`), and the selectors'
/// movements.
enum TextKeys {
    static let returnKeyCode: UInt16 = 36

    /// Each movement selector: the move and whether it extends the selection.
    static let moves: [String: (TextMove, Bool)] = {
        let plain: [(String, TextMove)] = [
            ("moveLeft:", .left), ("moveBackward:", .left), ("moveRight:", .right), ("moveForward:", .right),
            ("moveWordLeft:", .wordLeft), ("moveWordBackward:", .wordLeft), ("moveWordRight:", .wordRight), ("moveWordForward:", .wordRight),
            ("moveToBeginningOfLine:", .lineStart), ("moveToLeftEndOfLine:", .lineStart),
            ("moveToEndOfLine:", .lineEnd), ("moveToRightEndOfLine:", .lineEnd),
            ("moveUp:", .up), ("moveDown:", .down),
            ("moveToBeginningOfParagraph:", .paragraphStart), ("moveParagraphBackward:", .paragraphStart),
            ("moveToEndOfParagraph:", .paragraphEnd), ("moveParagraphForward:", .paragraphEnd),
            ("moveToBeginningOfDocument:", .documentStart), ("moveToEndOfDocument:", .documentEnd),
        ]
        var result: [String: (TextMove, Bool)] = [:]
        for (selector, move) in plain {
            result[selector] = (move, false)
            result[String(selector.dropLast()) + "AndModifySelection:"] = (move, true)
        }
        return result
    }()

    /// The selector a key means without an input context (arrows with their modifiers, the
    /// deletes, Return and Tab); nil for a character.
    static func selector(for event: NSEvent) -> String? {
        let flags = event.modifierFlags
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        let command = flags.contains(.command)
        func arrow(_ plain: String, word: String, line: String) -> String {
            let base = command ? line : option ? word : plain
            return shift ? String(base.dropLast()) + "AndModifySelection:" : base
        }
        switch event.keyCode {
        case 123: return arrow("moveLeft:", word: "moveWordLeft:", line: "moveToLeftEndOfLine:")
        case 124: return arrow("moveRight:", word: "moveWordRight:", line: "moveToRightEndOfLine:")
        case 126: return arrow("moveUp:", word: "moveToBeginningOfParagraph:", line: "moveToBeginningOfDocument:")
        case 125: return arrow("moveDown:", word: "moveToEndOfParagraph:", line: "moveToEndOfDocument:")
        case 51: return command ? "deleteToBeginningOfLine:" : option ? "deleteWordBackward:" : "deleteBackward:"
        case 117: return option ? "deleteWordForward:" : "deleteForward:"
        case returnKeyCode, 76: return "insertNewline:"
        case 48: return "insertTab:"
        default: return nil
        }
    }
}
