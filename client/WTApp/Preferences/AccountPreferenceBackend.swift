import Foundation
import GRPCNIOTransportHTTP2
import Observation
import WTProto
import WTSync

/// The account side of synced preferences over WTSync's `PreferenceSync` (preferences.adoc,
/// "Offline behavior"; BASIC-023): changed synced entries are queued in the app-level
/// `preferences_outbox` and sent at once; a send that fails is retried every 30 seconds until
/// it gets through; the account's map is fetched at launch, on sign-in and whenever *Sync
/// preferences with my account* is turned on, and every map the sync delivers is handed to the
/// store wholesale.  Until a sync is attached (and in test launches, which attach none) entries
/// wait here.
@MainActor
final class AccountPreferenceBackend: SyncedPreferenceBackend {
    static let retryInterval: Duration = .seconds(30)

    var onRemoteMap: (@MainActor ([String: PreferenceValue]) -> Void)?
    private(set) var sync: PreferenceSync?
    /// Entries enqueued before a sync was attached.
    private(set) var waiting: [String: PreferenceValue] = [:]
    /// The last failure, until a call succeeds (the retry is running meanwhile).
    private(set) var lastError: String?
    private var listener: Task<Void, Never>?
    private(set) var retry: Task<Void, Never>?
    private let sleep: @Sendable (Duration) async throws -> Void

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// Follows `sync`: delivers its maps, sends what waited, and fetches the account's map.
    @discardableResult
    func attach(_ sync: PreferenceSync, enabled: Bool) -> Task<Void, Never> {
        self.sync = sync
        listener?.cancel()
        listener = Task { [weak self] in
            for await map in await sync.updates() {
                guard let self else { return }
                self.onRemoteMap?(Self.values(map))
            }
        }
        let queued = waiting
        waiting = [:]
        return Task {
            do {
                try await sync.setEnabled(enabled)
                try await sync.enqueue(Self.wire(queued))
            } catch {
                note(error)
            }
            await refresh()
        }
    }

    func enqueue(_ entries: [String: PreferenceValue]) {
        guard let sync else {
            waiting.merge(entries) { $1 }
            return
        }
        let wire = Self.wire(entries)
        Task {
            do {
                try await sync.enqueue(wire)
                try await sync.push()
                succeeded()
            } catch {
                note(error)
            }
        }
    }

    /// `GetPreferences`, then whatever is still queued (launch, sign-in, reconnect, retry).
    func refresh() async {
        guard let sync else { return }
        do {
            try await sync.refresh()
            succeeded()
        } catch {
            note(error)
        }
    }

    /// *Sync preferences with my account* changed on this Mac.
    func setEnabled(_ on: Bool) async {
        guard let sync else { return }
        do {
            try await sync.setEnabled(on)
            succeeded()
        } catch {
            note(error)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        retry?.cancel()
        retry = nil
    }

    private func succeeded() {
        lastError = nil
        retry?.cancel()
        retry = nil
    }

    /// A failed call: the entries stay queued and a refresh runs again in 30 seconds.
    private func note(_ error: any Error) {
        lastError = String(describing: error)
        guard retry == nil else { return }
        let sleep = sleep
        retry = Task { [weak self] in
            do { try await sleep(Self.retryInterval) } catch { return }
            guard let self else { return }
            self.retry = nil
            await self.refresh()
        }
    }

    // MARK: Values on the wire

    /// The store's values as `account.v1.PreferenceValue`s (no stamp: the sync stamps them).
    static func wire(_ entries: [String: PreferenceValue]) -> PreferenceSync.Entries {
        entries.mapValues(wire)
    }

    static func wire(_ value: PreferenceValue) -> Wiretuner_Account_V1_PreferenceValue {
        var out = Wiretuner_Account_V1_PreferenceValue()
        switch value {
        case let .bool(value): out.boolValue = value
        case let .int(value): out.intValue = Int64(value)
        case let .double(value): out.doubleValue = value
        case let .string(value): out.stringValue = value
        case let .list(items): out.listValue = .with { $0.items = items }
        case let .color(color):
            out.colorValue = .with {
                $0.red = color.red
                $0.green = color.green
                $0.blue = color.blue
                $0.alpha = color.alpha
            }
        }
        return out
    }

    /// A delivered map as the store's values; an entry with no value is left out.
    static func values(_ map: PreferenceSync.Entries) -> [String: PreferenceValue] {
        map.compactMapValues(value)
    }

    static func value(_ wire: Wiretuner_Account_V1_PreferenceValue) -> PreferenceValue? {
        switch wire.value {
        case let .boolValue(value)?: .bool(value)
        case let .intValue(value)?: .int(Int(clamping: value))
        case let .doubleValue(value)?: .double(value)
        case let .stringValue(value)?: .string(value)
        case let .listValue(list)?: .list(list.items)
        case let .colorValue(color)?: .color(PreferenceColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha))
        // The shortcut sets are not a store value: ShortcutSetStore keeps and merges them
        // (customizing.adoc, BASIC-028).
        case .shortcutSetsValue?: nil
        case nil: nil
        }
    }
}

