import AppKit
import CoreText
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The three display switches (presence.adoc, "Display options"), read at each draw.
struct PresenceDisplayOptions: Equatable, Sendable {
    var showCursors = true
    var showNames = true
    var showSelections = true

    @MainActor init(preferences: PreferenceStore) {
        showCursors = preferences[PreferenceCatalog.Sync.showCursors]
        showNames = preferences[PreferenceCatalog.Sync.showCursorNames]
        showSelections = preferences[PreferenceCatalog.Sync.showSelections]
    }

    init(showCursors: Bool = true, showNames: Bool = true, showSelections: Bool = true) {
        self.showCursors = showCursors
        self.showNames = showNames
        self.showSelections = showSelections
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

    /// The cursors to draw.
    func cursors(_ participants: [RemoteParticipant], options: PresenceDisplayOptions, clock: CursorLabelClock) -> [CursorMark] {
        guard options.showCursors else { return [] }
        let toView = viewport.pasteboardToView
        return participants.compactMap { participant in
            guard let cursor = participant.cursor else { return nil }
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

    /// The text blocks collaborators are typing in, as a flag at the block's top-left corner in
    /// view points.  Mapping the caret's character to a glyph needs the text editor's layout
    /// (COLLAB-008): until it exists the flag marks the block.
    func carets(_ participants: [RemoteParticipant]) -> [(rect: Rect, name: String, color: Color)] {
        participants.compactMap { participant in
            guard let caret = participant.caret, let bounds = document.object(for: caret.node)?.bounds else { return nil }
            let rect = bounds.applying(viewport.pasteboardToView)
            return (Rect(x: rect.minX, y: rect.minY, width: 1.5, height: rect.height), participant.name, participant.color)
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
            for caret in carets(participants) {
                ctx.setFillColor(caret.color.cgColor)
                ctx.fill(caret.rect.cgRect)
                Self.drawTag(caret.name, at: Point(x: caret.rect.minX, y: caret.rect.minY - SelectionOverlay.tagFontSize - 2 * SelectionOverlay.tagPadding),
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
