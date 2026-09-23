import CoreGraphics
import Foundation
import Observation
import Synchronization
import WTCRDT
import WTProto

/// One other person in the document right now (docs/_includes/collaboration/presence.adoc), as
/// the canvas, the avatar strip and the panels read them: a `PresenceUpdate` in Swift types.
public struct PresenceParticipant: Sendable, Hashable, Identifiable {
    /// A text caret, when they are editing text.
    public struct Caret: Sendable, Hashable {
        public var node: OpID
        public var text: RegisterPath?
        /// The character the caret is before; `.zero` = the end.
        public var position: OpID
        /// The selection's other end, nil for a bare caret.
        public var rangeEnd: OpID?
    }

    /// The participant's key: the account (the frame carries no session id, so two Macs of one
    /// person are one participant; presence.adoc records this).
    public var id: String { userID }
    public var userID: String
    public var displayName: String
    /// The avatar's blob hash (32 raw bytes, or empty).
    public var avatarSHA256: Data
    public var role: Wiretuner_Account_V1_DocumentRole
    /// Index into the 12-color palette, stable per (document, person).
    public var colorIndex: Int
    /// Set when they are on a branch of this document.
    public var branchID: String
    /// No input for two minutes: the avatar is dimmed.
    public var isIdle: Bool
    public var page: OpID?
    /// Pointer in pasteboard points; nil when off the canvas.
    public var cursor: CGPoint?
    /// Visible rect in pasteboard points and zoom, for Follow.
    public var viewport: CGRect?
    public var zoom: Double?
    public var tool: String
    public var selection: [OpID]
    /// The whole selection's size (the frame carries at most 200 ids).
    public var selectionCount: Int
    public var subSelection: [RegisterPath]
    /// Objects they are actively changing ("Priya is editing this object").
    public var editing: [OpID]
    public var caret: Caret?
    public var spotlight: Bool
    public var followingUserID: String
    /// Their connection or ours dropped: drawn where they were until cleared.
    public var frozen: Bool

    /// The participant a frame describes.
    public init(_ update: Wiretuner_Sync_V1_PresenceUpdate) {
        userID = update.user.userID
        displayName = update.user.displayName
        avatarSHA256 = update.user.avatarSha256
        role = update.user.role
        colorIndex = Int(update.colorIndex)
        branchID = update.branchID
        isIdle = update.state == .idle
        page = update.hasPage ? OpID(update.page) : nil
        cursor = update.hasCursor ? CGPoint(x: update.cursor.x, y: update.cursor.y) : nil
        viewport = update.hasViewport ? CGRect(x: update.viewport.visible.x, y: update.viewport.visible.y,
                                               width: update.viewport.visible.width, height: update.viewport.visible.height) : nil
        zoom = update.hasViewport ? update.viewport.zoom : nil
        tool = update.tool
        selection = update.selection.map(OpID.init)
        selectionCount = max(Int(update.selectionCount), update.selection.count)
        subSelection = update.subSelection.compactMap(RegisterPath.init)
        editing = update.editing.map(OpID.init)
        caret = update.hasCaret ? Caret(node: OpID(update.caret.node), text: RegisterPath(update.caret.text),
                                        position: OpID(update.caret.position),
                                        rangeEnd: update.caret.hasRangeEnd ? OpID(update.caret.rangeEnd) : nil) : nil
        spotlight = update.spotlight
        followingUserID = update.followingUserID
        frozen = false
    }
}

/// Where WTApp reads presence from: `PresenceModel` conforms, and WTApp's `PresenceProviding`
/// (the canvas overlay's seam) adapts it.
@MainActor
public protocol PresenceObservable: AnyObject {
    /// Every remote participant, the local user excluded, newest arrival last.
    var participants: [PresenceParticipant] { get }
    /// The connection dropped more than a few seconds ago: "Offline -- working alone".
    var isOffline: Bool { get }
    /// Calls `handler` after every change; returns a token for `stopObserving`.
    @discardableResult
    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID
    func stopObserving(_ token: UUID)
}

/// The presence of everyone else in one document (SYNC-009; presence.adoc, "Client"): fed by the
/// subscription's `PresenceSnapshot` and `PresenceUpdate` frames through `SyncClient.events()`,
/// observed on the main actor.  A `GONE` frame removes a participant at once (the server sends
/// one when an entry expires, 15 s after its last update, or its subscription ends).  When our
/// own connection drops every participant freezes where it was, and after `clearAfter` (5 s) they
/// are cleared and `isOffline` is set; the next snapshot after reconnecting restores them.
@MainActor @Observable
public final class PresenceModel: PresenceObservable {
    public private(set) var participants: [PresenceParticipant] = []
    public private(set) var isOffline = false
    /// The signed-in account, never listed.
    public let localUserID: String
    @ObservationIgnored public let clearAfter: Duration

    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var clearing: Task<Void, Never>?
    @ObservationIgnored private var feed: Task<Void, Never>?

