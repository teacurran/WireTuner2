import AppKit
import CoreText
import WTCRDT
import WTGeometry
import WTModel
import WTRender
import WTText

/// The three display switches (presence.adoc, "Display options"), read at each draw.
struct PresenceDisplayOptions: Equatable, Sendable {
    var showCursors = true
    var showNames = true
    var showSelections = true
    /// The collaborators whose cursor this window hides (*Hide <name>'s Cursor*, COLLAB-060).
    var hiddenCursors: Set<String> = []

    @MainActor init(preferences: PreferenceStore, hiddenCursors: Set<String> = []) {
        showCursors = preferences[PreferenceCatalog.Sync.showCursors]
        showNames = preferences[PreferenceCatalog.Sync.showCursorNames]
        showSelections = preferences[PreferenceCatalog.Sync.showSelections]
        self.hiddenCursors = hiddenCursors
    }

    init(showCursors: Bool = true, showNames: Bool = true, showSelections: Bool = true, hiddenCursors: Set<String> = []) {
        self.showCursors = showCursors
        self.showNames = showNames
        self.showSelections = showSelections
        self.hiddenCursors = hiddenCursors
    }
}

/// When each collaborator's pointer last moved, so its name label hides after three seconds
/// without movement and comes back when it moves (presence.adoc, "Cursors").
@MainActor
final class CursorLabelClock {
    static let labelTimeout: TimeInterval = 3

    var now: @MainActor () -> Date = { Date() }
    private(set) var moved: [String: (point: Point, at: Date)] = [:]

    init() {}

    /// Records the participants' pointers; returns whether any moved.
    @discardableResult
    func update(_ participants: [RemoteParticipant]) -> Bool {
        let at = now()
        var changed = false
        var next: [String: (point: Point, at: Date)] = [:]
        for participant in participants {
            guard let cursor = participant.cursor else { continue }
            if let previous = moved[participant.id], previous.point == cursor {
                next[participant.id] = previous
            } else {
                next[participant.id] = (cursor, at)
                changed = true
            }
        }
        moved = next
        return changed
    }

    func showsLabel(_ id: String) -> Bool {
        guard let entry = moved[id] else { return false }
        return now().timeIntervalSince(entry.at) < Self.labelTimeout
    }
}

/// Draws everything presence puts on the canvas, on its own overlay layer above the tiles and
/// below the tool overlay (presence.adoc, "Client"; COLLAB-007, COLLAB-008, COLLAB-001):
/// collaborators' selection outlines with name tags (nested when shared), their selected points
/// as small squares, their cursors with name labels and tool badges, a flag on the text block a
/// collaborator is typing in, the attribution pulses, and the border in the followed person's
/// colour.  Frozen participants (a dropped connection) are drawn faded.  Objects that do not
/// resolve -- deleted, or not received yet -- draw nothing until they arrive.
@MainActor
struct PresenceOverlay {
    static let cursorSize = 14.0
    static let pointSize = 5.0
    static let borderWidth = 3.0

    let document: DocumentHandle
    let viewport: Viewport

    /// A cursor as drawn: the arrow's tip in view points, the label and its rect.
    struct CursorMark: Equatable {
        let participantID: String
        let tip: Point
        let label: String?
        let color: Color
        let faded: Bool
    }

    /// The cursors to draw: none with *Show collaborators' cursors* off, and none of the
    /// collaborators this window hides.
    func cursors(_ participants: [RemoteParticipant], options: PresenceDisplayOptions, clock: CursorLabelClock) -> [CursorMark] {
        guard options.showCursors else { return [] }
        let toView = viewport.pasteboardToView
        return participants.compactMap { participant in
            guard let cursor = participant.cursor, !options.hiddenCursors.contains(participant.id) else { return nil }
            var label: String?
            if options.showNames, clock.showsLabel(participant.id) {
                let badge = participant.editing.isEmpty || participant.tool.isEmpty ? "" : " · \(ToolID(participant.tool).displayTitle)"
                label = participant.name + badge
            }
            return CursorMark(participantID: participant.id, tip: toView.apply(cursor), label: label, color: participant.color, faded: participant.isFrozen)
        }
    }

    /// The collaborators' selected points in view points, with their colour.
    func points(_ participants: [RemoteParticipant]) -> [(point: Point, color: Color)] {
        var result: [(Point, Color)] = []
        for participant in participants where !participant.points.isEmpty {
            let wanted = Set(participant.points)
            for id in participant.selection {
                guard let object = document.object(for: id), let path = object.path else { continue }
                let toView = object.transform.concatenating(viewport.pasteboardToView)
                for contour in path.contours {
                    for point in contour.points where wanted.contains(RemoteParticipant.PointElement(contour: contour.id, point: point.id)) {
                        result.append((toView.apply(point.anchor), participant.color))
                    }
                }
            }
        }
        return result
    }

