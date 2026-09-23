import Foundation

/// The collaboration menu items (presence.adoc, "Display options", "Following someone";
/// reconcile.adoc, "The review sheet"): menu:File[Review Merge…], and menu:View[Collaborators]
/// with *Follow <name>*, *Stop Following*, *Spotlight Me* and the three display switches, which
/// are the same switches as the Preferences rows.
enum CollaborationCommands {
    enum ID {
        static let reviewMerge: CommandID = "file.reviewMerge"
        static let follow = ContextMenuCatalog.ID.follow
        static let stopFollowing: CommandID = "view.collaborators.stopFollowing"
        static let spotlight: CommandID = "view.collaborators.spotlight"
        static let showCursors: CommandID = "view.collaborators.showCursors"
        static let showNames: CommandID = "view.collaborators.showNames"
        static let showSelections: CommandID = "view.collaborators.showSelections"
    }

    static let collaborators = "Collaborators"
    static let noDocument = "No document is open"
    static let nothingToReview = "There is no recent merge to review"
    static let nobodyElse = "Nobody else has this document open"
    static let notFollowing = "You are not following anyone"

    static func menu(_ subsection: Int) -> MenuPath {
        MenuPath(StandardCommands.Menu.view, collaborators, section: StandardCommands.Section.viewVisibility, subsection: subsection)
    }

    @MainActor
    static func commands(window: @escaping @MainActor @Sendable () -> DocumentWindowController?, preferences: PreferenceStore) -> [Command] {
        let toggles: [(CommandID, PreferenceKey<Bool>)] = [
            (ID.showCursors, PreferenceCatalog.Sync.showCursors), (ID.showNames, PreferenceCatalog.Sync.showCursorNames),
            (ID.showSelections, PreferenceCatalog.Sync.showSelections),
        ]
        return [
            Command(
                id: ID.reviewMerge, title: "Review Merge…", menu: MenuPath(StandardCommands.Menu.file, section: 1),
                keywords: ["merge", "conflict", "offline", "reconcile"],
                validation: {
                    guard let window = window() else { return .disabled(noDocument) }
                    return window.session?.canReview == true ? .enabled : .disabled(nothingToReview)
                },
                action: .perform { _ = window()?.reviewMerge() }
            ),
            Command(
                id: ID.follow, title: "Follow <name>", menu: menu(0), contexts: [.presence], keywords: ["follow", "presence"],
                validation: {
                    guard let window = window() else { return .disabled(noDocument) }
                    guard let target = followTarget(window) else { return .disabled(nobodyElse) }
                    return CommandValidation(title: "Follow \(target.name)")
                },
                action: .perform {
                    guard let window = window(), let target = followTarget(window) else { return }
                    window.collaboration.follow(target.id)
                }
            ),
            Command(
                id: ID.stopFollowing, title: "Stop Following", menu: menu(0),
                validation: { window()?.collaboration.follow.isFollowing == true ? .enabled : .disabled(notFollowing) },
                action: .perform { window()?.collaboration.stopFollowing() }
            ),
            Command(
                id: ID.spotlight, title: "Spotlight Me", menu: menu(0), keywords: ["present", "follow me"],
                validation: {
                    guard let window = window() else { return .disabled(noDocument) }
                    return CommandValidation(title: window.collaboration.follow.isSpotlighting ? "Stop Spotlighting" : "Spotlight Me")
                },
                action: .perform { window()?.collaboration.toggleSpotlight() }
            ),
        ] + toggles.map { id, key in
            Command(
                id: id, title: key.title, menu: menu(1), validation: { .checked(preferences[key]) },
                action: .perform { preferences.set(!preferences[key], for: key) }
            )
        }
    }

    /// Whom *Follow* follows: the collaborator whose presence marker the context menu was opened
    /// on, else the first one present.
    @MainActor
    static func followTarget(_ window: DocumentWindowController) -> RemoteParticipant? {
        let participants = window.presence.participants
        if case .presence(let id, _)? = window.contextTarget, let participant = participants.first(where: { $0.id == id }) { return participant }
        return participants.first
    }

    /// Registers the commands; *Follow <name>* replaces the context menu catalog's placeholder in
    /// place.
    @MainActor
    static func install(into registry: CommandRegistry, window: @escaping @MainActor @Sendable () -> DocumentWindowController?, preferences: PreferenceStore) {
        for command in commands(window: window, preferences: preferences) { registry.replace(command) }
    }
}
