import AppKit
import AuthenticationServices
import Foundation
import Testing
import WTProto
@testable import WireTuner

/// A JWT with `claims` as its payload (unsigned: the app never verifies tokens itself).
func makeJWT(_ claims: [String: Any]) -> String {
    let payload = PKCE.base64URL(try! JSONSerialization.data(withJSONObject: claims))
    return "eyJhbGciOiJub25lIn0.\(payload).sig"
}

@Suite struct AuthConfigurationTests {
    @Test func defaultsToTheComposeRealmAndReadsInfoPlist() {
        let defaults = AuthConfiguration()
        #expect(defaults.issuer.absoluteString == "http://localhost:8180/realms/wiretuner")
        #expect(defaults.api.absoluteString == "http://localhost:8080")
        #expect(defaults.authorizationEndpoint.absoluteString == "http://localhost:8180/realms/wiretuner/protocol/openid-connect/auth")
        #expect(defaults.tokenEndpoint.path().hasSuffix("/openid-connect/token"))
        #expect(defaults.logoutEndpoint.path().hasSuffix("/openid-connect/logout"))
        #expect(AuthConfiguration(infoDictionary: nil) == defaults)
        #expect(AuthConfiguration(infoDictionary: ["WTAuthIssuer": "$(WT_AUTH_ISSUER)", "WTAPIURL": ""]) == defaults)
        #expect(AuthConfiguration(infoDictionary: ["WTAuthIssuer": "not a url"]) == defaults)
        let custom = AuthConfiguration(infoDictionary: ["WTAuthIssuer": "https://id.example.com/realms/wt", "WTAPIURL": "https://api.example.com"])
        #expect(custom.issuer.host() == "id.example.com" && custom.api.host() == "api.example.com")
        #expect(SignInMethod.standard.identityProviderHint == nil)
        #expect(SignInMethod.apple.identityProviderHint == "apple")
        #expect(SignInMethod.workspace(alias: "acme").identityProviderHint == "acme")
    }

    @Test func pkceMatchesTheRFCVector() {
        // RFC 7636, Appendix B.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let generated = PKCE.generate { Data(repeating: 0xFB, count: $0) }
        #expect(generated.verifier.count == 43 && !generated.verifier.contains("+") && !generated.verifier.contains("/") && !generated.verifier.contains("="))
        #expect(PKCE.randomState { Data(repeating: 0xFF, count: $0) }.count == 22)
        #expect(PKCE.secureRandom(32).count == 32)
        #expect(PKCE.generate().verifier != PKCE.generate().verifier)
    }

    @Test func tokensKnowWhenToRefreshAndDecodeClaims() {
        let now = Date(timeIntervalSince1970: 1000)
        let response = TokenResponse(accessToken: makeJWT(["sub": "s", "email": "p@example.com", "name": "Priya", "wt_auth_method": "passkey"]), refreshToken: nil, idToken: "id", expiresIn: 300, refreshExpiresIn: 0)
        let tokens = response.tokenSet(receivedAt: now, keepingRefreshToken: "old")
        #expect(tokens.refreshToken == "old" && tokens.refreshExpiresAt == nil && tokens.idToken == "id")
        #expect(!tokens.needsRefresh(at: now, leeway: 60))
        #expect(tokens.needsRefresh(at: now.addingTimeInterval(241), leeway: 60))
        #expect(tokens.claims == TokenClaims(subject: "s", email: "p@example.com", name: "Priya", authMethod: "passkey"))
        #expect(TokenResponse(accessToken: "a", refreshToken: "r", idToken: nil, expiresIn: 1, refreshExpiresIn: 10).tokenSet(receivedAt: now).refreshExpiresAt == now.addingTimeInterval(10))
        #expect(TokenClaims(jwt: "garbage") == TokenClaims())
        #expect(TokenClaims(jwt: "a.!!!.c") == TokenClaims())
        #expect(TokenClaims(jwt: makeJWT(["preferred_username": "priya"])).name == "priya")
        #expect(TokenClaims.base64URLDecode("YQ") == Data("a".utf8))
    }