    public init(localUserID: String, clearAfter: Duration = .seconds(5)) {
        self.localUserID = localUserID
        self.clearAfter = clearAfter
    }

    /// Feeds the model from a sync client's events (`SyncClient.events()`) until `unbind`.
    public func bind(to events: AsyncStream<SyncEvent>) {
        feed?.cancel()
        feed = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    public func unbind() {
        feed?.cancel()
        feed = nil
        clearing?.cancel()
        clearing = nil
    }

    func handle(_ event: SyncEvent) {
        switch event {
        case .presence(let snapshot): apply(snapshot)
        case .presenceUpdate(let update): apply(update)
        case .connection(let connected): connectionChanged(connected)
        default: break
        }
    }

    /// The participant with `id`, if present.
    public func participant(_ id: String) -> PresenceParticipant? {
        participants.first { $0.id == id }
    }

    /// Everyone present, replacing what was known; people already listed keep their place.
    public func apply(_ snapshot: Wiretuner_Sync_V1_PresenceSnapshot) {
        let incoming = snapshot.participants.filter { $0.state != .gone && $0.user.userID != localUserID }.map(PresenceParticipant.init)
        var next = participants.compactMap { known in incoming.last { $0.id == known.id } }
        for participant in incoming where !next.contains(where: { $0.id == participant.id }) {
            next.append(participant)
        }
        endOffline()
        participants = next
        notify()
    }

    /// One participant's current state; `GONE` removes them.
    public func apply(_ update: Wiretuner_Sync_V1_PresenceUpdate) {
        guard update.user.userID != localUserID else { return }
        let id = update.user.userID
        if update.state == .gone {
            participants.removeAll { $0.id == id }
        } else if let index = participants.firstIndex(where: { $0.id == id }) {
            participants[index] = PresenceParticipant(update)
        } else {
            participants.append(PresenceParticipant(update))
        }
        notify()
    }

    /// Our subscription came up or ended (presence.adoc, "Offline behavior").
    public func connectionChanged(_ connected: Bool) {
        if connected {
            endOffline()
            notify()
            return
        }
        for index in participants.indices {
            participants[index].frozen = true
        }
        notify()
        clearing?.cancel()
        clearing = Task { [weak self, clearAfter] in
            try? await Task.sleep(for: clearAfter)
            guard !Task.isCancelled, let self else { return }
            self.participants = []
            self.isOffline = true
            self.notify()
        }
    }

    private func endOffline() {
        clearing?.cancel()
        clearing = nil
        isOffline = false
        for index in participants.indices {
            participants[index].frozen = false
        }
    }

    @discardableResult
    public func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    public func stopObserving(_ token: UUID) {
        observers[token] = nil
    }

    private func notify() {
        for observer in observers.values {
            observer()
        }
    }
}

/// The caller's own presence as WTApp publishes it (presence.adoc, "Client"): cursor, viewport,
/// selection, editing set and caret are written as they change; the sync client reads it at
/// 20 Hz and sends it when it changed (`UpdatePresence`, coalesced), and every 10 s so the entry
/// does not expire.  Two minutes without input reads as `IDLE`; any input clears it.  With
/// *Show my cursor and selection to others* off, pointer, tool, selection, sub-selection and caret
/// are left out.
public final class LocalPresence: PresenceSource {
    private struct State {
        var update = Wiretuner_Sync_V1_PresenceUpdate()
        var lastInput: ContinuousClock.Instant
        var sharing = true
    }

    private let state: Mutex<State>
    private let idleAfter: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(idleAfter: Duration = .seconds(120), now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.idleAfter = idleAfter
        self.now = now
        state = Mutex(State(lastInput: now()))
    }

    /// Changes the published state; counts as input.
    public func update(_ body: (inout Wiretuner_Sync_V1_PresenceUpdate) -> Void) {
        let at = now()
        state.withLock {
            body(&$0.update)
            $0.lastInput = at
        }
    }

    /// Key or mouse input that changed nothing published (it still ends `IDLE`).
    public func input() {
        let at = now()
        state.withLock { $0.lastInput = at }
    }

    /// The *Show my cursor and selection to others* preference.
    public var sharing: Bool {
        get { state.withLock { $0.sharing } }
        set { state.withLock { $0.sharing = newValue } }
    }

    public func presence() async -> Wiretuner_Sync_V1_PresenceUpdate? {
        let at = now()
        return state.withLock { state in
            var update = state.update
            update.state = at - state.lastInput >= idleAfter ? .idle : .active
            if !state.sharing {
                update.clearCursor()
                update.tool = ""
                update.selection = []
                update.selectionCount = 0
                update.subSelection = []
                update.clearCaret()
            }
            return update
        }
    }
}
