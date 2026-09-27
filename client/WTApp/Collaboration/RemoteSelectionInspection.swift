import AppKit
import WTGeometry

/// Inspecting a collaborator's selection (inspect.adoc, "Inspecting someone else's selection";
/// COLLAB-037): menu:View[Collaborators > Inspect <name>'s Selection], or a click on the name tag of
/// their selection outline in Inspect mode, points the Inspect panel at that person's
/// `PresenceUpdate.selection`.  The panel follows their selection as their presence changes and
/// stops when the local selection changes, when they leave, or when it is stopped.
@MainActor
final class RemoteSelectionInspection {
    enum ID {
        static let inspectSelection: CommandID = "view.collaborators.inspectSelection"
    }

    private(set) var participantID: String?
    private(set) var name = ""
    private(set) var colorIndex = 0

    init() {}

    var isActive: Bool { participantID != nil }

    /// "Priya's selection", over the panel.
    var title: String { "\(name)'s selection" }

    func start(_ participant: RemoteParticipant) {
        participantID = participant.id
        name = participant.name
        colorIndex = participant.colorIndex
    }

    /// Stops inspecting; returns whether it was.
    @discardableResult
    func stop() -> Bool {
        guard participantID != nil else { return false }
        participantID = nil
        name = ""
        return true
    }

    /// The inspected participant among `participants`, nil when not inspecting or they left.
    func participant(in participants: [RemoteParticipant]) -> RemoteParticipant?  {
        guard let participantID else { return nil }
        return participants.first { $0.id == participantID }
    }

    /// Presence changed: follows a new name or colour; stops (and returns false) when the person left.
    @discardableResult
    func presenceDidChange(_ participants: [RemoteParticipant]) -> Bool {
        guard isActive else { return false }
        guard let participant = participant(in: participants) else {
            stop()
            return false
        }
        name = participant.name
        colorIndex = participant.colorIndex
        return true
    }

    /// The collaborator whose selection name tag is under `viewPoint` in `window` (topmost tag
    /// first), nil when none is or selections are not drawn.
    static func participant(atTag viewPoint: Point, in window: DocumentWindowController) -> RemoteParticipant? {
        guard window.environment.preferences[PreferenceCatalog.Sync.showSelections] else { return nil }
        let participants = window.presence.participants
        let overlay = SelectionOverlay(document: window.documentHandle, viewport: window.canvas.viewport)
        guard let mark = overlay.remoteMarks(for: participants).last(where: { $0.tagRect.contains(viewPoint) }) else { return nil }
        return participants.first { $0.id == mark.participantID }
    }

    static let noDocument = CollaborationCommands.noDocument
    static let nobodyElse = CollaborationCommands.nobodyElse

    /// menu:View[Collaborators > Inspect <name>'s Selection]: the collaborator the context menu
    /// was opened on, else the first one present (as *Follow*); `inspect` shows the panel on them.
    static func command(window: @escaping @MainActor () -> DocumentWindowController?,
                        inspect: @escaping @MainActor (DocumentWindowController, RemoteParticipant) -> Void) -> Command {
        Command(
            id: ID.inspectSelection, title: "Inspect <name>'s Selection", menu: CollaborationCommands.menu(0), contexts: [.presence],
            keywords: ["inspect", "presence", "selection", "measure"],
            validation: {
                guard let window = window() else { return .disabled(noDocument) }
                guard let target = CollaborationCommands.followTarget(window) else { return .disabled(nobodyElse) }
                return CommandValidation(title: "Inspect \(target.name)'s Selection")
            },
            action: .perform {
                guard let window = window(), let target = CollaborationCommands.followTarget(window) else { return }
                inspect(window, target)
            }
        )
    }
}

extension InspectTool {
    /// A click on a collaborator's name tag in Inspect mode: set by the Inspect panel's features
    /// to inspect that person's selection (COLLAB-037).
    @MainActor static var nameTagClicked: ((DocumentWindowController, RemoteParticipant) -> Void)?

    /// Whether the click at `viewPoint` landed on a name tag and was taken for inspecting.
    func inspectsNameTag(at viewPoint: Point) -> Bool {
        guard let handler = Self.nameTagClicked, let window = controller?.window,
              let participant = RemoteSelectionInspection.participant(atTag: viewPoint, in: window) else { return false }
        handler(window, participant)
        return true
    }
}