    @Test func tokenStoresRoundTrip() throws {
        let tokens = TokenSet(accessToken: "a", refreshToken: "r", idToken: nil, expiresAt: Date(timeIntervalSince1970: 5), refreshExpiresAt: nil)
        let memory = InMemoryTokenStore()
        #expect(try memory.load() == nil)
        try memory.save(tokens)
        #expect(try memory.load() == tokens)
        try memory.delete()
        #expect(try memory.load() == nil)

        let keychain = KeychainTokenStore(service: "com.villagecompute.wiretuner.tests.\(UUID().uuidString)")
        defer { try? keychain.delete() }
        do {
            #expect(try keychain.load() == nil)
            try keychain.save(tokens)
            var rotated = tokens
            rotated.refreshToken = "r2"
            try keychain.save(rotated)
            #expect(try keychain.load() == rotated)
            try keychain.delete()
            try keychain.delete()
            #expect(try keychain.load() == nil)
        } catch let KeychainTokenStore.Failure.status(status) {
            // A test host without a usable keychain (CI without a login keychain) reports a
            // status rather than crashing; that path is what is checked then.
            #expect(status != errSecSuccess)
        }
        #expect(KeychainTokenStore().service == KeychainTokenStore.defaultService)
    }

    @Test func launchEnvironmentKeepsTestsOffTheKeychain() {
        let ui = LaunchEnvironment(arguments: ["app", LaunchEnvironment.uiTestingArgument], environment: [:])
        #expect(ui.isUITesting && ui.isTesting && ui.tokenStore() is InMemoryTokenStore)
        let unit = LaunchEnvironment(arguments: [], environment: ["XCTestConfigurationFilePath": "/x"])
        #expect(unit.isUnitTesting && !unit.isUITesting)
        let live = LaunchEnvironment(arguments: [], environment: [:])
        #expect(!live.isTesting && live.tokenStore() is KeychainTokenStore)
        #expect(LaunchEnvironment().isUnitTesting, "this process is a unit-test host")
    }

    /// A unit-test host orders windows without AppKit's threaded window animations, which
    /// otherwise strand Dispatch workers until the global queues stop running; other launches
    /// keep them, and nothing is written to the preferences.
    @Test @MainActor func aUnitTestLaunchTurnsOffWindowAnimations() {
        let key = LaunchEnvironment.windowAnimationsKey
        #expect(UserDefaults.standard.object(forKey: key) as? Bool == false, "this host launched without them")
        #expect(UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] == nil)
        let suite = TestDefaults()
        defer { suite.remove() }
        let arguments = suite.defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        LaunchEnvironment(arguments: [LaunchEnvironment.uiTestingArgument], environment: [:]).applyProcessDefaults(to: suite.defaults)
        LaunchEnvironment(arguments: [], environment: [:]).applyProcessDefaults(to: suite.defaults)
        #expect(NSDictionary(dictionary: suite.defaults.volatileDomain(forName: UserDefaults.argumentDomain)) == NSDictionary(dictionary: arguments))
        LaunchEnvironment(arguments: [], environment: ["XCTestConfigurationFilePath": "/x"]).applyProcessDefaults(to: suite.defaults)
        #expect(suite.defaults.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? Bool == false)
        #expect(suite.defaults.bool(forKey: key) == false)
    }
}

@Suite struct AuthServiceTests {
    struct Fixture {
        let host: String
        let service: AuthService
        let store: InMemoryTokenStore
        let clock: TestClock
        let seen: Recorder<URL>
    }

