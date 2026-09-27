import Foundation
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync

/// Writes the local user's presence into the document session's `LocalPresence` (presence.adoc,
/// "Client", *Outgoing presence*): pointer, viewport, tool, selection (the first 200 and the
/// count), selected points, the editing set during a drag, spotlight and following.  The sync
/// client reads it at 20 Hz and sends what changed; with *Show my cursor and selection to others*
/// off it leaves pointer, tool, selection and caret out.
@MainActor
final class LocalPresencePublisher {
    /// The cap on `selection` a frame carries (presence.proto).
    static let selectionCap = 200
    static let subSelectionCap = 500

    let presence: LocalPresence

    init(presence: LocalPresence) {
        self.presence = presence
    }

    /// *Show my cursor and selection to others*.
    func setSharing(_ sharing: Bool) {
        presence.sharing = sharing
    }

    /// The pointer in pasteboard points; nil when it left the canvas.
    func pointer(_ point: Point?) {
        presence.update { update in
            if let point {
                update.cursor = Self.point(point)
            } else {
                update.clearCursor()
            }
        }
    }

    /// The visible rect and zoom, for Follow.
    func viewport(_ viewport: Viewport) {
        let visible = viewport.visiblePasteboardBounds
        presence.update { update in
            update.viewport.visible = Self.rect(visible)
            update.viewport.zoom = viewport.zoom
        }
    }

    /// The active page (the Document panel's and the pages' presence dots); nil for none.
    func page(_ id: OpID?) {
        presence.update { update in
            if let id { update.page = id.proto } else { update.clearPage() }
        }
    }

    func tool(_ id: ToolID) {
        presence.update { $0.tool = String(id.rawValue.prefix(32)) }
    }

    /// The selection: the first 200 objects and the count, and the selected points of paths.
    func selection(_ selection: Selection) {
        let ids = selection.ids
        var points: [Wiretuner_Doc_V1_FieldPath] = []
        for id in ids {
            guard case .points(let references)? = selection.subSelection(of: id) else { continue }
            for reference in references.sorted() where points.count < Self.subSelectionCap {
                points.append(Self.pointPath(contour: reference.contour, point: reference.point))
            }
        }
        presence.update { update in
            update.selection = ids.prefix(Self.selectionCap).map { $0.opID.proto }
            update.selectionCount = UInt32(ids.count)
            update.subSelection = points
        }
    }

    /// The objects a drag or a focused field is changing (empty when it ends).
    func editing(_ ids: [SelectionID]) {
        presence.update { $0.editing = ids.prefix(Self.selectionCap).map { $0.opID.proto } }
    }

    /// The Text tool's insertion point (`TextCaret`): the block (or the instance) and its TEXT
    /// field, the character the caret is before (zero: the end) and a selection's other end; nil
    /// clears it.
    func caret(_ caret: PresenceCaret?) {
        presence.update { update in
            guard let caret else {
                update.clearCaret()
                return
            }
            var value = Wiretuner_Sync_V1_TextCaret()
            value.node = caret.node.proto
            value.text = caret.text.proto
            value.position = caret.position.elementID
            if let end = caret.rangeEnd { value.rangeEnd = end.elementID }
            update.caret = value
        }
    }

    func spotlight(_ on: Bool) {
        presence.update { $0.spotlight = on }
    }

    func following(_ userID: String?) {
        presence.update { $0.followingUserID = userID ?? "" }
    }

    /// Key or mouse input that changed nothing published (ends *Idle*).
    func input() {
        presence.input()
    }

    static func point(_ point: Point) -> Wiretuner_Doc_V1_Point {
        var result = Wiretuner_Doc_V1_Point()
        result.x = point.x
        result.y = point.y
        return result
    }

    static func rect(_ rect: Rect) -> Wiretuner_Doc_V1_Rect {
        var result = Wiretuner_Doc_V1_Rect()
        result.x = rect.minX
        result.y = rect.minY
        result.width = rect.width
        result.height = rect.height
        return result
    }

    /// A selected point as a field path: `path.contours.<contour>.points.<point>`.
    static func pointPath(contour: OpID, point: OpID) -> Wiretuner_Doc_V1_FieldPath {
        RegisterPath(segments: [.field(NodeKind.path.rawValue), .field(2), .element(contour), .field(3), .element(point)]).proto
    }
}
