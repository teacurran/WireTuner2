import AppKit
import Foundation

/// What the team settings sheet, the invitation flow and the Share sheet talk to.  Injected so
/// tests use fakes (no network).
struct CollaborationServices: Sendable {
    var teams: any TeamClient
    var shares: any ShareClient
    /// `AuthService.validAccessToken()`; throws `AuthError.notSignedIn` when signed out, which
    /// reads as offline.
    var accessToken: @Sendable () async throws -> String
    /// Where share links point: `<links>/l/<token>` (the server's `wt.links.base-url`).
    var links: URL
    /// The tokens of links made on this Mac since launch: a token is returned only when its
    /// link is created, so only these can be copied again.
    var linkTokens = ShareLinkTokens()
}

/// The links host from the Info.plist (`WTLinksURL`, from the `WT_LINKS_URL` build setting).
enum LinkConfiguration {
    static let infoKey = "WTLinksURL"
    static let defaultBase = URL(string: "https://wiretuner.app")!

    static func base(infoDictionary: [String: Any]?) -> URL {
        guard let text = infoDictionary?[infoKey] as? String, !text.isEmpty, let url = URL(string: text), url.scheme != nil else { return defaultBase }
        return url
    }

    /// `https://<host>/l/<token>` (sharing.adoc, "Share links").
    static func shareURL(base: URL, token: String) -> URL {
        base.appending(path: "l").appending(path: token)
    }
}

/// Link tokens by link id, shared by every Share sheet of the process.
final class ShareLinkTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    init() {}

    subscript(linkID: String) -> String? {
        get { lock.withLock { tokens[linkID] } }
        set { lock.withLock { tokens[linkID] = newValue } }
    }
}

/// The error text and connectivity rule the collaboration sheets share with the library.
enum CollaborationErrors {
    static let offlineNotice = "You are offline. Sharing and team settings are available when you reconnect."

    static func isOffline(_ error: any Error) -> Bool { LibraryConnectivity.isOffline(error) }

    @MainActor static func message(for error: any Error) -> String? { LibraryModel.message(for: error) }
}

extension LaunchEnvironment {
    /// The collaboration clients the app runs with: gRPC against the configured API, tokens
    /// from `account`.
    func makeCollaborationServices(account: AccountModel, infoDictionary: [String: Any]?, defaults: UserDefaults) -> CollaborationServices {
        let configuration = AuthConfiguration(infoDictionary: infoDictionary)
        let version = (infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") + "/" + (infoDictionary?["CFBundleVersion"] as? String ?? "0")
        let deviceID = DeviceIdentity.current(defaults: defaults)
        let auth = account.auth
        return CollaborationServices(
            teams: GRPCTeamClient(api: configuration.api, clientVersion: version, deviceID: deviceID),
            shares: GRPCShareClient(api: configuration.api, clientVersion: version, deviceID: deviceID),
            accessToken: { try await auth.validAccessToken() }, links: LinkConfiguration.base(infoDictionary: infoDictionary)
        )
    }
}