    static func fixture(
        web: FakeWebAuthenticator.Behaviour = .approve(code: "the-code"), stored: TokenSet? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in },
        handler: @escaping FakeTokenEndpoint.Handler = { _, _ in (200, FakeTokenEndpoint.tokens()) }
    ) -> Fixture {
        let (host, session) = FakeTokenEndpoint.register(handler)
        let store = InMemoryTokenStore(stored)
        let clock = TestClock()
        let seen = Recorder<URL>()
        let configuration = AuthConfiguration(issuer: URL(string: "http://\(host)/realms/wiretuner")!)
        let service = AuthService(
            configuration: configuration, session: session, store: store, authenticator: FakeWebAuthenticator(web, seen: seen),
            now: { clock.now }, sleep: sleep
        )
        return Fixture(host: host, service: service, store: store, clock: clock, seen: seen)
    }

    @Test func buildsTheAuthorizationRequestAndReadsTheCallback() throws {
        let pkce = PKCE(verifier: "v")
        let url = AuthService.authorizationURL(configuration: AuthConfiguration(), method: .workspace(alias: "acme"), pkce: pkce, state: "s1")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(items["response_type"] == "code" && items["client_id"] == "wiretuner-mac")
        #expect(items["redirect_uri"] == "wiretuner://auth/callback" && items["scope"] == "openid profile email")
        #expect(items["code_challenge"] == pkce.challenge && items["code_challenge_method"] == "S256")
        #expect(items["state"] == "s1" && items["kc_idp_hint"] == "acme")
        let standard = AuthService.authorizationURL(configuration: AuthConfiguration(), method: .standard, pkce: pkce, state: "s")
        #expect(!standard.absoluteString.contains("kc_idp_hint"))

        #expect(try AuthService.authorizationCode(from: URL(string: "wiretuner://auth/callback?code=c&state=s")!, expectedState: "s") == "c")
        #expect(throws: AuthError.stateMismatch) { try AuthService.authorizationCode(from: URL(string: "wiretuner://auth/callback?code=c&state=x")!, expectedState: "s") }
        #expect(throws: AuthError.missingCode) { try AuthService.authorizationCode(from: URL(string: "wiretuner://auth/callback?code=&state=s")!, expectedState: "s") }
        #expect(throws: AuthError.authorization(code: "access_denied", description: nil)) {
            try AuthService.authorizationCode(from: URL(string: "wiretuner://auth/callback?error=access_denied")!, expectedState: "s")
        }
        #expect(String(decoding: AuthService.formBody(["b": "x y&z", "a": "1"]), as: UTF8.self) == "a=1&b=x%20y%26z")
    }

    @Test func signsInExchangingTheCodeWithTheVerifier() async throws {
        let access = makeJWT(["email": "p@example.com", "wt_auth_method": "apple"])
        let fixture = Self.fixture(handler: { _, _ in (200, FakeTokenEndpoint.tokens(access: access)) })
        let states = Recorder<AuthState>()
        await fixture.service.setStateHandler { states.append($0) }
        #expect(await fixture.service.state == .signedOut)
        let claims = try await fixture.service.signIn(method: .apple)
        #expect(claims.email == "p@example.com" && claims.authMethod == "apple")
        let request = try #require(FakeTokenEndpoint.requests(to: fixture.host).first)
        #expect(request.form["grant_type"] == "authorization_code" && request.form["code"] == "the-code")
        #expect(request.form["client_id"] == "wiretuner-mac" && request.form["redirect_uri"] == "wiretuner://auth/callback")
        let authorize = try #require(fixture.seen.values.first)
        let challenge = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "code_challenge" }!.value
        #expect(PKCE(verifier: request.form["code_verifier"]!).challenge == challenge, "the verifier matches the challenge sent")
        #expect(authorize.absoluteString.contains("kc_idp_hint=apple"))
        #expect(try fixture.store.load()?.accessToken == access)
        #expect(states.values == [.signedIn(claims)])
        #expect(try await fixture.service.validAccessToken() == access)
    }

    @Test func signInFailuresLeaveNoTokens() async {
        let cases: [(FakeWebAuthenticator.Behaviour, AuthError)] = [
            (.wrongState, .stateMismatch), (.noCode, .missingCode),
            (.error("access_denied"), .authorization(code: "access_denied", description: "Denied")), (.fail(.cancelled), .cancelled),
        ]
        for (behaviour, expected) in cases {
            let fixture = Self.fixture(web: behaviour)
            await #expect(throws: expected) { try await fixture.service.signIn() }
            #expect(await fixture.service.tokens == nil)
        }
        let refused = Self.fixture(handler: { _, _ in (400, FakeTokenEndpoint.json(["error": "invalid_client", "error_description": "Bad client"])) })
        await #expect(throws: AuthError.tokenEndpoint(code: "invalid_client", description: "Bad client")) { try await refused.service.signIn() }
        let broken = Self.fixture(handler: { _, _ in (502, Data("<html>".utf8)) })
        await #expect(throws: AuthError.http(status: 502)) { try await broken.service.signIn() }
        let garbled = Self.fixture(handler: { _, _ in (200, Data("{}".utf8)) })
        await #expect(throws: AuthError.invalidResponse) { try await garbled.service.signIn() }
    }

    @Test func expiredTokensRefreshOnceForConcurrentCallers() async throws {
        let stored = TokenSet(accessToken: "old", refreshToken: "r1", idToken: nil, expiresAt: TestClock().now.addingTimeInterval(30), refreshExpiresAt: nil)
        let fixture = Self.fixture(stored: stored, handler: { _, form in
            Thread.sleep(forTimeInterval: 0.05)
            return (200, FakeTokenEndpoint.tokens(access: "new-\(form["refresh_token"]!)", refresh: nil))
        })
        #expect(await fixture.service.state != .signedOut)
        async let a = fixture.service.validAccessToken()
        async let b = fixture.service.validAccessToken()
        let tokens = try await [a, b]
        #expect(tokens == ["new-r1", "new-r1"])
        #expect(await fixture.service.refreshCount == 1)
        #expect(FakeTokenEndpoint.requests(to: fixture.host).first?.form["grant_type"] == "refresh_token")
        #expect(try fixture.store.load()?.refreshToken == "r1", "a response without a new refresh token keeps the old one")
        #expect(try await fixture.service.validAccessToken() == "new-r1", "fresh now: no second refresh")
    }

    @Test func aRefusedRefreshEndsTheSession() async {
        let stored = TokenSet(accessToken: "old", refreshToken: "r", idToken: nil, expiresAt: .distantPast, refreshExpiresAt: nil)
        let fixture = Self.fixture(stored: stored, handler: { _, _ in (400, FakeTokenEndpoint.json(["error": "invalid_grant"])) })
        await #expect(throws: AuthError.sessionExpired) { try await fixture.service.validAccessToken() }
        #expect(await fixture.service.state == .signedOut)
        await #expect(throws: AuthError.notSignedIn) { try await fixture.service.validAccessToken() }
        await #expect(throws: AuthError.notSignedIn) { try await fixture.service.refresh() }
    }

    @Test func signOutEndsTheRealmSessionAndForgetsTokens() async throws {
        let stored = TokenSet(accessToken: "a", refreshToken: "r", idToken: nil, expiresAt: .distantFuture, refreshExpiresAt: nil)
        let fixture = Self.fixture(stored: stored, handler: { _, _ in (204, Data()) })
        await fixture.service.signOut()
        let logout = try #require(FakeTokenEndpoint.requests(to: fixture.host).first)
        #expect(logout.url.path().hasSuffix("/logout") && logout.form["refresh_token"] == "r")
        #expect(try fixture.store.load() == nil)
        await fixture.service.signOut()
        #expect(FakeTokenEndpoint.requests(to: fixture.host).count == 1, "nothing to end the second time")
    }

    @Test func silentRefreshSleepsUntilAMinuteBeforeExpiry() async throws {
        let sleeps = Recorder<TimeInterval>()
        let responses = Recorder<Int>()
        let clock = TestClock()
        let stored = TokenSet(accessToken: "a", refreshToken: "r", idToken: nil, expiresAt: clock.now.addingTimeInterval(900), refreshExpiresAt: nil)
        let fixture = Self.fixture(stored: stored, sleep: { seconds in
            sleeps.append(seconds)
            if sleeps.values.count > 3 { throw CancellationError() }
        }, handler: { _, _ in
            responses.append(0)
            // One offline failure, then a refused refresh.
            return responses.values.count == 1 ? (200, FakeTokenEndpoint.tokens(expiresIn: 900)) : responses.values.count == 2 ? (503, Data()) : (400, FakeTokenEndpoint.json(["error": "invalid_grant"]))
        })
        await fixture.service.startAutoRefresh()
        await fixture.service.autoRefreshFinished()
        #expect(sleeps.values.first == 840)
        #expect(sleeps.values.count == 3 && sleeps.values[2] == AuthService.retryDelay)
        #expect(await fixture.service.state == .signedOut, "the refused refresh ended the loop and the session")
        #expect(AuthService.delayBeforeRefresh(stored, now: clock.now.addingTimeInterval(10_000)) == 0)

        // Cancelling the sleep ends the loop; stopping twice is harmless.
        let idle = Self.fixture(stored: stored, sleep: { _ in throw CancellationError() })
        await idle.service.startAutoRefresh()
        await idle.service.autoRefreshFinished()
        await idle.service.stopAutoRefresh()
        await idle.service.stopAutoRefresh()
        #expect(await idle.service.refreshCount == 0)
    }
}

