import AppKit
import Observation
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTText

/// One text block being edited with the Text tool (creating-text.adoc, editing-text.adoc; TYPE-003,
/// TYPE-010): the block -- or, before the first character, the block about to be created -- the
/// selection as two Peritext anchors (`anchor` stays put, `focus` moves; a caret is the two equal),
/// the pending format, and the input method's marked text.  Every edit is a command performed
/// through the window's `CommandSink`; nothing here is written to the document otherwise, and the
/// marked text of a composition never is until it is committed.
///
/// The anchors are the `TextNode.anchor(at:)` form -- before the character at an offset, or the
/// end -- so typing at the insertion point leaves the caret after what was typed without waiting
/// for the change, a remote insert at the caret lands before it, and a deleted anchor character
/// reads as the offset it had (after the nearest surviving predecessor, editing-text "Caret
/// model").  Views and the tool read the geometry from here (pasteboard space) and stay thin.
@MainActor
@Observable
final class TextEditingSession {
    /// What is being edited.
    enum Target: Equatable {
        /// A click or drag made a place for a block; nothing is in the document until the first
        /// character (creating-text, "Creation").
        case pending(CreateTextBlock.Frame)
        /// The first character's change is on its way; keystrokes wait for it.
        case creating(CreateTextBlock.Frame)
        /// An existing block.
        case node(OpID)
    }

    /// The input method's composition: shown at the insertion point, never sent.
    struct MarkedText: Equatable {
        var text: String
        /// The selection inside it (UTF-16), as the input method set it.
        var selected: NSRange
    }

    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored let sink: any CommandSink
    private(set) var target: Target
    private(set) var anchor: Anchor = .end
    private(set) var focus: Anchor = .end
    /// At a soft line break the caret shows at the end of the earlier line (after Cmd-Right).
    private(set) var upstream = false
    /// Character formatting chosen at an insertion point: marks for the next typed characters
    /// (creating-text, "Data model": client state, never written on its own).
    private(set) var pendingFormat: [Wiretuner_Doc_V1_TextMarkValue] = []
    /// Paragraph properties chosen before the first character of a new block.
    private(set) var pendingParagraph = Wiretuner_Doc_V1_ParagraphProps()
    private(set) var marked: MarkedText?
    /// Moves with every document change, so views reading the session redraw.
    private(set) var revision = 0
    /// Edits and selection changes waiting for the change before them to land, so each reads the
    /// text the one before left (a keystroke typed while the new block is being created, an arrow
    /// right after typing).
    @ObservationIgnored private var queue: [@MainActor (TextEditingSession) -> Void] = []
    /// Changes performed and not landed yet.
    @ObservationIgnored private(set) var inflight = 0
    @ObservationIgnored private var landing: Task<Void, Never>?
    /// The layer a new block is created on (the window's active layer).
    @ObservationIgnored var layer: OpID?
    @ObservationIgnored var pasteboard: NSPasteboard = .general
    /// Called after the selection, the marked text or the block changed (the overlay, presence).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    /// Called once the new block exists.
    @ObservationIgnored var onCreate: (@MainActor (OpID) -> Void)?
    /// The x (container space) Up and Down keep while they move.
    @ObservationIgnored private var goalX: Double?
    /// The range and granularity a click began with, which a drag extends.
    @ObservationIgnored private var gesture: (range: Range<Int>, granularity: TextGranularity)?

    init(document: DocumentHandle, sink: any CommandSink, target: Target, layer: OpID? = nil) {
        self.document = document
        self.sink = sink
        self.target = target
        self.layer = layer
    }

    // MARK: Reading

    var node: OpID? {
        if case .node(let id) = target { return id }
        return nil
    }

    /// The block as merged now (nil before it exists).
    var text: TextNode? { node.flatMap { document.state.textNode($0) } }

    /// The live scalars.
    var scalars: [Unicode.Scalar] { text.map { Array($0.string.unicodeScalars) } ?? [] }

    private func offset(_ anchor: Anchor, in text: TextNode) -> Int {
        (try? text.offset(of: anchor)) ?? text.length
    }

    var focusOffset: Int { text.map { offset(focus, in: $0) } ?? 0 }
    var anchorOffset: Int { text.map { offset(anchor, in: $0) } ?? 0 }

