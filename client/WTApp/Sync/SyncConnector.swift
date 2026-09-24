import Foundation
import GRPCNIOTransportHTTP2
import WTModel
import WTSync

/// The sync client's token source over the account's `AuthService` (sync-protocol.adoc, "The
/// client as built", *Tokens*): a valid token, or after `UNAUTHENTICATED` a refreshed one.  A
/// signed-out account or a refused refresh is `TokenFailure.signInRequired` (*Sign in to sync*);
/// anything else is transient.
struct AuthTokenProvider: TokenProvider {
    var valid: @Sendable () async throws -> String
    var refresh: @Sendable () async throws -> String

    init(valid: @escaping @Sendable () async throws -> String, refresh: @escaping @Sendable () async throws -> String) {
        self.valid = valid
        self.refresh = refresh
    }

    init(auth: AuthService) {
        self.init(valid: { try await auth.validAccessToken() }, refresh: { try await auth.refresh().accessToken })
    }

    func accessToken(forceRefresh: Bool) async throws -> String {
        do {
            return try await forceRefresh ? refresh() : valid()
        } catch let error as AuthError {
            throw Self.requiresSignIn(error) ? TokenFailure.signInRequired : error
        }
    }

    /// Whether `error` means the user must sign in again.
    static func requiresSignIn(_ error: AuthError) -> Bool {
        switch error {
        case .notSignedIn, .tokenEndpoint: true
        default: false
        }
    }
}

/// A running connection to the sync service for one document: its client and how to close the
/// transport under it once the client stopped.
struct SyncConnection: Sendable {
    let client: SyncClient
    let close: @Sendable () async -> Void
    /// The transport under the client (version states, a copy's remaining changes), the
    /// document copy calls (`Fork`, `CreateBranch`) and the tokens they use; nil in tests.
    var transport: (any SyncTransport)?
    var copies: (any DocumentCopyTransport)?
    var tokens: (any TokenProvider)?
}

/// Makes a document's `SyncClient` over its store (client.adoc, "Concurrency"): the gRPC
/// transport in the app, a fake in tests.
@MainActor
protocol SyncConnecting: AnyObject {
    func connect(store: LocalStore, sink: any RemoteChangeSink, presence: LocalPresence?) throws -> SyncConnection
}

/// The app's connector: one `GRPCSyncTransport` per document session to `WT_API_URL`, which is
/// also the blob queue's transport, tokens from the account, the review thresholds from
/// Preferences.
@MainActor
final class GRPCSyncConnector: SyncConnecting {
    let api: URL
    let identity: GRPCSyncTransport<HTTP2ClientTransport.Posix>.Identity
    let tokens: any TokenProvider
    let blobDirectory: @Sendable () throws -> URL
    var options: @MainActor () -> SyncClient.Options

    init(api: URL, identity: GRPCSyncTransport<HTTP2ClientTransport.Posix>.Identity, tokens: any TokenProvider,
         blobDirectory: @escaping @Sendable () throws -> URL = { try BlobCache.defaultDirectory() },
         options: @escaping @MainActor () -> SyncClient.Options = { SyncClient.Options() }) {
        self.api = api
        self.identity = identity
        self.tokens = tokens
        self.blobDirectory = blobDirectory
        self.options = options
    }

    func connect(store: LocalStore, sink: any RemoteChangeSink, presence: LocalPresence?) throws -> SyncConnection {
        let transport = try GRPCSyncTransport.http2(api: api, identity: identity)
        let blobs = BlobQueue(store: store, cache: BlobCache(directory: try blobDirectory()), transport: transport, tokens: tokens)
        let client = SyncClient(store: store, sink: sink, transport: transport, tokens: tokens, presence: presence, blobs: blobs, options: options())
        let api = api
        let identity = identity
        let copies = LazyDocumentCopyTransport { try GRPCDocumentCopyTransport<HTTP2ClientTransport.Posix>.http2(api: api, identity: identity) }
        return SyncConnection(client: client, close: {
            await transport.close()
            await copies.close()
        }, transport: transport, copies: copies, tokens: tokens)
    }
}

extension SyncClient.Options {
    /// The options with the review thresholds and *Undo levels* read from `preferences`.
    @MainActor
    static func from(_ preferences: PreferenceStore) -> SyncClient.Options {
        var options = SyncClient.Options()
        let reconcile = ReconcilePreferences(
            autoMergeBelow: preferences[PreferenceCatalog.Sync.autoMergeBelow],
            askOverlapCount: preferences[PreferenceCatalog.Sync.askOverlapCount],
            askOverlapShare: Double(preferences[PreferenceCatalog.Sync.askOverlapShare]) / 100,
            alwaysAsk: preferences[PreferenceCatalog.Sync.alwaysAsk],
            suggestReviewAfter: .seconds(preferences[PreferenceCatalog.Sync.suggestReviewAfterHours] * 3600)
        )
        options.reconcile = { reconcile }
        options.undoLevels = preferences[PreferenceCatalog.Sync.undoLevels]
        return options
    }
}

extension LaunchEnvironment {
    /// "<version>/<build>" from the Info.plist, as every client carries it.
    static func clientVersion(_ infoDictionary: [String: Any]?) -> String {
        (infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") + "/" + (infoDictionary?["CFBundleVersion"] as? String ?? "0")
    }

    /// The sync connector the app runs with: gRPC against the configured API with the account's
    /// tokens; none in test launches, whose documents are memory documents.
    @MainActor
    func makeSyncConnector(account: AccountModel, infoDictionary: [String: Any]?, defaults: UserDefaults, preferences: PreferenceStore) -> (any SyncConnecting)? {
        guard !isTesting else { return nil }
        let configuration = AuthConfiguration(infoDictionary: infoDictionary)
        let identity = GRPCSyncTransport<HTTP2ClientTransport.Posix>.Identity(
            clientVersion: Self.clientVersion(infoDictionary), deviceID: DeviceIdentity.current(defaults: defaults)
        )
        return GRPCSyncConnector(api: configuration.api, identity: identity, tokens: AuthTokenProvider(auth: account.auth),
                                 options: { SyncClient.Options.from(preferences) })
    }

    /// The review sheet's Fork and CreateBranch client over the configured API.
    @MainActor
    func makeReviewWork(account: AccountModel, infoDictionary: [String: Any]?, defaults: UserDefaults) -> any ReviewWorkClient {
        let configuration = AuthConfiguration(infoDictionary: infoDictionary)
        let auth = account.auth
        let caller = GRPCUnaryCaller(api: configuration.api, clientVersion: Self.clientVersion(infoDictionary), deviceID: DeviceIdentity.current(defaults: defaults))
        return GRPCReviewWorkClient(caller: caller, accessToken: { try await auth.validAccessToken() })
    }
}