    /// The collaborators' carets in view points (COLLAB-008, TYPE-016): through the block's layout
    /// at the character the caret is before -- a deleted one reads where it was, before the next
    /// surviving character; zero is the end -- or, when the block cannot place it (nothing laid
    /// out yet), a flag at the block's top-left corner.  Carets in deleted blocks, or naming a
    /// character not received yet, are not drawn.  A caret is the line from `top` to `bottom`, so
    /// on text on a path it leans with the glyph it stands by; `rect` bounds it.
    func carets(_ participants: [RemoteParticipant]) -> [(rect: Rect, top: Point, bottom: Point, name: String, color: Color)] {
        participants.compactMap { participant in
            guard let caret = participant.caret, document.state.isLive(caret.node.opID) else { return nil }
            if let geometry = caretGeometry(caret) {
                let top = geometry.top
                let bottom = geometry.bottom
                return (Rect(x: min(top.x, bottom.x), y: min(top.y, bottom.y), width: max(abs(bottom.x - top.x), 1.5), height: max(abs(bottom.y - top.y), 1)),
                        top, bottom, participant.name, participant.color)
            }
            guard let bounds = document.object(for: caret.node)?.bounds else { return nil }
            let rect = bounds.applying(viewport.pasteboardToView)
            return (Rect(x: rect.minX, y: rect.minY, width: 1.5, height: rect.height), Point(x: rect.minX, y: rect.minY), Point(x: rect.minX, y: rect.maxY),
                    participant.name, participant.color)
        }
    }

    /// The text a remote caret is in, its layout and its placement: a block's own, or -- when the
    /// caret names an instance's text override (LIB-027) -- the master block holding the
    /// override's text, laid out as the instance draws it.  Nil when the caret's node holds no
    /// such text.
    static func caretText(_ caret: RemoteCaret, in document: DocumentHandle) -> (text: TextNode, layout: TextLayout, toPasteboard: WTGeometry.AffineTransform)? {
        let node = caret.node.opID
        let state = document.state
        if caret.text == TextFields.text {
            guard let text = state.textNode(node), let layout = document.textLayout(for: node) else { return nil }
            return (text, layout, Objects.pasteboardTransform(of: node, in: state))
        }
        guard let master = Symbols.overrideMaster(ofTextField: caret.text, in: node, state: state),
              let text = Symbols.textNode(master, in: node, state: state),
              let toPasteboard = Symbols.pasteboardTransform(ofMaster: master, in: node, state: state) else { return nil }
        return (text, TextEditingSession.layout(text, document: document), toPasteboard)
    }

    /// The live offset a caret's character stands for in `text`: before it (a tombstone: where it
    /// was), the end for zero; nil for a character the text does not hold.
    static func offset(_ char: OpID, in text: TextNode) -> Int? {
        char == .zero ? text.length : try? text.offset(of: Anchor(char: char, before: true))
    }

    /// A remote caret's ends and its selection's quads, in view points; nil when the block has
    /// no layout to place it in.
    func caretGeometry(_ caret: RemoteCaret) -> (top: Point, bottom: Point, selection: [[Point]])? {
        guard let (text, ownLayout, toPasteboard) = Self.caretText(caret, in: document), text.length > 0,
              let offset = Self.offset(caret.position, in: text) else { return nil }
        // A caret in the head of a linked flow is in the story, drawn in whichever member lays out
        // its character (TYPE-007).
        var layout = ownLayout
        var placement: (Int) -> WTGeometry.AffineTransform = { _ in toPasteboard }
        let node = caret.node.opID
        if caret.text == TextFields.text, let flow = document.chainLayout(for: node), flow.chain.first == node {
            let state = document.state
            layout = flow.layout
            placement = { flow.chain.indices.contains($0) ? Objects.pasteboardTransform(of: flow.chain[$0], in: state) : toPasteboard }
        }
        guard let placed = layout.caret(atOffset: offset) else { return nil }
        let pasteboardToView = viewport.pasteboardToView
        let toView = { (container: Int) in placement(container).concatenating(pasteboardToView) }
        var selection: [[Point]] = []
        if let end = caret.rangeEnd, let other = Self.offset(end, in: text), other != offset {
            selection = layout.selection(from: offset, to: other).map { quad in quad.corners.map { toView(quad.container).apply($0) } }
        }
        return (toView(placed.container).apply(placed.top), toView(placed.container).apply(placed.bottom), selection)
    }

    /// The collaborators' text selections, tinted in their colour.
    func textSelections(_ participants: [RemoteParticipant]) -> [(quad: [Point], color: Color)] {
        participants.flatMap { participant -> [(quad: [Point], color: Color)] in
            guard let caret = participant.caret, caret.rangeEnd != nil, document.state.isLive(caret.node.opID),
                  let geometry = caretGeometry(caret) else { return [] }
            return geometry.selection.map { ($0, participant.color) }
        }
    }

