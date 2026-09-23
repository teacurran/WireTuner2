import Foundation

/// The commands the preferences system delivers in place of the standard placeholders:
/// menu:WireTuner[Settings…] (`Cmd+,`) and menu:View[Smart Guides] (`Cmd+U`), which writes
/// `general.smart_guides` through the store so the check mark and the preference agree.
enum PreferenceCommands {
    @MainActor
    static func commands(store: PreferenceStore, showPreferences: @escaping @MainActor @Sendable () -> Void) -> [Command] {
        let smartGuides = PreferenceCatalog.General.smartGuides
        return [
            Command(
                id: StandardCommands.ID.settings, title: "Settings…", key: KeyEquivalent(",", .command),
                menu: MenuPath(StandardCommands.Menu.application, section: 1), keywords: ["preferences"],
                action: .perform(showPreferences)
            ),
            Command(
                id: StandardCommands.ID.smartGuides, title: "Smart Guides", key: KeyEquivalent("u", .command),
                menu: MenuPath(StandardCommands.Menu.view, section: 3), keywords: ["snap", "align"],
                validation: { .checked(store[smartGuides]) },
                action: .perform { store.set(!store[smartGuides], for: smartGuides) }
            ),
        ]
    }

    @MainActor
    static func install(into registry: CommandRegistry, store: PreferenceStore, showPreferences: @escaping @MainActor @Sendable () -> Void) {
        for command in commands(store: store, showPreferences: showPreferences) { registry.replace(command) }
    }
}
