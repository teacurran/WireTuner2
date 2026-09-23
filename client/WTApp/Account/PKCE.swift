import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636) with the S256 method, which the realm's Mac client
/// requires (`pkce.code.challenge.method = S256`).
struct PKCE: Equatable, Sendable {
    /// 43 characters of the unreserved set: 32 random bytes, base64url without padding.
    let verifier: String
    /// base64url(SHA-256(verifier)), no padding.
    let challenge: String
    static let method = "S256"

    init(verifier: String) {
        self.verifier = verifier
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A fresh verifier from `bytes` random bytes (32 gives the RFC's recommended 256 bits).
    static func generate(randomBytes: (Int) -> Data = PKCE.secureRandom) -> PKCE {
        PKCE(verifier: base64URL(randomBytes(32)))
    }

    /// An opaque value for `state` (CSRF protection on the callback).
    static func randomState(randomBytes: (Int) -> Data = PKCE.secureRandom) -> String {
        base64URL(randomBytes(16))
    }

    static func secureRandom(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
