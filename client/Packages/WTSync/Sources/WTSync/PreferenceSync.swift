import Foundation
import GRDB
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import SwiftProtobuf
import WTProto

/// The preference calls of `AccountService` (preferences.adoc, "Server"; PROTO-009 and the
/// server's per-key newest-wins merge).  `GRPCPreferencesTransport` is the network one; tests and
/// the simulator supply their own.
public protocol PreferencesTransport: Sendable {
    func getPreferences(_ request: Wiretuner_Account_V1_GetPreferencesRequest, token: String) async throws
        -> Wiretuner_Account_V1_GetPreferencesResponse
    func setPreferences(_ request: Wiretuner_Account_V1_SetPreferencesRequest, token: String) async throws
        -> Wiretuner_Account_V1_SetPreferencesResponse
}

/// `PreferencesTransport` over grpc-swift 2, with the metadata of api-conventions.adoc; rejections
/// arrive as `SyncCallError`s as they do from `GRPCSyncTransport`.
public final class GRPCPreferencesTransport<Transport: ClientTransport>: PreferencesTransport {
    private let client: GRPCClient<Transport>
    private let service: Wiretuner_Account_V1_AccountService.Client<Transport>
    private let identity: GRPCSyncTransport<Transport>.Identity
    private let connections: Task<Void, Never>

    /// A transport over `transport`; its connections run until `close()`.
    public init(transport: Transport, identity: GRPCSyncTransport<Transport>.Identity) {
        let client = GRPCClient(transport: transport)
        self.client = client
        service = Wiretuner_Account_V1_AccountService.Client(wrapping: client)
        self.identity = identity
        connections = Task { try? await client.runConnections() }
    }

    /// Closes the connection once in-flight calls have finished.
    public func close() async {
        client.beginGracefulShutdown()
        await connections.value
    }

    private func metadata(_ token: String) -> Metadata {
        var metadata = Metadata()
        metadata.addString("Bearer \(token)", forKey: "authorization")
        metadata.addString("macos/\(identity.clientVersion)", forKey: "wt-client")
        metadata.addString(identity.deviceID, forKey: "wt-device")
        metadata.addString(UUID().uuidString, forKey: "wt-request-id")
        return metadata
    }

    private func unary<Output: Sendable>(_ body: () async throws -> Output) async throws -> Output {
        do {
            return try await body()
        } catch {
            throw GRPCSyncTransport<Transport>.mapped(error)
        }
    }

    public func getPreferences(_ request: Wiretuner_Account_V1_GetPreferencesRequest, token: String) async throws
        -> Wiretuner_Account_V1_GetPreferencesResponse {
        try await unary { try await service.getPreferences(request, metadata: metadata(token)) }
    }

    public func setPreferences(_ request: Wiretuner_Account_V1_SetPreferencesRequest, token: String) async throws
        -> Wiretuner_Account_V1_SetPreferencesResponse {
        try await unary { try await service.setPreferences(request, metadata: metadata(token)) }
    }
}

extension GRPCPreferencesTransport where Transport == HTTP2ClientTransport.Posix {
    /// A transport to the API at `api` (`https` uses TLS).
    public static func http2(api: URL, identity: GRPCSyncTransport<Transport>.Identity) throws -> GRPCPreferencesTransport {
        let tls = api.scheme == "https"
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: api.host ?? "localhost", port: api.port ?? (tls ? 443 : 80)),
            transportSecurity: tls ? .tls : .plaintext
        )
        return GRPCPreferencesTransport(transport: transport, identity: identity)
    }
}

