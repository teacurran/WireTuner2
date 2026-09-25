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

    /// AppKit's switch for the animation it runs when a window is ordered in or out.
    static let windowAnimationsKey = "NSAutomaticWindowAnimationsEnabled"

    /// Process-wide defaults for this launch, set before any window exists.  A unit-test host
    /// turns off window order-in/out animations: AppKit runs each one (`_NSWindowTransformAnimation`)
    /// `.nonblockingThreaded`, parked on a Dispatch worker thread, and the windows that tests show
    /// and close in quick succession strand some of them there for good.  Across the suite they
    /// took all 64 workers, after which no global queue ran at all (the socket monitor's timer
    /// never fired).  The setting goes in the volatile argument domain, so nothing is written to
    /// the app's preferences; UI tests and real launches keep the animations.
    func applyProcessDefaults(to defaults: UserDefaults = .standard) {
        guard isUnitTesting else { return }
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[Self.windowAnimationsKey] = false
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

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
        let deviceID = DeviceIdentity.current(defaults: defaults)
        let client = GRPCAccountClient(api: configuration.api, clientVersion: version, deviceID: deviceID)
        return AccountModel(auth: auth, client: client, devices: GRPCTeamClient(api: configuration.api, clientVersion: version, deviceID: deviceID))
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