    /// The selected live range (empty at an insertion point).
    var selectedRange: Range<Int> {
        let (a, f) = (anchorOffset, focusOffset)
        return min(a, f)..<max(a, f)
    }

    var selectedText: String {
        let all = scalars
        let range = selectedRange.clamped(to: 0..<all.count)
        var view = String.UnicodeScalarView()
        view.append(contentsOf: all[range])
        return String(view)
    }

    /// Whether the document now holds the block (a remote delete or an undo of its creation ends
    /// the session).
    var isLive: Bool {
        guard let node else { return true }
        return document.state.isLive(node)
    }

    // MARK: Geometry

    /// The block's layout (nil before it exists).
    var layout: TextLayout? { node.flatMap { document.textLayout(for: $0) } }

    /// Container space → pasteboard: the block's placement through its groups and layer, or the
    /// new block's origin.
    var toPasteboard: WTGeometry.AffineTransform {
        switch target {
        case .node(let id): return Objects.pasteboardTransform(of: id, in: document.state)
        case .pending(let frame), .creating(let frame): return .translation(x: Self.origin(frame).x, y: Self.origin(frame).y)
        }
    }

    static func origin(_ frame: CreateTextBlock.Frame) -> Point {
        switch frame {
        case .point(let point): point
        case .area(let rect): Point(x: rect.minX, y: rect.minY)
        }
    }

    /// The container the block lays out in (its own, or the new block's).
    private var container: TextContainer {
        if let text { return TextLayoutReading.container(text) }
        switch target {
        case .pending(.area(let rect)), .creating(.area(let rect)):
            return .block(TextBlock(width: rect.width, height: rect.height, autoWidth: false, autoHeight: false))
        default:
            return .block(TextBlock(width: 0, height: 0, autoWidth: true, autoHeight: true))
        }
    }

    /// A one-space layout in the block's container with the pending format: where the caret of
    /// an empty block goes and how tall it is.
    private var emptyLayout: TextLayout {
        let attributes = TextLayoutReading.attributes(pendingFormat)
        let style = TextLayoutReading.paragraphStyle(text?.paragraphs.last?.props ?? pendingParagraph)
        return document.textEngine.layout(TextContent(" ", attributes: attributes, style: style), in: [container])
    }

    /// The layout the caret and hit tests read: the block's, or the empty one.
    private var editingLayout: TextLayout {
        if let text, text.length > 0, let layout { return layout }
        return emptyLayout
    }

    /// The block's rectangle in container space (a new auto-expanding block: the caret's height).
    var localFrame: Rect {
        // One container, one size.
        let size = editingLayout.sizes[0]
        return Rect(x: 0, y: 0, width: max(size.width, 1), height: max(size.height, 1))
    }

    /// The block's corners in pasteboard space, clockwise from the top-left.
    var frameCorners: [Point] {
        let frame = localFrame
        let transform = toPasteboard
        return [Point(x: frame.minX, y: frame.minY), Point(x: frame.maxX, y: frame.minY), Point(x: frame.maxX, y: frame.maxY),
                Point(x: frame.minX, y: frame.maxY)].map { transform.apply($0) }
    }

    /// The caret's ends (top, bottom) in pasteboard space; nil with a selection.
    var caret: (top: Point, bottom: Point)? {
        guard selectedRange.isEmpty else { return nil }
        let empty = (text?.length ?? 0) == 0
        guard let caret = editingLayout.caret(atOffset: empty ? 0 : focusOffset, upstream: upstream) else { return nil }
        return (toPasteboard.apply(caret.top), toPasteboard.apply(caret.bottom))
    }

    /// The selection's shape, one quadrilateral per line, pasteboard space.
    var selectionQuads: [[Point]] {
        let range = selectedRange
        guard !range.isEmpty, let layout else { return [] }
        let transform = toPasteboard
        return layout.selection(from: range.lowerBound, to: range.upperBound).map { $0.corners.map { transform.apply($0) } }
    }

    /// The caret's baseline point, pasteboard space (where marked text is drawn).
    var caretBaseline: Point? {
        let empty = (text?.length ?? 0) == 0
        return editingLayout.caret(atOffset: empty ? 0 : selectedRange.lowerBound, upstream: upstream).map { toPasteboard.apply($0.baseline) }
    }

