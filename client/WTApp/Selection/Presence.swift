import Foundation
import Observation
import WTRender

/// One other person with the document open, as the selection overlay needs them
/// (presence.adoc, "Selections and carets").  `WTSync.PresenceModel` (SYNC-009) fills these
/// from `PresenceUpdate` frames; `selection` then holds node ids.
struct RemoteParticipant: Identifiable, Hashable, Sendable {
    /// The session id (one person may have two Macs open).
    let id: String
    var name: String
    /// Index into the 12-colour palette, stable per (document, person); server-assigned.
    var colorIndex: Int
    var selection: [SelectionID]

    init(id: String, name: String, colorIndex: Int, selection: [SelectionID] = []) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.selection = selection
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
}

/// Where the overlay reads the other participants from.  A protocol so the canvas does not
/// depend on `WTSync`; SYNC-009's `PresenceModel` conforms to it when it lands.
@MainActor
protocol PresenceProviding: AnyObject {
    /// Every remote participant, the local user excluded, in a stable order.
    var participants: [RemoteParticipant] { get }
    /// Calls `handler` after every change; returns a token for `stopObserving`.
    @discardableResult
    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID
    func stopObserving(_ token: UUID)
}

/// The stand-in presence model until SYNC-009: holds whatever participants it is given
/// (nobody, in the app; fixtures, in tests and UI screenshots).
@MainActor
@Observable
final class StubPresenceModel: PresenceProviding {
    var participants: [RemoteParticipant] = [] {
        didSet { for observer in observers.values { observer() } }
    }

    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]

    init(participants: [RemoteParticipant] = []) {
        self.participants = participants
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