/// An account client that answers from a fixture.
struct FakeAccountClient: AccountClient {
    var result: Result<AccountProfile, AuthError>
    func me(accessToken: String) async throws -> AccountProfile { try result.get() }
}

@Suite @MainActor struct AccountModelTests {
    static let profile = AccountProfile(
        email: "p@example.com", displayName: "Priya",
        identities: [
            .init(provider: "apple", email: "x@privaterelay.appleid.com", emailVerified: true, isRelay: true, linkedAt: nil),
            .init(provider: "password", email: "p@example.com", emailVerified: false, isRelay: false, linkedAt: nil),
        ],
        devices: [.init(id: "d1", name: "Studio Mac", platform: "macOS", authMethod: "sso:acme", lastSeenAt: nil, isCurrent: true)]
    )

    func model(web: FakeWebAuthenticator.Behaviour = .approve(code: "c"), stored: TokenSet? = nil, client: AccountClient = FakeAccountClient(result: .success(AccountModelTests.profile))) -> AccountModel {
        let fixture = AuthServiceTests.fixture(web: web, stored: stored, sleep: { _ in throw CancellationError() }) { _, _ in
            (200, FakeTokenEndpoint.tokens(access: makeJWT(["email": "p@example.com"])))
        }
        return AccountModel(auth: fixture.service, client: client)
    }