    /// Pasteboard → container space (a degenerate placement reads as the identity).
    private var fromPasteboard: WTGeometry.AffineTransform { toPasteboard.inverted() ?? .identity }

    /// Whether `point` (pasteboard) is on the block: inside its rectangle grown by `tolerance`.
    func contains(_ point: Point, tolerance: Double = 0) -> Bool {
        localFrame.expanded(by: tolerance).contains(fromPasteboard.apply(point))
    }

    /// The boundary nearest `point` (pasteboard): the start of an empty block, the insertion
    /// point when nothing of the block is laid out (all of it overflows).
    func offset(at point: Point) -> Int {
        guard let text, text.length > 0, let layout else { return 0 }
        return layout.offset(at: fromPasteboard.apply(point), inContainer: 0) ?? focusOffset
    }

    // MARK: Selection

    /// Selects `anchor`...`focus` (live offsets, clamped).
    /// Selects `anchor`...`focus` (live offsets, clamped).  Moving the selection drops the
    /// pending format.
    func select(anchor anchorOffset: Int, focus focusOffset: Int, upstream: Bool = false) {
        enqueue { $0.setSelection(anchor: anchorOffset, focus: focusOffset, upstream: upstream) }
    }

    private func setSelection(anchor anchorOffset: Int, focus focusOffset: Int, upstream: Bool = false) {
        guard let text else { return }
        let clamp = { (offset: Int) in min(max(offset, 0), text.length) }
        anchor = text.anchor(at: clamp(anchorOffset))
        focus = text.anchor(at: clamp(focusOffset))
        self.upstream = upstream
        pendingFormat = []
        changed()
    }

    /// menu:Edit[Select All]: every character of the block.
    func selectAll() {
        enqueue { session in
            guard let text = session.text else { return }
            session.goalX = nil
            session.setSelection(anchor: 0, focus: text.length)
        }
    }

    /// A click at `point` (pasteboard): the insertion point there, or with `extend` the selection
    /// from the anchor to it; a double click the word, a triple click the paragraph.
    func click(at point: Point, granularity: TextGranularity, extend: Bool) {
        enqueue { $0.applyClick(at: point, granularity: granularity, extend: extend) }
    }

    private func applyClick(at point: Point, granularity: TextGranularity, extend: Bool) {
        goalX = nil
        let offset = offset(at: point)
        let all = scalars
        switch granularity {
        case .character:
            if extend {
                gesture = (anchorOffset..<anchorOffset, .character)
                setSelection(anchor: anchorOffset, focus: offset)
            } else {
                gesture = (offset..<offset, .character)
                setSelection(anchor: offset, focus: offset)
            }
        case .word:
            let range = TextNavigation.wordRange(at: offset, in: all)
            gesture = (range, .word)
            setSelection(anchor: range.lowerBound, focus: range.upperBound)
        case .paragraph:
            let range = TextNavigation.paragraphRange(at: offset, in: all)
            gesture = (range, .paragraph)
            setSelection(anchor: range.lowerBound, focus: range.upperBound)
        }
    }

    /// The drag after a click: the selection runs from the click's range to `point`, by the
    /// click's granularity.
    func drag(to point: Point) {
        enqueue { $0.applyDrag(to: point) }
    }

    private func applyDrag(to point: Point) {
        guard let (origin, granularity) = gesture else { return }
        let offset = offset(at: point)
        let all = scalars
        let reached: Range<Int> = switch granularity {
        case .character: offset..<offset
        case .word: TextNavigation.wordRange(at: offset, in: all)
        case .paragraph: TextNavigation.paragraphRange(at: offset, in: all)
        }
        if reached.lowerBound < origin.lowerBound {
            setSelection(anchor: origin.upperBound, focus: reached.lowerBound)
        } else {
            setSelection(anchor: origin.lowerBound, focus: max(reached.upperBound, origin.upperBound))
        }
    }

    /// The keyboard movements, extending the selection with `extend` (editing-text, "Keyboard
    /// selection and movement").  Left and Right collapse a selection to its edge.
    func move(_ move: TextMove, extend: Bool) {
        enqueue { $0.applyMove(move, extend: extend) }
    }

