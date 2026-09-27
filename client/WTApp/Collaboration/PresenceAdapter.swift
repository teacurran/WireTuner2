import Foundation
import Observation
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync

/// `WTSync.PresenceModel` (or any `PresenceObservable`) as the canvas and the panels read it
/// (presence.adoc, "Client"): each `PresenceParticipant` becomes a `RemoteParticipant` in
/// WTApp's own types, recomputed when the model changes.
@MainActor
@Observable
final class PresenceAdapter: PresenceProviding {
    @ObservationIgnored let source: any PresenceObservable
    private(set) var participants: [RemoteParticipant] = []
    private(set) var isOffline = false
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var token: UUID?

    init(source: any PresenceObservable) {
        self.source = source
        refresh()
        token = source.observe { [weak self] in self?.refresh() }
    }

    /// Stops following the model (the session ended).
    func detach() {
        if let token { source.stopObserving(token) }
        token = nil
    }

    private func refresh() {
        participants = source.participants.map(Self.participant)
        isOffline = source.isOffline
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

    /// One participant in WTApp's types.
    nonisolated static func participant(_ source: PresenceParticipant) -> RemoteParticipant {
        RemoteParticipant(
            id: source.id, name: source.displayName.isEmpty ? "Someone" : source.displayName, colorIndex: source.colorIndex,
            selection: source.selection.map(SelectionID.init), selectionCount: source.selectionCount,
            points: source.subSelection.compactMap(point), editing: source.editing.map(SelectionID.init),
            cursor: source.cursor.map { Point(x: Double($0.x), y: Double($0.y)) }, tool: source.tool,
            viewport: source.viewport.map { Rect(x: Double($0.minX), y: Double($0.minY), width: Double($0.width), height: Double($0.height)) },
            zoom: source.zoom, page: source.page.map(SelectionID.init),
            caret: source.caret.map { RemoteCaret(node: SelectionID($0.node), position: $0.position, rangeEnd: $0.rangeEnd, text: $0.text ?? TextFields.text) },
            role: roleTitle(source.role), branchID: source.branchID, isIdle: source.isIdle, isFrozen: source.frozen,
            spotlight: source.spotlight, followingUserID: source.followingUserID, canvas: source.canvas
        )
    }

    /// A sub-selection field path read as a selected point: its first element segment is the
    /// contour, its last the point (`contours.<contour>.points.<point>`); nil for anything else.
    nonisolated static func point(_ path: RegisterPath) -> RemoteParticipant.PointElement? {
        let elements = path.segments.compactMap { segment -> OpID? in
            if case .element(let id) = segment { return id }
            return nil
        }
        guard elements.count >= 2, let contour = elements.first, let point = elements.last else { return nil }
        return RemoteParticipant.PointElement(contour: contour, point: point)
    }

    /// The hover card's role word.
    nonisolated static func roleTitle(_ role: Wiretuner_Account_V1_DocumentRole) -> String {
        switch role {
        case .owner: "Owner"
        case .editor: "Editor"
        case .commenter: "Commenter"
        case .viewer: "Viewer"
        default: ""
        }
    }
}
