import Foundation
import Observation
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// A collaborator's text caret (presence.adoc, "Selections and carets"): the text block, the
/// character the caret is before (`.zero`: the end) and the other end of a range.
struct RemoteCaret: Hashable, Sendable {
    var node: SelectionID
    var position: OpID
    var rangeEnd: OpID?
    /// The TEXT field of the node: a block's own, or an instance's text override's (LIB-027).
    var text: RegisterPath

    init(node: SelectionID, position: OpID, rangeEnd: OpID? = nil, text: RegisterPath = TextFields.text) {
        self.node = node
        self.position = position
        self.rangeEnd = rangeEnd
        self.text = text
    }
}

/// The caret this person publishes (`TextCaret`): the node and TEXT field, the character the caret
/// is before (zero: the end) and a selection's other end.
struct PresenceCaret: Hashable, Sendable {
    var node: OpID
    var text: RegisterPath
    var position: OpID
    var rangeEnd: OpID?
}

/// One other person with the document open, as the canvas overlay, the avatar strip and the
/// panels need them (presence.adoc).  `PresenceAdapter` fills these from `WTSync.PresenceModel`
/// (SYNC-009); tests and the harness build them directly.
struct RemoteParticipant: Identifiable, Hashable, Sendable {
    /// The participant's key: the account (`PresenceParticipant.id`).
    let id: String
    var name: String
    /// Index into the 12-colour palette, stable per (document, person); server-assigned.
    var colorIndex: Int
    var selection: [SelectionID]
    /// The whole selection's size (a frame carries at most 200 ids).
    var selectionCount: Int
    /// Selected points of the selected paths (contour and point element ids).
    var points: [PointElement]
    /// Objects they are actively changing (a drag, a focused field).
    var editing: [SelectionID]
    /// Their pointer in pasteboard points; nil off the canvas.
    var cursor: Point?
    /// The active tool's id, for the cursor badge ("pointer", "pen", ...).
    var tool: String
    /// Their visible rect (pasteboard points) and zoom, for Follow.
    var viewport: Rect?
    var zoom: Double?
    /// The page their view is mostly on.
    var page: SelectionID?
    var caret: RemoteCaret?
    /// The document role, for the hover card.
    var role: String
    /// Set when they are on a branch of this document.
    var branchID: String
    /// No input for two minutes: the avatar is dimmed.
    var isIdle: Bool
    /// Their connection or ours dropped: drawn where they were, marked *Reconnecting*.
    var isFrozen: Bool
    /// They are spotlighting (asking everyone to follow them).
    var spotlight: Bool
    /// The user they follow, if any.
    var followingUserID: String

    /// A selected point: the contour element and the point element of a selected path.
    struct PointElement: Hashable, Sendable {
        var contour: OpID
        var point: OpID
    }

    init(id: String, name: String, colorIndex: Int, selection: [SelectionID] = [], selectionCount: Int? = nil, points: [PointElement] = [],
         editing: [SelectionID] = [], cursor: Point? = nil, tool: String = "", viewport: Rect? = nil, zoom: Double? = nil,
         page: SelectionID? = nil, caret: RemoteCaret? = nil, role: String = "", branchID: String = "", isIdle: Bool = false,
         isFrozen: Bool = false, spotlight: Bool = false, followingUserID: String = "") {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.selection = selection
        self.selectionCount = selectionCount ?? selection.count
        self.points = points
        self.editing = editing
        self.cursor = cursor
        self.tool = tool
        self.viewport = viewport
        self.zoom = zoom
        self.page = page
        self.caret = caret
        self.role = role
        self.branchID = branchID
        self.isIdle = isIdle
        self.isFrozen = isFrozen
        self.spotlight = spotlight
        self.followingUserID = followingUserID
    }

    var color: Color { PresencePalette.color(at: colorIndex) }
}

/// The twelve presence colours, in assignment order (presence.adoc, "Colors").
enum PresencePalette {
    static let colors: [Color] = [
        Color(red: 0.95, green: 0.45, blue: 0.10), Color(red: 0.16, green: 0.50, blue: 0.95),
        Color(red: 0.20, green: 0.70, blue: 0.30), Color(red: 0.85, green: 0.20, blue: 0.55),
        Color(red: 0.55, green: 0.35, blue: 0.90), Color(red: 0.00, green: 0.65, blue: 0.70),
        Color(red: 0.90, green: 0.25, blue: 0.20), Color(red: 0.75, green: 0.60, blue: 0.00),
        Color(red: 0.35, green: 0.45, blue: 0.60), Color(red: 0.95, green: 0.35, blue: 0.75),
        Color(red: 0.45, green: 0.60, blue: 0.15), Color(red: 0.60, green: 0.40, blue: 0.25),
    ]

    /// Wraps after twelve, as the server's assignment does.
    static func color(at index: Int) -> Color {
        let count = colors.count
        return colors[((index % count) + count) % count]
    }

    /// A stable colour index for an account seen outside presence (a comment's author, a
    /// branch's merger): a hash of its id.
    static func index(for account: String) -> Int {
        account.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    }
}

/// Where the overlay, the avatar strip and the Object panel read the other participants from.
/// A protocol so the canvas does not depend on `WTSync`; `PresenceAdapter` adapts SYNC-009's
/// `PresenceModel` to it.
@MainActor
protocol PresenceProviding: AnyObject {
    /// Every remote participant, the local user excluded, newest arrival last.
    var participants: [RemoteParticipant] { get }
    /// The connection dropped more than a few seconds ago: "Offline -- working alone".
    var isOffline: Bool { get }
    /// Calls `handler` after every change; returns a token for `stopObserving`.
    @discardableResult
    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID
    func stopObserving(_ token: UUID)
}

/// Presence without a session: whatever participants it is given (nobody, for a memory
/// document; fixtures, in tests and UI screenshots).
@MainActor
@Observable
final class StubPresenceModel: PresenceProviding {
    var participants: [RemoteParticipant] = [] {
        didSet { notify() }
    }
    var isOffline = false {
        didSet { notify() }
    }

    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]

    init(participants: [RemoteParticipant] = []) {
        self.participants = participants
    }

    private func notify() {
        for observer in observers.values { observer() }
    }

    @discardableResult
    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func stopObserving(_ token: UUID) {
        observers[token] = nil
    }
}