    private func applyMove(_ move: TextMove, extend: Bool) {
        guard let text, let layout else { return }
        let all = scalars
        let range = selectedRange
        let from = focusOffset
        var keepsGoal = false
        var up = false
        let lines = layout.lineRanges
        let target: Int
        switch move {
        case .left: target = !extend && !range.isEmpty ? range.lowerBound : max(from - 1, 0)
        case .right: target = !extend && !range.isEmpty ? range.upperBound : min(from + 1, text.length)
        case .wordLeft: target = TextNavigation.wordStart(before: from, in: all)
        case .wordRight: target = TextNavigation.wordEnd(after: from, in: all)
        case .lineStart: target = TextNavigation.lineStart(of: from, in: lines, upstream: upstream)
        case .lineEnd: (target, up) = TextNavigation.lineEnd(of: from, in: lines, scalars: all, upstream: upstream)
        case .up, .down:
            keepsGoal = true
            let goal = goalX ?? layout.caret(atOffset: from, upstream: upstream)?.baseline.x ?? 0
            goalX = goal
            target = TextNavigation.vertical(from: from, down: move == .down, goalX: goal, layout: layout, upstream: upstream)
        case .paragraphStart: target = TextNavigation.paragraphStart(before: from, in: all)
        case .paragraphEnd: target = TextNavigation.paragraphEnd(after: from, in: all)
        case .documentStart: target = 0
        case .documentEnd: target = text.length
        }
        if !keepsGoal { goalX = nil }
        setSelection(anchor: extend ? anchorOffset : target, focus: target, upstream: up)
    }

    // MARK: Editing

    /// Types `string` at the insertion point or over the selection (a keystroke with `typing`, a
    /// paste or committed composition without).  The first character of a new block creates it.
    func insert(_ string: String, typing: Bool = true) {
        guard !string.isEmpty else { return }
        enqueue { $0.applyInsert(string, typing: typing) }
    }

    private func applyInsert(_ string: String, typing: Bool) {
        goalX = nil
        guard case .node(let node) = target, let text else {
            if case .pending(let frame) = target { create(frame, string, typing: typing) }
            return
        }
        let range = selectedRange
        perform(TextKeystroke(node: node, from: anchor, to: focus, .insert(string), marks: pendingFormat, typing: typing))
        pendingFormat = []
        if !range.isEmpty { collapse(to: text.anchor(at: range.upperBound)) } else { changed() }
    }

    /// kbd:[Delete], kbd:[Fn+Delete], kbd:[Option+Delete] and Cut's removal.
    func delete(_ action: TextKeystroke.Action) {
        enqueue { $0.applyDelete(action) }
    }

    private func applyDelete(_ action: TextKeystroke.Action) {
        goalX = nil
        guard case .node(let node) = target, let text else { return }
        let range = selectedRange
        if range.isEmpty, action == .deleteSelection { return }
        perform(TextKeystroke(node: node, from: anchor, to: focus, action, typing: action == .backspace))
        if !range.isEmpty { collapse(to: text.anchor(at: range.upperBound)) } else { changed() }
    }

    /// kbd:[Cmd+Delete] (to the line's start) and kbd:[Ctrl+K] (to its end): the selection, or the
    /// insertion point to that end of the line.
    func deleteToLineEdge(end: Bool) {
        enqueue { session in
            guard session.selectedRange.isEmpty else { return session.applyDelete(.deleteSelection) }
            guard let layout = session.layout else { return }
            let from = session.focusOffset
            let lines = layout.lineRanges
            let edge = end ? TextNavigation.lineEnd(of: from, in: lines, scalars: session.scalars, upstream: session.upstream).offset
                : TextNavigation.lineStart(of: from, in: lines, upstream: session.upstream)
            guard edge != from else { return }
            session.setSelection(anchor: edge, focus: from)
            session.applyDelete(.deleteSelection)
        }
    }

    private func collapse(to caret: Anchor) {
        anchor = caret
        focus = caret
        upstream = false
        changed()
    }

    private func create(_ frame: CreateTextBlock.Frame, _ string: String, typing: Bool) {
        target = .creating(frame)
        let command = TypeNewTextBlock(CreateTextBlock(frame, text: string, marks: pendingFormat, paragraph: pendingParagraph, layer: layer), typing: typing)
        let document = document
        perform(command) { session, change in
            session.created(change?.createdObjects.first { document.state.nodeKind($0) == .text }, frame: frame)
        }
        changed()
    }