    @Test func signsInLoadsTheProfileAndSignsOut() async {
        let model = model()
        await model.start()
        #expect(!model.isSignedIn && model.statusTitle == "Not signed in")
        await model.signIn(.standard)
        #expect(model.isSignedIn && model.errorMessage == nil && !model.isBusy)
        #expect(model.statusTitle == "Signed in as p@example.com")
        await model.loadProfile()
        #expect(model.profile == Self.profile)
        #expect(model.profile?.devices.first?.methodTitle == "acme")
        await model.signOut()
        #expect(!model.isSignedIn && model.profile == nil)
    }

    @Test func aStoredSessionIsRestoredAndErrorsAreShown() async {
        let stored = TokenSet(accessToken: makeJWT(["name": "Priya"]), refreshToken: "r", idToken: nil, expiresAt: .distantFuture, refreshExpiresAt: nil)
        let model = model(stored: stored, client: FakeAccountClient(result: .failure(.http(status: 500))))
        await model.start()
        #expect(model.statusTitle == "Signed in as Priya")
        await model.loadProfile()
        #expect(model.errorMessage == "The sign-in server answered with HTTP 500.")
        let anonymous = self.model(stored: TokenSet(accessToken: "x", refreshToken: nil, idToken: nil, expiresAt: .distantFuture, refreshExpiresAt: nil))
        await anonymous.start(autoRefresh: false)
        #expect(anonymous.statusTitle == "Signed in as unknown account")
    }

    @Test func cancelledSignInIsQuietAndFailuresAreNot() async {
        let cancelled = model(web: .fail(.cancelled))
        await cancelled.signIn()
        #expect(cancelled.errorMessage == nil && !cancelled.isSignedIn)
        let forged = model(web: .wrongState)
        await forged.signIn(autoRefresh: false)
        #expect(forged.errorMessage == AccountModel.message(for: AuthError.stateMismatch))
        #expect(AccountModel.message(for: AuthError.missingCode) == "The sign-in server sent an unexpected response.")
        #expect(AccountModel.message(for: AuthError.authorization(code: "c", description: nil)) == "c")
        #expect(AccountModel.message(for: AuthError.tokenEndpoint(code: "c", description: "D")) == "D")
        #expect(AccountModel.message(for: AuthError.notSignedIn) == "You are not signed in.")
        #expect(AccountModel.message(for: AuthError.sessionExpired) == "Your session has ended. Sign in again.")
        #expect(AccountModel.message(for: URLError(.notConnectedToInternet)) != nil)
        let signedOut = model()
        await signedOut.loadProfile()
        #expect(signedOut.errorMessage == "You are not signed in.")
    }

