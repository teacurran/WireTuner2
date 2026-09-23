import AppKit
import AuthenticationServices

/// The part of `ASWebAuthenticationSession` sign-in uses, so the flow around it is tested
/// with a session that completes on its own.
@MainActor
protocol BrowserAuthenticationSession: AnyObject {
    func start() -> Bool
}

extension ASWebAuthenticationSession: BrowserAuthenticationSession {}

/// The live browser sign-in: `ASWebAuthenticationSession`, not ephemeral, so the realm's
/// passkey page runs the platform authenticator and iCloud Keychain passkeys are offered
/// (security.adoc, "Passkeys").  Thin by design; everything around it is `AuthService`.
final class WebAuthenticationSession: NSObject, WebAuthenticator, @unchecked Sendable {
    typealias Completion = @Sendable (URL?, (any Error)?) -> Void
    typealias Factory = @MainActor (URL, String, @escaping Completion) -> any BrowserAuthenticationSession

    /// Makes the session; the default is the system's.
    static let systemSession: Factory = { url, scheme, completion in
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { completion($0, $1) }
        session.presentationContextProvider = PresentationAnchor.shared
        session.prefersEphemeralWebBrowserSession = false
        return session
    }

    private let makeSession: Factory
    @MainActor private var current: (any BrowserAuthenticationSession)?

    init(makeSession: @escaping Factory = WebAuthenticationSession.systemSession) {
        self.makeSession = makeSession
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let session = self.makeSession(url, callbackScheme) { callback, error in
                    Task { @MainActor in self.current = nil }
                    continuation.resume(with: Self.result(callback: callback, error: error))
                }
                self.current = session
                if !session.start() {
                    self.current = nil
                    continuation.resume(throwing: AuthError.cancelled)
                }
            }
        }
    }

    /// The session's completion as a result: the person closing the window is `.cancelled`.
    static func result(callback: URL?, error: (any Error)?) -> Result<URL, any Error> {
        if let callback { return .success(callback) }
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { return .failure(AuthError.cancelled) }
        return .failure(error ?? AuthError.invalidResponse)
    }
}

/// Presents the sign-in sheet over the key window.
@MainActor
final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = PresentationAnchor()

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow() }
    }
}