    /// The new block exists (or its creation failed and the next keystroke tries again); what was
    /// typed meanwhile follows it.
    private func created(_ node: OpID?, frame: CreateTextBlock.Frame) {
        guard let node else {
            target = .pending(frame)
            changed()
            return
        }
        target = .node(node)
        anchor = .end
        focus = .end
        pendingFormat = []
        onCreate?(node)
        changed()
    }

    // MARK: Ordering

    /// Runs `step` now, or after the changes on their way and the steps before it.
    private func enqueue(_ step: @escaping @MainActor (TextEditingSession) -> Void) {
        if inflight == 0, queue.isEmpty {
            step(self)
        } else {
            queue.append(step)
        }
    }

    private func drain() {
        while inflight == 0, !queue.isEmpty {
            queue.removeFirst()(self)
        }
    }

    /// Performs `command`; once it lands, `then` runs and the waiting steps follow.  The session
    /// stays alive until then, so keystrokes typed before editing ended are not lost.
    @discardableResult
    private func perform(_ command: any WTModel.Command,
                         then: (@MainActor (TextEditingSession, Wiretuner_Doc_V1_Change?) -> Void)? = nil) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        inflight += 1
        let task = sink.perform(command)
        landing = Task { @MainActor in
            let change = await task.value
            then?(self, change)
            self.inflight -= 1
            self.drain()
        }
        return task
    }

    /// Waits until every change the session performed has landed and every waiting step ran.
    func settle() async {
        while inflight > 0, let landing {
            await landing.value
        }
    }

    // MARK: Pasteboard

    /// menu:Edit[Copy]: the selected characters as plain text.  False with nothing selected.
    @discardableResult
    func copy() -> Bool {
        let string = selectedText
        guard !string.isEmpty else { return false }
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        return true
    }

    /// menu:Edit[Cut].
    func cut() {
        enqueue { session in
            if session.copy() { session.applyDelete(.deleteSelection) }
        }
    }

    var canPaste: Bool { pasteboard.string(forType: .string)?.isEmpty == false }

    /// menu:Edit[Paste]: plain text at the insertion point or over the selection, line ends as
    /// paragraph ends.
    func paste() {
        guard let string = pasteboard.string(forType: .string), !string.isEmpty else { return }
        insert(string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"), typing: false)
    }

    // MARK: Input method

    /// The composition changed (`NSTextInputClient.setMarkedText`): shown, not sent.
    func setMarkedText(_ string: String, selected: NSRange) {
        marked = string.isEmpty ? nil : MarkedText(text: string, selected: selected)
        changed()
    }

    /// The composition ended: its text is committed as one string.
    func unmarkText() {
        guard let composed = marked else { return }
        marked = nil
        insert(composed.text, typing: false)
        changed()
    }

    /// `NSTextInputClient.insertText`: a committed string, replacing the composition, or the
    /// UTF-16 range the input method names (the press-and-hold accent menu replaces the letter
    /// before the caret).
    func insertCommitted(_ string: String, replacing range: NSRange?) {
        let composing = marked != nil
        marked = nil
        if let range, range.location != NSNotFound {
            enqueue { session in
                let scalarRange = TextNavigation.scalarRange(range, in: session.scalars)
                session.setSelection(anchor: scalarRange.lowerBound, focus: scalarRange.upperBound)
                session.applyInsert(string, typing: false)
            }
            return
        }
        insert(string, typing: !composing && string.count == 1)
    }

    /// The selection in UTF-16 (inside the composition while there is one).
    var selectedUTF16Range: NSRange {
        let all = scalars
        let range = selectedRange
        let location = TextNavigation.utf16Offset(range.lowerBound, in: all)
        if let marked { return NSRange(location: location + marked.selected.location, length: marked.selected.length) }
        return NSRange(location: location, length: TextNavigation.utf16Offset(range.upperBound, in: all) - location)
    }

    /// The composition's range in UTF-16, or `NSNotFound`.
    var markedUTF16Range: NSRange {
        guard let marked else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: TextNavigation.utf16Offset(selectedRange.lowerBound, in: scalars), length: marked.text.utf16.count)
    }

    /// The committed text in a UTF-16 range (what the input method reads around the caret).
    func substring(_ range: NSRange) -> (string: String, range: NSRange)? {
        let all = scalars
        guard range.location != NSNotFound, range.location <= TextNavigation.utf16Offset(all.count, in: all) else { return nil }
        let scalarRange = TextNavigation.scalarRange(range, in: all)
        var view = String.UnicodeScalarView()
        view.append(contentsOf: all[scalarRange])
        let location = TextNavigation.utf16Offset(scalarRange.lowerBound, in: all)
        return (String(view), NSRange(location: location, length: TextNavigation.utf16Offset(scalarRange.upperBound, in: all) - location))
    }

    // MARK: Formatting

    /// The winning mark values over the selection -- each run it covers -- or at an insertion
    /// point those of the character before it (after the pending format), which typing takes.
    var formatRuns: [[Wiretuner_Doc_V1_TextMarkValue]] {
        guard let text, text.length > 0 else { return [pendingFormat] }
        let range = selectedRange
        guard range.isEmpty else {
            return text.runs.filter { $0.range.overlaps(range) }.map(\.values)
        }
        let values = text.values(at: max(range.lowerBound - 1, 0))
        return [values.filter { value in !pendingFormat.contains { Self.sameAttribute($0, value) } } + pendingFormat]
    }

    /// The properties of the paragraphs the selection touches (a new block: its first one's).
    var paragraphProps: [Wiretuner_Doc_V1_ParagraphProps] {
        guard let text else { return [pendingParagraph] }
        return text.paragraphs(touching: selectedRange).map(\.props)
    }

    /// Whether two mark values set the same attribute (a `feature` mark: the same tag).
    static func sameAttribute(_ a: Wiretuner_Doc_V1_TextMarkValue, _ b: Wiretuner_Doc_V1_TextMarkValue) -> Bool {
        TextMarks.cleared(a) == TextMarks.cleared(b)
    }

    /// Formats the selection with `value` (one mark, one change); at an insertion point it
    /// becomes part of the pending format instead.
    /// The change's task when it ran at once (nil when it waits, or wrote nothing).
    @discardableResult
    func format(_ value: Wiretuner_Doc_V1_TextMarkValue) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        var result: Task<Wiretuner_Doc_V1_Change?, Never>?
        enqueue { session in
            let range = session.selectedRange
            if let node = session.node, let text = session.text, !range.isEmpty {
                result = session.perform(ApplyMark(node: node, from: text.anchor(at: range.lowerBound), to: text.anchor(at: range.upperBound), value: value))
                return
            }
            session.pendingFormat.removeAll { Self.sameAttribute($0, value) }
            session.pendingFormat.append(value)
            session.changed()
        }
        return result
    }

    /// Aligns the paragraphs the selection touches (a new block: its first paragraph).
    @discardableResult
    func align(_ alignment: Wiretuner_Doc_V1_Alignment) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        var result: Task<Wiretuner_Doc_V1_Change?, Never>?
        enqueue { session in
            guard let node = session.node, let text = session.text else {
                session.pendingParagraph.alignment = alignment
                session.changed()
                return
            }
            let range = session.selectedRange
            result = session.perform(SetParagraph(node: node, from: text.anchor(at: range.lowerBound), to: text.anchor(at: range.upperBound),
                                                  props: .with { $0.alignment = alignment }, fields: [[1]], label: "Alignment"))
        }
        return result
    }

    // MARK: Lifetime

    /// The document changed: views re-read.
    func documentDidChange() {
        revision &+= 1
        changed()
    }

    /// Ends editing: a composition is committed; an emptied block is deleted (an empty block is
    /// discarded when deselected, creating-text).  Returns the block that is left.
    @discardableResult
    func end() -> OpID? {
        unmarkText()
        guard let node, isLive else { return nil }
        let waiting = inflight > 0
        enqueue { session in
            if session.isLive, session.text?.length == 0 { session.perform(DeleteNodes([node])) }
        }
        return waiting || text?.length != 0 ? node : nil
    }

    /// The anchors presence publishes (presence.adoc, `TextCaret`): the character the caret is
    /// before (zero: the end) and, with a selection, the other end's.
    var presenceCaret: (node: OpID, position: OpID, rangeEnd: OpID?)? {
        guard let node, isLive, let text else { return nil }
        let range = selectedRange
        return (node, text.anchor(at: range.lowerBound).char, range.isEmpty ? nil : text.anchor(at: range.upperBound).char)
    }

    private func changed() {
        onChange?()
    }
}
