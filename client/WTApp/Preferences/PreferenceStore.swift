import Foundation
import Observation

/// The account side of synced preferences.  BASIC-023 implements it over
/// `AccountService.GetPreferences`/`SetPreferences` with a `preferences_outbox`; until then
/// `LocalPreferenceBackend` keeps everything on this Mac.
@MainActor
protocol SyncedPreferenceBackend: AnyObject {
    /// Synced entries changed on this Mac, to push.  A reset sends the explicit default so
    /// other Macs reset too (preferences.adoc, "Client").
    func enqueue(_ entries: [String: PreferenceValue])
    /// Set by the store: called with the account's full map whenever the backend fetches it.
    var onRemoteMap: (@MainActor ([String: PreferenceValue]) -> Void)? { get set }
}

/// The stub backend: accepts pushes and drops them, never delivers a remote map.
@MainActor
final class LocalPreferenceBackend: SyncedPreferenceBackend {
    private(set) var pushCount = 0
    var onRemoteMap: (@MainActor ([String: PreferenceValue]) -> Void)?

    init() {}

    func enqueue(_ entries: [String: PreferenceValue]) {
        pushCount += 1
    }
}

/// One change the store reports to observers.
struct PreferenceChange: Equatable, Sendable {
    let id: String
    let value: PreferenceValue
}

/// Reads and writes preferences.  Every value lives in `UserDefaults` under `wt.<id>`, so the
/// app works offline and at launch before any network; synced keys are additionally handed to
/// the `SyncedPreferenceBackend`.  An unset key reads as its catalog default, so a default
/// changed in a later version reaches everyone who never touched it.
@MainActor
@Observable
final class PreferenceStore {
    nonisolated static let suiteName = "com.villagecompute.wiretuner"
    nonisolated static let defaultsPrefix = "wt."

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let backend: SyncedPreferenceBackend
    @ObservationIgnored let catalog: [String: AnyPreferenceKey]

    /// Bumped on every change so SwiftUI forms reading through the store redraw.
    private(set) var revision = 0

    @ObservationIgnored private var continuations: [UUID: AsyncStream<PreferenceChange>.Continuation] = [:]

    /// - Parameter backend: the account side of synced keys; `nil` uses `LocalPreferenceBackend`.
    init(defaults: UserDefaults = PreferenceStore.makeDefaults(), backend: SyncedPreferenceBackend? = nil, catalog: [AnyPreferenceKey] = PreferenceCatalog.all) {
        self.defaults = defaults
        let backend = backend ?? LocalPreferenceBackend()
        self.backend = backend
        self.catalog = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        backend.onRemoteMap = { [weak self] map in self?.applyRemote(map) }
    }

    /// The `com.villagecompute.wiretuner` suite.  That is also the app's bundle identifier,
    /// for which `UserDefaults(suiteName:)` refuses a suite; the standard defaults are then
    /// the same domain.
    nonisolated static func makeDefaults(suiteName: String = PreferenceStore.suiteName) -> UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    // MARK: Reading

    subscript<Value>(key: PreferenceKey<Value>) -> Value {
        Value(preferenceValue: value(for: key.erased)) ?? key.defaultValue
    }

    /// The stored value, or the default when unset or unreadable.
    func value(for key: AnyPreferenceKey) -> PreferenceValue {
        _ = revision
        guard let object = defaults.object(forKey: key.defaultsKey),
            let value = PreferenceValue(propertyList: object, like: key.defaultValue), key.accepts(value)
        else { return key.defaultValue }
        return value
    }

    func isSet(_ key: AnyPreferenceKey) -> Bool {
        defaults.object(forKey: key.defaultsKey) != nil
    }

    // MARK: Writing

    /// Stores `value`; returns `false` (and changes nothing) when the catalog rejects it:
    /// wrong type, outside the range, not one of the options.
    @discardableResult
    func set<Value>(_ value: Value, for key: PreferenceKey<Value>) -> Bool {
        set(value.preferenceValue, for: key.erased)
    }

    @discardableResult
    func set(_ value: PreferenceValue, for key: AnyPreferenceKey) -> Bool {
        guard key.accepts(value) else { return false }
        guard value != self.value(for: key) || !isSet(key) else { return true }
        write(value, for: key)
        if key.scope == .synced, syncEnabled { backend.enqueue([key.id: value]) }
        return true
    }

    private func write(_ value: PreferenceValue, for key: AnyPreferenceKey) {
        defaults.set(value.propertyList, forKey: key.defaultsKey)
        didChange(key, to: value)
    }

    private func didChange(_ key: AnyPreferenceKey, to value: PreferenceValue) {
        revision += 1
        let change = PreferenceChange(id: key.id, value: value)
        for continuation in continuations.values { continuation.yield(change) }
    }

    /// Whether synced keys follow the account on this Mac.
    var syncEnabled: Bool { self[PreferenceCatalog.Sync.enabled] }

    // MARK: Restore defaults

    /// Restores every key of `category`; synced keys push their explicit default.
    func reset(category: PreferenceCategory) {
        reset(catalog.values.filter { $0.category == category })
    }

    /// Restore Defaults: every category.
    func resetAll() {
        reset(Array(catalog.values))
    }

    private func reset(_ keys: [AnyPreferenceKey]) {
        var pushed: [String: PreferenceValue] = [:]
        for key in keys.sorted(by: { $0.id < $1.id }) where isSet(key) {
            defaults.removeObject(forKey: key.defaultsKey)
            didChange(key, to: key.defaultValue)
            if key.scope == .synced { pushed[key.id] = key.defaultValue }
        }
        if !pushed.isEmpty, syncEnabled { backend.enqueue(pushed) }
    }

    // MARK: Remote

    /// Applies the account's map wholesale (newest-wins is resolved by the server): every
    /// synced key takes the map's value, or its default when the map has none.  Ignored while
    /// syncing is off on this Mac.
    func applyRemote(_ map: [String: PreferenceValue]) {
        guard syncEnabled else { return }
        for key in catalog.values.sorted(by: { $0.id < $1.id }) where key.scope == .synced {
            if let value = map[key.id], key.accepts(value) {
                if value != self.value(for: key) || !isSet(key) { write(value, for: key) }
            } else if isSet(key) {
                defaults.removeObject(forKey: key.defaultsKey)
                didChange(key, to: key.defaultValue)
            }
        }
    }

    // MARK: Observation

    /// Every change from now on.
    func changes() -> AsyncStream<PreferenceChange> {
        let (stream, continuation) = AsyncStream<PreferenceChange>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        return stream
    }

    /// The key's current value, then every new value.
    func values<Value>(for key: PreferenceKey<Value>) -> AsyncStream<Value> {
        let changes = changes()
        let initial = self[key]
        let id = key.id
        return AsyncStream { continuation in
            continuation.yield(initial)
            let task = Task {
                for await change in changes where change.id == id {
                    if let value = Value(preferenceValue: change.value) { continuation.yield(value) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Observers currently attached (tests).
    var observerCount: Int { continuations.count }
}