    @Test func menuCommandsFollowTheState() async throws {
        let model = model()
        var shown = 0
        let registry = CommandRegistry()
        AccountCommands.install(into: registry, model: model) { shown += 1 }
        let ids = AccountCommands.ID.self
        #expect(registry.validate(ids.signIn) == .enabled)
        #expect(registry.validate(ids.signOut) == .disabled(AccountCommands.notSignedIn))
        #expect(registry.validate(ids.showAccount) == .enabled)
        #expect(registry.perform(ids.showAccount) && shown == 1)
        #expect(registry.command(ids.signIn)?.menuPath?.menu == "WireTuner")
        await model.signIn(autoRefresh: false)
        #expect(registry.validate(ids.signIn) == .disabled(AccountCommands.alreadySignedIn))
        #expect(registry.validate(ids.signInWithApple) == .disabled(AccountCommands.alreadySignedIn))
        #expect(registry.validate(ids.showAccount)?.title == "Account (p@example.com)…")
        #expect(registry.perform(ids.signOut))
        for _ in 0..<50 where model.isSignedIn { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isSignedIn)
        #expect(registry.perform(ids.signIn))
        for _ in 0..<50 where !model.isSignedIn { try await Task.sleep(for: .milliseconds(10)) }
        await model.signOut()
        // While a sign-in is in flight the entry points are disabled and a second one is ignored.
        let pending = Task { await model.signIn(autoRefresh: false) }
        await Task.yield()
        if model.isBusy {
            #expect(registry.validate(ids.signIn) == .disabled(AccountCommands.signingIn))
            await model.signIn()
        }
        await pending.value
        await model.signOut()
        #expect(registry.perform(ids.signInWithApple))
        for _ in 0..<50 where !model.isSignedIn { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.isSignedIn)
    }

    @Test func theAccountWindowShowsBothStates() async {
        let model = model()
        let controller = AccountWindowController(model: model)
        controller.show()
        #expect(controller.window?.identifier == AccountWindowController.identifier)
        _ = controller.window?.contentView?.fittingSize
        await model.signIn(autoRefresh: false)
        controller.show()
        for _ in 0..<50 where model.profile == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.profile != nil, "showing the window signed in loads the profile")
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        _ = controller.window?.contentView?.fittingSize
        controller.close()

        let failing = self.model(web: .wrongState)
        await failing.signIn(autoRefresh: false)
        let errorWindow = AccountWindowController(model: failing)
        errorWindow.show()
        errorWindow.window?.contentView?.layoutSubtreeIfNeeded()
        _ = errorWindow.window?.contentView?.fittingSize
        errorWindow.close()
    }
}

@Suite struct AccountProfileTests {
    @Test func mapsMeResponsesAndMethodTitles() {
        var response = Wiretuner_Account_V1_MeResponse()
        response.account.email = "p@example.com"
        response.account.displayName = "Priya"
        var identity = Wiretuner_Account_V1_AccountIdentity()
        identity.provider = "apple"
        identity.email = "p@example.com"
        identity.emailVerified = true
        identity.linkedAt = .init(seconds: 100, nanos: 0)
        var plain = Wiretuner_Account_V1_AccountIdentity()
        plain.provider = "password"
        response.account.identities = [identity, plain]
        response.device.id = "d"
        response.device.name = "Mac"
        response.device.authMethod = "passkey"
        response.device.current = true
        response.device.lastSeenAt = .init(seconds: 200, nanos: 0)
        let profile = AccountProfile(response)
        #expect(profile.email == "p@example.com" && profile.displayName == "Priya")
        #expect(profile.identities.map(\.provider) == ["apple", "password"])
        #expect(profile.identities[0].linkedAt == Date(timeIntervalSince1970: 100) && profile.identities[1].linkedAt == nil)
        #expect(profile.identities[0].id == "apple|p@example.com")
        #expect(profile.devices == [.init(id: "d", name: "Mac", platform: "", authMethod: "passkey", lastSeenAt: Date(timeIntervalSince1970: 200), isCurrent: true)])
        var deviceless = Wiretuner_Account_V1_MeResponse()
        deviceless.account.email = "x"
        #expect(AccountProfile(deviceless).devices.isEmpty)
        var unseen = Wiretuner_Account_V1_Device()
        unseen.id = "u"
        #expect(AccountProfile.Device(unseen).lastSeenAt == nil)
        #expect(["passkey", "apple", "password", "sso:acme", "", "other"].map(AccountProfile.methodTitle) == ["Passkey", "Apple", "Password", "acme", "Unknown", "other"])
    }

