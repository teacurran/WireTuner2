import Foundation
import Security

/// The tokens of one signed-in session (security.adoc, "Tokens and transport": access 15 min,
/// refresh 30 days rotating).
struct TokenSet: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date
    var refreshExpiresAt: Date?

    /// Whether the access token expires within `leeway` of `now` (refresh it first).
    func needsRefresh(at now: Date, leeway: TimeInterval) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }

    /// The access token's claims, for display; the server validates the token itself.
    var claims: TokenClaims { TokenClaims(jwt: accessToken) }
}

/// The token endpoint's JSON (RFC 6749 §5.1 plus Keycloak's `refresh_expires_in`).
struct TokenResponse: Decodable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Double
    let refreshExpiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
        case refreshExpiresIn = "refresh_expires_in"
    }

    /// Keycloak sends `refresh_expires_in: 0` for tokens that expire with the session only.
    func tokenSet(receivedAt now: Date, keepingRefreshToken previous: String? = nil) -> TokenSet {
        TokenSet(
            accessToken: accessToken, refreshToken: refreshToken ?? previous, idToken: idToken,
            expiresAt: now.addingTimeInterval(expiresIn),
            refreshExpiresAt: refreshExpiresIn.flatMap { $0 > 0 ? now.addingTimeInterval($0) : nil }
        )
    }
}

/// The OAuth error body (`{"error": "invalid_grant", "error_description": ...}`).
struct OAuthErrorResponse: Decodable, Equatable, Sendable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// The claims the account menu shows before `AccountService.Me` answers.
struct TokenClaims: Equatable, Sendable {
    var subject: String?
    var email: String?
    var name: String?
    /// `passkey`, `apple`, `password` or `sso:<alias>` (the realm's `wt_auth_method` mapper).
    var authMethod: String?

    init(subject: String? = nil, email: String? = nil, name: String? = nil, authMethod: String? = nil) {
        self.subject = subject
        self.email = email
        self.name = name
        self.authMethod = authMethod
    }

    /// Decodes a JWT's payload without verifying it; garbage gives empty claims.
    init(jwt: String) {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2, let data = Self.base64URLDecode(String(parts[1])),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            self.init()
            return
        }
        self.init(
            subject: object["sub"] as? String, email: object["email"] as? String,
            name: (object["name"] as? String) ?? (object["preferred_username"] as? String),
            authMethod: object["wt_auth_method"] as? String
        )
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// Where tokens persist between launches.
protocol TokenStore: Sendable {
    func load() throws -> TokenSet?
    func save(_ tokens: TokenSet) throws
    func delete() throws
}

/// Tokens in memory only (tests, and UI tests that must not touch the login keychain).
final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: TokenSet?

    init(_ tokens: TokenSet? = nil) {
        self.tokens = tokens
    }

    func load() throws -> TokenSet? { lock.withLock { tokens } }
    func save(_ tokens: TokenSet) throws { lock.withLock { self.tokens = tokens } }
    func delete() throws { lock.withLock { tokens = nil } }
}

/// Tokens in the Keychain as one generic password item holding the JSON-encoded `TokenSet`
/// (security.adoc: refresh tokens are stored in the Keychain).  No access group: the item is
/// private to the app.  Accessible after first unlock so a silent refresh works while the
/// screen is locked, and never migrated to another device.
struct KeychainTokenStore: TokenStore {
    enum Failure: Error, Equatable {
        case status(OSStatus)
    }

    /// The Security framework calls, replaceable so tests reach the failure paths.
    struct Calls: Sendable {
        var copyMatching: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = { SecItemCopyMatching($0, $1) }
        var update: @Sendable (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) }
        var add: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = { SecItemAdd($0, $1) }
        var delete: @Sendable (CFDictionary) -> OSStatus = { SecItemDelete($0) }
    }

    static let defaultService = "com.villagecompute.wiretuner.auth"
    static let defaultAccount = "tokens"

    let service: String
    let account: String
    let calls: Calls

    init(service: String = KeychainTokenStore.defaultService, account: String = KeychainTokenStore.defaultAccount, calls: Calls = Calls()) {
        self.service = service
        self.account = account
        self.calls = calls
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() throws -> TokenSet? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = calls.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.status(status) }
        return try JSONDecoder().decode(TokenSet.self, from: data)
    }

    func save(_ tokens: TokenSet) throws {
        let data = try JSONEncoder().encode(tokens)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = calls.update(query as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = calls.add(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    func delete() throws {
        let status = calls.delete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
    }
}
