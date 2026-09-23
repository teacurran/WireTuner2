import Foundation

/// How the process was launched, for the choices that must differ under test: UI tests pass
/// `-WTUITesting` (TEST-002), unit tests run inside the app with `XCTestConfigurationFilePath`
/// set.  Under either, tokens live in memory, so no test reads or writes the login keychain
/// and no stored session triggers a background refresh (a socket the sandbox audit would see).
struct LaunchEnvironment: Equatable, Sendable {
    static let uiTestingArgument = "-WTUITesting"
    /// Makes a test launch reopen the saved session (UI tests of BASIC-001's restoration).
    static let restoreSessionArgument = "-WTRestoreSession"

    var isUITesting: Bool
    var isUnitTesting: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments, environment: [String: String] = ProcessInfo.processInfo.environment) {
        isUITesting = arguments.contains(Self.uiTestingArgument)
        isUnitTesting = environment["XCTestConfigurationFilePath"] != nil
        auditsSockets = SocketMonitor.isRequested(arguments: arguments)
        restoresSession = !(isUITesting || isUnitTesting) || arguments.contains(Self.restoreSessionArgument)
    }

    /// Whether launch reopens the last session's windows; test launches start clean unless
    /// they ask.
    var restoresSession: Bool

    /// `-WTSocketAudit` in a DEBUG build: the canvas reports socket counts (`SocketMonitor`).
    var auditsSockets: Bool

    var isTesting: Bool { isUITesting || isUnitTesting }

    /// The token store for this launch.
    func tokenStore() -> TokenStore {
        isTesting ? InMemoryTokenStore() : KeychainTokenStore()
    }

    /// The account model the app runs with.
    @MainActor
    func makeAccountModel(infoDictionary: [String: Any]?, defaults: UserDefaults) -> AccountModel {
        let configuration = AuthConfiguration(infoDictionary: infoDictionary)
        let version = (infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") + "/" + (infoDictionary?["CFBundleVersion"] as? String ?? "0")
        let auth = AuthService(configuration: configuration, store: tokenStore(), authenticator: WebAuthenticationSession())
        let client = GRPCAccountClient(api: configuration.api, clientVersion: version, deviceID: DeviceIdentity.current(defaults: defaults))
        return AccountModel(auth: auth, client: client)
    }

    /// The library the app runs with: gRPC against the configured API, tokens from `account`.
    @MainActor
    func makeLibraryModel(account: AccountModel, infoDictionary: [String: Any]?, defaults: UserDefaults, store: LibraryCacheStore?, thumbnails: ThumbnailCache) -> LibraryModel {
        let configuration = AuthConfiguration(infoDictionary: infoDictionary)
        let version = (infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") + "/" + (infoDictionary?["CFBundleVersion"] as? String ?? "0")
        let client = GRPCLibraryClient(api: configuration.api, clientVersion: version, deviceID: DeviceIdentity.current(defaults: defaults))
        let auth = account.auth
        let services = LibraryServices(
            documents: client, teams: client, blobs: client, account: account.client,
            accessToken: { try await auth.validAccessToken() }
        )
        return LibraryModel(services: services, store: store, thumbnails: thumbnails)
    }
}