/// The synced preferences of one account on this Mac (preferences.adoc, "Merge semantics" and
/// "Offline behavior"; BASIC-023).  Preferences read and write locally at once (`PreferenceStore`
/// in the app keeps every value in `UserDefaults`); a synced entry changed here is stamped with
/// `updated_at_ms` and this Mac's device id and queued in the `preferences_outbox` table of the
/// app-level store, then sent as a partial `SetPreferences`.  `GetPreferences` runs on sign-in and
/// on reconnect.  The server keeps, per key, the newer entry and answers the full map, which is
/// applied wholesale -- except that an entry still queued here and newer than the server's stands
/// until it is sent.  Maps to apply arrive on `updates()`.  `sync.shortcut_sets` is merged per set
/// (`ShortcutSetSync`): changes queued one after another join into one entry, a queued set the
/// server already has newer is dropped, and the queued sets lie over the server's in `updates()`.
///
/// *Sync preferences with my account* off (`setEnabled(false)`): nothing is queued or sent and no
/// remote map is delivered.  Turning it on fetches and applies the account's map.
public actor PreferenceSync {
    /// One synced entry as the app's store hands it over: the id and the value (no stamp).
    public typealias Entries = [String: Wiretuner_Account_V1_PreferenceValue]

    private let transport: any PreferencesTransport
    private let token: @Sendable () async throws -> String
    private let database: DatabaseQueue
    private let device: String
    private let now: @Sendable () -> Int64
    private var enabled: Bool
    private var continuations: [UUID: AsyncStream<Entries>.Continuation] = [:]
    /// The newest full map received from the server.
    public private(set) var accountMap: Entries = [:]

    /// A sync over `transport` whose outbox lives in the database at `url` (created when missing);
    /// `now` is the wall clock in milliseconds.
    public init(transport: any PreferencesTransport, url: URL, device: String, enabled: Bool = true,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                token: @escaping @Sendable () async throws -> String) throws {
        self.transport = transport
        self.token = token
        self.device = device
        self.enabled = enabled
        self.now = now
        database = try DatabaseQueue(path: url.path)
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS preferences_outbox (
                    id TEXT PRIMARY KEY NOT NULL,
                    value BLOB NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                )
                """)
        }
    }

    /// `~/Library/Application Support/WireTuner/Preferences.sqlite`: the app-level store.
    public static func defaultURL() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(component: "WireTuner")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(component: "Preferences.sqlite")
    }

    /// Whether *Sync preferences with my account* is on.
    public var isEnabled: Bool { enabled }

    /// Maps to apply wholesale to the synced keys, one per fetch or push answer while enabled.
    public func updates() -> AsyncStream<Entries> {
        let (stream, continuation) = AsyncStream<Entries>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { _ in Task { await self.removeContinuation(id) } }
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    /// Turns syncing on or off.  Turning it on fetches the account's map (and sends anything queued
    /// newer than it); turning it off forgets what was queued.
    public func setEnabled(_ on: Bool) async throws {
        guard on != enabled else { return }
        enabled = on
        if on {
            try await refresh()
        } else {
            try write { try $0.execute(sql: "DELETE FROM preferences_outbox") }
        }
    }

    /// Queues synced entries changed on this Mac, stamped now (nothing while sync is off).  The
    /// caller sends them with `push()` -- right away when online.
    public func enqueue(_ entries: Entries) throws {
        guard enabled, !entries.isEmpty else { return }
        let stamp = now()
        try database.write { db in
            for (id, value) in entries {
                var stamped = value
                stamped.updatedAtMs = stamp
                stamped.device = device
                // A shortcut set change joins the one already queued rather than replacing it.
                if case .shortcutSetsValue? = value.value, let bytes = try Data.fetchOne(db, sql: "SELECT value FROM preferences_outbox WHERE id = ?", arguments: [id]) {
                    stamped = ShortcutSetSync.merge(try Wiretuner_Account_V1_PreferenceValue(serializedBytes: bytes), stamped, now: stamp)
                }
                try db.execute(sql: "INSERT OR REPLACE INTO preferences_outbox (id, value, updated_at_ms) VALUES (?, ?, ?)",
                               arguments: [id, try stamped.serializedData(), stamp])
            }
        }
    }

    /// One synchronous write transaction on the outbox.
    private func write(_ body: (Database) throws -> Void) throws {
        try database.write(body)
    }

    /// The queued entries with their stamps.
    public func pending() throws -> Entries {
        try database.read { db in
            var out: Entries = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, value FROM preferences_outbox") {
                let bytes: Data = row["value"]
                out[row["id"]] = try Wiretuner_Account_V1_PreferenceValue(serializedBytes: bytes)
            }
            return out
        }
    }

    /// Sends the queued entries as one partial `SetPreferences` and applies the answer.  An entry
    /// re-queued while the call was in flight stays queued.  Does nothing when off or empty.
    @discardableResult
    public func push() async throws -> Entries? {
        guard enabled else { return nil }
        let queued = try pending()
        guard !queued.isEmpty else { return nil }
        var request = Wiretuner_Account_V1_SetPreferencesRequest()
        request.changes.values = queued
        let response = try await transport.setPreferences(request, token: try await token())
        try write { db in
            for (id, value) in queued {
                try db.execute(sql: "DELETE FROM preferences_outbox WHERE id = ? AND updated_at_ms = ?", arguments: [id, value.updatedAtMs])
            }
        }
        return try apply(response.preferences.values)
    }

    /// `GetPreferences` -- on sign-in, on reconnect and when sync is turned on -- then sends what
    /// is still queued.  Returns the map applied (nil when off).
    @discardableResult
    public func refresh() async throws -> Entries? {
        guard enabled else { return nil }
        let response = try await transport.getPreferences(Wiretuner_Account_V1_GetPreferencesRequest(), token: try await token())
        // Queued entries older than the server's are superseded: drop them rather than send.
        let server = response.preferences.values
        let queued = try pending()
        try write { db in
            for (id, value) in queued {
                // Shortcut sets are judged per set: only what the server does not have newer stays.
                if case .shortcutSetsValue(let sets)? = value.value, case .shortcutSetsValue(let known)? = server[id]?.value {
                    if let rest = ShortcutSetSync.unsent(sets, after: known) {
                        var kept = value
                        kept.shortcutSetsValue = rest
                        try db.execute(sql: "UPDATE preferences_outbox SET value = ? WHERE id = ?", arguments: [try kept.serializedData(), id])
                    } else {
                        try db.execute(sql: "DELETE FROM preferences_outbox WHERE id = ?", arguments: [id])
                    }
                } else if (server[id]?.updatedAtMs ?? .min) >= value.updatedAtMs {
                    try db.execute(sql: "DELETE FROM preferences_outbox WHERE id = ?", arguments: [id])
                }
            }
        }
        let applied = try apply(server)
        return try await push() ?? applied
    }

    /// Records `map` as the account's and delivers it with the still-queued newer entries on top.
    private func apply(_ map: Entries) throws -> Entries {
        accountMap = map
        var merged = map
        for (id, value) in try pending() {
            if case .shortcutSetsValue? = value.value, case .shortcutSetsValue? = map[id]?.value {
                merged[id] = ShortcutSetSync.merge(map[id], value, now: now())
            } else if (map[id]?.updatedAtMs ?? .min) < value.updatedAtMs {
                merged[id] = value
            }
        }
        for continuation in continuations.values {
            continuation.yield(merged)
        }
        return merged
    }

    // MARK: Review thresholds

    /// The review thresholds a synced map holds (`sync.*` ids; the share is a percentage), each
    /// unset or unreadable entry at its default, under the team's floor when there is one
    /// (preferences.adoc, "Data model": `max` for counts, share and hours, `min` for *Auto-merge
    /// below*).  What `SyncClient.Options.reconcile` answers.
    public static func reconcilePreferences(_ map: Entries, team: ReconcilePreferences? = nil) -> ReconcilePreferences {
        var user = ReconcilePreferences.standard
        func int(_ id: String) -> Int? {
            guard case .intValue(let value)? = map[id]?.value else { return nil }
            return Int(clamping: value)
        }
        if let value = int("sync.auto_merge_below") { user.autoMergeBelow = value }
        if let value = int("sync.ask_overlap_count") { user.askOverlapCount = value }
        if let value = int("sync.ask_overlap_share") { user.askOverlapShare = Double(value) / 100 }
        if case .boolValue(let value)? = map["sync.always_ask"]?.value { user.alwaysAsk = value }
        if let value = int("sync.suggest_review_after_hours") { user.suggestReviewAfter = .seconds(value * 3600) }
        return team.map(user.floored(by:)) ?? user
    }
}
