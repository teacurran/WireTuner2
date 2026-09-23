import Foundation

/// Where the app signs in and which server it talks to (security.adoc, "Accounts").  The
/// issuer and API URLs come from the build configuration (`WT_AUTH_ISSUER`, `WT_API_URL` in
/// `project.yml`, written into Info.plist); the defaults are the compose stack's Keycloak
/// realm (host port 8180) and API (8080).
struct AuthConfiguration: Equatable, Sendable {
    static let defaultIssuer = URL(string: "http://localhost:8180/realms/wiretuner")!
    static let defaultAPI = URL(string: "http://localhost:8080")!
    static let issuerInfoKey = "WTAuthIssuer"
    static let apiInfoKey = "WTAPIURL"
    /// The realm's public client for the Mac (`server/keycloak/wiretuner-realm.json`).
    static let clientID = "wiretuner-mac"
    static let callbackScheme = "wiretuner"
    static let redirectURI = URL(string: "wiretuner://auth/callback")!
    /// `offline_access` is not requested: the realm's 30-day rotating refresh token is an
    /// ordinary SSO-session refresh token (security.adoc, "Tokens and transport").
    static let scopes = ["openid", "profile", "email"]

    var issuer: URL
    var api: URL
    var clientID: String = AuthConfiguration.clientID
    var redirectURI: URL = AuthConfiguration.redirectURI

    init(issuer: URL = AuthConfiguration.defaultIssuer, api: URL = AuthConfiguration.defaultAPI) {
        self.issuer = issuer
        self.api = api
    }

    /// From an Info.plist dictionary; missing, empty or unexpanded (`$(WT_AUTH_ISSUER)`)
    /// values fall back to the defaults.
    init(infoDictionary: [String: Any]?) {
        func url(_ key: String) -> URL? {
            guard let text = infoDictionary?[key] as? String, !text.isEmpty, !text.hasPrefix("$("),
                let url = URL(string: text), url.scheme != nil
            else { return nil }
            return url
        }
        self.init(issuer: url(Self.issuerInfoKey) ?? Self.defaultIssuer, api: url(Self.apiInfoKey) ?? Self.defaultAPI)
    }

    /// Keycloak's OpenID Connect endpoints under the realm.
    var authorizationEndpoint: URL { issuer.appending(path: "protocol/openid-connect/auth") }
    var tokenEndpoint: URL { issuer.appending(path: "protocol/openid-connect/token") }
    var logoutEndpoint: URL { issuer.appending(path: "protocol/openid-connect/logout") }
}

/// Which entry point the person chose (security.adoc, "Accounts").  Keycloak's page offers
/// passkeys first, then the providers; a provider entry skips the page with `kc_idp_hint`.
enum SignInMethod: Equatable, Sendable {
    /// The realm's sign-in page: passkey first, then Apple, workspace SSO and password.
    case standard
    /// Straight to Sign in with Apple (the realm's `apple` identity provider).
    case apple
    /// Straight to a company workspace's identity provider, by its Keycloak alias.
    case workspace(alias: String)

    static let appleAlias = "apple"

    var identityProviderHint: String? {
        switch self {
        case .standard: nil
        case .apple: Self.appleAlias
        case let .workspace(alias): alias
        }
    }
}