    /// The pulses: each node's painted bounds in view points, the label and how far it has faded.
    func flashes(_ flashes: [AttributionFlashController.Flash], progress: (AttributionFlashController.Flash) -> Double)
        -> [(rect: Rect, label: String, color: Color, alpha: Double)] {
        flashes.compactMap { flash in
            guard let bounds = document.object(for: flash.node)?.bounds else { return nil }
            return (bounds.applying(viewport.pasteboardToView).expanded(by: 2), flash.label, flash.color, 1 - progress(flash))
        }
    }

    // MARK: Drawing

    func draw(in ctx: CGContext, participants: [RemoteParticipant], options: PresenceDisplayOptions, clock: CursorLabelClock,
              flashes: [AttributionFlashController.Flash] = [], progress: (AttributionFlashController.Flash) -> Double = { _ in 0 },
              following: Color? = nil) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if options.showSelections {
            let selection = SelectionOverlay(document: document, viewport: viewport)
            for mark in selection.remoteMarks(for: participants) { selection.drawMark(mark, in: ctx) }
            for (point, color) in points(participants) {
                ctx.setFillColor(color.cgColor)
                let half = Self.pointSize / 2
                ctx.fill(CGRect(x: point.x - half, y: point.y - half, width: Self.pointSize, height: Self.pointSize))
            }
            for (quad, color) in textSelections(participants) {
                ctx.setFillColor(color.cgColor.copy(alpha: 0.25) ?? color.cgColor)
                ctx.addPath(TextTool.polygon(quad))
                ctx.fillPath()
            }
            for caret in carets(participants) {
                ctx.setStrokeColor(caret.color.cgColor)
                ctx.setLineWidth(1.5)
                ctx.move(to: caret.top.cgPoint)
                ctx.addLine(to: caret.bottom.cgPoint)
                ctx.strokePath()
                Self.drawTag(caret.name, at: Point(x: caret.top.x, y: caret.top.y - SelectionOverlay.tagFontSize - 2 * SelectionOverlay.tagPadding),
                             color: caret.color, in: ctx)
            }
        }
        for flash in self.flashes(flashes, progress: progress) {
            ctx.setAlpha(max(flash.alpha, 0))
            ctx.setStrokeColor(flash.color.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(flash.rect.cgRect)
            Self.drawTag(flash.label, at: Point(x: flash.rect.minX, y: flash.rect.maxY + 2), color: flash.color, in: ctx)
            ctx.setAlpha(1)
        }
        for cursor in cursors(participants, options: options, clock: clock) {
            ctx.setAlpha(cursor.faded ? 0.4 : 1)
            ctx.addPath(Self.arrow(at: cursor.tip))
            ctx.setFillColor(cursor.color.cgColor)
            ctx.setStrokeColor(CGColor.white)
            ctx.setLineWidth(1)
            ctx.drawPath(using: .fillStroke)
            if let label = cursor.label {
                Self.drawTag(label, at: Point(x: cursor.tip.x + Self.cursorSize * 0.7, y: cursor.tip.y + Self.cursorSize * 0.8), color: cursor.color, in: ctx)
            }
            ctx.setAlpha(1)
        }
        if let following {
            ctx.setStrokeColor(following.cgColor)
            ctx.setLineWidth(Self.borderWidth)
            let inset = Self.borderWidth / 2
            ctx.stroke(CGRect(x: inset, y: inset, width: viewport.size.width - Self.borderWidth, height: viewport.size.height - Self.borderWidth))
        }
    }

    /// The pointer arrow with its tip at `tip` (view points, y down).
    static func arrow(at tip: Point) -> CGPath {
        let s = cursorSize
        let path = CGMutablePath()
        path.addLines(between: [
            tip.cgPoint, CGPoint(x: tip.x, y: tip.y + s), CGPoint(x: tip.x + s * 0.28, y: tip.y + s * 0.72),
            CGPoint(x: tip.x + s * 0.7, y: tip.y + s * 0.7),
        ])
        path.closeSubpath()
        return path
    }

    /// A name tag: white text on the colour, its top-left at `origin`.
    static func drawTag(_ text: String, at origin: Point, color: Color, in ctx: CGContext) {
        let size = SelectionOverlay.tagSize(for: text)
        let rect = CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: rect.minX + SelectionOverlay.tagPadding, y: rect.maxY - SelectionOverlay.tagPadding - 2)
        CTLineDraw(CTLineCreateWithAttributedString(SelectionOverlay.tagString(text)), ctx)
        ctx.restoreGState()
    }
}

extension ToolID {
    /// The tool's name for a cursor badge ("Pen", "Rectangle"): the catalog's title, else the id.
    @MainActor var displayTitle: String {
        ToolCatalog.all.first { $0.id == self }?.title ?? rawValue.capitalized
    }
}
