import Foundation
import WTProto
import WTSync

/// The server's synced preferences as the preference scenarios need them (BASIC-023;
/// preferences.adoc, "Merge semantics"): per account, per key the entry with the greater
/// `updated_at_ms` (receipt order on ties), answered as the full map -- `sync.shortcut_sets` per set,
/// with its tombstones aged on `now` (BASIC-028, `ShortcutSetSync`).  `transport(account:link:)`
/// gives a device its `PreferencesTransport` through that device's network link: a partitioned
/// device is offline.
public final class SimAccountService: Sendable {
    private let accounts = Locked([String: [String: Wiretuner_Account_V1_PreferenceValue]]())
    private let now: @Sendable () -> Int64

    /// A service whose clock, in milliseconds, is `now` (the simulation's, in scenarios).
    public init(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.now = now
    }

    /// The account's stored map.
    public func preferences(of account: String) -> [String: Wiretuner_Account_V1_PreferenceValue] {
        accounts.withLock { $0[account] ?? [:] }
    }

    /// A device's transport for `account`, through `link`.
    public func transport(account: String, link: NetworkLink) -> any PreferencesTransport {
        SimPreferencesTransport(service: self, account: account, link: link)
    }

    func set(_ changes: [String: Wiretuner_Account_V1_PreferenceValue], for account: String) -> [String: Wiretuner_Account_V1_PreferenceValue] {
        let now = now()
        return accounts.withLock { accounts in
            var map = accounts[account] ?? [:]
            for (id, value) in changes {
                map[id] = ShortcutSetSync.merge(map[id], value, now: now)
            }
            accounts[account] = map
            return map
        }
    }
}

/// `SimAccountService` through one device's link.
struct SimPreferencesTransport: PreferencesTransport {
    let service: SimAccountService
    let account: String
    let link: NetworkLink

    private func online() throws {
        guard !link.isPartitioned else { throw SyncCallError(code: 14, message: "offline") }
    }

    func getPreferences(_ request: Wiretuner_Account_V1_GetPreferencesRequest, token: String) async throws
        -> Wiretuner_Account_V1_GetPreferencesResponse {
        try online()
        var response = Wiretuner_Account_V1_GetPreferencesResponse()
        response.preferences.values = service.preferences(of: account)
        return response
    }

    func setPreferences(_ request: Wiretuner_Account_V1_SetPreferencesRequest, token: String) async throws
        -> Wiretuner_Account_V1_SetPreferencesResponse {
        try online()
        var response = Wiretuner_Account_V1_SetPreferencesResponse()
        response.preferences.values = service.set(request.changes.values, for: account)
        return response
    }
}
