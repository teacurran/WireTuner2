import Foundation

/// Runs the browser half of sign-in: opens `url` and returns the callback URL the realm
/// redirected to.  `WebAuthenticationSession` is the live one (`ASWebAuthenticationSession`);
/// tests answer with a callback of their own.
protocol WebAuthenticator: Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// What `AuthService` sends its token and logout requests through: `URLSession` in the app,
/// anything answering in tests.
protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: nil)
    }
}

enum AuthError: Error, Equatable, Sendable {
    /// The person closed the sign-in window.
    case cancelled
    /// The callback's `state` is not the one sent (a forged or stale redirect).
    case stateMismatch
    case missingCode
    /// The realm answered the authorization request with an OAuth error.
    case authorization(code: String, description: String?)
    /// The token endpoint refused (`invalid_client`, ...).
    case tokenEndpoint(code: String, description: String?)
    case http(status: Int)
    case invalidResponse
    case notSignedIn
    /// The refresh token was refused: the session ended (revoked device, expiry, sign-out
    /// elsewhere).  The tokens are gone; local documents are not touched.
    case sessionExpired
}

/// Whether someone is signed in, as the account menu shows it.
enum AuthState: Equatable, Sendable {
    case signedOut
    case signedIn(TokenClaims)
}

/// OIDC sign-in against the realm with PKCE, token storage and silent refresh (APP-008;
/// security.adoc, "Accounts" and "Tokens and transport").  An actor: the menu, the account
/// window and every gRPC call ask it for a valid access token concurrently, and one refresh
/// serves them all.  Signing out forgets the tokens only; documents, outboxes and local stores
/// stay on the Mac.
actor AuthService {
    /// Refresh when the access token has less than this left.
    static let refreshLeeway: TimeInterval = 60
    /// After a failed background refresh that was not a refusal (offline), try again after this.
    static let retryDelay: TimeInterval = 30

    let configuration: AuthConfiguration
    private let session: any HTTPTransport
    private let store: TokenStore
    private let authenticator: WebAuthenticator
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let randomBytes: @Sendable (Int) -> Data

    private(set) var tokens: TokenSet?
    private var refreshTask: Task<TokenSet, Error>?
    private var autoRefreshTask: Task<Void, Never>?
    private var stateHandler: (@Sendable (AuthState) -> Void)?
    private(set) var refreshCount = 0

    init(
        configuration: AuthConfiguration, session: any HTTPTransport = URLSession.shared, store: TokenStore, authenticator: WebAuthenticator,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        randomBytes: @escaping @Sendable (Int) -> Data = { PKCE.secureRandom($0) }
    ) {
        self.configuration = configuration
        self.session = session
        self.store = store
        self.authenticator = authenticator
        self.now = now
        self.sleep = sleep
        self.randomBytes = randomBytes
        tokens = try? store.load()
    }

    var state: AuthState {
        tokens.map { .signedIn($0.claims) } ?? .signedOut
    }

    /// Called on every sign-in, sign-out and session expiry.
    func setStateHandler(_ handler: (@Sendable (AuthState) -> Void)?) {
        stateHandler = handler
    }

    private func setTokens(_ tokens: TokenSet?) {
        self.tokens = tokens
        if let tokens { try? store.save(tokens) } else { try? store.delete() }
        stateHandler?(state)
    }

    // MARK: Sign-in

    /// The authorization request (RFC 6749 §4.1.1 with RFC 7636 and Keycloak's `kc_idp_hint`).
    nonisolated static func authorizationURL(configuration: AuthConfiguration, method: SignInMethod, pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: AuthConfiguration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: PKCE.method),
        ]
        if let hint = method.identityProviderHint { items.append(URLQueryItem(name: "kc_idp_hint", value: hint)) }
        components.queryItems = items
        return components.url!
    }

    /// The authorization code from the callback, after checking `state`.
    nonisolated static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw AuthError.authorization(code: error, description: value("error_description")) }
        guard value("state") == expectedState else { throw AuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw AuthError.missingCode }
        return code
    }

    /// Signs in through the browser and stores the tokens.
    @discardableResult
    func signIn(method: SignInMethod = .standard) async throws -> TokenClaims {
        let pkce = PKCE.generate(randomBytes: randomBytes)
        let state = PKCE.randomState(randomBytes: randomBytes)
        let url = Self.authorizationURL(configuration: configuration, method: method, pkce: pkce, state: state)
        let callback = try await authenticator.authenticate(url: url, callbackScheme: AuthConfiguration.callbackScheme)
        let code = try Self.authorizationCode(from: callback, expectedState: state)
        let response = try await tokenRequest([
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": configuration.redirectURI.absoluteString,
            "client_id": configuration.clientID, "code_verifier": pkce.verifier,
        ])
        let tokens = response.tokenSet(receivedAt: now())
        setTokens(tokens)
        return tokens.claims
    }

    // MARK: Tokens

    /// An access token good for at least `refreshLeeway`, refreshing first when needed.  A
    /// refresh mid-session changes nothing else: open documents keep syncing with the new
    /// token.
    func validAccessToken() async throws -> String {
        guard let tokens else { throw AuthError.notSignedIn }
        guard tokens.needsRefresh(at: now(), leeway: Self.refreshLeeway) else { return tokens.accessToken }
        return try await refresh().accessToken
    }

    /// Exchanges the refresh token; concurrent callers share one request.
    @discardableResult
    func refresh() async throws -> TokenSet {
        if let refreshTask { return try await refreshTask.value }
        guard let refreshToken = tokens?.refreshToken else { throw AuthError.notSignedIn }
        let task = Task { try await self.performRefresh(refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(_ refreshToken: String) async throws -> TokenSet {
        refreshCount += 1
        do {
            let response = try await tokenRequest([
                "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": configuration.clientID,
            ])
            let tokens = response.tokenSet(receivedAt: now(), keepingRefreshToken: refreshToken)
            setTokens(tokens)
            return tokens
        } catch AuthError.tokenEndpoint(code: "invalid_grant", _) {
            setTokens(nil)
            throw AuthError.sessionExpired
        }
    }

    /// POSTs a form to the token endpoint and decodes the answer.
    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(form)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        guard http.statusCode == 200 else {
            if let error = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data) {
                throw AuthError.tokenEndpoint(code: error.error, description: error.errorDescription)
            }
            throw AuthError.http(status: http.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else { throw AuthError.invalidResponse }
        return decoded
    }

    /// `application/x-www-form-urlencoded`, keys sorted so requests are reproducible.
    nonisolated static func formBody(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = form.keys.sorted().map { key in
            let value = form[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
            return "\(key)=\(value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    // MARK: Silent refresh

    /// How long to wait before refreshing `tokens` in the background.
    nonisolated static func delayBeforeRefresh(_ tokens: TokenSet, now: Date) -> TimeInterval {
        max(0, tokens.expiresAt.timeIntervalSince(now) - refreshLeeway)
    }

    /// Keeps the access token fresh while signed in: sleeps until a minute before expiry,
    /// refreshes, repeats.  Offline failures retry after `retryDelay`; a refused refresh
    /// (session over) or sign-out ends the loop.
    func startAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { await self.autoRefreshLoop() }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    /// Waits for the loop `startAutoRefresh` began (tests).
    func autoRefreshFinished() async {
        await autoRefreshTask?.value
    }

    private func autoRefreshLoop() async {
        var delay: TimeInterval?
        while !Task.isCancelled, let tokens {
            do {
                try await sleep(delay ?? Self.delayBeforeRefresh(tokens, now: now()))
            } catch {
                return
            }
            do {
                try await refresh()
                delay = nil
            } catch AuthError.sessionExpired {
                return
            } catch {
                delay = Self.retryDelay
            }
        }
    }

    // MARK: Sign-out

    /// Ends the session at the realm (best effort: offline sign-out still forgets the tokens)
    /// and forgets the tokens.  Local stores are kept.
    func signOut() async {
        stopAutoRefresh()
        if let refreshToken = tokens?.refreshToken {
            var request = URLRequest(url: configuration.logoutEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody(["client_id": configuration.clientID, "refresh_token": refreshToken])
            _ = try? await session.data(for: request)
        }
        setTokens(nil)
    }
}