    @Test func callsCarryTheMetadataAndReachTheConfiguredAPI() async {
        let metadata = CallMetadata(accessToken: "t", clientVersion: "0.1.0/1", deviceID: "d", requestID: "r")
        #expect(metadata.pairs.map(\.0) == ["authorization", "wt-client", "wt-device", "wt-request-id"])
        #expect(metadata.pairs.map(\.1) == ["Bearer t", "macos/0.1.0/1", "d", "r"])
        #expect(Array(metadata.metadata["authorization"]).count == 1)
        #expect(metadata == CallMetadata(accessToken: "t", clientVersion: "0.1.0/1", deviceID: "d", requestID: "r"))
        #expect(metadata != CallMetadata(accessToken: "u", clientVersion: "0.1.0/1", deviceID: "d", requestID: "r"))

        let plain = GRPCAccountClient(api: URL(string: "http://localhost:8080")!, clientVersion: "v", deviceID: "d")
        #expect(plain.endpoint.host == "localhost" && plain.endpoint.port == 8080 && !plain.endpoint.tls)
        let tls = GRPCAccountClient(api: URL(string: "https://api.example.com")!, clientVersion: "v", deviceID: "d")
        #expect(tls.endpoint.port == 443 && tls.endpoint.tls)
        #expect(GRPCAccountClient(api: URL(string: "http://h")!, clientVersion: "v", deviceID: "d").endpoint.port == 80)
        #expect(GRPCAccountClient(api: URL(string: "file:///x")!, clientVersion: "v", deviceID: "d").endpoint.host == "localhost")

        // Nothing listens on port 1: the call fails instead of hanging.
        let closed = GRPCAccountClient(api: URL(string: "http://127.0.0.1:1")!, clientVersion: "v", deviceID: "d")
        await #expect(throws: (any Error).self) { try await closed.me(accessToken: "t") }
    }

    @Test func deviceIdentityIsStablePerInstall() {
        let suite = "WireTunerTests.device.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = DeviceIdentity.current(defaults: defaults)
        #expect(DeviceIdentity.current(defaults: defaults) == id)
        #expect(UUID(uuidString: id) != nil)
    }

    @Test func webSessionResultsMapCancellation() throws {
        let url = URL(string: "wiretuner://auth/callback?code=c")!
        #expect(try WebAuthenticationSession.result(callback: url, error: nil).get() == url)
        let cancelled = ASWebAuthenticationSessionError(.canceledLogin)
        #expect(throws: AuthError.cancelled) { try WebAuthenticationSession.result(callback: nil, error: cancelled).get() }
        #expect(throws: URLError.self) { try WebAuthenticationSession.result(callback: nil, error: URLError(.badURL)).get() }
        #expect(throws: AuthError.invalidResponse) { try WebAuthenticationSession.result(callback: nil, error: nil).get() }
    }
}

/// A transport that answers with something other than HTTP.
struct NonHTTPTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (Data(), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
    }
}

/// A browser session that completes as soon as it starts, or refuses to start.
@MainActor
final class InstantSession: BrowserAuthenticationSession {
    let starts: Bool
    let complete: () -> Void
    init(starts: Bool, complete: @escaping () -> Void) {
        self.starts = starts
        self.complete = complete
    }
    func start() -> Bool {
        if starts { complete() }
        return starts
    }
}

@Suite struct AuthEdgeTests {
    @Test func nonHTTPAnswersAndBareCallbacksAreRejected() async {
        let service = AuthService(configuration: AuthConfiguration(), session: NonHTTPTransport(), store: InMemoryTokenStore(), authenticator: FakeWebAuthenticator(.approve(code: "c")))
        await #expect(throws: AuthError.invalidResponse) { try await service.signIn() }
        #expect(throws: AuthError.stateMismatch) { try AuthService.authorizationCode(from: URL(string: "wiretuner://auth/callback")!, expectedState: "s") }
        #expect(PKCE.randomState().count == 22)
    }

