import Foundation
import Observation

/// The account state the menu and the account window observe, over `AuthService` and the
/// account RPCs.  Main-actor bound; every network step runs in the actor or the client.
@MainActor
@Observable
final class AccountModel {
    private(set) var state: AuthState = .signedOut
    private(set) var isBusy = false
    private(set) var profile: AccountProfile?
    private(set) var errorMessage: String?
    /// Every active device of the account (`ListDevices`, SEC-003); nil until loaded, when the
    /// window shows the calling device from `Me`.
    private(set) var devices: [AccountProfile.Device]?

    @ObservationIgnored let auth: AuthService
    @ObservationIgnored let client: AccountClient
    @ObservationIgnored let deviceClient: (any DeviceClient)?

    init(auth: AuthService, client: AccountClient, devices: (any DeviceClient)? = nil) {
        self.auth = auth
        self.client = client
        deviceClient = devices ?? client as? DeviceClient
    }

    /// The devices the window lists: the full list once loaded, else `Me`'s device.
    var shownDevices: [AccountProfile.Device] { devices ?? profile?.devices ?? [] }

    var isSignedIn: Bool { state != .signedOut }

    /// "Signed in as priya@example.com" / "Not signed in".
    var statusTitle: String {
        guard case let .signedIn(claims) = state else { return "Not signed in" }
        return "Signed in as \(profile?.email ?? claims.email ?? claims.name ?? "unknown account")"
    }

    /// Reads the stored session, follows the service's changes (a refused refresh signs out)
    /// and keeps the token fresh while signed in.
    func start(autoRefresh: Bool = true) async {
        await auth.setStateHandler { [weak self] state in
            Task { @MainActor in self?.apply(state) }
        }
        apply(await auth.state)
        if autoRefresh, isSignedIn { await auth.startAutoRefresh() }
    }

    func apply(_ state: AuthState) {
        self.state = state
        if state == .signedOut {
            profile = nil
            devices = nil
        }
    }

    func signIn(_ method: SignInMethod = .standard, autoRefresh: Bool = true) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let claims = try await auth.signIn(method: method)
            apply(.signedIn(claims))
            if autoRefresh { await auth.startAutoRefresh() }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Forgets the session; documents and local stores stay.
    func signOut() async {
        await auth.signOut()
        apply(.signedOut)
    }

    /// Fetches the identities and devices (`AccountService.Me`, then `ListDevices`).
    func loadProfile() async {
        errorMessage = nil
        do {
            let token = try await auth.validAccessToken()
            profile = try await client.me(accessToken: token)
            if let deviceClient { devices = try await deviceClient.listDevices(accessToken: token) }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Revokes another Mac (`RevokeDevice`): its token refresh fails from now on.  This Mac
    /// signs out instead.
    func revokeDevice(_ id: String) async {
        guard let deviceClient, shownDevices.contains(where: { $0.id == id && !$0.isCurrent }) else { return }
        errorMessage = nil
        do {
            _ = try await deviceClient.revokeDevice(deviceID: id, accessToken: try await auth.validAccessToken())
            devices = shownDevices.filter { $0.id != id }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    static func message(for error: any Error) -> String? {
        switch error as? AuthError {
        case .cancelled?: nil
        case .stateMismatch?: "The sign-in response did not match the request. Try again."
        case .missingCode?, .invalidResponse?: "The sign-in server sent an unexpected response."
        case let .authorization(code, description)?, let .tokenEndpoint(code, description)?: description ?? code
        case let .http(status)?: "The sign-in server answered with HTTP \(status)."
        case .notSignedIn?: "You are not signed in."
        case .sessionExpired?: "Your session has ended. Sign in again."
        case nil: error.localizedDescription
        }
    }
}