extension LaunchEnvironment {
    /// The preferences sync over the configured API and the app-level store; none in test
    /// launches or when the store cannot be opened.
    @MainActor
    func makePreferenceSync(account: AccountModel, infoDictionary: [String: Any]?, defaults: UserDefaults, enabled: Bool) -> PreferenceSync? {
        guard !isTesting, let url = try? PreferenceSync.defaultURL() else { return nil }
        let configuration = AuthConfiguration(infoDictionary: infoDictionary)
        let device = DeviceIdentity.current(defaults: defaults)
        let identity = GRPCSyncTransport<HTTP2ClientTransport.Posix>.Identity(clientVersion: Self.clientVersion(infoDictionary), deviceID: device)
        guard let transport = try? GRPCPreferencesTransport.http2(api: configuration.api, identity: identity) else { return nil }
        let auth = account.auth
        return try? PreferenceSync(transport: transport, url: url, device: device, enabled: enabled) { try await auth.validAccessToken() }
    }
}

/// The team floors for the review thresholds each open document's session named in `Welcome`
/// (preferences.adoc, "Sync and collaboration"; BASIC-023): the Preferences window shows the
/// front document's -- the fields read the floored value and refuse to go past it.
@MainActor
@Observable
final class ReviewFloors {
    static let shared = ReviewFloors()

    private(set) var floors: [String: ReconcilePreferences] = [:]
    /// The front document's id.
    @ObservationIgnored var activeDocument: @MainActor () -> String? = { nil }

    /// The floor of `document`'s session (nil: none).
    func update(_ floor: ReconcilePreferences?, for document: String) {
        floors[document] = floor
    }

    /// The front document's floor, else the only one.
    var current: ReconcilePreferences? {
        if let id = activeDocument(), let floor = floors[id] { return floor }
        return floors.count == 1 ? floors.values.first : nil
    }

    /// A threshold's value under `floor`: the user's value raised to the team's (lowered for
    /// *Auto-merge below*, turned on for *Always ask*); other keys pass through.
    static func floored(_ value: PreferenceValue, id: String, floor: ReconcilePreferences?) -> PreferenceValue {
        guard let floor, let bound = bound(id, floor: floor) else { return value }
        switch (value, bound) {
        case let (.int(user), .int(team)): return .int(id == PreferenceCatalog.Sync.autoMergeBelow.id ? min(user, team) : max(user, team))
        case let (.bool(user), .bool(team)): return .bool(user || team)
        default: return value
        }
    }

    /// Whether the user may set `value` under `floor`.
    static func allows(_ value: PreferenceValue, id: String, floor: ReconcilePreferences?) -> Bool {
        floored(value, id: id, floor: floor) == value
    }

    /// "Team minimum: 40 objects" under a floored field.
    static func note(id: String, floor: ReconcilePreferences?) -> String? {
        guard let floor, let bound = bound(id, floor: floor) else { return nil }
        switch bound {
        case let .int(team): return id == PreferenceCatalog.Sync.autoMergeBelow.id ? "Team maximum: \(team.formatted())" : "Team minimum: \(team.formatted())"
        case let .bool(team): return team ? "Your team always asks" : nil
        default: return nil
        }
    }

    /// The team's value of a threshold, in the preference's units.
    private static func bound(_ id: String, floor: ReconcilePreferences) -> PreferenceValue? {
        switch id {
        case PreferenceCatalog.Sync.autoMergeBelow.id: .int(floor.autoMergeBelow)
        case PreferenceCatalog.Sync.askOverlapCount.id: .int(floor.askOverlapCount)
        case PreferenceCatalog.Sync.askOverlapShare.id: .int(Int((floor.askOverlapShare * 100).rounded()))
        case PreferenceCatalog.Sync.alwaysAsk.id: .bool(floor.alwaysAsk)
        case PreferenceCatalog.Sync.suggestReviewAfterHours.id: .int(Int(floor.suggestReviewAfter.components.seconds / 3600))
        default: nil
        }
    }
}