    @Test func liveDefaultsReadTheClockAndSleep() async throws {
        let stored = TokenSet(accessToken: "a", refreshToken: "r", idToken: nil, expiresAt: .distantFuture, refreshExpiresAt: nil)
        let service = AuthService(configuration: AuthConfiguration(), store: InMemoryTokenStore(stored), authenticator: FakeWebAuthenticator(.noCode))
        #expect(try await service.validAccessToken() == "a")
        await service.startAutoRefresh()
        await service.stopAutoRefresh()
        // Signed out: the loop ends at once.
        let empty = AuthService(configuration: AuthConfiguration(), store: InMemoryTokenStore(), authenticator: FakeWebAuthenticator(.noCode))
        await empty.startAutoRefresh()
        await empty.autoRefreshFinished()
        #expect(await empty.refreshCount == 0)
    }

    @Test func keychainFailuresSurfaceTheirStatus() throws {
        var calls = KeychainTokenStore.Calls()
        calls.copyMatching = { _, _ in errSecSuccess }
        calls.update = { _, _ in errSecAuthFailed }
        calls.delete = { _ in errSecInteractionNotAllowed }
        let store = KeychainTokenStore(service: "x", calls: calls)
        #expect(throws: KeychainTokenStore.Failure.status(errSecSuccess)) { try store.load() }
        let tokens = TokenSet(accessToken: "a", refreshToken: nil, idToken: nil, expiresAt: .distantFuture, refreshExpiresAt: nil)
        #expect(throws: KeychainTokenStore.Failure.status(errSecAuthFailed)) { try store.save(tokens) }
        #expect(throws: KeychainTokenStore.Failure.status(errSecInteractionNotAllowed)) { try store.delete() }
        var adding = KeychainTokenStore.Calls()
        adding.update = { _, _ in errSecItemNotFound }
        adding.add = { _, _ in errSecDuplicateItem }
        #expect(throws: KeychainTokenStore.Failure.status(errSecDuplicateItem)) { try KeychainTokenStore(service: "x", calls: adding).save(tokens) }
    }

    @Test @MainActor func browserSessionsCompleteOrCancel() async throws {
        let callback = URL(string: "wiretuner://auth/callback?code=c")!
        let approving = WebAuthenticationSession { _, _, completion in InstantSession(starts: true) { completion(callback, nil) } }
        #expect(try await approving.authenticate(url: URL(string: "http://kc/auth")!, callbackScheme: "wiretuner") == callback)
        let refusing = WebAuthenticationSession { _, _, _ in InstantSession(starts: false) {} }
        await #expect(throws: AuthError.cancelled) { try await refusing.authenticate(url: URL(string: "http://kc/auth")!, callbackScheme: "wiretuner") }
        let system = WebAuthenticationSession.systemSession(URL(string: "http://kc/auth")!, "wiretuner") { _, _ in }
        let session = try #require(system as? ASWebAuthenticationSession)
        #expect(!session.prefersEphemeralWebBrowserSession)
        _ = PresentationAnchor.shared.presentationAnchor(for: session)
        _ = WebAuthenticationSession()
    }

    @Test @MainActor func theAppBuildsItsAccountModelAndWindow() {
        let suite = TestDefaults()
        let model = LaunchEnvironment(arguments: [], environment: [:]).makeAccountModel(
            infoDictionary: ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "3"], defaults: suite.defaults
        )
        #expect((model.client as? GRPCAccountClient)?.clientVersion == "1.2/3")
        let fallback = LaunchEnvironment(arguments: [LaunchEnvironment.uiTestingArgument], environment: [:]).makeAccountModel(infoDictionary: nil, defaults: suite.defaults)
        #expect((fallback.client as? GRPCAccountClient)?.clientVersion == "0/0")
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults, account: model)
        delegate.showAccount()
        delegate.showAccount()
        #expect(delegate.accountWindowController?.window?.isVisible == true)
        delegate.accountWindowController?.close()
    }

    @Test @MainActor func accountViewActionsReachTheModel() async throws {
        let model = AccountModelTests().model()
        await AccountView.perform(.signIn(.workspace(alias: "acme")), model: model)
        #expect(model.isSignedIn)
        await AccountView.perform(.refresh, model: model)
        #expect(model.profile != nil)
        await AccountView.perform(.signOut, model: model)
        #expect(!model.isSignedIn)
        AccountView(model: model).handler(.signIn(.apple))()
        for _ in 0..<50 where !model.isSignedIn { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.isSignedIn)
        #expect(AccountView.Action.refresh != .signOut)
    }
}
