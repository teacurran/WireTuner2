import AppKit

/// The Sounds preferences' playback (preferences.adoc, "Sounds"; BASIC-025): the system alert
/// sound chosen for each snap kind, played when the snap resolver reports a snap, at most once
/// per 100 ms, and never while *Play user interface sound effects* is off in System Settings.
/// Choosing a sound in the Preferences window plays it once as a preview.
@MainActor
final class SnapSoundPlayer {
    /// Snaps closer together than this play one sound.
    static let minimumInterval = 0.1
    /// The global default behind *Play user interface sound effects*.
    static let uiSoundsKey = "com.apple.sound.uiaudio.enabled"

    let preferences: PreferenceStore
    /// Plays the named system sound; replaceable in tests.
    var play: @MainActor (String) -> Void = { name in NSSound(named: NSSound.Name(name))?.play() }
    /// Whether macOS plays interface sounds; replaceable in tests.
    var uiSoundsEnabled: @MainActor () -> Bool = { SnapSoundPlayer.systemUISoundsEnabled() }
    var clock: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var lastPlayed = -Double.infinity
    private var observation: UUID?

    init(preferences: PreferenceStore) {
        self.preferences = preferences
        observation = preferences.observe { [weak self] change in self?.preferenceDidChange(change) }
    }

    /// The preference that names the sound for `kind`.
    static func key(for kind: SnapKind) -> PreferenceKey<String> {
        switch kind {
        case .point: PreferenceCatalog.Sounds.snapPoint
        case .object: PreferenceCatalog.Sounds.snapObject
        case .grid: PreferenceCatalog.Sounds.snapGrid
        case .guide: PreferenceCatalog.Sounds.snapGuide
        }
    }

    /// `global` read from the global domain: absent means on.
    static func systemUISoundsEnabled(global: [String: Any]? = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)) -> Bool {
        (global?[uiSoundsKey] as? NSNumber)?.boolValue ?? true
    }

    /// A snap during a drag: plays its sound unless one played in the last 100 ms.  Returns
    /// whether a sound played.
    @discardableResult
    func snapped(_ kind: SnapKind) -> Bool {
        let name = preferences[Self.key(for: kind)]
        let now = clock()
        guard !name.isEmpty, uiSoundsEnabled(), now - lastPlayed >= Self.minimumInterval else { return false }
        lastPlayed = now
        play(name)
        return true
    }

    /// A sound chosen in the Preferences window plays once as a preview.
    private func preferenceDidChange(_ change: PreferenceChange) {
        guard SnapKind.allCases.contains(where: { Self.key(for: $0).id == change.id }),
            case let .string(name) = change.value, !name.isEmpty, uiSoundsEnabled()
        else { return }
        play(name)
    }
}
